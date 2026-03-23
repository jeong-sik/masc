const __vite__mapDeps=(i,m=__vite__mapDeps,d=(m.f||(m.f=["assets/governance-QqcN6gK6.js","assets/vendor-Chwn_OlE.js","assets/filter-chips-Cu5kYIK3.js","assets/input-DWPrIiMN.js","assets/feedback-state-DiW1_ueY.js","assets/tools-BBi1aIXn.js","assets/activity-graph-EaoTpPzs.js","assets/status-B0VmVlgi.js","assets/shared-ajMFPXbw.js","assets/status-chip-B-Vgmq3f.js","assets/stat-tile-Dyk_8z2I.js","assets/work-CDL_cOy_.js","assets/helpers-Bd2DyH_v.js","assets/control-ChBArxyb.js","assets/lab-unified-CkqmzGH4.js","assets/logs-CZL9xhtx.js"])))=>i.map(i=>d[i]);
var zr=Object.defineProperty;var Or=(e,t,n)=>t in e?zr(e,t,{enumerable:!0,configurable:!0,writable:!0,value:n}):e[t]=n;var Ce=(e,t,n)=>Or(e,typeof t!="symbol"?t+"":t,n);import{e as Ir,_ as Yt,c as m,b as ie,x as et,l as B,k as qa,H as Nn,A as Lr,y as ke,d as We,G as Mr}from"./vendor-Chwn_OlE.js";(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const r of s)if(r.type==="childList")for(const l of r.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&a(l)}).observe(document,{childList:!0,subtree:!0});function n(s){const r={};return s.integrity&&(r.integrity=s.integrity),s.referrerPolicy&&(r.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?r.credentials="include":s.crossOrigin==="anonymous"?r.credentials="omit":r.credentials="same-origin",r}function a(s){if(s.ep)return;s.ep=!0;const r=n(s);fetch(s.href,r)}})();var c=Ir.bind(Yt);const jr=["overview","monitoring","command","workspace","lab","logs"],ts={home:{tab:"overview"},status:{tab:"monitoring",params:{section:"sessions"}},work:{tab:"workspace",params:{section:"board"}},operations:{tab:"command",params:{section:"intervene"}},situation:{tab:"monitoring",params:{section:"sessions"}},agents:{tab:"monitoring",params:{section:"agents"}},activity:{tab:"monitoring",params:{section:"activity"}},control:{tab:"command",params:{section:"intervene"}},mission:{tab:"monitoring",params:{section:"sessions"}},"agent-roster":{tab:"monitoring",params:{section:"agents"}},execution:{tab:"monitoring",params:{section:"sessions"}},"keeper-roster":{tab:"monitoring",params:{section:"agents"}},live:{tab:"monitoring",params:{section:"activity"}},social:{tab:"monitoring",params:{section:"activity"}},proof:{tab:"workspace",params:{section:"evidence"}},memory:{tab:"workspace",params:{section:"board"}},governance:{tab:"command",params:{section:"governance"}},planning:{tab:"workspace",params:{section:"planning"}},tools:{tab:"lab",params:{section:"tools"}},intervene:{tab:"command",params:{section:"intervene"}}},Dr=new Set(["warroom","summary","orchestra","swarm","operations","topology","alerts","trace","chains","control"]),oa=[{id:"overview",label:"오버뷰",icon:"🏠",description:"빠른 신호 및 브리핑 통합 화면",defaultTab:"overview",tabs:["overview"]},{id:"monitoring",label:"모니터링",icon:"📡",description:"세션 룸 및 에이전트/키퍼 현황 관찰",defaultTab:"monitoring",defaultParams:{section:"sessions"},tabs:["monitoring"]},{id:"command",label:"지휘 통제",icon:"🎛️",description:"실시간 개입, 워룸, 거버넌스 제어",defaultTab:"command",defaultParams:{section:"intervene"},tabs:["command"]},{id:"workspace",label:"작업",icon:"📋",description:"작업 게시판, 근거 및 계획 이력 탐색",defaultTab:"workspace",defaultParams:{section:"board"},tabs:["workspace"]},{id:"lab",label:"실험실",icon:"🧪",description:"시스템 도구 테스트 및 TRPG 실험",defaultTab:"lab",defaultParams:{section:"tools"},tabs:["lab"]},{id:"logs",label:"로그",icon:"📜",description:"시스템 실행 로그",defaultTab:"logs",tabs:["logs"]}],Nr=oa.map(e=>({id:e.id,label:e.label,icon:e.icon,description:e.description,defaultParams:e.defaultParams})),ns={monitoring:[{id:"sessions",label:"세션 & 룸",description:"진행 중인 세션과 룸 현황을 봅니다.",params:{section:"sessions"}},{id:"agents",label:"에이전트 & 키퍼",description:"로스터 및 활성 에이전트 상태를 탐색합니다.",params:{section:"agents"}},{id:"activity",label:"활동 그래프",description:"실시간 이벤트 흐름을 봅니다.",params:{section:"activity"}}],command:[{id:"intervene",label:"실시간 개입",description:"방, 세션, 키퍼에 바로 개입합니다.",params:{section:"intervene"}},{id:"warroom",label:"워룸 & 스웜",description:"워룸 상황판과 오케스트라 지휘면입니다.",params:{section:"warroom"}},{id:"governance",label:"거버넌스",description:"의사결정 기록 및 판결 흐름 제어입니다.",params:{section:"governance"}}],workspace:[{id:"board",label:"작업 게시판",description:"팀 대화와 지식 공유를 봅니다.",params:{section:"board"}},{id:"evidence",label:"근거 및 이력",description:"작업 증거와 검증 결과를 봅니다.",params:{section:"evidence"}},{id:"planning",label:"계획 및 메트릭",description:"장기 목표와 루프를 봅니다.",params:{section:"planning"}},{id:"worktrees",label:"워크트리",description:"현재 활성화된 작업 공간입니다.",params:{section:"worktrees"}}],lab:[{id:"tools",label:"도구 & 실험",description:"도구 인벤토리와 기타 실험을 진행합니다.",params:{section:"tools"}},{id:"trpg",label:"TRPG",description:"TRPG 실험 기능을 분리해 둔 화면입니다.",params:{section:"trpg"}},{id:"avatars",label:"아바타",description:"아바타 갤러리와 표현 실험을 봅니다.",params:{section:"avatars"}}]};function qr(e){return ns[e].map(t=>t.id)}function Fr(e){var t;return((t=oa.find(n=>n.id===e))==null?void 0:t.defaultParams)??{}}function as(e){return e==="overview"||e==="logs"?[]:ns[e]}function q(e,t){const n={...t};return e==="overview"||e==="logs"?(delete n.section,delete n.surface,n):(qr(e).includes(n.section)||(n.section=Fr(e).section??""),e==="command"&&n.section==="warroom"?n.surface&&!Dr.has(n.surface)&&delete n.surface:delete n.surface,n)}function os(e){if(e.tab==="overview"||e.tab==="logs")return null;const t=q(e.tab,e.params);return as(e.tab).find(n=>n.params.section===t.section)??null}const ss={tab:"overview",params:{},postId:null},Br=new Set(["warroom","summary","orchestra","swarm","operations","topology","alerts","trace","chains","control"]),Kr=new Set(["overview","trpg","avatars"]);function Ur(e){return!!e&&jr.includes(e)}function Fa(e){if(!e)return null;if(Ur(e))return{tab:e};const t=ts[e];return t?{tab:t.tab,params:t.params}:null}function vt(e){try{return decodeURIComponent(e)}catch{return e}}function qn(e){const t={};return e&&new URLSearchParams(e).forEach((a,s)=>{t[s]=a}),t}function Hr(e){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function rs(e,t){if(e[0]==="chains"){const l={...t,section:"command",surface:"chains"};return e[1]==="operation"&&e[2]&&(l.operation=vt(e[2])),{tab:"command",params:q("command",l),postId:null}}if(e[0]==="lab"){if(e[1]){const d=vt(e[1]),_={...t};return Kr.has(d)?(_.section=d,{tab:"lab",params:q("lab",_),postId:null}):(_.section="command",_.surface=d,{tab:"command",params:q("command",_),postId:null})}if(t.surface){const d={...t};return t.surface==="trpg"||t.surface==="avatars"?(d.section=t.surface,{tab:"lab",params:q("lab",d),postId:null}):(d.section="command",{tab:"command",params:q("command",d),postId:null})}if(!t.section&&!t.surface)return{tab:"command",params:q("command",{...t,section:"command"}),postId:null};const l={...t};return{tab:"lab",params:q("lab",l),postId:null}}if((e[0]==="operations"||e[0]==="command")&&e[1]){const l={...t},d=vt(e[1]);return d==="intervene"||d==="command"||d==="tools"?l.section=d:Br.has(d)&&(l.section="command",l.surface=d),{tab:"command",params:q("command",l),postId:null}}if((e[0]==="status"||e[0]==="monitoring"||e[0]==="work"||e[0]==="workspace")&&e[1]){const l=e[0],d=l==="status"?"monitoring":l==="work"?"workspace":l,_={...t,section:vt(e[1])};return{tab:d,params:q(d,_),postId:null}}const n=e[0],a=t.tab;if((n==="lab"||a==="lab")&&t.surface&&!t.section){const l={...t,section:"command"};return t.surface==="trpg"||t.surface==="avatars"?(l.section=t.surface,{tab:"lab",params:q("lab",l),postId:null}):{tab:"command",params:q("command",l),postId:null}}const s=Fa(n)||Fa(a)||{tab:"overview"},r=q(s.tab,{...t,...s.params??{}});return{tab:s.tab,params:r,postId:null}}function Qt(e){const t=(e||"").replace(/^#/,"").trim();if(!t)return ss;const n=vt(t);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const d=n.indexOf("?");d>=0&&(a=n.slice(0,d),s=n.slice(d+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const r=qn(s),l=Hr(a);return rs(l,r)}function Gr(e,t){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...ss,params:qn(t.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits")return null;const s=qn(t.replace(/^\?/,""));return rs(a,s)}function Zt(e){const t=e.tab,n=Object.entries(e.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${t}`;const a=new URLSearchParams(n);return`#${t}?${a.toString()}`}const E=m(Qt(window.location.hash));window.addEventListener("hashchange",()=>{const e=Qt(window.location.hash);E.value=e;const t=Zt(e);window.location.hash!==t&&window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${t}`)});function J(e,t){const n=ts[e],a=n?n.tab:e,s=n!=null&&n.params?{...n.params,...t??{}}:t??{},r={tab:a,params:q(a,s),postId:null},l=Zt(r);E.value=r,window.location.hash!==l&&(window.location.hash=l)}function _f(e){window.location.hash=`#workspace?section=board&post=${encodeURIComponent(e)}`}function Wr(){if(window.location.hash&&window.location.hash!=="#"){E.value=Qt(window.location.hash);const t=Zt(E.value);window.location.hash!==t&&window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${t}`);return}const e=Gr(window.location.pathname,window.location.search);if(e){E.value=e;const t=Zt(e);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${t}`);return}window.location.hash="#overview",E.value=Qt(window.location.hash)}function sa(){return new URLSearchParams(window.location.search)}const Jr="masc_dashboard_agent_name";function is(){var e;try{return((e=localStorage.getItem(Jr))==null?void 0:e.trim())||null}catch{return null}}function Vr(){var t,n;const e=sa();return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||is()||"dashboard"}function ls(){const e=sa(),t={},n=e.get("token"),a=is(),s=e.get("agent")??e.get("agent_name")??a;return n&&(t.Authorization=`Bearer ${n}`),s&&(t["X-MASC-Agent"]=encodeURIComponent(s)),t}function cs(){return{...ls(),"Content-Type":"application/json"}}const Xr=35e3,ra=3e4,Yr=6e4,Qr=3e4,Ba=new Set([408,425,429,500,502,503,504]);class Rt extends Error{constructor(n){const a=n.method.toUpperCase(),s=n.timeout===!0,r=s?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(r);Ce(this,"method");Ce(this,"path");Ce(this,"status");Ce(this,"statusText");Ce(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=s}}async function De(e,t,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(e,{...t,signal:a.signal})}catch(r){if(r instanceof Error&&r.name==="AbortError"){const l=typeof t.method=="string"?t.method.toUpperCase():"GET";throw new Rt({method:l,path:e,timeout:!0,timeoutMs:n})}throw r}finally{clearTimeout(s)}}function Zr(){var t,n;const e=sa();return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function P(e,t={}){const n=await De(e,{headers:ls()},t.timeoutMs??Xr);if(!n.ok)throw new Rt({method:"GET",path:e,status:n.status,statusText:n.statusText});return n.json()}function wr(e){return new Promise(t=>setTimeout(t,e))}function ei(e){const t=e.match(/\b(\d{3})\b/);if(!t)return null;const n=t[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function ti(e){if(e instanceof Rt)return e.timeout||typeof e.status=="number"&&Ba.has(e.status);if(!(e instanceof Error))return!1;if(/timeout after \d+ms/i.test(e.message)||e instanceof TypeError&&/failed to fetch|networkerror|load failed/i.test(e.message))return!0;const t=ei(e.message);return t!==null&&Ba.has(t)}async function us(e,t,n=2){let a=0;for(;;)try{return await t()}catch(s){if(!ti(s)||a>=n)throw s;const r=250*(a+1);console.warn(`[dashboard/api] ${e} failed (attempt ${a+1}), retrying in ${r}ms`,s),await wr(r),a+=1}}async function st(e,t,n,a=ra){const s=await De(e,{method:"POST",headers:{...cs()},body:JSON.stringify(t)},a);if(!s.ok)throw new Rt({method:"POST",path:e,status:s.status,statusText:s.statusText});return s.json()}async function ni(e,t,n,a=ra){const s=await De(e,{method:"POST",headers:{...cs()},body:JSON.stringify(t)},a);if(!s.ok)throw new Rt({method:"PATCH",path:e,status:s.status,statusText:s.statusText});return s.json()}function ai(e){switch(e.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"social_sweep":return 45e3;default:return ra}}function zt(e){return st("/api/v1/operator/action",e,void 0,ai(e))}function oi(e,t,n="confirm"){return st("/api/v1/operator/confirm",{actor:e,confirm_token:t,decision:n})}function si(){return P("/api/v1/operator")}function ds(e={}){const t=new URLSearchParams;e.targetType&&t.set("target_type",e.targetType),e.targetId&&t.set("target_id",e.targetId),e.includeWorkers!=null&&t.set("include_workers",e.includeWorkers?"true":"false");const n=t.toString();return P(`/api/v1/operator/digest${n?`?${n}`:""}`)}let Je=null,ut=null;function _s(e){const t={"Content-Type":"application/json",Accept:"application/json"};return Je&&(t["Mcp-Session-Id"]=Je),t}async function ri(e,t=Yr){const n=await De("/mcp",{method:"POST",headers:_s(),body:JSON.stringify(e)},t),a=n.headers.get("Mcp-Session-Id");if(a&&(Je=a),!n.ok)throw new Error(`POST /mcp: ${n.status} ${n.statusText}`);return n.text()}async function ii(){if(!Je)return ut||(ut=(async()=>{try{const t=(await De("/mcp",{method:"POST",headers:{"Content-Type":"application/json",Accept:"application/json"},body:JSON.stringify({jsonrpc:"2.0",method:"initialize",params:{protocolVersion:"2025-03-26",capabilities:{},clientInfo:{name:"masc-dashboard",version:"1.0.0"}},id:0})},1e4)).headers.get("Mcp-Session-Id");t&&(Je=t),Je&&await De("/mcp",{method:"POST",headers:_s(),body:JSON.stringify({jsonrpc:"2.0",method:"notifications/initialized"})},5e3).catch(()=>{})}finally{ut=null}})(),ut)}function li(e){const t=e.split(`
`).find(a=>a.startsWith("data: ")),n=t?t.slice(6).trim():e.trim();return JSON.parse(n)}function ci(e){var t,n,a,s,r,l,d;if((t=e.error)!=null&&t.message)throw new Error(e.error.message);if((n=e.result)!=null&&n.isError){const _=((s=(a=e.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(_)}return((d=(l=(r=e.result)==null?void 0:r.content)==null?void 0:l[0])==null?void 0:d.text)??""}async function W(e,t){await ii();const n=await ri({jsonrpc:"2.0",method:"tools/call",params:{name:e,arguments:t},id:Math.floor(Date.now()%1e6)}),a=li(n);return ci(a)}function xn(e){const t=e.trim();return t?JSON.parse(t):{}}async function mf(e){return xn(await W("masc_autoresearch_status",{loop_id:e}))}async function pf(e,t){return xn(await W("masc_autoresearch_inject",{loop_id:e,hypothesis:t}))}async function ff(e){return xn(await W("masc_autoresearch_cycle",{loop_id:e}))}async function vf(e,t){return xn(await W("masc_autoresearch_stop",{loop_id:e,reason:t}))}function u(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function o(e){return typeof e=="string"&&e.trim()!==""?e.trim():void 0}function i(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function k(e){return typeof e=="boolean"?e:void 0}function C(e){return Array.isArray(e)?e.map(t=>typeof t=="string"?t.trim():"").filter(Boolean):[]}function S(e,t=[]){if(Array.isArray(e))return e;if(!u(e))return[];for(const n of t){const a=e[n];if(Array.isArray(a))return a}return[]}function ce(e){if(typeof e=="string"&&e.trim()!=="")return e;if(!(typeof e!="number"||!Number.isFinite(e)||e<=0))return new Date(e*1e3).toISOString()}const wt="[STATE]",Fn="[/STATE]";function ui(e){const t=e.indexOf(wt);if(t<0)return null;const n=t+wt.length,a=e.indexOf(Fn,n);return a<0?null:e.slice(n,a).trim()||null}function di(e){let t=e;for(;;){const n=t.indexOf(wt);if(n<0)return t;const a=t.indexOf(Fn,n+wt.length);if(a<0)return t.slice(0,n);t=`${t.slice(0,n)}${t.slice(a+Fn.length)}`}}function _i(e){return e.split(`
`).filter(t=>!t.trim().startsWith("SKILL")).join(`
`)}function yn(e){const t=_i(e);return di(t).replace(/\n{3,}/g,`

`).trim()}function ms(e){const t=(()=>{if(!u(e))return null;const r=e.raw_payload;return u(r)?r:e})();if(!t)return null;const n=o(t.reply)??"",a=n?ui(n):null,s=u(t.usage)?{inputTokens:i(t.usage.input_tokens)??null,outputTokens:i(t.usage.output_tokens)??null,totalTokens:i(t.usage.total_tokens)??null}:null;return{traceId:o(t.trace_id)??null,generation:i(t.generation)??null,modelUsed:o(t.model_used)??null,latencyMs:i(t.latency_ms)??null,costUsd:i(t.cost_usd)??null,usage:s,skillPrimary:o(t.skill_primary)??null,skillReason:o(t.skill_reason)??null,stateBlock:a,replyText:n||null,rawPayload:t}}async function mi(e,t,n){const a={message:t},s=await zt({actor:Vr(),action_type:"keeper_message",target_type:"keeper",target_id:e,payload:a}),r=u(s.result)?s.result:null,l=r&&typeof r.reply=="string"?r.reply:"",d=r&&u(r.result)?r.result:r,_=ms(d);return{text:yn(l||"(empty reply)"),details:_}}async function pi(e,t,n){return mi(e,t)}function fi(){const e=new URLSearchParams(window.location.search),t={"Content-Type":"application/json"},n=e.get("token"),a=(()=>{var r;try{return((r=localStorage.getItem("masc_dashboard_agent_name"))==null?void 0:r.trim())||null}catch{return null}})(),s=e.get("agent")??e.get("agent_name")??a;return n&&(t.Authorization=`Bearer ${n}`),s&&(t["X-MASC-Agent"]=encodeURIComponent(s)),t}function vi(e){const t=e.replace(/\r\n/g,`
`),n=[];let a=0;for(;;){const s=t.indexOf(`

`,a);if(s<0)return{frames:n,rest:t.slice(a)};n.push(t.slice(a,s)),a=s+2}}function Ka(e){const t=e.split(`
`).filter(n=>n.startsWith("data:")).map(n=>n.slice(5).trimStart());if(t.length===0)return null;try{return JSON.parse(t.join(`
`))}catch{return null}}function gi(e){return e.type==="RUN_FINISHED"||e.type==="RUN_ERROR"}async function bi(e,t,n,{signal:a,onEvent:s}){var p;const r=await fetch("/api/v1/keepers/chat/stream",{method:"POST",headers:{...fi(),Accept:"text/event-stream"},body:JSON.stringify({name:e,message:t}),signal:a});if(!r.ok){const f=await r.text();let h=f||`Streaming request failed (${r.status})`;try{const v=JSON.parse(f);h=((p=v.error)==null?void 0:p.message)??v.message??h}catch{}throw new Error(h)}if(!r.body)throw new Error("Streaming response body is unavailable");const l=r.body.getReader(),d=new TextDecoder;let _="";try{for(;;){const{done:h,value:v}=await l.read();_+=d.decode(v??new Uint8Array,{stream:!h});const{frames:b,rest:A}=vi(_);_=A;for(const g of b){const y=Ka(g);if(y&&(s(y),gi(y))){try{await l.cancel()}catch{}return}}if(h)break}const f=_.trim();if(f){const h=Ka(f);h&&s(h)}}finally{l.releaseLock()}}function x(e,t=""){return typeof e=="string"?e:t}function L(e,t=0){return typeof e=="number"&&Number.isFinite(e)?e:t}function N(e){if(typeof e=="number"&&Number.isFinite(e))return Math.trunc(e);if(typeof e!="string")return;const t=Number.parseInt(e.trim(),10);return Number.isFinite(t)?t:void 0}function ps(e,t=!1){return typeof e=="boolean"?e:t}function se(e){return Array.isArray(e)?e.map(t=>typeof t=="string"?t.trim():u(t)?x(t.name,"").trim()||x(t.id,"").trim()||x(t.skill,"").trim():"").filter(t=>t.length>0):[]}function hi(e,t){if(e==="dm"||e==="player"||e==="npc")return e;const n=t.trim().toLowerCase();return n==="dm"||n.startsWith("dm-")?"dm":n.startsWith("p")||n.startsWith("player-")?"player":"npc"}function xi(e){return{hp:L(e.hp,0),max_hp:L(e.max_hp,0),mp:L(e.mp,0),max_mp:L(e.max_mp,0),level:L(e.level,1),xp:L(e.xp,0),strength:L(e.strength??e.str,0),dexterity:L(e.dexterity??e.dex,0),constitution:L(e.constitution??e.con,0),intelligence:L(e.intelligence??e.int,0),wisdom:L(e.wisdom??e.wis,0),charisma:L(e.charisma??e.cha,0)}}function yi(e,t,n){const a=u(t)?t:{};return{id:e,name:x(a.name,e),role:hi(a.role,e),keeper:typeof n=="string"&&n.trim()?n:void 0,archetype:x(a.archetype,"")||void 0,persona:x(a.persona,"")||void 0,portrait:x(a.portrait,"")||void 0,background:x(a.background,"")||void 0,traits:se(a.traits),skills:se(a.skills),stats:xi(a),status:ps(a.alive,!0)?"active":"down"}}function $i(e,t){return x(t.summary,"")||x(t.reply,"")||x(t.content,"")||x(t.text,"")||e}function ki(e,t){const n=u(e)?e:{},a=u(n.payload)?n.payload:{},s=x(n.actor_id,"").trim()||x(a.actor_id,"").trim(),r=x(n.actor_name,"").trim()||x(a.actor_name,"").trim()||t.get(s)||"",l=x(n.type,"event");return{type:l,actor:r||s||void 0,actor_id:s||void 0,actor_name:r||void 0,seq:N(n.seq),room_id:x(n.room_id,"")||void 0,phase:x(n.phase,"")||x(a.phase,"")||void 0,category:x(n.category,"")||void 0,visibility:x(n.visibility,"")||x(a.visibility,"")||void 0,event_id:x(n.event_id,"")||void 0,content:$i(l,a),timestamp:x(n.ts,"")||x(n.timestamp,"")||void 0}}function Si(e){const t=u(e)?e:{},n=x(t.result??t.outcome,"").trim().toLowerCase();if(!(n!=="victory"&&n!=="defeat"&&n!=="draw"))return{result:n,reason:x(t.reason,"")||void 0,summary:x(t.summary,"")||void 0,turn:N(t.turn),phase:x(t.phase,"")||void 0}}function Ai(e){const t=u(e)?e:{};if(Object.keys(t).length!==0)return{phase_open:ps(t.phase_open,!1),min_points:L(t.min_points,0),window:x(t.window,""),last_opened_turn:N(t.last_opened_turn)??null,last_closed_turn:N(t.last_closed_turn)??null}}function Ti(e){return u(e)?Object.entries(e).map(([t,n])=>{const a=u(n)?n:{};return{actor_id:t,score:L(a.score,0),last_reason:x(a.last_reason,"")||null,reasons:se(a.reasons)}}):[]}function Ci(e,t,n){const a=x(e.room_id,"")||n||"default",s=u(e.state)?e.state:{},r=u(s.party)?s.party:{},l=u(s.actor_control)?s.actor_control:{},d=Object.entries(r).map(([v,b])=>yi(v,b,l[v])),_=new Map(d.map(v=>[v.id,v.name])),p=t.map(v=>ki(v,_)),f=(()=>{var b;const v=u(s.current_round)?s.current_round:{};if(!(Object.keys(v).length===0&&p.length===0))return{round_number:N(v.round_number??v.round)??0,phase:x(v.phase,"")||x(s.phase,"")||"round",events:p,timestamp:x(v.timestamp,"")||((b=p[p.length-1])==null?void 0:b.timestamp)||new Date().toISOString()}})();return{session:{id:x(s.session_id,"")||a,room:a,status:(()=>{const v=x(s.status,"active");return v==="paused"||v==="ended"?v:"active"})(),round:(f==null?void 0:f.round_number)??0,actors:d,created_at:x(s.created_at,"")||new Date().toISOString()},current_round:f,map:x(s.map,"")||void 0,join_gate:Ai(s.join_gate),contribution_ledger:Ti(s.contribution_ledger),outcome:Si(s.session_outcome),party:d,story_log:p,history:[]}}function fs(e){return e instanceof Error&&"status"in e&&e.status===404}async function Ei(e){const t=`?room_id=${encodeURIComponent(e)}`;try{const n=await P(`/api/v1/trpg/events${t}`);return Array.isArray(n.events)?n.events:[]}catch(n){if(fs(n))return[];throw n}}async function Pi(e){const t=`?room_id=${encodeURIComponent(e)}`,[n,a]=await Promise.all([P(`/api/v1/trpg/state${t}`).catch(s=>{if(fs(s))return{room_id:e};throw s}),Ei(e)]);return Ci(n,a,e)}function Ht(e){if(typeof e=="string"&&e.trim())return e;if(typeof e!="number"||Number.isNaN(e))return null;const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}function M(e){if(typeof e=="string"){const t=e.trim();return t||null}if(typeof e=="number"&&Number.isFinite(e)){const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}return null}function $(e){if(typeof e!="string")return null;const t=e.trim();return t||null}function vs(e){if(!u(e))return null;const t=x(e.confirm_token??e.token,"").trim();return t?{confirm_token:t,actor:$(e.actor)??void 0,action_type:$(e.action_type)??void 0,target_type:$(e.target_type)??void 0,target_id:$(e.target_id),delegated_tool:$(e.delegated_tool)??void 0,created_at:M(e.created_at)??void 0,preview:e.preview}:null}function Ri(e){return u(e)?{board_post_id:$(e.board_post_id),task_id:$(e.task_id),operation_id:$(e.operation_id),team_session_id:$(e.team_session_id)}:{}}function ia(e){if(!u(e))return null;const t=$(e.action_kind),n=$(e.resolved_tool),a=$(e.target_type),s=$(e.target_id),r=$(e.reason);return!t&&!n&&!a&&!r?null:{action_kind:t??void 0,resolved_tool:n,target_type:a,target_id:s,reason:r??void 0,payload_preview:e.payload_preview}}function gs(e){if(!u(e))return null;const t=$(e.action_type),n=$(e.delegated_tool),a=$(e.confirmation_state),s=M(e.created_at);return!t&&!n&&!a&&!s?null:{action_type:t??void 0,delegated_tool:n,confirmation_state:a??void 0,created_at:s}}function bs(e){if(!u(e))return null;const t=vs(e.pending_confirm),n=$(e.pending_confirm_token)??(t==null?void 0:t.confirm_token)??null;return{requires_human_gate:typeof e.requires_human_gate=="boolean"?e.requires_human_gate:void 0,pending_confirm:t,pending_confirm_token:n,ready_to_execute:typeof e.ready_to_execute=="boolean"?e.ready_to_execute:void 0}}function zi(e){if(!u(e))return null;const t=$(e.summary),n=$(e.target_id);return!t&&!n?null:{judgment_id:$(e.judgment_id)??void 0,target_kind:$(e.target_kind)??void 0,target_id:n??void 0,status:$(e.status)??void 0,summary:t??void 0,confidence:typeof e.confidence=="number"?e.confidence:null,generated_at:M(e.generated_at),expires_at:M(e.expires_at),model_used:$(e.model_used),keeper_name:$(e.keeper_name),evidence_refs:se(e.evidence_refs),recommended_action:ia(e.recommended_action),guardrail_state:bs(e.guardrail_state),executed_route:gs(e.executed_route)}}function Oi(e){if(!u(e))return null;const t=x(e.id,"").trim(),n=x(e.topic??e.title,"").trim();if(!t||!n)return null;const a=Ri(e.context);return{kind:x(e.kind,"case"),id:t,topic:n,status:x(e.status??e.state,"open"),origin:$(e.origin),subject_type:$(e.subject_type),risk_class:$(e.risk_class),provenance:$(e.provenance),auto_execution_state:$(e.auto_execution_state),petition_count:N(e.petition_count),brief_count:N(e.brief_count),last_activity_at:M(e.last_activity_at),truth_summary:$(e.truth_summary)??void 0,judgment_summary:$(e.judgment_summary),confidence:typeof e.confidence=="number"?e.confidence:null,related_agents:se(e.related_agents),context:a,linked_board_post_id:$(e.linked_board_post_id)??a.board_post_id??null,linked_task_id:$(e.linked_task_id)??a.task_id??null,linked_operation_id:$(e.linked_operation_id)??a.operation_id??null,linked_session_id:$(e.linked_session_id)??a.team_session_id??null,recommended_action:ia(e.recommended_action),executed_route:gs(e.executed_route),guardrail_state:bs(e.guardrail_state),evidence_refs:se(e.evidence_refs)}}function Ii(e){if(!u(e))return null;const t=x(e.id,"").trim(),n=x(e.author,"").trim(),a=x(e.summary,"").trim();return!t||!n||!a?null:{id:t,author:n,stance:x(e.stance,"support"),summary:a,evidence_refs:se(e.evidence_refs),created_at:M(e.created_at)}}function hs(e){if(!u(e))return null;const t=x(e.id,"").trim(),n=x(e.case_id,"").trim();return!t||!n?null:{id:t,case_id:n,status:x(e.status,"blocked"),risk_class:$(e.risk_class),action_request:ia(e.action_request),created_at:M(e.created_at),updated_at:M(e.updated_at),execution_ref:$(e.execution_ref),result_summary:$(e.result_summary),actor:$(e.actor)}}function la(e){if(!u(e)||!u(e.case))return null;const t=e.case,n=x(t.id,"").trim(),a=x(t.title,"").trim();return!n||!a?null:{case:{id:n,petition_ids:se(t.petition_ids),title:a,origin:$(t.origin),subject_type:$(t.subject_type),risk_class:$(t.risk_class),status:x(t.status,"pending_ruling"),created_at:M(t.created_at),updated_at:M(t.updated_at),source_refs:se(t.source_refs),briefs:Array.isArray(t.briefs)?t.briefs.map(s=>Ii(s)).filter(s=>s!==null):[]},petitions:Array.isArray(e.petitions)?e.petitions.flatMap(s=>{if(!u(s))return[];const r=x(s.id,"").trim(),l=x(s.case_id,"").trim(),d=x(s.title,"").trim();return!r||!l||!d?[]:[{id:r,case_id:l,title:d,origin:$(s.origin),subject_type:$(s.subject_type),risk_class:$(s.risk_class),source_refs:se(s.source_refs),created_by:$(s.created_by),created_at:M(s.created_at)}]}):[],ruling:zi(e.ruling),execution_order:hs(e.execution_order)}}function Li(e){if(!u(e))return null;const t=x(e.kind,"").trim();return t?{kind:t,item_kind:$(e.item_kind)??void 0,item_id:$(e.item_id)??void 0,topic:$(e.topic)??void 0,created_at:M(e.created_at),summary:$(e.summary)??void 0,actor:$(e.actor),index:N(e.index),decision:$(e.decision)}:null}function Mi(e){if(u(e))return{judge_online:typeof e.judge_online=="boolean"?e.judge_online:void 0,refreshing:typeof e.refreshing=="boolean"?e.refreshing:void 0,generated_at:M(e.generated_at),expires_at:M(e.expires_at),model_used:$(e.model_used),keeper_name:$(e.keeper_name),last_error:$(e.last_error)}}function ji(e){var s;const t=e.trim(),a=((s=(t.startsWith("[flair:")?t.replace(/^\[flair:[^\]]+\]\s*/i,""):t).split(`
`)[0])==null?void 0:s.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function Di(e){if(!u(e))return null;const t=x(e.source,"").trim()||null,n=x(e.state_block,"").trim()||null;return!t&&!n?null:{source:t,state_block:n}}function Ni(e){if(!u(e))return null;const t=x(e.id,"").trim(),n=x(e.author,"").trim(),a=x(e.body,"").trim()||x(e.content,"").trim(),s=a;if(!t||!n)return null;const r=L(e.score,0),l=L(e.votes_up,0),d=L(e.votes_down,0),_=L(e.votes,r||l-d),p=L(e.comment_count,L(e.reply_count,0)),f=(()=>{const y=e.flair;if(typeof y=="string"&&y.trim())return y.trim();if(u(y)){const T=x(y.name,"").trim();if(T)return T}return x(e.flair_name,"").trim()||void 0})(),h=x(e.created_at_iso,"").trim()||Ht(e.created_at),v=x(e.updated_at_iso,"").trim()||(e.updated_at!==void 0?Ht(e.updated_at):h),A=x(e.title,"").trim()||ji(a),g=Array.isArray(e.tags)?e.tags.filter(y=>typeof y=="string"&&y.trim()!==""):[];return{id:t,author:n,post_kind:(()=>{const y=x(e.post_kind,"").trim().toLowerCase();return y==="automation"||y==="system"||y==="human"?y:void 0})(),title:A,body:a,content:s,meta:Di(e.meta),tags:g,votes:_,vote_balance:r,comment_count:p,created_at:h??"",updated_at:v??"",flair:f,hearth:x(e.hearth,"").trim()||null,visibility:x(e.visibility,"").trim()||void 0,expires_at:x(e.expires_at_iso,"").trim()||(e.expires_at!==void 0&&e.expires_at!==0?Ht(e.expires_at):"")||null,hearth_count:L(e.hearth_count,0)}}function qi(e){if(!u(e))return null;const t=x(e.id,"").trim(),n=x(e.post_id,"").trim(),a=x(e.author,"").trim();return!t||!a?null:{id:t,post_id:n,author:a,content:x(e.content,""),created_at:Ht(e.created_at)??""}}async function gf(e){return us("fetchBoardPost",async()=>{const t=await P(`/api/v1/board/${e}?format=flat`),n=u(t.post)?t.post:t,a=Ni(n)??{id:e,author:"unknown",post_kind:"human",title:"Post",body:"",content:"",meta:null,tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},r=(Array.isArray(t.comments)?t.comments:[]).map(qi).filter(l=>l!==null);return{...a,comments:r}})}function bf(e,t){return st("/api/v1/tools/masc_board_vote",{post_id:e,direction:t,vote:t,voter:Zr()})}function hf(e,t,n,a="internal"){return st("/api/v1/tools/masc_board_post",{title:e,content:t,author:n,kind:a})}function xf(e,t,n){return st("/api/v1/tools/masc_board_comment",{post_id:e,author:t,content:n})}function Fi(){return P("/api/v1/dashboard/shell")}function yf(e){const t=new URLSearchParams;e!=null&&e.limit&&t.set("limit",String(e.limit)),e!=null&&e.level&&t.set("level",e.level),e!=null&&e.module&&t.set("module",e.module);const n=t.toString();return P(`/api/v1/dashboard/logs${n?`?${n}`:""}`)}function Bi(e,t=4,n=20){return P(`/api/v1/agent-timeline?agent_name=${encodeURIComponent(e)}&since_hours=${t}&limit=${n}`)}function $f(e){return P(`/api/v1/agent-relations?agent_name=${encodeURIComponent(e)}`)}function Ki(){return P("/api/v1/dashboard/room-truth",{timeoutMs:Qr})}function Ui(){return P("/api/v1/dashboard/execution")}function Hi(e,t){const n=new URLSearchParams;return n.set("sort_by",e),t!=null&&t.excludeSystem&&n.set("exclude_system","true"),t!=null&&t.excludeAutomation&&n.set("exclude_automation","true"),P(`/api/v1/dashboard/board${n.toString()?`?${n}`:""}`)}function kf(){return us("fetchDashboardGovernance",async()=>{const e=await P("/api/v1/dashboard/governance"),t=Array.isArray(e.items)?e.items.map(a=>Oi(a)).filter(a=>a!==null):[],n=Array.isArray(e.pending_actions)?e.pending_actions.map(a=>vs(a)).filter(a=>a!==null):[];return{generated_at:M(e.generated_at)??void 0,summary:u(e.summary)?{cases_open:N(e.summary.cases_open)??void 0,pending_ruling:N(e.summary.pending_ruling)??void 0,ready_auto_execute:N(e.summary.ready_auto_execute)??void 0,needs_human_gate:N(e.summary.needs_human_gate)??void 0,executed:N(e.summary.executed)??void 0,blocked:N(e.summary.blocked)??void 0,ready_to_execute:N(e.summary.ready_to_execute)??void 0,oldest_open_case_age_s:typeof e.summary.oldest_open_case_age_s=="number"?e.summary.oldest_open_case_age_s:null,last_activity_age_s:typeof e.summary.last_activity_age_s=="number"?e.summary.last_activity_age_s:null,judge_online:typeof e.summary.judge_online=="boolean"?e.summary.judge_online:void 0,judge_last_seen_at:M(e.summary.judge_last_seen_at)}:void 0,items:t,activity:Array.isArray(e.activity)?e.activity.map(a=>Li(a)).filter(a=>a!==null):[],judge:Mi(e.judge),pending_actions:n}})}function Sf(){return P("/api/v1/governance/params")}function Gi(){return P("/api/v1/dashboard/mission")}function Wi(e){const t=`?session_id=${encodeURIComponent(e)}`;return P(`/api/v1/dashboard/session${t}`)}function Ji(e=!1){return P(`/api/v1/dashboard/mission/briefing${e?"?force=1":""}`)}function Vi(e,t){const n=new URLSearchParams;e&&n.set("session_id",e),t&&n.set("operation_id",t);const a=n.toString();return P(`/api/v1/dashboard/proof${a?`?${a}`:""}`)}function Xi(){return P("/api/v1/dashboard/planning")}function Af(){return P("/api/v1/tool-metrics")}function Tf(){return P("/api/v1/dashboard/tools")}function Yi(){return P("/api/v1/command-plane")}function Qi(){return P("/api/v1/command-plane/summary")}function Zi(){return P("/api/v1/chains/summary")}function wi(e){return P(`/api/v1/chains/runs/${encodeURIComponent(e)}`)}function el(){return P("/api/v1/command-plane/help")}function tl(e,t){const n=new URLSearchParams;e&&n.set("run_id",e),t&&n.set("operation_id",t);const a=n.toString();return P(`/api/v1/command-plane/swarm${a?`?${a}`:""}`)}function nl(e,t){const n=new URLSearchParams;e&&n.set("run_id",e),t&&n.set("operation_id",t);const a=n.toString();return P(`/api/v1/command-plane/orchestra${a?`?${a}`:""}`)}function al(e,t){return st(e,t)}function ol(e){return P(`/api/v1/keepers/${encodeURIComponent(e)}/config`)}function sl(e,t){return ni(`/api/v1/keepers/${encodeURIComponent(e)}/config`,t)}async function rl(e,t){await W("masc_broadcast",{agent_name:e,message:t})}async function il(e=40){return(await W("masc_messages",{limit:e})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function ll(e,t=20){return W("masc_task_history",{task_id:e,limit:t})}async function Cf(e){const t=await W("masc_petition_submit",{title:e,origin:"human",subject_type:"task",risk_class:"low",requested_action:{action_type:"add_task",payload:{title:e}}});try{const n=JSON.parse(t),a=u(n.case)?n.case:null,s=u(n.petition)?n.petition:null,r=u(n.ruling)?n.ruling:null;return!a||!s?null:la({case:a,petitions:[s],ruling:r,execution_order:null})}catch{return null}}async function Ef(e,t,n){const a=await W("masc_case_brief_submit",{case_id:e,stance:t,summary:n});try{const s=JSON.parse(a),r=la(s);if(r)return r}catch{}return cl(e)}async function cl(e){const t=await W("masc_case_status",{case_id:e});try{return la(JSON.parse(t))}catch{return null}}async function Pf(e,t){const n=await W("masc_execution_orders",{case_id:e,decision:t});try{return hs(JSON.parse(n))}catch{return null}}async function Rf(){try{const e=await De("/api/v1/activity/graph",{},1e4);return e.ok?await e.json():null}catch{return null}}let ul=0;const ze=m([]),dl={success:"border-l-[var(--ok)]",warning:"border-l-[var(--warn)]",error:"border-l-[var(--bad)]"},_l={success:"✓",warning:"⚠",error:"✕"},ml={success:"text-[var(--ok)]",warning:"text-[var(--warn)]",error:"text-[var(--bad)]"};function Q(e,t="success",n=4e3){const a=++ul;ze.value=[...ze.value,{id:a,message:e,type:t}],setTimeout(()=>{ze.value=ze.value.filter(s=>s.id!==a)},n)}function pl(e){ze.value=ze.value.filter(t=>t.id!==e)}function fl(){const e=ze.value;return e.length===0?null:c`
    <div class="fixed top-5 right-5 z-[var(--z-overlay-toast,3070)] flex flex-col gap-3">
      ${e.map(t=>c`
        <div
          key=${t.id}
          class="flex items-center gap-3 py-2.5 px-3.5 min-w-[240px] max-w-[380px] rounded-lg border-l-[3px] border-l-solid border border-solid border-[var(--card-border)] bg-[rgba(10,18,34,0.95)] shadow-[0_8px_24px_rgba(0,0,0,0.35),0_2px_8px_rgba(0,0,0,0.2)] backdrop-blur-sm cursor-pointer transition-opacity duration-200 hover:opacity-90 animate-[slideInRight_0.25s_ease-out] ${dl[t.type]}"
          onClick=${()=>pl(t.id)}
        >
          <span class="text-sm shrink-0 ${ml[t.type]}">${_l[t.type]}</span>
          <span class="text-[12px] text-[var(--text-body)] leading-[1.4]">${t.message}</span>
        </div>
      `)}
    </div>
  `}function vl(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="active"||t==="busy"||t==="listening"||t==="idle"||t==="inactive"||t==="offline"?t:t==="in_progress"||t==="claimed"?"busy":"offline"}function gl(e){var r;const t=((r=e.status)==null?void 0:r.toLowerCase())??"";if(t==="offline"||t==="inactive")return"offline";const n=e.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const s=a.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}function bl(e,t){const n=t.get(e.name);if(n!=null)return n;const a=e.last_heartbeat?Date.parse(e.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const s=[e.last_turn_ago_s,e.last_proactive_ago_s,e.last_handoff_ago_s,e.last_compaction_ago_s].find(r=>typeof r=="number"&&Number.isFinite(r)&&r>=0);return typeof s=="number"?Date.now()-s*1e3:null}function hl(e){return Array.isArray(e)?e.map(t=>{if(!u(t))return null;const n=i(t.ts_unix),a=i(t.context_ratio);if(n==null||a==null)return null;const s=u(t.handoff)?t.handoff:null;return{ts:n,context_ratio:a,context_tokens:i(t.context_tokens)??0,context_max:i(t.context_max)??0,latency_ms:i(t.latency_ms)??0,generation:i(t.generation)??0,channel:typeof t.channel=="string"?t.channel:"turn",is_handoff:s!=null&&t.handoff_performed===!0,is_compaction:t.compacted===!0,compaction_saved_tokens:i(t.compaction_saved_tokens)??0,compaction_trigger:typeof t.compaction_trigger=="string"?t.compaction_trigger:null,model_used:typeof t.model_used=="string"?t.model_used:"",cost_usd:i(t.cost_usd)??Number.NaN,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?i(s.new_generation)??null:null}}).filter(t=>t!==null):[]}function xl(e){if(!u(e))return;const t={};for(const[n,a]of Object.entries(e)){if(n==="top_tools"){if(!Array.isArray(a))continue;const r=a.filter(l=>u(l)&&typeof l.tool=="string"&&l.tool.trim()!=="");r.length>0&&(t.top_tools=r);continue}const s=i(a);s!=null&&(t[n]=s)}return Object.keys(t).length>0?t:void 0}function yl(e){if(!u(e))return null;const t=o(e.health_state),n=o(e.next_action_path),a=o(e.last_reply_status);if(!t||!n||!a)return null;const s=o(e.quiet_reason)??null;return{health_state:t,quiet_reason:s,next_action_path:n,last_reply_status:a,last_reply_at:ce(e.last_reply_at)??o(e.last_reply_at)??null,last_reply_preview:o(e.last_reply_preview)??null,last_error:o(e.last_error)??null,next_eligible_at_s:i(e.next_eligible_at_s)??null,recoverable:typeof e.recoverable=="boolean"?e.recoverable:n==="recover",summary:o(e.summary),keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0,continuity_state:o(e.continuity_state)??null,continuity_summary:o(e.continuity_summary)??null}}function $l(e){return(Array.isArray(e)?e:u(e)&&Array.isArray(e.keepers)?e.keepers:[]).map(n=>{if(!u(n))return null;const a=u(n.agent)?n.agent:null,s=u(n.context)?n.context:null,r=xl(n.metrics_window),l=o(n.name);if(!l)return null;const d=i(n.context_ratio)??i(s==null?void 0:s.context_ratio),_=o(n.status)??o(a==null?void 0:a.status)??"offline",p=o(n.model)??o(n.active_model)??o(n.primary_model),f=C(n.skill_secondary),h=hl(n.metrics_series),v=s?{source:o(s.source),context_ratio:i(s.context_ratio),context_tokens:i(s.context_tokens),context_max:i(s.context_max),message_count:i(s.message_count),has_checkpoint:typeof s.has_checkpoint=="boolean"?s.has_checkpoint:void 0}:void 0,b=a?{name:o(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:o(a.error),agent_type:o(a.agent_type),status:o(a.status),current_task:o(a.current_task)??null,joined_at:o(a.joined_at),last_seen:o(a.last_seen),last_seen_ago_s:i(a.last_seen_ago_s),capabilities:C(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0;return{name:l,runtime_class:n.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:typeof n.desired=="boolean"?n.desired:void 0,resident_registered:typeof n.resident_registered=="boolean"?n.resident_registered:void 0,reconcile_status:o(n.reconcile_status)??null,emoji:o(n.emoji),koreanName:o(n.koreanName)??o(n.korean_name),agent_name:o(n.agent_name),trace_id:o(n.trace_id),model:p,primary_model:o(n.primary_model),active_model:o(n.active_model),next_model_hint:o(n.next_model_hint)??null,status:vl(_),presence_keepalive:typeof n.presence_keepalive=="boolean"?n.presence_keepalive:void 0,presence_keepalive_sec:i(n.presence_keepalive_sec),keepalive_running:typeof n.keepalive_running=="boolean"?n.keepalive_running:void 0,proactive_enabled:typeof n.proactive_enabled=="boolean"?n.proactive_enabled:void 0,proactive_idle_sec:i(n.proactive_idle_sec),proactive_cooldown_sec:i(n.proactive_cooldown_sec),last_heartbeat:o(n.last_heartbeat)??o(a==null?void 0:a.last_seen),generation:i(n.generation),turn_count:i(n.turn_count)??i(n.total_turns),keeper_age_s:i(n.keeper_age_s),last_turn_ago_s:i(n.last_turn_ago_s),last_handoff_ago_s:i(n.last_handoff_ago_s),last_compaction_ago_s:i(n.last_compaction_ago_s),last_proactive_ago_s:i(n.last_proactive_ago_s),last_proactive_preview:o(n.last_proactive_preview)??null,context_ratio:d,context_tokens:i(n.context_tokens)??i(s==null?void 0:s.context_tokens),context_max:i(n.context_max)??i(s==null?void 0:s.context_max),context_source:o(n.context_source)??o(s==null?void 0:s.source),context:v,traits:C(n.traits),interests:C(n.interests),primaryValue:o(n.primaryValue)??o(n.primary_value),activityLevel:i(n.activityLevel)??i(n.activity_level),memory_recent_note:o(n.memory_recent_note)??null,recent_input_preview:o(n.recent_input_preview)??null,recent_output_preview:o(n.recent_output_preview)??null,recent_tool_names:C(n.recent_tool_names)??[],allowed_tool_names:C(n.allowed_tool_names)??[],latest_tool_names:C(n.latest_tool_names)??[],latest_tool_call_count:i(n.latest_tool_call_count)??null,tool_audit_source:o(n.tool_audit_source)??null,tool_audit_at:ce(n.tool_audit_at)??o(n.tool_audit_at)??null,conversation_tail_count:i(n.conversation_tail_count),k2k_count:i(n.k2k_count),handoff_count_total:i(n.handoff_count_total)??i(n.trace_history_count),compaction_count:i(n.compaction_count),last_compaction_saved_tokens:i(n.last_compaction_saved_tokens),diagnostic:yl(n.diagnostic),skill_primary:o(n.skill_primary)??null,skill_secondary:f,skill_reason:o(n.skill_reason)??null,metrics_series:h.length>0?h:void 0,metrics_window:r,agent:b}}).filter(n=>n!==null)}function V(e,t=120){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-1)}…`:n:null}function zf(e,t=260){return e.length<=t?e:`${e.slice(0,t-1)}…`}function Ee(e){return(e??"").trim().toLowerCase()}function K(e){const t=typeof e=="number"?e:Date.parse(e);return Number.isNaN(t)?0:t}function Gt(e,t=88){return V(e,t)??""}function Nt(e){return typeof e!="number"||!Number.isFinite(e)||e<0?null:new Date(Date.now()-e*1e3).toISOString()}function dt(e){return e.last_heartbeat??Nt(e.last_turn_ago_s)??Nt(e.last_proactive_ago_s)??Nt(e.last_handoff_ago_s)??Nt(e.last_compaction_ago_s)}function kl(e){const t=e.title.trim();return t||Gt(e.content)}function Sl(e){const t=e.generation??"?",n=typeof e.context_ratio=="number"&&Number.isFinite(e.context_ratio)?`${Math.round(e.context_ratio*100)}%`:"?";return e.last_heartbeat?`Heartbeat gen=${t} ctx=${n}`:`Keeper snapshot gen=${t} ctx=${n}`}function Al(e,t,n,a={}){var R;const s=e.filter(T=>T.status==="claimed"||T.status==="in_progress").length,r=t.slice().sort((T,z)=>K(z.timestamp??"")-K(T.timestamp??""))[0],l=n.slice().sort((T,z)=>K(z.timestamp)-K(T.timestamp))[0],d=(a.boardPosts??[]).slice().sort((T,z)=>K(z.updated_at||z.created_at)-K(T.updated_at||T.created_at))[0],_=(a.keepers??[]).filter(T=>dt(T)!==null).sort((T,z)=>K(dt(z)??0)-K(dt(T)??0))[0],p=r?K(r.timestamp??""):0,f=l?K(l.timestamp):0,h=d?K(d.updated_at||d.created_at):0,v=_?K(dt(_)??0):0,b=a.lastSeen?K(a.lastSeen):0,A=((R=a.currentTask)==null?void 0:R.trim())||(s>0?`${s} claimed tasks`:null);if(p===0&&f===0&&h===0&&v===0&&b===0)return{activeAssignedCount:s,lastActivityAt:null,lastActivityText:A};const y=[r?{timestamp:r.timestamp,ts:p,text:Gt(r.content)}:null,d?{timestamp:d.updated_at||d.created_at,ts:h,text:`Post: ${Gt(kl(d))}`}:null,_?{timestamp:dt(_),ts:v,text:Sl(_)}:null,l?{timestamp:new Date(l.timestamp).toISOString(),ts:f,text:Gt(l.text)}:null].filter(T=>T!==null).sort((T,z)=>z.ts-T.ts)[0];return y&&y.ts>=b?{activeAssignedCount:s,lastActivityAt:y.timestamp,lastActivityText:y.text}:{activeAssignedCount:s,lastActivityAt:a.lastSeen??null,lastActivityText:A??"Presence heartbeat"}}function Be(e,t){const n=new Map;for(const a of e){const s=t(a);if(!s)continue;const r=n.get(s);r?r.push(a):n.set(s,[a])}return n}function fe(e,t,n){const a=e.value;if(a.length!==t.length){e.value=t;return}if(a.length===0)return;const s=a[0],r=t[0],l=a[a.length-1],d=t[t.length-1];(s==null||r==null||l==null||d==null||n(s)!==n(r)||n(l)!==n(d))&&(e.value=t)}function Tl(e){const t=typeof e=="string"?e.toLowerCase():"";if(t==="active"||t==="busy"||t==="listening"||t==="idle"||t==="inactive"||t==="offline")return t;if(t==="in_progress"||t==="claimed")return"busy";if(t==="dead"||t==="left")return"offline"}function Cl(e){const t=typeof e=="string"?e.toLowerCase():"";if(t==="todo"||t==="in_progress"||t==="claimed"||t==="done"||t==="cancelled")return t;if(t==="inprogress")return"in_progress"}function El(e){if(!u(e))return null;const t=o(e.name);return t?{name:t,agent_type:o(e.agent_type),status:Tl(e.status),current_task:o(e.current_task)??null,joined_at:o(e.joined_at),last_seen:o(e.last_seen),capabilities:C(e.capabilities),emoji:o(e.emoji),koreanName:o(e.koreanName)??o(e.korean_name),model:o(e.model),traits:C(e.traits),interests:C(e.interests),activityLevel:i(e.activityLevel)??i(e.activity_level),primaryValue:o(e.primaryValue)??o(e.primary_value)}:null}function Pl(e){if(!u(e))return null;const t=o(e.id),n=o(e.title);return!t||!n?null:{id:t,title:n,status:Cl(e.status),priority:i(e.priority),assignee:o(e.assignee),description:o(e.description),created_at:o(e.created_at),updated_at:o(e.updated_at)}}function Rl(e){if(!u(e))return null;const t=o(e.from)??o(e.from_agent),n=o(e.content)??"",a=o(e.timestamp);return{id:o(e.id),seq:i(e.seq),from:t,content:n,timestamp:a,type:o(e.type)}}function ca(e){const t=typeof e=="string"?e.toLowerCase():"";if(t==="ok"||t==="warn"||t==="bad")return t}function xs(e){return u(e)?{active_sessions:i(e.active_sessions),blocked_sessions:i(e.blocked_sessions),active_operations:i(e.active_operations),blocked_operations:i(e.blocked_operations),runtime_pressure:i(e.runtime_pressure),worker_alerts:i(e.worker_alerts),continuity_alerts:i(e.continuity_alerts),priority_items:i(e.priority_items),todo_tasks:i(e.todo_tasks),claimed_tasks:i(e.claimed_tasks),running_tasks:i(e.running_tasks),done_tasks:i(e.done_tasks),cancelled_tasks:i(e.cancelled_tasks),keepers:i(e.keepers)}:null}function $e(e){if(!u(e))return null;const t=o(e.surface),n=o(e.label),a=o(e.target_type),s=o(e.target_id),r=o(e.focus_kind);return!t||!n||!a||!s||!r?null:{surface:t==="command"?"command":"intervene",label:n,target_type:a,target_id:s,focus_kind:r,operation_id:o(e.operation_id)??null,command_surface:o(e.command_surface)??null}}function ys(e){if(!u(e))return null;const t=o(e.id),n=o(e.kind),a=o(e.summary),s=o(e.target_type),r=o(e.target_id);return!t||!a||!s||!r||n!=="session"&&n!=="operation"?null:{id:t,kind:n,severity:ca(e.severity),status:o(e.status),summary:a,target_type:s,target_id:r,linked_session_id:o(e.linked_session_id)??null,linked_operation_id:o(e.linked_operation_id)??null,last_seen_at:o(e.last_seen_at)??null,top_handoff:$e(e.top_handoff),intervene_handoff:$e(e.intervene_handoff),command_handoff:$e(e.command_handoff)}}function zl(e){if(!u(e))return null;const t=o(e.session_id),n=o(e.goal);return!t||!n?null:{session_id:t,goal:n,room:o(e.room)??null,status:o(e.status),health:o(e.health),member_names:C(e.member_names),linked_operation_id:o(e.linked_operation_id)??null,linked_detachment_id:o(e.linked_detachment_id)??null,runtime_blocker:o(e.runtime_blocker)??null,worker_gap_summary:o(e.worker_gap_summary)??null,last_activity_at:o(e.last_activity_at)??null,last_activity_summary:o(e.last_activity_summary)??null,communication_summary:o(e.communication_summary)??null,active_count:i(e.active_count),seen_count:i(e.seen_count),planned_count:i(e.planned_count),required_count:i(e.required_count),counts_basis:o(e.counts_basis)??null,top_handoff:$e(e.top_handoff),intervene_handoff:$e(e.intervene_handoff),command_handoff:$e(e.command_handoff)}}function Ol(e){if(!u(e))return null;const t=o(e.operation_id),n=o(e.objective);return!t||!n?null:{operation_id:t,objective:n,status:o(e.status),stage:o(e.stage)??null,assigned_unit_id:o(e.assigned_unit_id)??null,assigned_unit_label:o(e.assigned_unit_label)??null,linked_session_id:o(e.linked_session_id)??null,linked_detachment_id:o(e.linked_detachment_id)??null,blocker_summary:o(e.blocker_summary)??null,search_status:o(e.search_status)??null,next_tool:o(e.next_tool)??null,updated_at:o(e.updated_at)??null,top_handoff:$e(e.top_handoff),command_handoff:$e(e.command_handoff)}}function Ua(e){if(!u(e))return null;const t=o(e.name)??o(e.agent_name),n=o(e.note),a=o(e.focus),s=o(e.state);if(!t||!n||!a||s!=="working"&&s!=="watching"&&s!=="quiet"&&s!=="offline")return null;const r=o(e.signal_truth),l=r==="live"||r==="stale"||r==="absent"?r:void 0,d=o(e.evidence_source),_=d==="message"||d==="presence"||d==="none"?d:void 0;return{name:t,agent_name:o(e.agent_name),status:o(e.status),tone:ca(e.tone),state:s,note:n,focus:a,last_signal_at:o(e.last_signal_at)??null,last_signal_age_sec:i(e.last_signal_age_sec)??null,signal_truth:l,evidence_source:_,active_task_count:i(e.active_task_count),related_session_id:o(e.related_session_id)??null,related_operation_id:o(e.related_operation_id)??null,emoji:o(e.emoji),korean_name:o(e.korean_name),model:o(e.model)??null,recent_output_preview:o(e.recent_output_preview)??null,recent_event:o(e.recent_event)??null}}function Il(e){if(!u(e))return null;const t=o(e.name),n=o(e.note),a=o(e.focus),s=o(e.state);return!t||!n||!a||s!=="healthy"&&s!=="warning"&&s!=="critical"?null:{name:t,agent_name:o(e.agent_name)??null,status:o(e.status),tone:ca(e.tone),state:s,note:n,focus:a,last_signal_at:o(e.last_signal_at)??null,last_autonomous_action_at:o(e.last_autonomous_action_at)??null,generation:i(e.generation),turn_count:i(e.turn_count),context_ratio:i(e.context_ratio)??null,continuity:o(e.continuity)??null,lifecycle:o(e.lifecycle)??null,related_session_id:o(e.related_session_id)??null,model:o(e.model)??null,emoji:o(e.emoji),korean_name:o(e.korean_name),skill_reason:o(e.skill_reason)??null,recent_input_preview:o(e.recent_input_preview)??null,recent_output_preview:o(e.recent_output_preview)??null,recent_tool_names:C(e.recent_tool_names)??[],allowed_tool_names:C(e.allowed_tool_names)??[],latest_tool_names:C(e.latest_tool_names)??[],latest_tool_call_count:i(e.latest_tool_call_count)??null,tool_audit_source:o(e.tool_audit_source)??null,tool_audit_at:o(e.tool_audit_at)??null,last_proactive_preview:o(e.last_proactive_preview)??null,continuity_summary:o(e.continuity_summary)??null,skill_route_summary:o(e.skill_route_summary)??null}}function Ne(e){if(!u(e))return null;const t=o(e.kind),n=o(e.summary),a=o(e.target_type);return!t||!n||!a?null:{kind:t,severity:o(e.severity)??"warn",summary:n,target_type:a,target_id:o(e.target_id)??null,actor:o(e.actor)??null,evidence:e.evidence}}function Ae(e){if(!u(e))return null;const t=o(e.action_type),n=o(e.target_type),a=o(e.reason);return!t||!n||!a?null:{action_type:t,target_type:n,target_id:o(e.target_id)??null,severity:o(e.severity)??"warn",reason:a,confirm_required:k(e.confirm_required),suggested_payload:u(e.suggested_payload)?e.suggested_payload:void 0,preview:e.preview}}function Ha(e){if(typeof e.seq=="number"&&Number.isFinite(e.seq))return e.seq;const t=Date.parse(e.timestamp??"");return Number.isNaN(t)?0:t}function Ll(e,t){if(t.length===0)return e;const n=new Map;for(const a of e){const s=typeof a.seq=="number"?`seq:${a.seq}`:`ts:${a.timestamp??""}|from:${a.from??""}|content:${a.content}`;n.set(s,a)}for(const a of t){const s=typeof a.seq=="number"?`seq:${a.seq}`:`ts:${a.timestamp??""}|from:${a.from??""}|content:${a.content}`;n.set(s,a)}return[...n.values()].sort((a,s)=>Ha(a)-Ha(s)).slice(-500)}function Ml(e){if(!u(e))return;const t=o(e.release_version),n=ce(e.started_at),a=i(e.uptime_seconds);if(!(!t||!n||a==null))return{release_version:t,commit:o(e.commit)??null,started_at:n,uptime_seconds:a}}function $s(e,t){return u(e)?{...e,generated_at:t??ce(e.generated_at)??void 0,build:Ml(e.build)}:null}function ks(e,t){return t?e?{...e,...t,build:t.build??e.build,generated_at:t.generated_at??e.generated_at}:t:e}function jl(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="running"||t==="interrupted"||t==="completed"||t==="stopped"||t==="error"?t:t.startsWith("error")?"error":"running"}function Dl(e){if(!u(e))return null;const t=i(e.iteration);if(t==null)return null;const n=i(e.metric_before)??0,a=i(e.metric_after)??n,s=u(e.evidence)?e.evidence:null;return{iteration:t,metric_before:n,metric_after:a,delta:i(e.delta)??a-n,changes:o(e.changes)??"",failed_attempts:o(e.failed_attempts)??"",next_suggestion:o(e.next_suggestion)??"",elapsed_ms:i(e.elapsed_ms)??0,cost_usd:i(e.cost_usd)??null,evidence:s?{worker_engine:(s.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:o(s.worker_model)??"",tool_call_count:i(s.tool_call_count)??0,tool_names:C(s.tool_names)??[],session_id:o(s.session_id)??"",evidence_status:s.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function Nl(e){var r,l;if(!u(e))return null;const t=o(e.loop_id);if(!t)return null;const n=i(e.baseline_metric)??0,a=Array.isArray(e.history)?e.history.map(Dl).filter(d=>d!==null):[],s=i(e.current_metric)??((r=a[0])==null?void 0:r.metric_after)??n;return{loop_id:t,profile:o(e.profile)??"unknown",status:jl(e.status),strict_mode:typeof e.strict_mode=="boolean"?e.strict_mode:void 0,error_message:o(e.error_message)??o(e.error_reason)??null,stop_reason:o(e.stop_reason)??o(e.reason)??null,current_iteration:i(e.current_iteration)??((l=a[0])==null?void 0:l.iteration)??0,max_iterations:i(e.max_iterations)??0,baseline_metric:n,current_metric:s,target:o(e.target)??"",stagnation_streak:i(e.stagnation_streak)??0,stagnation_limit:i(e.stagnation_limit)??0,elapsed_seconds:i(e.elapsed_seconds)??0,updated_at:ce(e.updated_at)??null,stopped_at:ce(e.stopped_at)??null,execution_mode:e.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:e.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:o(e.worker_model)??null,evidence_policy:e.evidence_policy==="hard"||e.evidence_policy==="legacy"?e.evidence_policy:void 0,latest_tool_call_count:i(e.latest_tool_call_count)??0,latest_tool_names:C(e.latest_tool_names)??[],session_id:o(e.session_id)??null,evidence_status:e.evidence_status==="legacy_unverified"?"legacy_unverified":e.evidence_status==="verified"?"verified":null,durability:e.durability==="persistent_backend"||e.durability==="memory_only"?e.durability:void 0,persistence_backend:e.persistence_backend==="filesystem"||e.persistence_backend==="postgres"||e.persistence_backend==="memory"?e.persistence_backend:void 0,recoverable:typeof e.recoverable=="boolean"?e.recoverable:void 0,history:a}}const ql=m(null);m([]);const Fl=m(null),rt=m([]),Ot=m([]),Bn=m([]),qe=m([]),Y=m(null),Bl=m(null),Kl=m(null),Ul=m(!1),Hl=m([]),Ss=m([]),Gl=m([]),ua=m([]),da=m([]),Wl=m([]),Wt=m(new Map),As=m([]),Jl=m("recent"),Vl=m(!0),Xl=m(null),En=m(""),Yl=m([]),Ga=m(!1),Ql=50,Zl=20,Ve=m([]),At=m(new Map),ht=m(null),$n=m(0);function Ke(e){const t=Ve.value[0];t&&t.type===e.type&&t.agent_name===e.agent_name&&t.timestamp===e.timestamp||(Ve.value=[e,...Ve.value].slice(0,Ql),$n.value++)}function wl(e){const t=new Map(At.value);if(t.set(e.keeper_name,e),t.size>Zl){let n=null,a=1/0;for(const[s,r]of t)r.timestamp<a&&(n=s,a=r.timestamp);n&&t.delete(n)}At.value=t,ht.value=Date.now(),$n.value++}const Ts=ie(()=>({agentEventsCount:Ve.value.length,keeperSnapshotsCount:At.value.size,lastKeeperTick:ht.value,totalEvents:$n.value})),ec=m(new Map),Cs=m("unknown"),Kn=m(null),Un=m(!1),Wa=m(!1),Ja=m(!1),Va=m(!1);m(null);const Es=m(null),tc=m(null),nc=m(null),ac=m(null),Xa=m(0);ie(()=>rt.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle"));const Of=ie(()=>{const e=Ot.value;return{todo:e.filter(t=>t.status==="todo"),inProgress:e.filter(t=>t.status==="in_progress"||t.status==="claimed"),done:e.filter(t=>t.status==="done")}}),If=ie(()=>{const e=new Map,t=Ot.value,n=Bn.value,a=Tt.value,s=As.value,r=qe.value,l=Be(t,v=>Ee(v.assignee)),d=Be(n,v=>Ee(v.from??"")),_=Be(a,v=>Ee(v.agent)),p=Be(a,v=>Ee(v.author)),f=Be(s,v=>Ee(v.author)),h=Be(r,v=>Ee(v.name));for(const v of rt.value){const b=Ee(v.name),A=_.get(b)??[],g=p.get(b)??[],y=A.length===0?g:g.length===0?A:A.concat(g);e.set(b,Al(l.get(b)??[],d.get(b)??[],y,{currentTask:v.current_task,lastSeen:v.last_seen,boardPosts:f.get(b)??[],keepers:h.get(b)??[]}))}return e});ie(()=>{var t;const e=new Map;for(const n of qe.value){const a=((t=n.status)==null?void 0:t.toLowerCase())??"";if(a==="offline"||a==="inactive"){e.set(n.name,"offline");continue}!n.metrics_series||n.metrics_series.length===0||e.set(n.name,gl(n))}return e});const oc=12e4;ie(()=>{const e=Date.now(),t=new Set,n=Wt.value;for(const a of qe.value){const s=bl(a,n);s!=null&&e-s>oc&&t.add(a.name)}return t});function sc(e){return e==="dashboard_refresh"||e==="masc/dashboard_refresh"||e.startsWith("goal_")||e.startsWith("masc/goal_")||e.startsWith("mdal_")||e.startsWith("masc/mdal_")||e.startsWith("operator_")||e.startsWith("masc/operator_")||e.startsWith("command_plane_")||e.startsWith("masc/command_plane_")}async function it(){Un.value=!0;try{await Promise.all([ic(),Oe()]),Es.value=new Date().toISOString()}catch(e){console.warn("[Dashboard] refresh error:",e)}finally{Un.value=!1}}function rc(e){var a,s;Yl.value=(Array.isArray(e.goals)?e.goals:[]).map(r=>{if(!u(r))return null;const l=o(r.id),d=o(r.title),_=o(r.horizon),p=o(r.status),f=o(r.created_at),h=o(r.updated_at);return!l||!d||!_||!p||!f||!h?null:{id:l,horizon:_,title:d,metric:o(r.metric)??null,target_value:o(r.target_value)??null,due_date:o(r.due_date)??null,priority:i(r.priority)??3,status:p,parent_goal_id:o(r.parent_goal_id)??null,last_review_note:o(r.last_review_note)??null,last_review_at:o(r.last_review_at)??null,created_at:f,updated_at:h}}).filter(r=>r!==null);const t=new Map,n=Array.isArray((a=e.mdal)==null?void 0:a.loops)?e.mdal.loops:[];for(const r of n){const l=Nl(r);l&&t.set(l.loop_id,l)}ec.value=t,Kn.value=typeof((s=e.mdal)==null?void 0:s.error)=="string"?e.mdal.error:null,Cs.value=Kn.value?"error":t.size===0?"idle":"ready"}async function ic(){try{const e=await Fi(),t=$s(e.status,e.generated_at);t&&(Y.value=ks(Y.value,t)),e.counts&&(ql.value={agents:e.counts.agents??0,tasks:e.counts.tasks??0,keepers:e.counts.keepers??0}),e.providers&&(Fl.value=e.providers)}catch(e){console.warn("[Dashboard] shell fetch error:",e),Q("서버 연결 실패 — 데이터를 불러올 수 없습니다","error",6e3)}}const lc=3e4;async function Oe(e){var t;if(!(!(e!=null&&e.force)&&Date.now()-Xa.value<lc))try{const n=await Ui(),a=$s(n.status,n.generated_at),s=(t=Y.value)==null?void 0:t.room;a&&(Y.value=ks(Y.value,a));const r=s!=null&&(a==null?void 0:a.room)!=null&&s!==a.room,l=(Array.isArray(n.agents)?n.agents:[]).map(El).filter(g=>g!==null);fe(rt,l,g=>g.name);const d=(Array.isArray(n.tasks)?n.tasks:[]).map(Pl).filter(g=>g!==null);fe(Ot,d,g=>g.id);const _=(Array.isArray(n.messages)?n.messages:[]).map(Rl).filter(g=>g!==null);Bn.value=r?_:Ll(Bn.value,_),qe.value=$l(n.keepers),Kl.value=xs(n.summary);const p=(Array.isArray(n.execution_queue)?n.execution_queue:Array.isArray(n.priority_queue)?n.priority_queue:[]).map(ys).filter(g=>g!==null);fe(Hl,p,g=>g.id);const f=(Array.isArray(n.session_briefs)?n.session_briefs:[]).map(zl).filter(g=>g!==null);fe(Ss,f,g=>g.session_id);const h=(Array.isArray(n.operation_briefs)?n.operation_briefs:[]).map(Ol).filter(g=>g!==null);fe(Gl,h,g=>g.operation_id);const v=(Array.isArray(n.worker_support_briefs)?n.worker_support_briefs:Array.isArray(n.worker_briefs)?n.worker_briefs:[]).map(Ua).filter(g=>g!==null);fe(ua,v,g=>g.name);const b=(Array.isArray(n.continuity_briefs)?n.continuity_briefs:[]).map(Il).filter(g=>g!==null);fe(da,b,g=>g.name);const A=(Array.isArray(n.offline_worker_briefs)?n.offline_worker_briefs:[]).map(Ua).filter(g=>g!==null);fe(Wl,A,g=>g.name),Bl.value=null,Ul.value=!0,Xa.value=Date.now(),Es.value=new Date().toISOString()}catch(n){console.warn("[Dashboard] execution fetch error:",n),Q("실행 데이터 로드 실패","error",5e3)}}async function _a(){Wa.value=!0;try{const e=await Hi(Jl.value,{excludeSystem:Vl.value});As.value=e.posts??[],tc.value=new Date().toISOString()}catch(e){console.warn("[Board] fetch error:",e),Q("게시판을 불러오지 못했습니다","error")}finally{Wa.value=!1}}async function cc(){var e;Ja.value=!0;try{const t=En.value||((e=Y.value)==null?void 0:e.room)||"default";En.value||(En.value=t);const n=await Pi(t);Xl.value=n}catch(t){console.warn("[TRPG] fetch error:",t)}finally{Ja.value=!1}}async function Ps(){Ga.value=!0,Va.value=!0;try{const e=await Xi();rc(e),nc.value=new Date().toISOString(),ac.value=new Date().toISOString()}catch(e){console.warn("[Planning] fetch error:",e),Cs.value="error",Kn.value=e instanceof Error?e.message:String(e)}finally{Ga.value=!1,Va.value=!1}}async function uc(){return Ps()}const Ya="masc_dashboard_sse_session_id",dc=1e3,_c=15e3,le=m(!1),Rs=m(0),zs=m(null),Tt=m([]),ma=m(0),en=m(0);function mc(){let e=sessionStorage.getItem(Ya);return e||(e=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Ya,e)),e}const pc=200;function fc(e,t,n="system",a={}){const s={agent:e,text:t,narrativeText:a.narrativeText??t,timestamp:Date.now(),kind:n,...a};Tt.value=[s,...Tt.value].slice(0,pc)}function tn(e,t=88){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-3)}...`:n:void 0}function Qa(e,t){const n=tn(t);return n?`${e}: ${n}`:`New ${e.toLowerCase()}`}function Os(e){const t=tn(e);return t?`: ${t}`:""}function D(e){return(e??"").trim()||"system"}function vc(e,t,n){const a=D(e),s=(t??"").trim(),r=(n??"").trim();return s&&r?`${a}가 태스크 ${s}를 ${r} 상태로 갱신했습니다.`:s?`${a}가 태스크 ${s}를 갱신했습니다.`:`${a}가 태스크 상태를 갱신했습니다.`}function Za(e,t,n){return`${D(t)}가 ${e}을 남겼습니다${Os(n)}`}function j(e,t,n,a,s={}){fc(e,t,n,{eventType:a,...s})}let ne=null,Xe=null,nn=0;function Is(){Xe&&(clearTimeout(Xe),Xe=null)}function gc(){if(Xe)return;nn++;const e=Math.min(nn,5),t=Math.min(_c,dc*Math.pow(2,e));Xe=setTimeout(()=>{Xe=null,Ls()},t)}function Ls(){Is(),ne&&(ne.close(),ne=null);const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),a=e.get("token");n&&t.set("agent",n),a&&t.set("token",a),t.set("session_id",mc());const s=t.toString()?`/sse?${t.toString()}`:"/sse",r=new EventSource(s);ne=r,r.onopen=()=>{if(ne!==r)return;const l=nn>0;nn=0,le.value=!0,l&&ma.value++},r.onerror=()=>{ne===r&&(le.value&&(en.value=Date.now()),le.value=!1,r.close(),ne=null,gc())},r.onmessage=l=>{try{const d=JSON.parse(l.data);Rs.value++,zs.value=d,bc(d)}catch{}}}function bc(e){const t=e.type,n="masc/",a=t.startsWith(n)&&!t.startsWith("masc/board_")?t.slice(n.length):t,s=e.agent??e.author??e.from??e.from_agent??"";switch(a){case"agent_joined":j(s,"Joined","system","agent_joined",{narrativeText:`${D(s)}가 room에 참여했습니다.`});break;case"agent_left":j(s,"Left","system","agent_left",{narrativeText:`${D(s)}가 room에서 나갔습니다.`});break;case"broadcast":j(s,`${(e.message??e.content??"").slice(0,80)}`,"system","broadcast",{narrativeText:`${D(s)}가 공지/메시지를 보냈습니다${Os(e.message??e.content)}`});break;case"task_update":j(s,`Task: ${e.task_id??""} -> ${e.status??""}`,"tasks","task_update",{narrativeText:vc(s,e.task_id,e.status)});break;case"board_post":case"masc/board_post":j(s,Qa("Post",e.content??e.message),"board","board_post",{author:e.author??s,narrativeText:Za("게시글",e.author??s,e.content??e.message),preview:tn(e.content??e.message),postId:e.post_id});break;case"board_comment":case"masc/board_comment":j(s,Qa("Comment",e.content??e.message),"board","board_comment",{author:e.author??s,narrativeText:Za("댓글",e.author??s,e.content??e.message),preview:tn(e.content??e.message),postId:e.post_id});break;case"keeper_heartbeat":j(e.name??s,`Heartbeat gen=${e.generation??"?"} ctx=${e.context_ratio!=null?Math.round(e.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat",{narrativeText:`${D(e.name??s)}가 하트비트를 보냈습니다 (gen ${e.generation??"?"}, ctx ${e.context_ratio!=null?Math.round(e.context_ratio*100)+"%":"?"})`});break;case"keeper_handoff":j(e.name??s,`Handoff gen ${e.from_generation??"?"} -> ${e.to_generation??"?"} (${e.to_model??"?"})`,"keepers","keeper_handoff",{narrativeText:`${D(e.name??s)}가 keeper handoff를 수행했습니다 (gen ${e.from_generation??"?"} → ${e.to_generation??"?"}, ${e.to_model??"?"})`});break;case"keeper_compaction":j(e.name??s,`Compaction saved ${e.saved_tokens??"?"} tokens (${e.trigger??"?"})`,"keepers","keeper_compaction",{narrativeText:`${D(e.name??s)}가 context compaction을 수행했습니다 (${e.saved_tokens??"?"} tokens, ${e.trigger??"?"})`});break;case"keeper_guardrail":j(e.name??s,`Guardrail: ${e.reason??"stopped"}`,"keepers","keeper_guardrail",{narrativeText:`${D(e.name??s)}가 guardrail에 의해 중단되었습니다: ${e.reason??"stopped"}`});break;case"oas:masc:lodge:agent_selected":{const r=e.payload??{};Ke({type:"selected",agent_name:r.agent_name??"",trigger:r.trigger??void 0,thompson_score:typeof r.thompson_score=="number"?r.thompson_score:void 0,final_score:typeof r.final_score=="number"?r.final_score:void 0,timestamp:typeof r.timestamp=="number"?r.timestamp:typeof e.ts_unix=="number"?e.ts_unix:Date.now()/1e3});break}case"oas:masc:lodge:agent_decision":{const r=e.payload??{};Ke({type:"decision",agent_name:r.agent_name??"",action:r.action??void 0,trigger_reason:r.trigger_reason??void 0,timestamp:typeof r.timestamp=="number"?r.timestamp:typeof e.ts_unix=="number"?e.ts_unix:Date.now()/1e3});break}case"oas:masc:lodge:agent_action_executed":{const r=e.payload??{};Ke({type:"action_executed",agent_name:r.agent_name??"",action:r.action??void 0,success:typeof r.success=="boolean"?r.success:void 0,timestamp:typeof r.timestamp=="number"?r.timestamp:typeof e.ts_unix=="number"?e.ts_unix:Date.now()/1e3});break}case"oas:masc:keeper:snapshot":{const r=e.payload??{},l={keeper_name:r.keeper_name??"",generation:r.generation??0,context_ratio:r.context_ratio??0,message_count:r.message_count??0,timestamp:r.timestamp??Date.now()/1e3};wl(l),j(l.keeper_name,`Keeper snapshot gen=${l.generation} ctx=${Math.round(l.context_ratio*100)}%`,"oas","oas_keeper_snapshot",{narrativeText:`${D(l.keeper_name)}의 keeper snapshot이 갱신되었습니다 (gen ${l.generation}, ctx ${Math.round(l.context_ratio*100)}%)`});break}case"oas:masc:keeper:resident_lifecycle":{const r=e.payload??{},l=r.agent_name??"",d=r.event??void 0,_=r.detail??void 0;Ke({type:"keeper_resident_lifecycle",agent_name:l,event:d,detail:_,timestamp:typeof r.timestamp=="number"?r.timestamp:typeof e.ts_unix=="number"?e.ts_unix:Date.now()/1e3}),j(l,`Resident ${[d,_].filter(Boolean).join(" · ")||"lifecycle"}`,"oas","oas_event",{narrativeText:`${D(l)} resident lifecycle 이벤트`+([d,_].filter(Boolean).length>0?` (${[d,_].filter(Boolean).join(" · ")})`:"")});break}case"oas:masc:trust_updated":{const r=e.payload??{},l=r.agent_a??"",d=r.agent_b??"",_=typeof r.trust_score=="number"?r.trust_score:void 0;Ke({type:"trust_updated",agent_name:l,secondary_agent:d,trust_score:_,timestamp:typeof r.timestamp=="number"?r.timestamp:typeof e.ts_unix=="number"?e.ts_unix:Date.now()/1e3}),j(l,`Trust ${d}${_!=null?` · ${_.toFixed(2)}`:""}`,"oas","oas_event",{narrativeText:`${D(l)}와 ${D(d)} 사이 trust score가 갱신되었습니다`+(_!=null?` (${_.toFixed(2)})`:"")});break}case"oas:masc:reputation_changed":{const r=e.payload??{},l=r.agent_name??"",d=typeof r.old_score=="number"?r.old_score:void 0,_=typeof r.new_score=="number"?r.new_score:void 0,p=r.trend??void 0;Ke({type:"reputation_changed",agent_name:l,old_score:d,new_score:_,trend:p,timestamp:typeof r.timestamp=="number"?r.timestamp:typeof e.ts_unix=="number"?e.ts_unix:Date.now()/1e3}),j(l,`Reputation${d!=null&&_!=null?` ${d.toFixed(2)} → ${_.toFixed(2)}`:""}${p?` · ${p}`:""}`,"oas","oas_event",{narrativeText:`${D(l)} reputation이 갱신되었습니다`+(d!=null&&_!=null?` (${d.toFixed(2)} → ${_.toFixed(2)})`:"")+(p?`, trend=${p}`:"")});break}case"oas:masc:keeper:tick":{const r=Date.now();(ht.value===null||r-ht.value>100)&&(ht.value=r),$n.value++;break}default:j(s,a,"system","unknown",{narrativeText:`${D(s)} 이벤트: ${a}`})}}function hc(){Is(),ne&&(ne.close(),ne=null),le.value=!1}const xc=m(null),Hn=m(!1),Gn=m(null);let Re=null,wa=0;const yc=6e4;function $c(e){return u(e)?{room:o(e.room)??o(e.current_room),room_base_path:o(e.room_base_path),cluster:o(e.cluster),project:o(e.project),paused:k(e.paused),version:o(e.version),generated_at:o(e.generated_at),tempo_interval_s:i(e.tempo_interval_s)}:null}function kc(e){return u(e)?{actor_filter:o(e.actor_filter)??null,filter_active:k(e.filter_active)??!1,visible_count:i(e.visible_count)??0,total_count:i(e.total_count)??0,hidden_count:i(e.hidden_count)??0,hidden_actors:C(e.hidden_actors),confirm_required_actions:S(e.confirm_required_actions).flatMap(t=>{if(!u(t))return[];const n=o(t.action_type),a=o(t.target_type);return!n||!a?[]:[{action_type:n,target_type:a,description:o(t.description),confirm_required:k(t.confirm_required)}]})}:null}function Sc(e){return u(e)?{count:i(e.count)??0,bad_count:i(e.bad_count)??0,warn_count:i(e.warn_count)??0,provenance:o(e.provenance)??null,top_item:Ne(e.top_item)}:null}function Ac(e){return u(e)?{count:i(e.count)??0,provenance:o(e.provenance)??null,top_action:Ae(e.top_action)}:null}function Tc(e){if(!u(e))return null;const t=o(e.label),n=o(e.reason),a=o(e.source),s=o(e.provenance);return!t||!n||!a||!s?null:{label:t,reason:n,source:a,provenance:s,target_kind:o(e.target_kind)??null,target_id:o(e.target_id)??null,suggested_tab:o(e.suggested_tab)??null,suggested_surface:o(e.suggested_surface)??null,suggested_params:u(e.suggested_params)?Object.fromEntries(Object.entries(e.suggested_params).map(([r,l])=>{const d=o(l);return d?[r,d]:null}).filter(r=>r!==null)):{}}}function Cc(e){const t=u(e)?e:{},n=u(t.room)?t.room:{},a=u(t.execution)?t.execution:{},s=u(t.command)?t.command:{},r=u(t.operator)?t.operator:{};return{generated_at:o(t.generated_at),room:{status:$c(n.status),counts:u(n.counts)?{agents:i(n.counts.agents),tasks:i(n.counts.tasks),keepers:i(n.counts.keepers)}:void 0,provenance:o(n.provenance)??null},execution:{summary:xs(a.summary),top_queue:ys(a.top_queue),provenance:o(a.provenance)??null},command:{active_operations:i(s.active_operations),active_detachments:i(s.active_detachments),pending_approvals:i(s.pending_approvals),bad_alerts:i(s.bad_alerts),warn_alerts:i(s.warn_alerts),moving_lanes:i(s.moving_lanes),active_lanes:i(s.active_lanes),provenance:o(s.provenance)??null},operator:{health:o(r.health)??null,attention_summary:Sc(r.attention_summary),recommendation_summary:Ac(r.recommendation_summary),pending_confirm_summary:kc(r.pending_confirm_summary),provenance:o(r.provenance)??null},focus:Tc(t.focus)}}const tt=m(!1),Ec=3e3,Pc=10;async function ae(e){if(Re)return Re;if(!(!(e!=null&&e.force)&&Date.now()-wa<yc))return Hn.value=!0,Gn.value=null,Re=(async()=>{try{const t=await Ki();if(u(t)&&o(t.status)==="initializing"){tt.value=!0,Ms(1);return}tt.value=!1,xc.value=Cc(t),wa=Date.now()}catch(t){Gn.value=t instanceof Error?t.message:"Failed to load room truth"}finally{Hn.value=!1,Re=null}})(),Re}function Ms(e){if(e>Pc){tt.value=!1,Gn.value="Server warm-up timed out. Try refreshing.",Hn.value=!1,Re=null;return}window.setTimeout(()=>{Re=null,ae().then(()=>{tt.value&&Ms(e+1)})},Ec)}const Rc="modulepreload",zc=function(e){return"/dashboard/"+e},eo={},_e=function(t,n,a){let s=Promise.resolve();if(n&&n.length>0){let l=function(p){return Promise.all(p.map(f=>Promise.resolve(f).then(h=>({status:"fulfilled",value:h}),h=>({status:"rejected",reason:h}))))};document.getElementsByTagName("link");const d=document.querySelector("meta[property=csp-nonce]"),_=(d==null?void 0:d.nonce)||(d==null?void 0:d.getAttribute("nonce"));s=l(n.map(p=>{if(p=zc(p),p in eo)return;eo[p]=!0;const f=p.endsWith(".css"),h=f?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${p}"]${h}`))return;const v=document.createElement("link");if(v.rel=f?"stylesheet":Rc,f||(v.as="script"),v.crossOrigin="",v.href=p,_&&v.setAttribute("nonce",_),document.head.appendChild(v),f)return new Promise((b,A)=>{v.addEventListener("load",b),v.addEventListener("error",()=>A(new Error(`Unable to preload CSS for ${p}`)))})}))}function r(l){const d=new Event("vite:preloadError",{cancelable:!0});if(d.payload=l,window.dispatchEvent(d),!d.defaultPrevented)throw l}return s.then(l=>{for(const d of l||[])d.status==="rejected"&&r(d.reason);return t().catch(r)})},js=m(""),ue=m({}),F=m({}),nt=m({}),an=m({}),Wn=m({}),Jn=m({}),re=m({}),on=m({}),pa=new Map,fa=new Map;function I(e,t,n){e.value={...e.value,[t]:n}}function Oc(e){var n;const t=(n=o(e))==null?void 0:n.toLowerCase();return t==="user"||t==="assistant"||t==="system"||t==="tool"?t:"other"}function Ic(e){switch(e){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Lc(e,t){return e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":t==="quiet_hours"?"Social quiet hours are active. Direct messages still work, but scheduled public-square reactions may look asleep.":t==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":t==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Mc(e,t,n){return o(e)??Lc(t,n)}function jc(e,t){return typeof e=="boolean"?e:t==="recover"}function sn(e){if(!u(e))return null;const t=o(e.health_state),n=o(e.next_action_path),a=o(e.last_reply_status);return!t||!n||!a?null:{health_state:t,quiet_reason:o(e.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:ce(e.last_reply_at)??null,last_reply_preview:o(e.last_reply_preview)??null,last_error:o(e.last_error)??null,next_eligible_at_s:i(e.next_eligible_at_s)??null,recoverable:jc(e.recoverable,n),summary:Mc(e.summary,t,o(e.quiet_reason)??null),keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0,continuity_state:o(e.continuity_state)??null,continuity_summary:o(e.continuity_summary)??null}}function Dc(e){return u(e)?{status:e.status,diagnostic:sn(e.diagnostic)}:null}function Nc(e){return u(e)?{recovered:k(e.recovered)??!1,skipped_reason:o(e.skipped_reason)??null,before:sn(e.before),after:sn(e.after),down:e.down,up:e.up}:null}function qc(e,t){if(!u(e))return null;const n=Oc(e.role),a=o(e.content)??o(e.preview);if(!a)return null;const s=yn(a);if(!s)return null;const r=ce(e.ts_unix)??ce(e.timestamp);return{id:`${n}-${r??"entry"}-${t}`,role:n,label:Ic(n),text:s,rawText:a,timestamp:r,delivery:"history",streamState:null,details:null}}function Ds(e,t,n){const a=u(n)?n:null,s=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((r,l)=>qc(r,l)).filter(r=>r!==null):[];return{name:e,diagnostic:sn(a==null?void 0:a.diagnostic),history:s,rawText:t,rawStatus:n,loadedAt:new Date().toISOString()}}function to(e,t){const n=F.value[e]??[];F.value={...F.value,[e]:[...n,t].slice(-50)}}function kn(e,t,n){const a=F.value[e]??[];F.value={...F.value,[e]:a.map(s=>s.id===t?n(s):s)}}function Pn(e,t,n,a){kn(e,t,s=>({...s,streamState:n,delivery:a}))}function Fc(e,t,n){kn(e,t,a=>({...a,rawText:`${a.rawText??a.text}${n}`,text:yn(`${a.rawText??a.text}${n}`),streamState:"streaming",delivery:"streaming"}))}function he(e,t,n){kn(e,t,a=>({...a,...n}))}function Bc(e,t){return e.role!==t.role||e.text!==t.text?!1:e.timestamp&&t.timestamp?e.timestamp===t.timestamp:!0}function Kc(e,t){const a=(F.value[e]??[]).filter(s=>s.delivery!=="history"&&!t.some(r=>Bc(s,r)));F.value={...F.value,[e]:[...t,...a].slice(-50)}}function It(e,t){ue.value={...ue.value,[e]:t},Kc(e,t.history)}function qt(e,t){const n=ue.value[e];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};It(e,{...n,diagnostic:{...a,...t}})}function Uc(e,t,n){fa.set(e,t),pa.set(e,n)}function Ns(e){fa.delete(e),pa.delete(e)}function Hc(e){return fa.get(e)??null}function Gc(e){return pa.get(e)}function Vn(e){const t=e.trim();if(!t)return;const n=Gc(t),a=Hc(t);n&&n.abort(),a&&he(t,a,{delivery:"timeout",streamState:null,error:"Stream cancelled",timestamp:new Date().toISOString()}),Ns(t),I(an,t,!1),I(on,t,null)}function Wc(e,t,n){switch(n.type){case"RUN_STARTED":return Pn(e,t,"opening","sending"),null;case"TEXT_MESSAGE_START":return Pn(e,t,"streaming","streaming"),null;case"TEXT_MESSAGE_CONTENT":{const a=typeof n.delta=="string"?n.delta:"";return a&&Fc(e,t,a),null}case"TEXT_MESSAGE_END":return Pn(e,t,"finalizing","streaming"),null;case"CUSTOM":if(n.name==="KEEPER_REPLY_DETAILS"){const a=ms(n.value);a&&kn(e,t,s=>{const r=a.replyText??s.rawText??s.text,l=yn(r);return{...s,details:a,rawText:r,text:l}})}return null;case"RUN_ERROR":return typeof n.value=="string"?n.value:(u(n.value)?o(n.value.message):null)??"Keeper stream failed";default:return null}}async function rn(){try{await it()}catch(e){console.warn("[keeper-runtime] dashboard refresh failed",e)}}function Jc(e){js.value=e.trim()}async function va(e,t=!1){const n=e.trim();if(!n)return null;if(!t&&ue.value[n])return ue.value[n];I(nt,n,!0),I(re,n,null);try{const a=await W("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:50});let s=null;try{s=JSON.parse(a)}catch{s=null}const r=Ds(n,a,s);return It(n,r),r}catch(a){const s=a instanceof Error?a.message:`Failed to inspect ${n}`;return I(re,n,s),null}finally{I(nt,n,!1)}}async function Vc(e){const t=e.trim();if(t){I(nt,t,!0);try{const n=await W("masc_keeper_status",{name:t,fast:!0,include_context:!1,include_metrics_overview:!1,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:0,tail_messages:200});let a=null;try{a=JSON.parse(n)}catch{a=null}const s=Ds(t,n,a);It(t,s)}catch{}finally{I(nt,t,!1)}}}async function Xc(e,t){var _,p;const n=e.trim(),a=t.trim();if(!n||!a)return;Vn(n);const s=`local-${Date.now()}`,r=`reply-${Date.now()}`;to(n,{id:s,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending",streamState:null,details:null}),to(n,{id:r,role:"assistant",label:n,text:"",rawText:"",timestamp:null,delivery:"sending",streamState:"opening",details:null}),I(an,n,!0),I(re,n,null),I(on,n,Date.now());const l=new AbortController;Uc(n,r,l);let d=null;try{he(n,s,{delivery:"delivered"});let f=Date.now();d=setInterval(()=>{Date.now()-f>12e4&&(d!=null&&clearInterval(d),d=null,Vn(n))},5e3),await bi(n,a,void 0,{signal:l.signal,onEvent:b=>{f=Date.now();const A=Wc(n,r,b);if(A)throw new Error(A)}});const h=(F.value[n]??[]).find(b=>b.id===r)??null,v=(h==null?void 0:h.text.trim())||"(empty reply)";he(n,r,{text:v,delivery:"delivered",streamState:null,timestamp:new Date().toISOString(),error:null}),qt(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:v.slice(0,200),last_error:null})}catch(f){if(f instanceof Error&&f.name==="AbortError")throw he(n,r,{delivery:"timeout",streamState:null,error:"Stream cancelled",timestamp:new Date().toISOString()}),qt(n,{last_reply_status:"error",last_error:"Stream cancelled"}),I(re,n,"Stream cancelled"),f;if(!((_=(F.value[n]??[]).find(A=>A.id===r))!=null&&_.text.trim()))try{const A=await pi(n,a);he(n,r,{text:A.text.trim()||"(empty reply)",rawText:((p=A.details)==null?void 0:p.replyText)??(A.text.trim()||"(empty reply)"),delivery:"delivered",streamState:null,details:A.details,error:null,timestamp:new Date().toISOString()}),he(n,s,{delivery:"delivered",error:null}),qt(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(A.text.trim()||"(empty reply)").slice(0,200),last_error:null}),await rn();return}catch{}const b=f instanceof Error?f.message:`Failed to send direct message to ${n}`;throw he(n,r,{delivery:"error",streamState:null,error:b,timestamp:new Date().toISOString()}),he(n,s,{delivery:"error",error:b}),qt(n,{last_reply_status:"error",last_error:b}),I(re,n,b),f}finally{d!=null&&clearInterval(d),Ns(n),I(an,n,!1),I(on,n,null),await rn()}}async function Yc(e,t){const n=e.trim();if(!n)return null;I(Wn,n,!0),I(re,n,null);try{const a=await zt({actor:t,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),s=Dc(a.result),r=(s==null?void 0:s.diagnostic)??null;if(r){const l=ue.value[n];It(n,{name:n,diagnostic:r,history:(l==null?void 0:l.history)??F.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await rn(),r}catch(a){const s=a instanceof Error?a.message:`Failed to probe ${n}`;throw I(re,n,s),a}finally{I(Wn,n,!1)}}async function Qc(e,t){const n=e.trim();if(!n)return null;I(Jn,n,!0),I(re,n,null);try{const a=await zt({actor:t,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),s=Nc(a.result),r=(s==null?void 0:s.after)??null;if(r){const l=ue.value[n];It(n,{name:n,diagnostic:r,history:(l==null?void 0:l.history)??F.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await rn(),r}catch(a){const s=a instanceof Error?a.message:`Failed to recover ${n}`;throw I(re,n,s),a}finally{I(Jn,n,!1)}}let Jt=null;function Lf(e){Jt=e}let Me=null;function Zc(e){Me=e}let G=null;function wc(e){G=e}let je=null;function eu(e){je=e}const oe={};let Ye=null;function xt(e,t,n=500){oe[e]&&clearTimeout(oe[e]),oe[e]=setTimeout(()=>{t(),delete oe[e]},n)}const tu={agent_joined:{target:"execution"},"masc/agent_joined":{target:"execution"},agent_left:{target:"execution"},"masc/agent_left":{target:"execution"},broadcast:{target:"execution"},"masc/broadcast":{target:"execution"},keeper_handoff:{target:"execution"},keeper_compaction:{target:"execution"},keeper_guardrail:{target:"execution"},client_input_approved:{target:"operator",debounceMs:300},client_input_rejected:{target:"operator",debounceMs:300},client_input_updated:{target:"operator",debounceMs:300},board_post:{target:"board"},"masc/board_post":{target:"board"},board_comment:{target:"board"},"masc/board_comment":{target:"board"},mdal_started:{target:"mdal",debounceMs:350},mdal_iteration:{target:"mdal",debounceMs:350},mdal_completed:{target:"mdal",debounceMs:350},mdal_stopped:{target:"mdal",debounceMs:350}},nu=[{prefix:"task_",target:"execution"},{prefix:"masc/task_",target:"execution"}],no={execution:Oe,board:_a,mdal:uc,operator:()=>G==null?void 0:G()},au=new Set(["keeper_handoff","keeper_compaction","keeper_guardrail","keeper_turn_complete","masc/keeper_handoff","masc/keeper_compaction","masc/keeper_guardrail","masc/keeper_turn_complete"]);function ou(e){if(!e.name)return;const t=e.ts_unix?e.ts_unix*1e3:Date.now();if(Wt.value.get(e.name)===t)return;const a=new Map(Wt.value);a.set(e.name,t),Wt.value=a}function su(e){if(xt("operator",()=>G==null?void 0:G(),600),e.type==="keeper_turn_complete"){const t=e.name??"",n=js.value;t&&t===n&&xt(`keeper_thread_${t}`,()=>{va(t,!0)},800)}}function ru(){Ye||(Ye=setTimeout(()=>{it(),Me==null||Me(),G==null||G(),Ye=null},500))}async function iu(){Jt==null||Jt();const{loadRuntimeParams:e}=await _e(async()=>{const{loadRuntimeParams:t}=await import("./governance-QqcN6gK6.js");return{loadRuntimeParams:t}},__vite__mapDeps([0,1,2,3,4]));e()}function lu(){const e=en.value>0?Date.now()-en.value:0,t=Math.round(e/1e3),n=t>0?`${t}초 단절 후 재연결됨`:"서버 연결 복구됨";Q(n,"success",3e3),ae({force:!0}),it(),Oe(),_a(),Me==null||Me(),G==null||G(),je==null||je()}function cu(){const e=ma.subscribe(()=>{le.value&&lu()}),t=zs.subscribe(n=>{if(!n)return;if(n.type==="keeper_heartbeat"){ou(n);return}sc(n.type)&&ru();const a=tu[n.type];a&&xt(a.target,no[a.target],a.debounceMs);for(const{prefix:s,target:r}of nu)if(n.type.startsWith(s)){xt(r,no[r]);break}au.has(n.type)&&su(n),(n.type.startsWith("decision_")||n.type==="governance_param_changed")&&xt("governance",()=>void iu())});return()=>{t(),e();for(const n of Object.keys(oe))clearTimeout(oe[n]),delete oe[n]}}const uu=(typeof import.meta<"u",3e4);let yt=null;function du(){yt||(yt=setInterval(()=>{le.value,it(),je==null||je()},uu))}function _u(){yt&&(clearInterval(yt),yt=null)}function mu(){for(const e of Object.keys(oe))clearTimeout(oe[e]),delete oe[e];Ye&&(clearTimeout(Ye),Ye=null)}function qs(e){if(!u(e))return null;const t=o(e.action_type),n=o(e.target_type);return!t||!n?null:{action_type:t,target_type:n,description:o(e.description),confirm_required:k(e.confirm_required)}}function Fs(e){if(!u(e))return null;const t=o(e.confirm_token)??o(e.token);return t?{confirm_token:t,actor:o(e.actor),action_type:o(e.action_type),target_type:o(e.target_type),target_id:o(e.target_id)??null,delegated_tool:o(e.delegated_tool),created_at:o(e.created_at),preview:e.preview}:null}function Bs(e){return u(e)?{actor_filter:o(e.actor_filter)??null,filter_active:k(e.filter_active)??!1,visible_count:i(e.visible_count)??0,total_count:i(e.total_count)??0,hidden_count:i(e.hidden_count)??0,hidden_actors:C(e.hidden_actors),confirm_required_actions:S(e.confirm_required_actions).map(qs).filter(t=>t!==null)}:null}function pu(e){if(!u(e))return null;const t=S(e.items,["confirms"]).map(Fs).filter(a=>a!==null),n=Bs(e.summary);return!n&&t.length===0?null:{items:t,summary:n??{actor_filter:null,filter_active:!1,visible_count:t.length,total_count:t.length,hidden_count:0,hidden_actors:[],confirm_required_actions:[]}}}function Mf(e){var s,r,l,d;const t=(e==null?void 0:e.pending_confirm_envelope)??null,n=(t==null?void 0:t.items)??(e==null?void 0:e.pending_confirms)??[],a=(t==null?void 0:t.summary)??(e==null?void 0:e.pending_confirm_summary)??{actor_filter:null,filter_active:!1,visible_count:n.length,total_count:n.length,hidden_count:0,hidden_actors:[],confirm_required_actions:((s=e==null?void 0:e.available_actions)==null?void 0:s.filter(_=>_.confirm_required))??[]};return{items:n,summary:a,actor_filter:((r=a.actor_filter)==null?void 0:r.trim())||null,visible_count:a.visible_count??n.length,total_count:a.total_count??n.length,hidden_count:a.hidden_count??0,hidden_actors:a.hidden_actors??[],confirm_required_actions:(l=a.confirm_required_actions)!=null&&l.length?a.confirm_required_actions:((d=e==null?void 0:e.available_actions)==null?void 0:d.filter(_=>_.confirm_required))??[]}}const Xn=m(null),fu=m(null),Se=m(null),ao=m(!1),at=m(null),ln=m(!1),cn=m(null),un=m(!1),oo=m([]);let vu=1;function gu(e){return u(e)?{id:o(e.id),seq:i(e.seq),from:o(e.from)??o(e.from_agent)??"system",content:o(e.content)??"",timestamp:o(e.timestamp)??new Date().toISOString(),type:o(e.type)}:null}function bu(e){return u(e)?{room_id:o(e.room_id),current_room:o(e.current_room)??o(e.room),project:o(e.project),cluster:o(e.cluster),paused:k(e.paused),pause_reason:o(e.pause_reason)??null,paused_by:o(e.paused_by)??null,paused_at:o(e.paused_at)??null}:{}}function so(e){if(!u(e))return;const t=Object.entries(e).map(([n,a])=>{const s=o(a);return s?[n,s]:null}).filter(n=>n!==null);return t.length>0?Object.fromEntries(t):void 0}function Ks(e){if(!u(e))return null;const t=o(e.kind),n=o(e.summary),a=o(e.target_type);return!t||!n||!a?null:{kind:t,severity:o(e.severity)??"warn",summary:n,target_type:a,target_id:o(e.target_id)??null,actor:o(e.actor)??null,evidence:e.evidence}}function $t(e){if(!u(e))return null;const t=o(e.action_type),n=o(e.target_type),a=o(e.reason);return!t||!n||!a?null:{action_type:t,target_type:n,target_id:o(e.target_id)??null,severity:o(e.severity)??"warn",reason:a,confirm_required:k(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function Us(e){return u(e)?{enabled:k(e.enabled),judge_online:k(e.judge_online),refreshing:k(e.refreshing),generated_at:o(e.generated_at)??null,expires_at:o(e.expires_at)??null,model_used:o(e.model_used)??null,keeper_name:o(e.keeper_name)??null,last_error:o(e.last_error)??null}:null}function Rn(e){return u(e)?{summary:o(e.summary)??null,confidence:i(e.confidence)??null,provenance:o(e.provenance)??null,authoritative:k(e.authoritative),surface:o(e.surface)??null,fresh_until:o(e.fresh_until)??null,keeper_name:o(e.keeper_name)??null,fallback_used:k(e.fallback_used),disagreement_with_truth:k(e.disagreement_with_truth)}:null}function hu(e){return u(e)?{judgment_id:o(e.judgment_id)??void 0,surface:o(e.surface)??null,target_type:o(e.target_type)??null,target_id:o(e.target_id)??null,status:o(e.status)??null,summary:o(e.summary)??null,confidence:i(e.confidence)??null,generated_at:o(e.generated_at)??null,fresh_until:o(e.fresh_until)??null,keeper_name:o(e.keeper_name)??null,model_name:o(e.model_name)??null,runtime_name:o(e.runtime_name)??null,evidence_refs:C(e.evidence_refs),recommended_action:$t(e.recommended_action),supersedes:C(e.supersedes),fallback_used:k(e.fallback_used),disagreement_with_truth:k(e.disagreement_with_truth),provenance:o(e.provenance)??null}:null}function xu(e){return u(e)?{actor:o(e.actor)??null,spawn_agent:o(e.spawn_agent)??null,spawn_role:o(e.spawn_role)??null,spawn_model:o(e.spawn_model)??null,worker_class:o(e.worker_class)??null,parent_actor:o(e.parent_actor)??null,capsule_mode:o(e.capsule_mode)??null,runtime_pool:o(e.runtime_pool)??null,lane_id:o(e.lane_id)??null,controller_level:o(e.controller_level)??null,control_domain:o(e.control_domain)??null,supervisor_actor:o(e.supervisor_actor)??null,model_tier:o(e.model_tier)??null,task_profile:o(e.task_profile)??null,risk_level:o(e.risk_level)??null,routing_confidence:i(e.routing_confidence)??null,routing_reason:o(e.routing_reason)??null,status:o(e.status)??"unknown",turn_count:i(e.turn_count)??0,empty_note_turn_count:i(e.empty_note_turn_count)??0,has_turn:k(e.has_turn)??!1,last_turn_ts_iso:o(e.last_turn_ts_iso)??null}:null}function yu(e){if(!u(e))return null;const t=o(e.session_id);return t?{session_id:t,goal:o(e.goal),status:o(e.status),health:o(e.health),scale_profile:o(e.scale_profile),control_profile:o(e.control_profile),planned_worker_count:i(e.planned_worker_count),active_agent_count:i(e.active_agent_count),last_turn_age_sec:i(e.last_turn_age_sec)??null,attention_count:i(e.attention_count),recommended_action_count:i(e.recommended_action_count),top_attention:Ks(e.top_attention),top_recommendation:$t(e.top_recommendation)}:null}function ro(e){if(!u(e))return null;const t=o(e.loop_id),n=o(e.status);return!t&&!n?null:{loop_id:t??null,session_id:o(e.session_id)??null,status:n??null,current_cycle:i(e.current_cycle)??void 0,best_score:i(e.best_score)??null,last_decision:o(e.last_decision)??null,target_file:o(e.target_file)??null,workdir:o(e.workdir)??null,source_workdir:o(e.source_workdir)??null,program_note:o(e.program_note)??null,operation_id:o(e.operation_id)??null,queued_hypothesis:o(e.queued_hypothesis)??null,warnings:S(e.warnings).map(a=>typeof a=="string"?a.trim():"").filter(Boolean),error:o(e.error)??null}}function Hs(e){const t=u(e)?e:{};return{trace_id:o(t.trace_id),target_type:o(t.target_type)??"room",target_id:o(t.target_id)??null,health:o(t.health),judgment_owner:o(t.judgment_owner)??null,authoritative_judgment_available:k(t.authoritative_judgment_available),resident_judge_runtime:Us(t.resident_judge_runtime),judgment:hu(t.judgment),active_guidance_layer:o(t.active_guidance_layer)??null,active_summary:Rn(t.active_summary),active_recommended_actions:S(t.active_recommended_actions).map($t).filter(n=>n!==null),active_recommendation_source:o(t.active_recommendation_source)??null,active_recommendation_summary:Rn(t.active_recommendation_summary),fallback_recommended_actions:S(t.fallback_recommended_actions).map($t).filter(n=>n!==null),recommendation_summary:Rn(t.recommendation_summary),swarm_status:u(t.swarm_status)?t.swarm_status:void 0,attention_items:S(t.attention_items).map(Ks).filter(n=>n!==null),recommended_actions:S(t.recommended_actions).map($t).filter(n=>n!==null),session_cards:S(t.session_cards).map(yu).filter(n=>n!==null),worker_cards:S(t.worker_cards).map(xu).filter(n=>n!==null)}}function $u(e){if(!u(e))return null;const t=u(e.status)?e.status:void 0,n=u(e.summary)?e.summary:u(t==null?void 0:t.summary)?t.summary:void 0,a=u(e.session)?e.session:u(t==null?void 0:t.session)?t.session:void 0,s=o(e.session_id)??o(n==null?void 0:n.session_id)??o(a==null?void 0:a.session_id);if(!s)return null;const r=so(e.report_paths)??so(t==null?void 0:t.report_paths),l=S(e.recent_events,["events"]).filter(u);return{session_id:s,status:o(e.status)??o(n==null?void 0:n.status)??o(a==null?void 0:a.status),progress_pct:i(e.progress_pct)??i(n==null?void 0:n.progress_pct),elapsed_sec:i(e.elapsed_sec)??i(n==null?void 0:n.elapsed_sec),remaining_sec:i(e.remaining_sec)??i(n==null?void 0:n.remaining_sec),done_delta_total:i(e.done_delta_total)??i(n==null?void 0:n.done_delta_total),summary:n,team_health:u(e.team_health)?e.team_health:u(t==null?void 0:t.team_health)?t.team_health:void 0,communication_metrics:u(e.communication_metrics)?e.communication_metrics:u(t==null?void 0:t.communication_metrics)?t.communication_metrics:void 0,orchestration_state:u(e.orchestration_state)?e.orchestration_state:u(t==null?void 0:t.orchestration_state)?t.orchestration_state:void 0,cascade_metrics:u(e.cascade_metrics)?e.cascade_metrics:u(t==null?void 0:t.cascade_metrics)?t.cascade_metrics:void 0,report_paths:r,linked_autoresearch:ro(e.linked_autoresearch)??ro(t==null?void 0:t.linked_autoresearch)??null,session:a,recent_events:l}}function io(e){if(!u(e))return null;const t=o(e.name);if(!t)return null;const n=u(e.context)?e.context:void 0;return{name:t,runtime_class:e.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:k(e.desired),resident_registered:k(e.resident_registered),agent_name:o(e.agent_name),status:o(e.status),autonomy_level:o(e.autonomy_level),context_ratio:i(e.context_ratio)??i(n==null?void 0:n.context_ratio),generation:i(e.generation),active_goal_ids:C(e.active_goal_ids),last_autonomous_action_at:o(e.last_autonomous_action_at)??null,last_turn_ago_s:i(e.last_turn_ago_s),model:o(e.model)??o(e.active_model)??o(e.primary_model)}}function ku(e){const t=u(e)?e:{},n=pu(t.pending_confirm_envelope);return{room:bu(t.room),sessions:S(t.sessions,["items","sessions"]).map($u).filter(a=>a!==null),keepers:S(t.keepers,["items","keepers"]).map(io).filter(a=>a!==null),resident_judge_runtime:Us(t.resident_judge_runtime),persistent_agents:S(t.persistent_agents,["items","persistent_agents"]).map(io).filter(a=>a!==null),recent_messages:S(t.recent_messages,["messages"]).map(gu).filter(a=>a!==null),pending_confirms:(n==null?void 0:n.items)??S(t.pending_confirms,["items","confirms"]).map(Fs).filter(a=>a!==null),pending_confirm_envelope:n??void 0,pending_confirm_summary:(n==null?void 0:n.summary)??Bs(t.pending_confirm_summary)??void 0,available_actions:S(t.available_actions,["actions"]).map(qs).filter(a=>a!==null)}}function Ft(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e)}catch{return String(e)}}function lo(e){return e.target_id?`${e.target_type}:${e.target_id}`:e.target_type}function dn(e){oo.value=[{...e,id:vu++,at:new Date().toISOString()},...oo.value].slice(0,20)}function Gs(e){return e.confirm_required?Ft(e.preview)||"Confirmation required":Ft(e.result)||Ft(e.executed_action)||Ft(e.delegated_tool_result)||e.status}async function ot(){ao.value=!0,at.value=null;try{const e=await si();Xn.value=ku(e)}catch(e){at.value=e instanceof Error?e.message:"Failed to load operator snapshot"}finally{ao.value=!1}}async function Sn(){ln.value=!0,cn.value=null;try{const e=await ds({targetType:"room"});fu.value=Hs(e)}catch(e){cn.value=e instanceof Error?e.message:"Failed to load operator digest"}finally{ln.value=!1}}async function ga(e){if(!e){Se.value=null;return}ln.value=!0,cn.value=null;try{const t=await ds({targetType:"team_session",targetId:e,includeWorkers:!0});Se.value=Hs(t)}catch(t){cn.value=t instanceof Error?t.message:"Failed to load session digest"}finally{ln.value=!1}}async function jf(e){var t;un.value=!0,at.value=null;try{const n=await zt(e);return dn({actor:e.actor,action_type:e.action_type,target_label:lo(e),outcome:n.confirm_required?"preview":"executed",message:Gs(n),delegated_tool:n.delegated_tool}),await ot(),await Sn(),(t=Se.value)!=null&&t.target_id&&await ga(Se.value.target_id),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";throw at.value=a,dn({actor:e.actor,action_type:e.action_type,target_label:lo(e),outcome:"error",message:a}),n}finally{un.value=!1}}async function Df(e,t,n="confirm"){var a;un.value=!0,at.value=null;try{const s=await oi(e,t,n);return dn({actor:e,action_type:n,target_label:t,outcome:"confirmed",message:Gs(s),delegated_tool:s.delegated_tool}),await ot(),await Sn(),(a=Se.value)!=null&&a.target_id&&await ga(Se.value.target_id),s}catch(s){const r=s instanceof Error?s.message:"Operator confirmation failed";throw at.value=r,dn({actor:e,action_type:"confirm",target_label:t,outcome:"error",message:r}),s}finally{un.value=!1}}wc(()=>{var e;ot(),Sn(),(e=Se.value)!=null&&e.target_id&&ga(Se.value.target_id)});const me=m(null),Nf=ie(()=>{var e;return((e=me.value)==null?void 0:e.agent_briefs)??[]}),qf=ie(()=>{var e;return((e=me.value)==null?void 0:e.keeper_briefs)??[]}),Yn=m(!1),Qn=m(null),Su=m(null),co=m(!1),uo=m(null),_o=m(null),zn=m(!1),On=m(null);let Qe=null;function mo(){Qe!==null&&(window.clearTimeout(Qe),Qe=null)}function Au(e,t=1500){Qe===null&&(Qe=window.setTimeout(()=>{Qe=null,e(!1)},t))}function Tu(e){if(!u(e))return null;const t=o(e.id),n=o(e.kind),a=o(e.summary),s=o(e.target_type);return!t||!n||!a||!s?null:{id:t,kind:n,severity:o(e.severity)??"warn",summary:a,target_type:s,target_id:o(e.target_id)??null,top_action:Ae(e.top_action),related_session_ids:S(e.related_session_ids).map(r=>typeof r=="string"?r.trim():"").filter(Boolean),related_agent_names:S(e.related_agent_names).map(r=>typeof r=="string"?r.trim():"").filter(Boolean),evidence_preview:S(e.evidence_preview).map(r=>typeof r=="string"?r.trim():"").filter(Boolean),last_seen_at:o(e.last_seen_at)??null}}function Ws(e){if(!u(e))return null;const t=o(e.session_id),n=o(e.goal);return!t||!n?null:{session_id:t,goal:n,created_by:o(e.created_by)??null,origin_kind:o(e.origin_kind)==="system"?"system":"human",room:o(e.room)??null,status:o(e.status),health:o(e.health),member_names:S(e.member_names).map(a=>typeof a=="string"?a.trim():"").filter(Boolean),started_at:o(e.started_at)??null,elapsed_sec:i(e.elapsed_sec)??null,operation_id:o(e.operation_id)??null,blocker_summary:o(e.blocker_summary)??null,last_event_at:o(e.last_event_at)??null,last_event_summary:o(e.last_event_summary)??null,communication_summary:o(e.communication_summary)??null,active_count:i(e.active_count),seen_count:i(e.seen_count),planned_count:i(e.planned_count),required_count:i(e.required_count),counts_basis:o(e.counts_basis)??null,related_attention_count:i(e.related_attention_count)??0,top_attention:Ne(e.top_attention),top_recommendation:Ae(e.top_recommendation)}}function Js(e){if(!u(e))return null;const t=o(e.agent_name);return t?{agent_name:t,display_name:o(e.display_name)??null,is_live:typeof e.is_live=="boolean"?e.is_live:void 0,current_work:o(e.current_work)??null,recent_input_preview:o(e.recent_input_preview)??null,recent_output_preview:o(e.recent_output_preview)??null,recent_tool_names:S(e.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_activity_at:o(e.last_activity_at)??null}:null}function Vs(e){if(!u(e))return null;const t=o(e.operation_id);return t?{operation_id:t,status:o(e.status),stage:o(e.stage)??null,detachment_status:o(e.detachment_status)??null,objective:o(e.objective)??null,updated_at:o(e.updated_at)??null}:null}function Xs(e){if(!u(e))return null;const t=o(e.name);return t?{name:t,agent_name:o(e.agent_name)??null,status:o(e.status),generation:i(e.generation),context_ratio:i(e.context_ratio)??null,last_turn_ago_s:i(e.last_turn_ago_s)??null,current_work:o(e.current_work)??null}:null}function Ys(e){const t=Ws(e);return t?{...t,member_previews:S(u(e)?e.member_previews:void 0).map(Js).filter(n=>n!==null),operation_badges:S(u(e)?e.operation_badges:void 0).map(Vs).filter(n=>n!==null),keeper_refs:S(u(e)?e.keeper_refs:void 0).map(Xs).filter(n=>n!==null)}:null}function Cu(e){if(!u(e))return null;const t=o(e.agent_name);return t?{agent_name:t,display_name:o(e.display_name)??null,is_live:typeof e.is_live=="boolean"?e.is_live:void 0,archived_reason:o(e.archived_reason)??null,status:o(e.status),where:o(e.where)??null,with_whom:S(e.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:o(e.current_work)??null,related_session_id:o(e.related_session_id)??null,related_attention_count:i(e.related_attention_count)??0,last_activity_at:o(e.last_activity_at)??null,last_activity_age_sec:i(e.last_activity_age_sec)??null,signal_truth:o(e.signal_truth)==="live"||o(e.signal_truth)==="stale"||o(e.signal_truth)==="archived"||o(e.signal_truth)==="unknown"?o(e.signal_truth):void 0,evidence_source:o(e.evidence_source)==="message"||o(e.evidence_source)==="presence"||o(e.evidence_source)==="session"||o(e.evidence_source)==="none"?o(e.evidence_source):void 0,recent_output_preview:o(e.recent_output_preview)??null,recent_input_preview:o(e.recent_input_preview)??null,recent_tool_names:S(e.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean)}:null}function Eu(e){if(!u(e))return null;const t=o(e.name);return t?{name:t,agent_name:o(e.agent_name)??null,status:o(e.status),generation:i(e.generation),context_ratio:i(e.context_ratio)??null,last_turn_ago_s:i(e.last_turn_ago_s)??null,current_work:o(e.current_work)??null,last_autonomous_action_at:o(e.last_autonomous_action_at)??null,allowed_tool_names:S(e.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:S(e.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:i(e.latest_tool_call_count)??null,tool_audit_source:o(e.tool_audit_source)??null,tool_audit_at:o(e.tool_audit_at)??null}:null}function Pu(e){if(!u(e))return null;const t=o(e.id),n=o(e.signal_type),a=o(e.summary),s=o(e.target_type);return!t||!n||!a||!s?null:{id:t,signal_type:n==="action"?"action":"attention",severity:o(e.severity)??"warn",summary:a,target_type:s,target_id:o(e.target_id)??null,attention:Ne(e.attention),action:Ae(e.action)}}function Ru(e){if(!u(e))return null;const t=o(e.id),n=o(e.summary);return!t||!n?null:{id:t,timestamp:o(e.timestamp)??null,event_type:o(e.event_type),actor:o(e.actor)??null,summary:n}}function zu(e){if(!u(e))return null;const t=o(e.session_id);return t?{session_id:t,goal:o(e.goal),status:o(e.status),health:o(e.health),scale_profile:o(e.scale_profile),control_profile:o(e.control_profile),planned_worker_count:i(e.planned_worker_count),active_agent_count:i(e.active_agent_count),last_turn_age_sec:i(e.last_turn_age_sec)??null,attention_count:i(e.attention_count),recommended_action_count:i(e.recommended_action_count),top_attention:Ne(e.top_attention),top_recommendation:Ae(e.top_recommendation)}:null}function Ou(e){if(!u(e))return null;const t=o(e.session_id);if(!t)return null;const n=u(e.status)?e.status:e,a=u(n.summary)?n.summary:void 0;return{session_id:t,status:o(e.status)??o(a==null?void 0:a.status)??(u(n.session)?o(n.session.status):void 0),progress_pct:i(e.progress_pct)??i(a==null?void 0:a.progress_pct),elapsed_sec:i(e.elapsed_sec)??i(a==null?void 0:a.elapsed_sec),remaining_sec:i(e.remaining_sec)??i(a==null?void 0:a.remaining_sec),done_delta_total:i(e.done_delta_total)??i(a==null?void 0:a.done_delta_total),summary:u(e.summary)?e.summary:a,team_health:u(e.team_health)?e.team_health:u(n.team_health)?n.team_health:void 0,communication_metrics:u(e.communication_metrics)?e.communication_metrics:u(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:u(e.orchestration_state)?e.orchestration_state:u(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:u(e.cascade_metrics)?e.cascade_metrics:u(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:u(e.report_paths)?Object.fromEntries(Object.entries(e.report_paths).map(([s,r])=>{const l=o(r);return l?[s,l]:null}).filter(s=>s!==null)):u(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([s,r])=>{const l=o(r);return l?[s,l]:null}).filter(s=>s!==null)):void 0,session:u(e.session)?e.session:u(n.session)?n.session:void 0,recent_events:S(e.recent_events,["events"]).filter(u)}}function Iu(e){if(!u(e))return null;const t=o(e.name);return t?{name:t,agent_name:o(e.agent_name),status:o(e.status),autonomy_level:o(e.autonomy_level),context_ratio:i(e.context_ratio),generation:i(e.generation),active_goal_ids:S(e.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:o(e.last_autonomous_action_at)??null,last_turn_ago_s:i(e.last_turn_ago_s),model:o(e.model)}:null}function Lu(e){if(!u(e))return null;const t=o(e.confirm_token)??o(e.token);return t?{confirm_token:t,actor:o(e.actor),action_type:o(e.action_type),target_type:o(e.target_type),target_id:o(e.target_id)??null,delegated_tool:o(e.delegated_tool),created_at:o(e.created_at),preview:e.preview}:null}function Mu(e){if(!u(e))return null;const t=o(e.action_type),n=o(e.target_type);return!t||!n?null:{action_type:t,target_type:n,description:o(e.description),confirm_required:k(e.confirm_required)}}function ju(e){const t=u(e)?e:{};return{room_health:o(t.room_health),cluster:o(t.cluster),project:o(t.project),current_room:o(t.current_room)??o(t.room)??null,paused:k(t.paused),tempo_interval_s:i(t.tempo_interval_s),active_agents:i(t.active_agents),keeper_pressure:i(t.keeper_pressure),active_operations:i(t.active_operations),pending_approvals:i(t.pending_approvals),incident_count:i(t.incident_count),recommended_action_count:i(t.recommended_action_count),top_attention:Ne(t.top_attention),top_action:Ae(t.top_action)}}function Du(e){const t=u(e)?e:{},n=u(t.swarm_overview)?t.swarm_overview:{};return{health:o(t.health),active_operations:i(t.active_operations),pending_approvals:i(t.pending_approvals),swarm_overview:{active_lanes:i(n.active_lanes),moving_lanes:i(n.moving_lanes),stalled_lanes:i(n.stalled_lanes),projected_lanes:i(n.projected_lanes),last_movement_at:o(n.last_movement_at)??null},top_attention:Ne(t.top_attention),top_action:Ae(t.top_action),session_cards:S(t.session_cards).map(zu).filter(a=>a!==null)}}function Nu(e){const t=u(e)?e:{};return{sessions:S(t.sessions,["items"]).map(Ou).filter(n=>n!==null),keepers:S(t.keepers,["items"]).map(Iu).filter(n=>n!==null),pending_confirms:S(t.pending_confirms).map(Lu).filter(n=>n!==null),available_actions:S(t.available_actions).map(Mu).filter(n=>n!==null)}}function qu(e){const t=u(e)?e:{},n=S(t.session_briefs).map(Ws).filter(s=>s!==null),a=S(t.sessions).map(Ys).filter(s=>s!==null);return{generated_at:o(t.generated_at),summary:ju(t.summary),incidents:S(t.incidents).map(Ne).filter(s=>s!==null),recommended_actions:S(t.recommended_actions).map(Ae).filter(s=>s!==null),command_focus:Du(t.command_focus),operator_targets:Nu(t.operator_targets),attention_queue:S(t.attention_queue).map(Tu).filter(s=>s!==null),sessions:a.length>0?a:n.map(s=>({...s,member_previews:[],operation_badges:[],keeper_refs:[]})),session_briefs:n,agent_briefs:S(t.agent_briefs).map(Cu).filter(s=>s!==null),keeper_briefs:S(t.keeper_briefs).map(Eu).filter(s=>s!==null),internal_signals:S(t.internal_signals).map(Pu).filter(s=>s!==null)}}function Fu(e){const t=u(e)?e:{};return{generated_at:o(t.generated_at),session_id:o(t.session_id)??"",session:Ys(t.session),timeline:S(t.timeline).map(Ru).filter(n=>n!==null),participants:S(t.participants).map(Js).filter(n=>n!==null),operations:S(t.operations).map(Vs).filter(n=>n!==null),keepers:S(t.keepers).map(Xs).filter(n=>n!==null),error:o(t.error)??null}}function Bu(e){if(!u(e))return null;const t=o(e.id),n=o(e.label),a=o(e.summary);if(!t||!n||!a)return null;const s=o(e.status)??"unclear";return{id:t,label:n,status:s==="ok"||s==="healthy"||s==="aligned"||s==="watch"||s==="risk"||s==="unclear"?s:"unclear",summary:a,signal_class:o(e.signal_class)==="metadata_gap"||o(e.signal_class)==="mixed"||o(e.signal_class)==="operational_risk"?o(e.signal_class):void 0,evidence_quality:o(e.evidence_quality)==="strong"||o(e.evidence_quality)==="partial"||o(e.evidence_quality)==="missing"?o(e.evidence_quality):void 0,evidence:S(e.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function Ku(e){if(!u(e))return null;const t=o(e.kind),n=o(e.summary),a=o(e.scope_type),s=o(e.severity);return!t||!n||!a||!s||a!=="session"&&a!=="keeper"&&a!=="agent"||s!=="info"&&s!=="watch"?null:{kind:t,summary:n,scope_type:a,scope_id:o(e.scope_id)??null,severity:s}}function Uu(e){const t=u(e)?e:{},n=u(t.basis)?t.basis:{},a=o(t.status)??"error",s=a==="ok"||a==="pending"||a==="unavailable"||a==="error"?a:"error";return{generated_at:o(t.generated_at),cached:k(t.cached),stale:k(t.stale),refreshing:k(t.refreshing),status:s,summary:o(t.summary)??null,model:o(t.model)??null,ttl_sec:i(t.ttl_sec),criteria:S(t.criteria).map(r=>typeof r=="string"?r.trim():"").filter(Boolean),basis:{current_room:o(n.current_room)??null,crew_count:i(n.crew_count),agent_count:i(n.agent_count),keeper_count:i(n.keeper_count)},metadata_gap_count:i(t.metadata_gap_count),metadata_gaps:S(t.metadata_gaps).map(Ku).filter(r=>r!==null),sections:S(t.sections).map(Bu).filter(r=>r!==null),error:o(t.error)??null,last_error:o(t.last_error)??null}}async function Vt(){Yn.value=!0,Qn.value=null;try{const e=await Gi();me.value=qu(e)}catch(e){Qn.value=e instanceof Error?e.message:"Failed to load mission snapshot"}finally{Yn.value=!1}}async function Ff(e){if(!e){_o.value=null,On.value=null,zn.value=!1;return}zn.value=!0,On.value=null;try{const t=await Wi(e);_o.value=Fu(t)}catch(t){On.value=t instanceof Error?t.message:"Failed to load session detail"}finally{zn.value=!1}}async function Qs(e=!1){co.value=!0,uo.value=null;try{const t=await Ji(e),n=Uu(t);Su.value=n,n.refreshing||n.status==="pending"?Au(Qs):mo()}catch(t){uo.value=t instanceof Error?t.message:"Failed to load mission briefing",mo()}finally{co.value=!1}}const Hu=m(null),po=m(!1),fo=m(null);async function Gu(e,t){po.value=!0,fo.value=null;try{Hu.value=await Vi(e,t)}catch(n){fo.value=n instanceof Error?n.message:String(n)}finally{po.value=!1}}function Wu(e){if(!u(e))return null;const t=o(e.code),n=o(e.severity),a=o(e.summary);return!t||!n||!a?null:{code:t,severity:n,summary:a}}function Ju(e){if(!u(e))return null;const t=o(e.lane_id),n=o(e.label),a=o(e.kind),s=o(e.phase),r=o(e.motion_state),l=o(e.source_of_truth),d=o(e.movement_reason),_=o(e.current_step);if(!t||!n||!a||!s||!r||!l||!d||!_)return null;const p=u(e.counts)?e.counts:{};return{lane_id:t,label:n,kind:a,present:k(e.present)??!1,phase:s,motion_state:r,source_of_truth:l,last_movement_at:o(e.last_movement_at)??null,movement_reason:d,current_step:_,blockers:C(e.blockers),counts:{operations:i(p.operations),detachments:i(p.detachments),workers:i(p.workers),approvals:i(p.approvals),alerts:i(p.alerts)},hard_flags:Array.isArray(e.hard_flags)?e.hard_flags.map(Wu).filter(f=>f!==null):[]}}function Vu(e){if(!u(e))return null;const t=o(e.event_id),n=o(e.lane_id),a=o(e.kind),s=o(e.timestamp),r=o(e.title),l=o(e.detail),d=o(e.tone),_=o(e.source);return!t||!n||!a||!s||!r||!l||!d||!_?null:{event_id:t,lane_id:n,kind:a,timestamp:s,title:r,detail:l,tone:d,source:_}}function Xu(e){if(!u(e))return null;const t=o(e.code),n=o(e.severity),a=o(e.summary);return!t||!n||!a?null:{code:t,severity:n,summary:a,why_it_matters:o(e.why_it_matters)??void 0,next_tool:o(e.next_tool)??void 0,next_step:o(e.next_step)??void 0,lane_ids:C(e.lane_ids),count:i(e.count)??0}}function ba(e){if(!u(e))return;const t=u(e.overview)?e.overview:{},n=u(e.gaps)?e.gaps:{},a=u(e.narrative)?e.narrative:{},s=u(e.recommended_next_action)?e.recommended_next_action:void 0;return{generated_at:o(e.generated_at),narrative:{state:o(a.state)??void 0,started:o(a.started)??void 0,active_work:o(a.active_work)??void 0,completion:o(a.completion)??void 0,lane_id:o(a.lane_id)??null},overview:{active_lanes:i(t.active_lanes),moving_lanes:i(t.moving_lanes),stalled_lanes:i(t.stalled_lanes),projected_lanes:i(t.projected_lanes),last_movement_at:o(t.last_movement_at)??null},lanes:Array.isArray(e.lanes)?e.lanes.map(Ju).filter(r=>r!==null):[],timeline:Array.isArray(e.timeline)?e.timeline.map(Vu).filter(r=>r!==null):[],gaps:{count:i(n.count),items:Array.isArray(n.items)?n.items.map(Xu).filter(r=>r!==null):[]},recommended_next_action:s?{tool:o(s.tool)??"masc_operator_snapshot",label:o(s.label)??"Observe operator state",reason:o(s.reason)??"",lane_id:o(s.lane_id)??null}:void 0}}function Zs(e){if(!u(e))return;const t=u(e.workers)?e.workers:{},n=k(e.pass);return{status:o(e.status)??"missing",source:o(e.source)??"none",reason_code:o(e.reason_code)??null,status_summary:o(e.status_summary)??null,run_id:o(e.run_id)??null,captured_at:o(e.captured_at)??null,...n!==void 0?{pass:n}:{},...i(e.peak_hot_slots)!=null?{peak_hot_slots:i(e.peak_hot_slots)}:{},...i(e.ctx_per_slot)!=null?{ctx_per_slot:i(e.ctx_per_slot)}:{},workers:{expected:i(t.expected),joined:i(t.joined),current_task_bound:i(t.current_task_bound),fresh_heartbeats:i(t.fresh_heartbeats),done:i(t.done),final:i(t.final)},expected_artifact_dir:o(e.expected_artifact_dir)??null,artifact_ref:o(e.artifact_ref)??null,missing_reason:o(e.missing_reason)??null}}function Yu(e){if(u(e))return{policy_class:o(e.policy_class),approval_class:o(e.approval_class),tool_allowlist:C(e.tool_allowlist),model_allowlist:C(e.model_allowlist),requires_human_for:C(e.requires_human_for),autonomy_level:o(e.autonomy_level),escalation_timeout_sec:i(e.escalation_timeout_sec),kill_switch:k(e.kill_switch),frozen:k(e.frozen)}}function Qu(e){if(u(e))return{headcount_cap:i(e.headcount_cap),active_operation_cap:i(e.active_operation_cap),max_cost_usd:i(e.max_cost_usd),max_tokens:i(e.max_tokens)}}function ha(e){if(!u(e))return null;const t=o(e.unit_id),n=o(e.label),a=o(e.kind);return!t||!n||!a?null:{unit_id:t,label:n,kind:a,parent_unit_id:o(e.parent_unit_id)??null,leader_id:o(e.leader_id)??null,roster:C(e.roster),capability_profile:C(e.capability_profile),source:o(e.source),created_at:o(e.created_at),updated_at:o(e.updated_at),policy:Yu(e.policy),budget:Qu(e.budget)}}function ws(e){if(!u(e))return null;const t=ha(e.unit);return t?{unit:t,leader_status:o(e.leader_status),roster_total:i(e.roster_total),roster_live:i(e.roster_live),active_operation_count:i(e.active_operation_count),health:o(e.health),reasons:C(e.reasons),children:Array.isArray(e.children)?e.children.map(ws).filter(n=>n!==null):[]}:null}function Zu(e){if(u(e))return{total_units:i(e.total_units),company_count:i(e.company_count),platoon_count:i(e.platoon_count),squad_count:i(e.squad_count),leaf_agent_unit_count:i(e.leaf_agent_unit_count),live_agent_count:i(e.live_agent_count),managed_unit_count:i(e.managed_unit_count),active_operation_count:i(e.active_operation_count)}}function er(e){const t=u(e)?e:{};return{version:o(t.version),generated_at:o(t.generated_at),source:o(t.source),summary:Zu(t.summary),units:Array.isArray(t.units)?t.units.map(ws).filter(n=>n!==null):[]}}function wu(e){if(!u(e))return null;const t=o(e.kind),n=o(e.status);return!t||!n?null:{kind:t,chain_id:o(e.chain_id)??null,goal:o(e.goal)??null,run_id:o(e.run_id)??null,status:n,viewer_path:o(e.viewer_path)??null,last_sync_at:o(e.last_sync_at)??null}}function An(e){if(!u(e))return null;const t=o(e.operation_id),n=o(e.objective),a=o(e.assigned_unit_id),s=o(e.trace_id),r=o(e.status);return!t||!n||!a||!s||!r?null:{operation_id:t,objective:n,assigned_unit_id:a,autonomy_level:o(e.autonomy_level),policy_class:o(e.policy_class),budget_class:o(e.budget_class),detachment_session_id:o(e.detachment_session_id)??null,trace_id:s,checkpoint_ref:o(e.checkpoint_ref)??null,active_goal_ids:C(e.active_goal_ids),note:o(e.note)??null,created_by:o(e.created_by),source:o(e.source),status:r,chain:wu(e.chain),created_at:o(e.created_at),updated_at:o(e.updated_at)}}function ed(e){if(!u(e))return null;const t=An(e.operation);return t?{operation:t,assigned_unit_label:o(e.assigned_unit_label)}:null}function _t(e){if(u(e))return{tone:o(e.tone),pending_ops:i(e.pending_ops),blocked_ops:i(e.blocked_ops),in_flight_ops:i(e.in_flight_ops),pipeline_stalls:i(e.pipeline_stalls),bus_traffic:i(e.bus_traffic),l1_hit_rate:i(e.l1_hit_rate),invalidation_count:i(e.invalidation_count),current_pending:i(e.current_pending),current_in_flight:i(e.current_in_flight),cdb_wakeups:i(e.cdb_wakeups),total_stolen:i(e.total_stolen),avg_best_score:i(e.avg_best_score),avg_candidate_count:i(e.avg_candidate_count),best_first_operations:i(e.best_first_operations),active_sessions:i(e.active_sessions),commit_rate:i(e.commit_rate),total_speculations:i(e.total_speculations)}}function td(e){if(!u(e))return;const t=u(e.pipeline)?e.pipeline:void 0,n=u(e.cache)?e.cache:void 0,a=u(e.ooo)?e.ooo:void 0,s=u(e.speculative)?e.speculative:void 0,r=u(e.search_fabric)?e.search_fabric:void 0,l=u(e.signals)?e.signals:void 0;return{pipeline:t?{total_ops:i(t.total_ops),completed_ops:i(t.completed_ops),stalled_cycles:i(t.stalled_cycles),hazards_detected:i(t.hazards_detected),forwarding_used:i(t.forwarding_used),pipeline_flushes:i(t.pipeline_flushes),ipc:i(t.ipc)}:void 0,cache:n?{total_reads:i(n.total_reads),total_writes:i(n.total_writes),l1_hit_rate:i(n.l1_hit_rate),invalidation_count:i(n.invalidation_count),writeback_count:i(n.writeback_count),bus_traffic:i(n.bus_traffic)}:void 0,ooo:a?{agent_count:i(a.agent_count),total_added:i(a.total_added),total_issued:i(a.total_issued),total_completed:i(a.total_completed),total_stolen:i(a.total_stolen),cdb_wakeups:i(a.cdb_wakeups),stall_cycles:i(a.stall_cycles),global_cdb_events:i(a.global_cdb_events),current_pending:i(a.current_pending),current_in_flight:i(a.current_in_flight)}:void 0,speculative:s?{total_speculations:i(s.total_speculations),total_commits:i(s.total_commits),total_aborts:i(s.total_aborts),commit_rate:i(s.commit_rate),total_fast_calls:i(s.total_fast_calls),total_cost_usd:i(s.total_cost_usd),active_sessions:i(s.active_sessions)}:void 0,search_fabric:r?{total_operations:i(r.total_operations),best_first_operations:i(r.best_first_operations),legacy_operations:i(r.legacy_operations),blocked_operations:i(r.blocked_operations),ready_operations:i(r.ready_operations),research_pipeline_operations:i(r.research_pipeline_operations),avg_candidate_count:i(r.avg_candidate_count),avg_best_score:i(r.avg_best_score),top_stage:o(r.top_stage)??null}:void 0,signals:l?{issue_pressure:_t(l.issue_pressure),cache_contention:_t(l.cache_contention),scheduler_efficiency:_t(l.scheduler_efficiency),routing_confidence:_t(l.routing_confidence),speculative_posture:_t(l.speculative_posture)}:void 0}}function tr(e){const t=u(e)?e:{},n=u(t.summary)?t.summary:void 0;return{version:o(t.version),generated_at:o(t.generated_at),summary:n?{total:i(n.total),active:i(n.active),paused:i(n.paused),managed:i(n.managed),projected:i(n.projected)}:void 0,microarch:td(t.microarch),operations:Array.isArray(t.operations)?t.operations.map(ed).filter(a=>a!==null):[]}}function nr(e){if(!u(e))return null;const t=o(e.detachment_id),n=o(e.operation_id),a=o(e.assigned_unit_id);return!t||!n||!a?null:{detachment_id:t,operation_id:n,assigned_unit_id:a,leader_id:o(e.leader_id)??null,roster:C(e.roster),session_id:o(e.session_id)??null,checkpoint_ref:o(e.checkpoint_ref)??null,runtime_kind:o(e.runtime_kind)??null,runtime_ref:o(e.runtime_ref)??null,source:o(e.source),status:o(e.status),last_event_at:o(e.last_event_at)??null,last_progress_at:o(e.last_progress_at)??null,heartbeat_deadline:o(e.heartbeat_deadline)??null,created_at:o(e.created_at),updated_at:o(e.updated_at)}}function nd(e){if(!u(e))return null;const t=nr(e.detachment);return t?{detachment:t,assigned_unit_label:o(e.assigned_unit_label),operation:An(e.operation)}:null}function ar(e){const t=u(e)?e:{},n=u(t.summary)?t.summary:void 0;return{version:o(t.version),generated_at:o(t.generated_at),summary:n?{total:i(n.total),active:i(n.active),projected:i(n.projected)}:void 0,detachments:Array.isArray(t.detachments)?t.detachments.map(nd).filter(a=>a!==null):[]}}function ad(e){if(!u(e))return null;const t=o(e.decision_id),n=o(e.trace_id),a=o(e.requested_action),s=o(e.scope_type),r=o(e.scope_id);return!t||!n||!a||!s||!r?null:{decision_id:t,trace_id:n,requested_action:a,scope_type:s,scope_id:r,operation_id:o(e.operation_id)??null,target_unit_id:o(e.target_unit_id)??null,requested_by:o(e.requested_by),status:o(e.status),reason:o(e.reason)??null,source:o(e.source),detail:e.detail,created_at:o(e.created_at),decided_at:o(e.decided_at)??null,expires_at:o(e.expires_at)??null}}function or(e){const t=u(e)?e:{},n=u(t.summary)?t.summary:void 0;return{version:o(t.version),generated_at:o(t.generated_at),summary:n?{total:i(n.total),pending:i(n.pending),approved:i(n.approved),denied:i(n.denied)}:void 0,decisions:Array.isArray(t.decisions)?t.decisions.map(ad).filter(a=>a!==null):[]}}function od(e){if(!u(e))return null;const t=ha(e.unit);return t?{unit:t,roster_total:i(e.roster_total),roster_live:i(e.roster_live),headcount_cap:i(e.headcount_cap),active_operations:i(e.active_operations),active_operation_cap:i(e.active_operation_cap),utilization:i(e.utilization)}:null}function sd(e){const t=u(e)?e:{};return{version:o(t.version),generated_at:o(t.generated_at),capacity:Array.isArray(t.capacity)?t.capacity.map(od).filter(n=>n!==null):[]}}function rd(e){if(!u(e))return null;const t=o(e.alert_id);return t?{alert_id:t,severity:o(e.severity),kind:o(e.kind),scope_type:o(e.scope_type),scope_id:o(e.scope_id),title:o(e.title),detail:o(e.detail),timestamp:o(e.timestamp)}:null}function sr(e){const t=u(e)?e:{},n=u(t.summary)?t.summary:void 0;return{version:o(t.version),generated_at:o(t.generated_at),summary:n?{total:i(n.total),bad:i(n.bad),warn:i(n.warn)}:void 0,alerts:Array.isArray(t.alerts)?t.alerts.map(rd).filter(a=>a!==null):[]}}function rr(e){if(!u(e))return null;const t=o(e.event_id),n=o(e.trace_id),a=o(e.event_type);return!t||!n||!a?null:{event_id:t,trace_id:n,event_type:a,operation_id:o(e.operation_id)??null,unit_id:o(e.unit_id)??null,actor:o(e.actor)??null,source:o(e.source),timestamp:o(e.timestamp),detail:e.detail}}function id(e){const t=u(e)?e:{};return{version:o(t.version),generated_at:o(t.generated_at),events:Array.isArray(t.events)?t.events.map(rr).filter(n=>n!==null):[]}}function ld(e){if(!u(e))return null;const t=o(e.id),n=o(e.title),a=o(e.status),s=o(e.detail),r=o(e.next_tool);return!t||!n||!a||!s||!r?null:{id:t,title:n,status:a,detail:s,next_tool:r}}function cd(e){if(!u(e))return null;const t=o(e.code),n=o(e.severity),a=o(e.title),s=o(e.detail),r=o(e.next_tool);return!t||!n||!a||!s||!r?null:{code:t,severity:n,title:a,detail:s,next_tool:r}}function ud(e){if(!u(e))return null;const t=o(e.from),n=o(e.content),a=o(e.timestamp),s=i(e.seq);return!t||!n||!a||s==null?null:{seq:s,from:t,content:n,timestamp:a}}function dd(e){if(!u(e))return null;const t=o(e.name),n=o(e.role),a=o(e.lane),s=o(e.status),r=o(e.claim_marker),l=o(e.done_marker),d=o(e.final_marker);if(!t||!n||!a||!s||!r||!l||!d)return null;const _=(()=>{if(!u(e.last_message))return null;const p=i(e.last_message.seq),f=o(e.last_message.content),h=o(e.last_message.timestamp);return p==null||!f||!h?null:{seq:p,content:f,timestamp:h}})();return{name:t,role:n,lane:a,joined:k(e.joined)??!1,live_presence:k(e.live_presence)??!1,completed:k(e.completed)??!1,status:s,current_task:o(e.current_task)??null,bound_task_id:o(e.bound_task_id)??null,bound_task_title:o(e.bound_task_title)??null,bound_task_status:o(e.bound_task_status)??null,current_task_matches_run:k(e.current_task_matches_run)??!1,squad_member:k(e.squad_member)??!1,detachment_member:k(e.detachment_member)??!1,last_seen:o(e.last_seen)??null,heartbeat_age_sec:i(e.heartbeat_age_sec)??null,heartbeat_fresh:k(e.heartbeat_fresh)??!1,claim_marker_seen:k(e.claim_marker_seen)??!1,done_marker_seen:k(e.done_marker_seen)??!1,final_marker_seen:k(e.final_marker_seen)??!1,claim_marker:r,done_marker:l,final_marker:d,last_message:_}}function _d(e){if(!u(e))return;const t=Array.isArray(e.timeline)?e.timeline.map(n=>{if(!u(n))return null;const a=o(n.timestamp),s=i(n.active_slots);if(!a||s==null)return null;const r=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:a,active_slots:s,active_slot_ids:r}}).filter(n=>n!==null):[];return{slot_url:o(e.slot_url)??null,provider_base_url:o(e.provider_base_url)??null,provider_reachable:k(e.provider_reachable)??null,provider_status_code:i(e.provider_status_code)??null,provider_model_id:o(e.provider_model_id)??null,actual_model_id:o(e.actual_model_id)??null,expected_slots:i(e.expected_slots),actual_slots:i(e.actual_slots),expected_ctx:i(e.expected_ctx),actual_ctx:i(e.actual_ctx),configured_capacity:i(e.configured_capacity),slot_reachable:k(e.slot_reachable)??null,slot_status_code:i(e.slot_status_code)??null,runtime_blocker:o(e.runtime_blocker)??null,detail:o(e.detail)??null,checked_at:o(e.checked_at)??null,total_slots:i(e.total_slots),ctx_per_slot:i(e.ctx_per_slot),active_slots_now:i(e.active_slots_now),peak_active_slots:i(e.peak_active_slots),sample_count:i(e.sample_count),last_sample_at:o(e.last_sample_at)??null,timeline:t}}function md(e){if(!u(e))return null;const t=o(e.run_id),n=o(e.status),a=o(e.decided_by),s=o(e.decided_at),r=o(e.reason);if(!t||!n||!a||!s||!r)return null;const l=[];return Array.isArray(e.history)&&e.history.forEach(d=>{if(!u(d))return;const _=o(d.status),p=o(d.decided_by),f=o(d.decided_at),h=o(d.reason);!_||!p||!f||!h||l.push({status:_,decided_by:p,decided_at:f,reason:h,operation_id:o(d.operation_id)??null,detachment_id:o(d.detachment_id)??null,note:o(d.note)??null})}),{run_id:t,status:n,decided_by:a,decided_at:s,reason:r,operation_id:o(e.operation_id)??null,detachment_id:o(e.detachment_id)??null,note:o(e.note)??null,history:l}}function pd(e){if(!u(e))return null;const t=o(e.run_id),n=o(e.recommended_kind),a=o(e.reason);return!t||!n||!a?null:{run_id:t,recommended_kind:n,continue_available:k(e.continue_available)??!1,rerun_available:k(e.rerun_available)??!1,abandon_available:k(e.abandon_available)??!1,reason:a,evidence:u(e.evidence)?{operation_id:o(e.evidence.operation_id)??null,detachment_id:o(e.evidence.detachment_id)??null,joined_workers:i(e.evidence.joined_workers),current_task_bound:i(e.evidence.current_task_bound),fresh_heartbeats:i(e.evidence.fresh_heartbeats),trace_events:i(e.evidence.trace_events),message_events:i(e.evidence.message_events),runtime_blocker:o(e.evidence.runtime_blocker)??null}:void 0,provenance:o(e.provenance),decision_engine:o(e.decision_engine),authoritative:k(e.authoritative)}}function fd(e){const t=u(e)?e:{},n=u(t.summary)?t.summary:void 0;return{version:o(t.version),generated_at:o(t.generated_at),run_id:o(t.run_id),room_id:o(t.room_id),operation_id:o(t.operation_id)??null,run_resolution:md(t.run_resolution),resolution_recommendation:pd(t.resolution_recommendation),recommended_next_tool:o(t.recommended_next_tool),summary:n?{expected_workers:i(n.expected_workers),joined_workers:i(n.joined_workers),live_workers:i(n.live_workers),squad_roster_size:i(n.squad_roster_size),detachment_roster_size:i(n.detachment_roster_size),current_task_bound:i(n.current_task_bound),fresh_heartbeats:i(n.fresh_heartbeats),claim_markers_seen:i(n.claim_markers_seen),done_markers_seen:i(n.done_markers_seen),final_markers_seen:i(n.final_markers_seen),completed_workers:i(n.completed_workers),peak_hot_slots:i(n.peak_hot_slots),hot_window_ok:k(n.hot_window_ok),pass_hot_concurrency:k(n.pass_hot_concurrency),pass_end_to_end:k(n.pass_end_to_end),pending_decisions:i(n.pending_decisions),pass:k(n.pass)}:void 0,provider:_d(t.provider),operation:An(t.operation),squad:ha(t.squad),detachment:nr(t.detachment),workers:Array.isArray(t.workers)?t.workers.map(dd).filter(a=>a!==null):[],checklist:Array.isArray(t.checklist)?t.checklist.map(ld).filter(a=>a!==null):[],blockers:Array.isArray(t.blockers)?t.blockers.map(cd).filter(a=>a!==null):[],recent_messages:Array.isArray(t.recent_messages)?t.recent_messages.map(ud).filter(a=>a!==null):[],recent_trace_events:Array.isArray(t.recent_trace_events)?t.recent_trace_events.map(rr).filter(a=>a!==null):[],truth_notes:C(t.truth_notes)}}function vd(e){return u(e)?{chain_id:o(e.chain_id)??null,started_at:i(e.started_at)??null,progress:i(e.progress)??null,elapsed_sec:i(e.elapsed_sec)??null}:null}function ir(e){if(!u(e))return null;const t=o(e.event);return t?{event:t,chain_id:o(e.chain_id)??null,timestamp:o(e.timestamp)??null,duration_ms:i(e.duration_ms)??null,message:o(e.message)??null,tokens:i(e.tokens)??null}:null}function gd(e){if(!u(e))return null;const t=o(e.id);return t?{id:t,type:o(e.type),status:o(e.status),duration_ms:i(e.duration_ms)??null,error:o(e.error)??null}:null}function lr(e){if(!u(e))return null;const t=o(e.run_id),n=o(e.chain_id);return n?{run_id:t??null,chain_id:n,duration_ms:i(e.duration_ms),success:k(e.success),mermaid:o(e.mermaid),nodes:Array.isArray(e.nodes)?e.nodes.map(gd).filter(a=>a!==null):[]}:null}function bd(e){if(!u(e))return null;const t=An(e.operation);return t?{operation:t,runtime:vd(e.runtime),history:ir(e.history),mermaid:o(e.mermaid)??null,preview_run:lr(e.preview_run)}:null}function hd(e){const t=u(e)?e:{};return{status:o(t.status)??"disconnected",base_url:o(t.base_url)??null,message:o(t.message)??null}}function xd(e){const t=u(e)?e:{},n=u(t.summary)?t.summary:void 0;return{version:o(t.version),generated_at:o(t.generated_at),connection:hd(t.connection),summary:n?{linked_operations:i(n.linked_operations),active_chains:i(n.active_chains),running_operations:i(n.running_operations),recent_failures:i(n.recent_failures),last_history_event_at:o(n.last_history_event_at)??null}:void 0,operations:Array.isArray(t.operations)?t.operations.map(bd).filter(a=>a!==null):[],recent_history:Array.isArray(t.recent_history)?t.recent_history.map(ir).filter(a=>a!==null):[]}}function yd(e){const t=u(e)?e:{};return{run:lr(t.run)}}function $d(e){if(!u(e))return null;const t=o(e.title),n=o(e.path);return!t||!n?null:{title:t,path:n}}function kd(e){if(!u(e))return null;const t=o(e.id),n=o(e.title),a=o(e.summary);return!t||!n||!a?null:{id:t,title:n,summary:a}}function Sd(e){if(!u(e))return null;const t=o(e.id),n=o(e.title),a=o(e.tool),s=o(e.summary);return!t||!n||!a||!s?null:{id:t,title:n,tool:a,summary:s,success_signals:C(e.success_signals),pitfalls:C(e.pitfalls)}}function Ad(e){if(!u(e))return null;const t=o(e.id),n=o(e.title),a=o(e.summary),s=o(e.when_to_use);return!t||!n||!a||!s?null:{id:t,title:n,summary:a,when_to_use:s,steps:Array.isArray(e.steps)?e.steps.map(Sd).filter(r=>r!==null):[]}}function Td(e){if(!u(e))return null;const t=o(e.id),n=o(e.title),a=o(e.description);return!t||!n||!a?null:{id:t,title:n,description:a,tools:C(e.tools)}}function Cd(e){if(!u(e))return null;const t=o(e.id),n=o(e.title),a=o(e.symptom),s=o(e.why),r=o(e.fix_tool),l=o(e.fix_summary);return!t||!n||!a||!s||!r||!l?null:{id:t,title:n,symptom:a,why:s,fix_tool:r,fix_summary:l}}function Ed(e){if(!u(e))return null;const t=o(e.id),n=o(e.title),a=o(e.path_id),s=o(e.transport);return!t||!n||!a||!s?null:{id:t,title:n,path_id:a,transport:s,request:e.request,response:e.response,notes:C(e.notes)}}function Pd(e){const t=u(e)?e:{};return{version:o(t.version),generated_at:o(t.generated_at),docs:Array.isArray(t.docs)?t.docs.map($d).filter(n=>n!==null):[],concepts:Array.isArray(t.concepts)?t.concepts.map(kd).filter(n=>n!==null):[],golden_paths:Array.isArray(t.golden_paths)?t.golden_paths.map(Ad).filter(n=>n!==null):[],tool_groups:Array.isArray(t.tool_groups)?t.tool_groups.map(Td).filter(n=>n!==null):[],pitfalls:Array.isArray(t.pitfalls)?t.pitfalls.map(Cd).filter(n=>n!==null):[],examples:Array.isArray(t.examples)?t.examples.map(Ed).filter(n=>n!==null):[]}}function Rd(e){if(!u(e))return null;const t=o(e.label),n=o(e.value);return!t||!n?null:{label:t,value:n}}function zd(e){if(!u(e))return null;const t=o(e.id),n=o(e.kind),a=o(e.label),s=o(e.tone),r=o(e.provenance);return!t||!n||!a||!s||!r?null:{id:t,kind:n,label:a,subtitle:o(e.subtitle)??null,status:o(e.status)??null,tone:s,pulse:o(e.pulse)??null,provenance:r,visual_class:o(e.visual_class)??void 0,glyph:o(e.glyph)??void 0,parent_id:o(e.parent_id)??null,lane_id:o(e.lane_id)??null,link_tab:o(e.link_tab)??null,link_surface:o(e.link_surface)??null,link_params:u(e.link_params)?Object.fromEntries(Object.entries(e.link_params).map(([l,d])=>{const _=o(d);return _?[l,_]:null}).filter(l=>l!==null)):{},facts:Array.isArray(e.facts)?e.facts.map(Rd).filter(l=>l!==null):[]}}function Od(e){if(!u(e))return null;const t=o(e.id),n=o(e.source),a=o(e.target),s=o(e.kind),r=o(e.tone),l=o(e.provenance);return!t||!n||!a||!s||!r||!l?null:{id:t,source:n,target:a,kind:s,label:o(e.label)??null,tone:r,provenance:l,animated:k(e.animated)}}function Id(e){if(!u(e))return null;const t=o(e.id),n=o(e.kind),a=o(e.label),s=o(e.tone),r=o(e.provenance);return!t||!n||!a||!s||!r?null:{id:t,kind:n,label:a,detail:o(e.detail)??null,tone:s,provenance:r,source_id:o(e.source_id)??null,target_id:o(e.target_id)??null,suggested_surface:o(e.suggested_surface)??null,suggested_params:u(e.suggested_params)?Object.fromEntries(Object.entries(e.suggested_params).map(([l,d])=>{const _=o(d);return _?[l,_]:null}).filter(l=>l!==null)):{}}}function Ld(e){if(!u(e))return null;const t=o(e.target_kind),n=o(e.target_id),a=o(e.label),s=o(e.reason);return!t||!n||!a||!s?null:{target_kind:t,target_id:n,label:a,reason:s,suggested_surface:o(e.suggested_surface)??null,suggested_params:u(e.suggested_params)?Object.fromEntries(Object.entries(e.suggested_params).map(([r,l])=>{const d=o(l);return d?[r,d]:null}).filter(r=>r!==null)):{}}}function Md(e){const t=u(e)?e:{},n=u(t.room)?t.room:{},a=u(t.summary)?t.summary:void 0;return{version:o(t.version),generated_at:o(t.generated_at),room:{room_id:o(n.room_id),project:o(n.project),cluster:o(n.cluster),paused:k(n.paused),pause_reason:o(n.pause_reason)??null,agent_count:i(n.agent_count),task_count:i(n.task_count),message_count:i(n.message_count)},summary:a?{session_count:i(a.session_count),operation_count:i(a.operation_count),detachment_count:i(a.detachment_count),lane_count:i(a.lane_count),worker_count:i(a.worker_count),keeper_count:i(a.keeper_count),signal_count:i(a.signal_count),alert_count:i(a.alert_count)}:void 0,nodes:Array.isArray(t.nodes)?t.nodes.map(zd).filter(s=>s!==null):[],edges:Array.isArray(t.edges)?t.edges.map(Od).filter(s=>s!==null):[],signals:Array.isArray(t.signals)?t.signals.map(Id).filter(s=>s!==null):[],focus:Ld(t.focus),swarm_status:ba(t.swarm_status),swarm_proof:Zs(t.swarm_proof),truth_notes:C(t.truth_notes)}}function jd(e){const t=u(e)?e:{};return{version:o(t.version),generated_at:o(t.generated_at),topology:er(t.topology),operations:tr(t.operations),detachments:ar(t.detachments),alerts:sr(t.alerts),decisions:or(t.decisions),capacity:sd(t.capacity),traces:id(t.traces),swarm_status:ba(t.swarm_status)}}function Dd(e){const t=u(e)?e:{},n=er(t.topology),a=tr(t.operations),s=ar(t.detachments),r=sr(t.alerts),l=or(t.decisions);return{version:o(t.version),generated_at:o(t.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:a.version,generated_at:a.generated_at,summary:a.summary,microarch:a.microarch},detachments:{version:s.version,generated_at:s.generated_at,summary:s.summary},alerts:{version:r.version,generated_at:r.generated_at,summary:r.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:ba(t.swarm_status),swarm_proof:Zs(t.swarm_proof)}}const Nd=m(null),xa=m(null),vo=m(!1),Zn=m(!1),go=m(null),bo=m(null),ho=m(null),xo=m(null),H=m("warroom"),qd=m(null),yo=m(!1),$o=m(null),cr=m(null),ko=m(!1),So=m(null),ur=m(null),Ao=m(!1),To=m(null),Fd=m(null),Co=m(!1),Eo=m(null),wn=m(null),ea=m(!1),ta=m(null),Xt=m(null);let gt=null;function ya(e){return e!=="summary"&&e!=="swarm"&&e!=="warroom"&&e!=="orchestra"}function dr(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((s,r)=>{e.has(r)||e.set(r,s)}),e}function _r(){const t=dr().get("run_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function mr(){const t=dr().get("operation_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function Bf(e){H.value=e,ya(e)&&Bd()}async function pr(){vo.value=!0,go.value=null;try{const e=await Qi();Nd.value=Dd(e)}catch(e){go.value=e instanceof Error?e.message:"Failed to load command-plane summary"}finally{vo.value=!1}}function Kf(e){Xt.value=e}async function $a(){Zn.value=!0,bo.value=null;try{const e=await Yi();xa.value=jd(e)}catch(e){bo.value=e instanceof Error?e.message:"Failed to load command-plane snapshot"}finally{Zn.value=!1}}async function Bd(){xa.value||Zn.value||await $a()}async function fr(){await pr(),ya(H.value)&&await $a()}async function ka(){var e;Co.value=!0,Eo.value=null;try{const t=await Zi(),n=xd(t);Fd.value=n;const a=Xt.value;n.operations.length===0?Xt.value=null:(!a||!n.operations.some(s=>s.operation.operation_id===a))&&(Xt.value=((e=n.operations[0])==null?void 0:e.operation.operation_id)??null)}catch(t){Eo.value=t instanceof Error?t.message:"Failed to load chain summary"}finally{Co.value=!1}}function Uf(){gt=null,wn.value=null,ea.value=!1,ta.value=null}async function Hf(e){gt=e,ea.value=!0,ta.value=null;try{const t=await wi(e);if(gt!==e)return;wn.value=yd(t)}catch(t){if(gt!==e)return;wn.value=null,ta.value=t instanceof Error?t.message:"Failed to load chain run"}finally{gt===e&&(ea.value=!1)}}async function Gf(){yo.value=!0,$o.value=null;try{const e=await el();qd.value=Pd(e)}catch(e){$o.value=e instanceof Error?e.message:"Failed to load command-plane help"}finally{yo.value=!1}}async function Sa(e=_r(),t=mr()){ko.value=!0,So.value=null;try{const n=await tl(e,t);cr.value=fd(n)}catch(n){So.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{ko.value=!1}}async function Aa(e=_r(),t=mr()){Ao.value=!0,To.value=null;try{const n=await nl(e,t);ur.value=Md(n)}catch(n){To.value=n instanceof Error?n.message:"Failed to load orchestra map"}finally{Ao.value=!1}}async function Te(e,t,n){ho.value=e,xo.value=null;try{await al(t,n),await pr(),(xa.value||ya(H.value))&&await $a(),await Sa(),await Aa(),await ka()}catch(a){throw xo.value=a instanceof Error?a.message:"Failed to execute command-plane action",a}finally{ho.value=null}}function Wf(e){return Te(`pause:${e}`,"/api/v1/command-plane/operations/pause",{operation_id:e})}function Jf(e){return Te(`resume:${e}`,"/api/v1/command-plane/operations/resume",{operation_id:e})}function Vf(e){return Te(`recall:${e}`,"/api/v1/command-plane/dispatch/recall",{operation_id:e})}function Xf(e={}){return Te("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...e.operationId?{operation_id:e.operationId}:{},...e.detachmentId?{detachment_id:e.detachmentId}:{}})}function Yf(e){return Te(`approve:${e}`,"/api/v1/command-plane/policy/approve",{decision_id:e})}function Qf(e){return Te(`deny:${e}`,"/api/v1/command-plane/policy/deny",{decision_id:e})}function Zf(e,t){return Te(`freeze:${e}`,"/api/v1/command-plane/policy/freeze",{unit_id:e,enabled:t})}function wf(e,t){return Te(`kill:${e}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:e,enabled:t})}Zc(()=>{fr(),ka(),(H.value==="swarm"||H.value==="warroom"||H.value==="orchestra"||cr.value!==null)&&Sa(),(H.value==="orchestra"||ur.value!==null)&&Aa(),H.value==="warroom"&&ot()});async function Kd(){const{refreshGovernance:e}=await _e(async()=>{const{refreshGovernance:t}=await import("./governance-QqcN6gK6.js");return{refreshGovernance:t}},__vite__mapDeps([0,1,2,3,4]));await e()}async function Ud(){const{refreshTools:e}=await _e(async()=>{const{refreshTools:t}=await import("./tools-BBi1aIXn.js");return{refreshTools:t}},__vite__mapDeps([5,1]));await e()}async function Hd(){const{refreshActivityGraph:e}=await _e(async()=>{const{refreshActivityGraph:t}=await import("./activity-graph-EaoTpPzs.js");return{refreshActivityGraph:t}},__vite__mapDeps([6,1,4]));await e()}function vr(e){if(e==="home"&&(ae(),Oe(),Vt()),e==="status"){const t=E.value.params.section;t==="activity"?(Oe(),Hd()):t==="agents"?(ae(),Oe(),Vt()):(ae(),Vt(),Qs())}if(e==="work"){const t=E.value.params.section;t==="evidence"?Gu(E.value.params.session_id,E.value.params.operation_id):t==="governance"?Kd():t==="planning"?(Ps(),Oe()):_a()}if(e==="operations"){const t=E.value.params.section;t==="command"?(ae(),fr(),ka(),(H.value==="swarm"||H.value==="warroom"||H.value==="orchestra")&&Sa(),H.value==="orchestra"&&Aa(),H.value==="warroom"&&ot()):t==="tools"?Ud():(ae(),ot(),Sn())}if(e==="lab"){const t=E.value.params.section;t==="trpg"?cc():ae()}}function Gd(e,t){for(var n in t)e[n]=t[n];return e}function Po(e,t){for(var n in e)if(n!=="__source"&&!(n in t))return!0;for(var a in t)if(a!=="__source"&&e[a]!==t[a])return!0;return!1}function Ro(e,t){this.props=e,this.context=t}(Ro.prototype=new et).isPureReactComponent=!0,Ro.prototype.shouldComponentUpdate=function(e,t){return Po(this.props,e)||Po(this.state,t)};var zo=B.__b;B.__b=function(e){e.type&&e.type.__f&&e.ref&&(e.props.ref=e.ref,e.ref=null),zo&&zo(e)};var Wd=B.__e;B.__e=function(e,t,n,a){if(e.then){for(var s,r=t;r=r.__;)if((s=r.__c)&&s.__c)return t.__e==null&&(t.__e=n.__e,t.__k=n.__k),s.__c(e,t)}Wd(e,t,n,a)};var Oo=B.unmount;function gr(e,t,n){return e&&(e.__c&&e.__c.__H&&(e.__c.__H.__.forEach(function(a){typeof a.__c=="function"&&a.__c()}),e.__c.__H=null),(e=Gd({},e)).__c!=null&&(e.__c.__P===n&&(e.__c.__P=t),e.__c.__e=!0,e.__c=null),e.__k=e.__k&&e.__k.map(function(a){return gr(a,t,n)})),e}function br(e,t,n){return e&&n&&(e.__v=null,e.__k=e.__k&&e.__k.map(function(a){return br(a,t,n)}),e.__c&&e.__c.__P===t&&(e.__e&&n.appendChild(e.__e),e.__c.__e=!0,e.__c.__P=n)),e}function ye(){this.__u=0,this.o=null,this.__b=null}function hr(e){if(!e.__)return null;var t=e.__.__c;return t&&t.__a&&t.__a(e)}function Lt(e){var t,n,a,s=null;function r(l){if(t||(t=e()).then(function(d){d&&(s=d.default||d),a=!0},function(d){n=d,a=!0}),n)throw n;if(!a)throw t;return s?Yt(s,l):null}return r.displayName="Lazy",r.__f=!0,r}function Bt(){this.i=null,this.l=null}B.unmount=function(e){var t=e.__c;t&&(t.__z=!0),t&&t.__R&&t.__R(),t&&32&e.__u&&(e.type=null),Oo&&Oo(e)},(ye.prototype=new et).__c=function(e,t){var n=t.__c,a=this;a.o==null&&(a.o=[]),a.o.push(n);var s=hr(a.__v),r=!1,l=function(){r||a.__z||(r=!0,n.__R=null,s?s(_):_())};n.__R=l;var d=n.__P;n.__P=null;var _=function(){if(!--a.__u){if(a.state.__a){var p=a.state.__a;a.__v.__k[0]=br(p,p.__c.__P,p.__c.__O)}var f;for(a.setState({__a:a.__b=null});f=a.o.pop();)f.__P=d,f.forceUpdate()}};a.__u++||32&t.__u||a.setState({__a:a.__b=a.__v.__k[0]}),e.then(l,l)},ye.prototype.componentWillUnmount=function(){this.o=[]},ye.prototype.render=function(e,t){if(this.__b){if(this.__v.__k){var n=document.createElement("div"),a=this.__v.__k[0].__c;this.__v.__k[0]=gr(this.__b,n,a.__O=a.__P)}this.__b=null}var s=t.__a&&Yt(qa,null,e.fallback);return s&&(s.__u&=-33),[Yt(qa,null,t.__a?null:e.children),s]};var Io=function(e,t,n){if(++n[1]===n[0]&&e.l.delete(t),e.props.revealOrder&&(e.props.revealOrder[0]!=="t"||!e.l.size))for(n=e.i;n;){for(;n.length>3;)n.pop()();if(n[1]<n[0])break;e.i=n=n[2]}};(Bt.prototype=new et).__a=function(e){var t=this,n=hr(t.__v),a=t.l.get(e);return a[0]++,function(s){var r=function(){t.props.revealOrder?(a.push(s),Io(t,e,a)):s()};n?n(r):r()}},Bt.prototype.render=function(e){this.i=null,this.l=new Map;var t=Nn(e.children);e.revealOrder&&e.revealOrder[0]==="b"&&t.reverse();for(var n=t.length;n--;)this.l.set(t[n],this.i=[1,0,this.i]);return e.children},Bt.prototype.componentDidUpdate=Bt.prototype.componentDidMount=function(){var e=this;this.l.forEach(function(t,n){Io(e,n,t)})};var Jd=typeof Symbol<"u"&&Symbol.for&&Symbol.for("react.element")||60103,Vd=/^(?:accent|alignment|arabic|baseline|cap|clip(?!PathU)|color|dominant|fill|flood|font|glyph(?!R)|horiz|image(!S)|letter|lighting|marker(?!H|W|U)|overline|paint|pointer|shape|stop|strikethrough|stroke|text(?!L)|transform|underline|unicode|units|v|vector|vert|word|writing|x(?!C))[A-Z]/,Xd=/^on(Ani|Tra|Tou|BeforeInp|Compo)/,Yd=/[A-Z0-9]/g,Qd=typeof document<"u",Zd=function(e){return(typeof Symbol<"u"&&typeof Symbol()=="symbol"?/fil|che|rad/:/fil|che|ra/).test(e)};et.prototype.isReactComponent={},["componentWillMount","componentWillReceiveProps","componentWillUpdate"].forEach(function(e){Object.defineProperty(et.prototype,e,{configurable:!0,get:function(){return this["UNSAFE_"+e]},set:function(t){Object.defineProperty(this,e,{configurable:!0,writable:!0,value:t})}})});var Lo=B.event;function wd(){}function e_(){return this.cancelBubble}function t_(){return this.defaultPrevented}B.event=function(e){return Lo&&(e=Lo(e)),e.persist=wd,e.isPropagationStopped=e_,e.isDefaultPrevented=t_,e.nativeEvent=e};var n_={enumerable:!1,configurable:!0,get:function(){return this.class}},Mo=B.vnode;B.vnode=function(e){typeof e.type=="string"&&(function(t){var n=t.props,a=t.type,s={},r=a.indexOf("-")===-1;for(var l in n){var d=n[l];if(!(l==="value"&&"defaultValue"in n&&d==null||Qd&&l==="children"&&a==="noscript"||l==="class"||l==="className")){var _=l.toLowerCase();l==="defaultValue"&&"value"in n&&n.value==null?l="value":l==="download"&&d===!0?d="":_==="translate"&&d==="no"?d=!1:_[0]==="o"&&_[1]==="n"?_==="ondoubleclick"?l="ondblclick":_!=="onchange"||a!=="input"&&a!=="textarea"||Zd(n.type)?_==="onfocus"?l="onfocusin":_==="onblur"?l="onfocusout":Xd.test(l)&&(l=_):_=l="oninput":r&&Vd.test(l)?l=l.replace(Yd,"-$&").toLowerCase():d===null&&(d=void 0),_==="oninput"&&s[l=_]&&(l="oninputCapture"),s[l]=d}}a=="select"&&s.multiple&&Array.isArray(s.value)&&(s.value=Nn(n.children).forEach(function(p){p.props.selected=s.value.indexOf(p.props.value)!=-1})),a=="select"&&s.defaultValue!=null&&(s.value=Nn(n.children).forEach(function(p){p.props.selected=s.multiple?s.defaultValue.indexOf(p.props.value)!=-1:s.defaultValue==p.props.value})),n.class&&!n.className?(s.class=n.class,Object.defineProperty(s,"className",n_)):(n.className&&!n.class||n.class&&n.className)&&(s.class=s.className=n.className),t.props=s})(e),e.$$typeof=Jd,Mo&&Mo(e)};var jo=B.__r;B.__r=function(e){jo&&jo(e),e.__c};var Do=B.diffed;B.diffed=function(e){Do&&Do(e);var t=e.props,n=e.__e;n!=null&&e.type==="textarea"&&"value"in t&&t.value!==n.value&&(n.value=t.value==null?"":t.value)};const a_={default:"bg-[var(--white-8)] text-[var(--text-muted)]",warn:"bg-[var(--warn-12)] text-[var(--warn)]",ok:"bg-[rgba(74,222,128,0.12)] text-[#86efac]",bad:"bg-[rgba(251,113,133,0.12)] text-[#fda4af]",accent:"bg-[var(--accent-12)] text-[var(--accent)]"},o_="inline-flex items-center text-[10px] px-1.5 py-px rounded tabular-nums font-medium";function s_({tone:e="default",class:t,children:n}){const a=[o_,a_[e],t].filter(Boolean).join(" ");return c`<span class=${a}>${n}</span>`}function r_(e,t){const n=t==null?void 0:t.state;if(n==="working")return"working";if(n==="watching")return"watching";if(n==="quiet")return"quiet";if(n==="offline")return"offline";const a=(e==null?void 0:e.status)??(t==null?void 0:t.status);return a==="active"||a==="busy"?"working":a==="listening"||a==="idle"?"watching":a==="offline"||a==="inactive"?"offline":"quiet"}const _n={working:0,watching:1,quiet:2,offline:3};function i_(e,t,n){return{name:(e==null?void 0:e.name)??(t==null?void 0:t.name)??(n==null?void 0:n.name)??"unknown",koreanName:(e==null?void 0:e.koreanName)??(t==null?void 0:t.korean_name)??(n==null?void 0:n.korean_name)??null,emoji:(e==null?void 0:e.emoji)??(t==null?void 0:t.emoji)??(n==null?void 0:n.emoji)??null,model:(e==null?void 0:e.model)??(t==null?void 0:t.model)??(n==null?void 0:n.model)??null,status:(e==null?void 0:e.status)??(t==null?void 0:t.status)??(n==null?void 0:n.status)??"unknown",state:r_(e,t),focus:(t==null?void 0:t.focus)??(n==null?void 0:n.focus)??null,currentTask:(e==null?void 0:e.current_task)??null,recentTools:(n==null?void 0:n.recent_tool_names)??(n==null?void 0:n.latest_tool_names)??[],recentOutputPreview:(t==null?void 0:t.recent_output_preview)??(n==null?void 0:n.recent_output_preview)??null,contextRatio:(n==null?void 0:n.context_ratio)??null,lastSignalAt:(t==null?void 0:t.last_signal_at)??(n==null?void 0:n.last_signal_at)??null,lastSignalAgeSec:(t==null?void 0:t.last_signal_age_sec)??null,signalTruth:(t==null?void 0:t.signal_truth)??null,relatedSessionId:(t==null?void 0:t.related_session_id)??(n==null?void 0:n.related_session_id)??null}}const l_=ie(()=>{var A;const e=rt.value,t=ua.value,n=Ss.value,a=da.value,s=new Map;for(const g of e)s.set(g.name,g);const r=new Map;for(const g of t)r.set(g.name,g);const l=new Map;for(const g of a)l.set(g.agent_name??g.name,g);const d=new Map;for(const g of n)d.set(g.session_id,g);const _=new Set;for(const g of e)_.add(g.name);for(const g of t)_.add(g.name);for(const g of a)_.add(g.agent_name??g.name);const p=new Map;for(const g of n)for(const y of g.member_names??[])p.set(y,g.session_id);const f=new Map;for(const g of _){const y=s.get(g)??null,R=r.get(g)??null,T=l.get(g)??null,z=i_(y,R,T),Z=z.relatedSessionId??p.get(g)??null,w=f.get(Z)??[];w.push(z),f.set(Z,w)}for(const[,g]of f)g.sort((y,R)=>{const T=_n[y.state],z=_n[R.state];return T!==z?T-z:y.name.localeCompare(R.name)});const h=[],v=[...f.keys()].filter(g=>g!==null);v.sort((g,y)=>{const R=d.get(g),T=d.get(y),z=pe=>pe==="critical"||pe==="bad"?0:pe==="degraded"?1:pe==="ok"||pe==="healthy"?2:3,Z=z(R==null?void 0:R.health),w=z(T==null?void 0:T.health);return Z!==w?Z-w:g.localeCompare(y)});for(const g of v){const y=d.get(g),R=f.get(g)??[];h.push({sessionId:g,goal:(y==null?void 0:y.goal)??null,status:(y==null?void 0:y.status)??null,health:(y==null?void 0:y.health)??null,memberCount:((A=y==null?void 0:y.member_names)==null?void 0:A.length)??R.length,agents:R})}const b=f.get(null);return b&&b.length>0&&h.push({sessionId:null,goal:null,status:null,health:null,memberCount:b.length,agents:b}),h}),c_=ie(()=>l_.value.flatMap(t=>t.agents).sort((t,n)=>_n[t.state]-_n[n.state]||t.name.localeCompare(n.name)).slice(0,8)),mn="masc_dashboard_workflow_context",u_=900*1e3;function U(e){return typeof e=="string"&&e.trim()!==""?e.trim():null}function ve(e){const t=U(e);return t||(typeof e=="number"&&Number.isFinite(e)?String(e):null)}function xr(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function na(e){return u(e)?e:null}function d_(e){if(!e)return null;try{return JSON.stringify(e)}catch{return null}}function __(e){if(!e)return null;try{const t=JSON.parse(e);if(!u(t))return null;const n=U(t.id),a=U(t.source_surface),s=U(t.source_label),r=U(t.summary),l=U(t.created_at);return!n||a!=="mission"&&a!=="execution"||!s||!r||!l?null:{id:n,source_surface:a,source_label:s,action_type:U(t.action_type),target_type:U(t.target_type),target_id:U(t.target_id),focus_kind:U(t.focus_kind),operation_id:U(t.operation_id),command_surface:U(t.command_surface),summary:r,payload_preview:U(t.payload_preview),suggested_payload:na(t.suggested_payload),preview:t.preview??null,evidence:t.evidence??null,created_at:l}}catch{return null}}function Ta(e){const t=Date.parse(e.created_at);return Number.isNaN(t)?!1:Date.now()-t<=u_}function m_(){const e=xr(),t=__((e==null?void 0:e.getItem(mn))??null);return t?Ta(t)?t:(e==null||e.removeItem(mn),null):null}const yr=m(m_());function p_(e){const t=e&&Ta(e)?e:null;yr.value=t;const n=xr();if(!n)return;if(!t){n.removeItem(mn);return}const a=d_(t);a&&n.setItem(mn,a)}function f_(e){if(!e)return null;const t=na(e.suggested_payload);if(t)return t;if(u(e.preview)){const n=na(e.preview.payload);if(n)return n}return null}function v_(e){if(!e)return null;const t=ve(e.message);if(t)return t;const n=ve(e.task_title)??ve(e.title),a=ve(e.task_description)??ve(e.description),s=ve(e.reason),r=ve(e.priority)??ve(e.task_priority);return n&&a?`${n} · ${a}`:n&&r?`${n} · P${r}`:n||a||s||null}function Ca(e,t,n,a,s,r,l,d){return[e,t,n??"action",a??"target",s??"room",r??"focus",l??"operation",d].join(":")}function lt(e,t,n="상황판 추천 액션"){const a=new Date().toISOString(),s=f_(e),r=(e==null?void 0:e.target_type)??(t==null?void 0:t.target_type)??null,l=(e==null?void 0:e.target_id)??(t==null?void 0:t.target_id)??null,d=(t==null?void 0:t.kind)??(e==null?void 0:e.action_type)??null,_=(e==null?void 0:e.reason)??(t==null?void 0:t.summary)??n;return{id:Ca("mission",n,(e==null?void 0:e.action_type)??null,r,l,d,null,a),source_surface:"mission",source_label:n,action_type:(e==null?void 0:e.action_type)??null,target_type:r,target_id:l,focus_kind:d,operation_id:null,command_surface:null,summary:_,payload_preview:v_(s),suggested_payload:s,preview:(e==null?void 0:e.preview)??null,evidence:(t==null?void 0:t.evidence)??null,created_at:a}}function ev({targetType:e,targetId:t,focusKind:n,sourceLabel:a="Execution 진단",summary:s,operationId:r=null,commandSurface:l=null}){const d=new Date().toISOString();return{id:Ca("execution",a,null,e,t,n,r,d),source_surface:"execution",source_label:a,action_type:null,target_type:e,target_id:t,focus_kind:n,operation_id:r,command_surface:l,summary:s,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:d}}function g_(e,t){return(t.source==="mission"||t.source==="execution")&&(t.action_type??null)===(e.action_type??null)&&(t.target_type??null)===(e.target_type??null)&&(t.target_id??null)===(e.target_id??null)&&(t.focus_kind??null)===(e.focus_kind??null)&&(t.operation_id??null)===(e.operation_id??null)}function tv(e){const{params:t}=e;if(t.source!=="mission"&&t.source!=="execution")return null;const n=yr.value;if(n&&Ta(n)&&g_(n,t))return n;const a=new Date().toISOString(),s=t.source==="execution"?"execution":"mission";return{id:Ca(s,s==="execution"?"Execution 이어보기":"상황판 이어보기",t.action_type??null,t.target_type??null,t.target_id??null,t.focus_kind??null,t.operation_id??null,a),source_surface:s,source_label:s==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:t.action_type??null,target_type:t.target_type??null,target_id:t.target_id??null,focus_kind:t.focus_kind??t.action_type??null,operation_id:t.operation_id??null,command_surface:t.surface??null,summary:s==="execution"?t.focus_kind?`${t.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":t.focus_kind?`${t.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:a}}function b_(e){return{source:e.source_surface,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function h_(e){if(e.command_surface)return e.command_surface;const t=[e.focus_kind,e.summary,e.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"summary":t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")||t.includes("swarm")?"swarm":e.focus_kind==="operation"||e.target_type==="operation"?"operations":e.target_type==="room"?"orchestra":"swarm"}function x_(e){return{source:e.source_surface,surface:h_(e),...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function y_(e){return b_(e)}function $_(e){return x_(e)}function k_(e){return e!=null&&e.target_type?e.target_id?`${e.target_type} · ${e.target_id}`:e.target_type:"대상 정보 없음"}function nv(e){switch(e){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";default:return(e==null?void 0:e.trim())||"추천 액션"}}function av(e){switch(e){case"warroom":return"워룸";case"summary":return"요약";case"orchestra":return"오케스트라";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(e==null?void 0:e.trim())||"지휘"}}function S_(e,t="정보 없음"){if(!e)return t;const n=Date.parse(e);if(Number.isNaN(n))return e;const a=Math.max(0,Math.round((Date.now()-n)/1e3));return a<60?`${a}초 전`:a<3600?`${Math.round(a/60)}분 전`:a<86400?`${Math.round(a/3600)}시간 전`:`${Math.round(a/86400)}일 전`}function ov(e){return typeof e!="number"||!Number.isFinite(e)?"정보 없음":e<60?`${Math.round(e)}초`:e<3600?`${Math.round(e/60)}분`:`${Math.round(e/3600)}시간`}function A_(e){return typeof e!="number"||!Number.isFinite(e)||e<0?"확인 필요":e<60?`${Math.round(e)}초`:e<3600?`${Math.round(e/60)}분`:e<86400?`${Math.round(e/3600)}시간`:`${Math.round(e/86400)}일`}function sv(e){return e==null?"":e<60?`${Math.round(e)}s`:e<3600?`${Math.floor(e/60)}m ${Math.round(e%60)}s`:`${Math.floor(e/3600)}h ${Math.floor(e%3600/60)}m`}function T_(e){const t=Date.now(),n=typeof e=="number"?e<1e12?e*1e3:e:new Date(e).getTime(),a=Math.floor((t-n)/1e3);if(a<60)return`${a}초 전`;const s=Math.floor(a/60);if(s<60)return`${s}분 전`;const r=Math.floor(s/60);return r<24?`${r}시간 전`:`${Math.floor(r/24)}일 전`}function C_(e){switch((e??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"working":return"작업 중";case"watching":return"관찰 중";case"listening":return"대기";case"pending":return"대기 중";case"paused":return"일시정지";case"blocked":return"차단됨";case"interrupted":return"중단됨";case"warn":case"watch":case"warning":case"degraded":return"주의";case"bad":case"critical":case"risk":return"위험";case"offline":case"inactive":return"오프라인";case"idle":case"quiet":return"대기";case"loading":return"불러오는 중";case"error":case"failed":return"오류";case"unavailable":return"사용 불가";case"stale":return"오래됨";case"refreshing":return"갱신 중";case"cached":return"캐시됨";case"connected":return"연결됨";case"disconnected":return"끊김";case"ready":return"준비됨";case"done":case"completed":case"ended":return"완료";case"cancelled":return"취소됨";case"stopped":return"문제";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function rv(e){const t=(e??"").trim().toLowerCase();return t?t==="active"||t==="running"?"진행 중":t==="paused"?"일시정지":t==="done"||t==="ended"||t==="completed"?"완료":t==="failed"||t==="error"||t==="stopped"?"문제":t==="offline"?"오프라인":t==="idle"?"대기":t==="unknown"?"확인 필요":(e==null?void 0:e.trim())||"확인 필요":"확인 필요"}function iv(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function E_(e){return S_(e,"방금")}const pn=m(null),fn=m(null);function lv(e){switch((e??"").trim().toLowerCase()){case"room":return"방";case"team_session":case"session":return"세션";case"operation":return"작전";case"keeper":return"키퍼";case"agent":return"에이전트";default:return(e==null?void 0:e.trim())||"대상"}}function cv(e){return e!=null&&e.confirm_required?"확인 후 실행":"즉시 실행"}function uv(e){return k_(e?lt(e,null,"상황판 추천 액션"):null)}function Tn(e,t=lt()){p_(t),J("operations",e==="intervene"?{section:"intervene",...y_(t)}:{section:"command",...$_(t)})}function dv(e){Tn("intervene",lt(null,e,"상황판 incident"))}function _v(e){Tn("command",lt(null,e,"상황판 incident"))}function mv(e,t,n="상황판 추천 액션"){Tn("intervene",lt(e,t,n))}function pv(e,t,n="상황판 추천 액션"){Tn("command",lt(e,t,n))}function fv(e,t){const n={source:"mission",target_type:"team_session",target_id:t,focus_kind:"team_session"};e==="command"&&(n.surface="swarm"),J("operations",{section:e==="command"?"command":"intervene",...n})}function vv(e){return{kind:e.kind,severity:e.severity,summary:e.summary,target_type:e.target_type,target_id:e.target_id??null,actor:null,evidence:e.evidence_preview}}function gv(e){var n,a;const t=qe.value.find(s=>s.name===e.name||s.agent_name===e.agent_name)??null;return{brief:e,keeper:t,currentWork:V(e.current_work,110)??V(t==null?void 0:t.skill_primary,110)??V(t==null?void 0:t.last_proactive_reason,110)??"명시된 키퍼 초점 없음",recentInput:V(t==null?void 0:t.recent_input_preview,120)??null,recentOutput:V(t==null?void 0:t.recent_output_preview,120)??V((n=t==null?void 0:t.diagnostic)==null?void 0:n.last_reply_preview,120)??V(t==null?void 0:t.last_proactive_preview,120)??null,recentEvent:V(t==null?void 0:t.last_proactive_reason,120)??V((a=t==null?void 0:t.diagnostic)==null?void 0:a.summary,120)??null,recentTools:(t==null?void 0:t.recent_tool_names)??[]}}function bv(){const e=me.value;if(!e)return new Map;const t=e.sessions.length>0?e.sessions:e.session_briefs;return new Map(t.map(n=>[n.session_id,n]))}function hv(e){pn.value=pn.value===e?null:e,fn.value=null}function xv(e){fn.value=fn.value===e?null:e,pn.value=null}function yv(){pn.value=null,fn.value=null}function $v(e,t){const n=(e??t??"").trim().toLowerCase();return n==="offline"||n==="inactive"||n==="archived"?"mission-state-offline":n==="idle"||n==="quiet"||n==="stale"?"mission-state-idle":n==="active"||n==="running"||n==="ok"||n==="healthy"?"mission-state-alive":""}function kv(e){return e==="mission-state-idle"?"bg-[var(--warn)]":e==="mission-state-offline"?"bg-[#555]":""}function P_(e){var h,v;if(!e){const b=Qn.value;return b?{text:`데이터 로드 실패: ${b}`,tone:"warn",reasons:[]}:Yn.value?{text:"데이터 로딩 중...",tone:"ok",reasons:[]}:{text:"데이터 대기 중...",tone:"ok",reasons:[]}}const t=(e.sessions??[]).length>0?e.sessions:e.session_briefs??[],n=t.length,a=t.filter(b=>b.blocker_summary).length,s=e.attention_queue??[],r=s.length,l=(((h=e.agent_briefs)==null?void 0:h.length)??0)>0,d=(((v=e.keeper_briefs)==null?void 0:v.length)??0)>0;if(n===0&&!l&&!d)return{text:"유휴 상태. 세션, 에이전트, 키퍼 모두 비활성.",tone:"ok",reasons:[]};const _=[];let p=0;for(const b of t)b.blocker_summary&&(p++,p<=3&&_.push({category:"blocker",text:`${b.goal??b.session_id}: ${b.blocker_summary.slice(0,80)}`,severity:"bad"}));for(const b of s.slice(0,5))_.push({category:"attention",text:b.summary??b.kind??"주의 항목",severity:b.severity==="critical"||b.severity==="bad"?"bad":"warn"});const f=e.incidents??[];for(const b of f.slice(0,3))_.push({category:"incident",text:b.summary??"인시던트",severity:b.severity==="critical"?"bad":"warn"});if(n===0)return{text:"진행 중인 세션 없음.",tone:"ok",reasons:_};if(a===0&&r===0)return{text:`${n}개 세션 순조롭게 진행 중.`,tone:"ok",reasons:_};if(a>0){const b=r>0?` ${r}건 주의 필요.`:"",A=a>n/2?"bad":"warn";return{text:`${n}개 세션 중 ${a}개 막힘.${b}`,tone:A,reasons:_}}return{text:`${n}개 세션 진행 중. ${r}건 주의 항목.`,tone:"warn",reasons:_}}const R_={blocker:"막힘",attention:"주의",incident:"인시던트"};function z_(e){return e==="bad"?"⚠":e==="warn"?"◉":"✓"}function No(e){return e==="bad"?"border-l-[var(--bad)]":e==="warn"?"border-l-[var(--warn)]":"border-l-[var(--ok)]"}function O_(e){return e==="bad"?"bg-[rgba(239,68,68,0.06)]":e==="warn"?"bg-[rgba(251,191,36,0.05)]":"bg-[var(--white-3)]"}function I_(e){return e==="bad"?"text-[var(--bad)]":e==="warn"?"text-[var(--warn)]":"text-[var(--ok)]"}function L_({snap:e}){const{text:t,tone:n,reasons:a}=P_(e),s=n!=="ok"&&a.length>0;return c`
    <div class="flex flex-col gap-0">
      <div class="flex items-center gap-3 px-4 py-3 rounded-lg border border-[var(--card-border)] border-l-[3px] ${No(n)} ${O_(n)}">
        <span class="shrink-0 w-5 h-5 flex items-center justify-center text-sm ${I_(n)}">${z_(n)}</span>
        <span class="flex-1 min-w-0 text-sm font-medium text-[var(--text-strong)] leading-snug">${t}</span>
      </div>
      ${s?c`
        <div class="flex flex-col gap-1 px-4 py-2 border-l-[3px] ${No(n)} ml-0">
          ${a.map((r,l)=>c`
            <div class="flex items-center gap-2 text-xs" key=${l}>
              <span class="shrink-0 px-1.5 py-px rounded text-[10px] font-semibold uppercase tracking-wide ${r.severity==="bad"?"bg-[var(--bad-8)] text-[var(--bad-light)]":"bg-[var(--warn-12)] text-[var(--warn)]"}">${R_[r.category]??r.category}</span>
              <span class="truncate text-[var(--text-muted)]">${r.text}</span>
            </div>
          `)}
        </div>
      `:null}
    </div>
  `}function M_(e){const t=[];for(const r of e.attention_queue)t.push({id:r.id,severity:r.severity,summary:r.summary,relatedNames:[...r.related_agent_names],lastSeen:r.last_seen_at??null});const n=(e.sessions??[]).length>0?e.sessions:e.session_briefs??[],a=new Set(t.map(r=>r.id));for(const r of n)r.blocker_summary&&!a.has(`blocker-${r.session_id}`)&&t.push({id:`blocker-${r.session_id}`,severity:"bad",summary:r.blocker_summary,relatedNames:r.member_names.slice(0,3),lastSeen:r.last_event_at??null});const s={bad:0,critical:0,warn:1,watch:1,ok:2};return t.sort((r,l)=>{const d=s[r.severity]??1,_=s[l.severity]??1;return d-_}),t.slice(0,3)}function j_(e){return e==="bad"||e==="critical"?"bg-[var(--bad)]":e==="warn"||e==="watch"?"bg-[var(--warn)]":"bg-[var(--ok)]"}function D_(e){return e==="bad"||e==="critical"?"bg-[var(--bad)]":e==="warn"||e==="watch"?"bg-[var(--warn)]":"bg-[var(--ok)]"}function N_({snap:e}){if(!e)return null;const t=M_(e);return t.length===0?null:c`
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-2">
        <span class="w-2 h-2 rounded-full bg-[var(--warn)] shrink-0"></span>
        <span class="text-xs font-semibold text-[var(--text-strong)] uppercase tracking-wider">주의 항목</span>
        <span class="text-xs text-[var(--text-muted)]">${t.length}건</span>
      </div>
      <div class="flex flex-col gap-2">
        ${t.map(n=>c`
          <div class="flex rounded-lg border border-[var(--card-border)] bg-[var(--card)] overflow-hidden" key=${n.id}>
            <div class="w-1 shrink-0 ${D_(n.severity)}" />
            <div class="flex flex-col gap-1.5 p-4 min-w-0 flex-1">
              <div class="flex items-start gap-2">
                <span class="w-2 h-2 rounded-full shrink-0 mt-1.5 ${j_(n.severity)}"></span>
                <span class="text-sm font-medium text-[var(--text-strong)] leading-snug">
                  ${V(n.summary,100)}
                </span>
              </div>
              <div class="flex gap-2 flex-wrap items-center pl-4">
                ${n.relatedNames.map(a=>c`
                  <span class="text-[10px] px-1.5 py-px rounded bg-[var(--white-6)] text-[var(--text-muted)] font-medium" key=${a}>${a}</span>
                `)}
                ${n.lastSeen?c`
                  <span class="text-[10px] text-[var(--text-muted)]">${E_(n.lastSeen)}</span>
                `:null}
              </div>
            </div>
          </div>
        `)}
      </div>
    </div>
  `}const qo=m(0);function q_(e){const t=e.agent??null,n=e.narrativeText??e.preview??e.text;return{actor:t,text:n,raw:`${e.preview??e.text}`,timestamp:e.timestamp}}function F_(e){return e<120?"지금":e<3600?`${Math.round(e/60)}분 전`:`${Math.round(e/3600)}시간 전`}function B_(e){if(e.length===0)return[];const t=Date.now(),n=[];let a="",s=[];for(const r of e){const l=Math.max(0,(t-r.timestamp)/1e3),d=F_(l);d!==a&&(s.length>0&&n.push({label:a,events:s}),a=d,s=[]),s.push(r)}return s.length>0&&n.push({label:a,events:s}),n}function K_(e){const t=new Date(e);return`${String(t.getHours()).padStart(2,"0")}:${String(t.getMinutes()).padStart(2,"0")}`}function U_({entries:e,maxItems:t}){const n=t??8,a=n+qo.value,s=e.value.length,r=e.value.slice(-a).reverse();if(r.length===0)return c`
      <div class="flex flex-col items-center gap-2 py-8 text-center">
        <div class="text-[var(--text-muted)] text-sm">이벤트 대기 중</div>
        <div class="text-[var(--text-muted)] text-xs leading-relaxed">에이전트 활동, 세션 변경, 시스템 이벤트가 여기에 나타납니다.</div>
      </div>
    `;const l=r.map(q_),d=B_(l),_=s>a;return c`
    <div class="flex flex-col gap-3">
      ${d.map(p=>c`
        <div class="flex flex-col gap-0" key=${p.label}>
          <div class="text-[10px] font-semibold text-[var(--text-muted)] uppercase tracking-wider pb-1.5 mb-1 border-b border-[var(--white-6)]">${p.label}</div>
          <div class="flex flex-col">
            ${p.events.map(f=>c`
              <div class="flex items-start gap-3 py-1.5 group" key=${f.timestamp}>
                <span class="text-[10px] text-[var(--text-muted)] tabular-nums shrink-0 mt-0.5 w-8">${K_(f.timestamp)}</span>
                <div class="w-1.5 h-1.5 rounded-full bg-[var(--card-border)] shrink-0 mt-1.5"></div>
                <div class="flex-1 min-w-0">
                  ${f.actor?c`<span class="text-xs font-medium text-[var(--accent)] mr-1.5">${f.actor}</span>`:null}
                  <span class="text-xs text-[var(--text-body)] leading-relaxed">${f.text}</span>
                </div>
              </div>
            `)}
          </div>
        </div>
      `)}
      ${_?c`
        <button
          class="w-full py-2 bg-transparent border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-xs cursor-pointer text-center rounded-md hover:border-[var(--accent)] hover:text-[var(--accent)] transition-colors"
          onClick=${()=>{qo.value+=n}}
        >
          더 보기 (${s-a}건 남음)
        </button>
      `:null}
    </div>
  `}function H_(e){const t=new Date(e*1e3);return`${String(t.getHours()).padStart(2,"0")}:${String(t.getMinutes()).padStart(2,"0")}:${String(t.getSeconds()).padStart(2,"0")}`}function G_(e){switch(e){case"post":return"badge--post";case"comment":return"badge--comment";case"upvote":return"badge--upvote";case"skip":case"passed":case"skipped":return"badge--skip";default:return""}}function W_(e){switch(e){case"selected":return"selected";case"decision":return"decision";case"action_executed":return"executed";case"keeper_resident_lifecycle":return"resident";case"trust_updated":return"trust";case"reputation_changed":return"reputation";default:return e}}function Fo(e){switch(e.type){case"selected":return e.trigger?`trigger ${e.trigger}`:"selection updated";case"decision":return[e.action,e.trigger_reason].filter(Boolean).join(" · ")||"decision updated";case"action_executed":return[e.action,e.success!=null?e.success?"ok":"fail":null].filter(Boolean).join(" · ");case"keeper_resident_lifecycle":return[e.event,e.detail].filter(Boolean).join(" · ")||"resident lifecycle";case"trust_updated":return[e.secondary_agent,e.trust_score!=null?`score ${e.trust_score.toFixed(2)}`:null].filter(Boolean).join(" · ");case"reputation_changed":return[e.old_score!=null&&e.new_score!=null?`${e.old_score.toFixed(2)} -> ${e.new_score.toFixed(2)}`:null,e.trend??null].filter(Boolean).join(" · ");default:return""}}function J_(e){return e>70?"bg-[var(--warn)]":e>50?"bg-[var(--accent)]":"bg-[var(--ok)]"}function V_(){const e=Ve.value,t=At.value,n=Ts.value,a=new Set(e.map(d=>d.agent_name)),s=e[0],r=s!=null?s.timestamp:null,l=r!=null?Math.round((Date.now()/1e3-r)/60):null;return c`
    <div class="flex gap-4 text-xs text-[var(--text-muted)] mb-4">
      <span>에이전트 ${a.size}명</span>
      <span>${n.totalEvents}건${t.size>0?` / 키퍼 ${t.size}명`:""}</span>
      <span>${l!=null?`${l}분 전`:"이벤트 대기 중"}</span>
    </div>
  `}function X_(){const e=At.value;if(e.size===0)return null;const t=[...e.values()].sort((n,a)=>a.timestamp-n.timestamp);return c`
    <div class="flex flex-col gap-2 mb-4">
      <div class="text-[10px] text-[var(--text-muted)] uppercase tracking-wider font-semibold mb-1">키퍼 컨텍스트</div>
      ${t.map(n=>{const a=Math.round(n.context_ratio*100);return c`
          <div class="flex items-center gap-3 text-xs" key=${n.keeper_name}>
            <span class="text-[var(--text-strong)] font-medium w-20 truncate">${n.keeper_name}</span>
            <span class="text-[var(--text-muted)] text-[10px] w-8">g${n.generation}</span>
            <div class="flex-1 h-1.5 bg-[var(--white-6)] rounded-full overflow-hidden">
              <div class="h-full rounded-full transition-all ${J_(a)}" style=${{width:`${a}%`}}></div>
            </div>
            <span class="text-[var(--text-muted)] tabular-nums w-8 text-right">${a}%</span>
            <span class="text-[var(--text-muted)] text-[10px] w-12">${n.message_count} msg</span>
          </div>
        `})}
    </div>
  `}function Y_(){const e=Ve.value;return e.length===0?c`<div class="text-xs text-[var(--text-muted)] py-3 text-center">OAS 에이전트 이벤트 대기 중...</div>`:c`
    <div class="flex flex-col gap-0.5">
      ${e.slice(0,15).map((t,n)=>c`
        <div class="flex items-center gap-3 py-1 text-xs" key=${n}>
          <span class="text-[var(--text-muted)] tabular-nums w-14 shrink-0">${H_(t.timestamp)}</span>
          <span class="text-[var(--text-strong)] font-medium w-20 truncate shrink-0">${t.agent_name}</span>
          <span class="text-[var(--text-muted)] w-14 shrink-0">${W_(t.type)}</span>
          ${t.action?c`<span class="oas-event-badge ${G_(t.action)}">${t.action}</span>`:null}
          ${t.trigger?c`<span class="oas-event-trigger">${t.trigger}</span>`:null}
          ${t.success!=null?c`<span class="text-[10px] ${t.success?"text-[var(--ok)]":"text-[var(--bad)]"}">${t.success?"ok":"fail"}</span>`:null}
          ${Fo(t)?c`<span class="text-[var(--text-muted)] truncate">${Fo(t)}</span>`:null}
        </div>
      `)}
    </div>
  `}function Q_(){const e=Ts.value;return c`
    <div class="p-4 rounded-lg border border-[var(--card-border)] bg-[var(--card)]">
      <div class="flex justify-between items-center mb-3">
        <span class="text-xs font-semibold text-[var(--text-strong)] uppercase tracking-wider">실행 흐름</span>
        <span class="text-[10px] text-[var(--text-muted)] tabular-nums">${e.totalEvents}건</span>
      </div>

      <${V_} />
      <${X_} />

      <details class="group">
        <summary class="cursor-pointer text-xs text-[var(--text-muted)] py-1 hover:text-[var(--accent)] transition-colors">에이전트 실행 (raw events)</summary>
        <div class="mt-2">
          <${Y_} />
        </div>
      </details>
    </div>
  `}const Bo=[{skin:"#f5c89a",hair:"#7a4e3a",point:"#e8917a",highlight:"#f5c542"},{skin:"#b8e0d2",hair:"#3d6b5e",point:"#8dbd97",highlight:"#e0f0e3"},{skin:"#c5b8e8",hair:"#5a4785",point:"#b8a4d6",highlight:"#e3d9f2"},{skin:"#f0d6a8",hair:"#8a6530",point:"#e8c070",highlight:"#fff3d6"},{skin:"#a8d4f0",hair:"#3a6585",point:"#7ab8e0",highlight:"#d6ecfa"},{skin:"#f0a8c0",hair:"#854060",point:"#e07a98",highlight:"#fad6e6"},{skin:"#d4f0a8",hair:"#5a8530",point:"#b0d870",highlight:"#ecfad6"},{skin:"#f0c8a8",hair:"#85553a",point:"#e0a07a",highlight:"#fae4d6"},{skin:"#a8e8f0",hair:"#3a7885",point:"#7ad0e0",highlight:"#d6f4fa"},{skin:"#e8d0a8",hair:"#7a6030",point:"#d4b470",highlight:"#f5ead6"},{skin:"#c0e0b8",hair:"#4a7040",point:"#98c888",highlight:"#e0f0d8"},{skin:"#e0b8d4",hair:"#704060",point:"#c898b8",highlight:"#f0d8e8"}],Ko=["humanoid","robot","animal","abstract"];function $r(e){let t=5381;for(let n=0;n<e.length;n++)t=(t<<5)+t+e.charCodeAt(n)>>>0;return t}function Z_(e){const t=$r(e.toLowerCase());return Bo[t%Bo.length]}function w_(e,t){if(t&&t.length>0){const a=t.join(" ").toLowerCase();if(a.includes("robot")||a.includes("machine")||a.includes("auto"))return"robot";if(a.includes("animal")||a.includes("creature")||a.includes("pet"))return"animal";if(a.includes("abstract")||a.includes("concept")||a.includes("system"))return"abstract"}const n=$r(e.toLowerCase()+"_template");return Ko[n%Ko.length]}const em={humanoid:[0,0,2,2,2,2,0,0,0,2,2,2,2,2,2,0,0,2,1,3,3,1,2,0,0,0,1,1,1,1,0,0,0,0,1,4,4,1,0,0,0,3,3,1,1,3,3,0,0,0,1,1,1,1,0,0,0,0,1,0,0,1,0,0],robot:[0,0,3,3,3,3,0,0,0,3,2,2,2,2,3,0,0,3,4,1,1,4,3,0,0,3,2,2,2,2,3,0,0,0,3,3,3,3,0,0,0,1,3,2,2,3,1,0,0,0,3,2,2,3,0,0,0,3,3,0,0,3,3,0],animal:[2,0,0,0,0,0,0,2,2,2,0,0,0,0,2,2,0,2,1,1,1,1,2,0,0,1,4,1,1,4,1,0,0,1,1,3,3,1,1,0,0,0,1,1,1,1,0,0,0,0,0,1,1,0,0,0,0,0,0,3,3,0,0,0],abstract:[0,0,0,3,3,0,0,0,0,0,3,4,4,3,0,0,0,3,1,1,1,1,3,0,3,4,1,2,2,1,4,3,3,4,1,2,2,1,4,3,0,3,1,1,1,1,3,0,0,0,3,4,4,3,0,0,0,0,0,3,3,0,0,0]};function tm(e,t){switch(e){case 1:return t.skin;case 2:return t.hair;case 3:return t.point;case 4:return t.highlight;default:return null}}function nm(e){return e==null?"activity-dot--unknown":e<60?"activity-dot--live-pulse":e<300?"activity-dot--live":e<1800?"activity-dot--stale":"activity-dot--inactive"}function am(e){return e==="live"?"signal-ring--live":e==="stale"?"signal-ring--stale":e==="archived"?"signal-ring--archived":""}function om(e){if(e!=null)return e<60?"방금 활동":e<300?"최근 활동":e<1800?"잠시 비활성":"비활성"}function sm(e){if(e)return t=>{(t.key==="Enter"||t.key===" ")&&(t.preventDefault(),e())}}function rm(e,t=20){if(!e)return null;const n=e.replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-1)}…`:n:null}function im({name:e,status:t,traits:n,size:a,showName:s,onClick:r,currentWork:l,activityAge:d,hasBlocker:_,signalTruth:p,alwaysShowBubble:f}){const h=Z_(e),v=w_(e,n),b=em[v],A=a==="sm"?"pixel-avatar--sm":a==="lg"?"pixel-avatar--lg":a==="xl"?"pixel-avatar--xl":"",g=t??"idle",y=_?"pixel-avatar--has-blocker":"",R=am(p),T=[];for(let Fe=0;Fe<64;Fe++){const jt=tm(b[Fe]??0,h);T.push(c`<span
        class="pixel-avatar__cell"
        style=${{background:jt??"transparent"}}
      />`)}const z=nm(d??null),Z=rm(l),w=c`
    <div
      class="pixel-avatar rounded-md ${A} ${y} ${R}"
      data-status=${g}
      title=${e}
      onClick=${r}
      onKeyDown=${sm(r)}
      role=${r?"button":void 0}
      tabindex=${r?"0":void 0}
    >
      ${T}
      <span
        class="pixel-avatar__activity-dot ${z}"
        aria-label=${om(d??null)}
      />
      ${Z?c`
        <span class="pixel-avatar__speech-bubble rounded-md ${f?"always-visible":""}">
          ${Z}
        </span>
      `:null}
    </div>
  `;return s?c`
    <div class="pixel-avatar rounded-md-wrap">
      ${w}
      <span class=${g!=="offline"&&g!=="inactive"?"pixel-avatar-name pixel-avatar-name--active":"pixel-avatar-name"}>${e}</span>
    </div>
  `:w}function Uo(e){switch((e??"").trim().toLowerCase()){case"running":return 0;case"paused":return 1;case"pending":return 2;case"interrupted":return 3;case"completed":case"done":return 4;default:return 5}}function lm(e,t){const n=(e??t??"").trim();if(!n)return{primary:t??"session",secondary:null};const a=n.split("·").map(s=>s.trim()).filter(Boolean);return{primary:a[0]??n,secondary:a.length>1?a.slice(1).join(" · "):null}}function aa(e){return e.origin_kind==="system"}function cm(e){const t=(e??"").trim().toLowerCase();return t==="running"?"bg-[var(--ok)]":t==="paused"||t==="interrupted"?"bg-[var(--warn)]":t==="completed"||t==="done"?"bg-[var(--text-muted)]":"bg-[var(--accent)]"}function Ea({label:e,count:t,linkLabel:n,onLink:a}){return c`
    <div class="flex items-center justify-between mb-3">
      <div class="flex items-center gap-2">
        <span class="text-xs font-semibold text-[var(--text-strong)] uppercase tracking-wider">${e}</span>
        ${t!=null?c`<${s_}>${t}<//>`:null}
      </div>
      ${n&&a?c`<button class="text-[10px] text-[var(--accent)] cursor-pointer bg-transparent border-0 p-0 hover:underline" onClick=${a}>${n}</button>`:null}
    </div>
  `}function um(e){var l;const{primary:t,secondary:n}=lm(e.goal,e.session_id),a=(e.created_by??"").trim(),s=aa(e),r=!!e.blocker_summary;return c`
    <div
      class="p-5 rounded-2xl border bg-card/60 backdrop-blur-md cursor-pointer transition-all duration-200 shadow-sm shadow-black/10 hover:shadow-md hover:bg-card hover:-translate-y-0.5 group ${r?"border-bad/50":"border-card-border hover:border-accent/40"}"
      key=${e.session_id}
      onClick=${()=>J("status",{section:"sessions",session_id:e.session_id})}
    >
      <div class="flex items-start gap-3 mb-3">
        <span class="w-2.5 h-2.5 rounded-full shrink-0 mt-1 shadow-[0_0_8px_rgba(0,0,0,0.5)] ${cm(e.status)}"></span>
        <div class="min-w-0 flex-1">
          <div class="text-[14px] font-bold text-text-strong leading-snug truncate group-hover:text-accent transition-colors">${t}</div>
          ${n?c`<div class="text-[12px] text-text-muted mt-1 truncate">${n}</div>`:null}
        </div>
      </div>
      <div class="flex items-center gap-4 text-[11px] text-text-muted/90 pl-6 font-medium">
        ${a?c`<span>${s?"시스템":a}</span>`:null}
        ${e.status?c`<span>${C_(e.status)}</span>`:null}
        ${e.elapsed_sec?c`<span>${A_(e.elapsed_sec)}</span>`:null}
        ${(l=e.member_names)!=null&&l.length?c`<span>${e.member_names.length}명</span>`:null}
      </div>
      ${r?c`
        <div class="text-[11px] font-medium text-bad-light mt-4 pl-6 truncate bg-bad/10 py-1.5 px-3 rounded-lg border border-bad/20">${e.blocker_summary}</div>
      `:null}
    </div>
  `}function Ho({title:e,icon:t,sessions:n,emptyCopy:a}){return c`
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-2">
        <span class="text-xs text-[var(--text-muted)]">${t}</span>
        <span class="text-xs font-medium text-[var(--text-strong)]">${e}</span>
        <span class="text-[10px] px-1.5 py-px rounded bg-[var(--white-6)] text-[var(--text-muted)] tabular-nums">${n.length}</span>
      </div>
      ${n.length>0?c`<div class="flex flex-col gap-2">${n.map(um)}</div>`:c`<div class="text-xs text-[var(--text-muted)] py-3 text-center">${a}</div>`}
    </div>
  `}function dm(){const e=me.value,t=(e==null?void 0:e.sessions)??(e==null?void 0:e.session_briefs)??[];if(t.length===0)return null;const n=[...t].sort((r,l)=>{const d=r.blocker_summary?2:r.related_attention_count>0?1:0,_=l.blocker_summary?2:l.related_attention_count>0?1:0;if(d!==_)return _-d;const p=Uo(r.status),f=Uo(l.status);return p!==f?p-f:(l.elapsed_sec??0)-(r.elapsed_sec??0)}),a=n.filter(r=>!aa(r)).slice(0,3),s=n.filter(r=>aa(r)).slice(0,3);return c`
    <div>
      <${Ea}
        label="세션"
        count=${t.length}
        linkLabel="전체 보기 ->"
        onLink=${()=>J("status",{section:"sessions"})}
      />
      <div class="grid grid-cols-2 max-[960px]:grid-cols-1 gap-4">
        <${Ho}
          title="사용자 작업"
          icon="\u{1F464}"
          sessions=${a}
          emptyCopy="사용자 세션 없음"
        />
        <${Ho}
          title="시스템 루프"
          icon="\u{2699}\u{FE0F}"
          sessions=${s}
          emptyCopy="시스템 세션 없음"
        />
      </div>
    </div>
  `}function _m(e){return e==="working"?"bg-[var(--ok)]":e==="watching"?"bg-[var(--accent)]":e==="quiet"?"bg-[var(--text-muted)]":"bg-[#555]"}function mm(){const e=c_.value;return e.length===0?null:c`
    <div>
      <${Ea}
        label="에이전트"
        count=${e.length}
        linkLabel="전체 보기 ->"
        onLink=${()=>J("status",{section:"agents"})}
      />
      <div class="grid grid-cols-[repeat(auto-fill,minmax(280px,1fr))] gap-4">
        ${e.map(t=>c`
          <div
            class="flex items-start gap-4 p-5 rounded-2xl border border-card-border bg-card/60 backdrop-blur-md cursor-pointer transition-all duration-200 shadow-sm shadow-black/10 hover:shadow-md hover:bg-card hover:-translate-y-0.5 hover:border-accent/40 group"
            key=${t.name}
            onClick=${()=>J("status",{section:"agents",agent:t.name})}
          >
            <${im} name=${t.name} emoji=${t.emoji} size=${40} />
            <div class="flex flex-col min-w-0 flex-1 gap-1.5">
              <div class="flex items-center gap-2">
                <span class="w-2.5 h-2.5 rounded-full shrink-0 shadow-[0_0_8px_rgba(0,0,0,0.5)] ${_m(t.state)}"></span>
                <span class="text-[14px] font-bold text-text-strong group-hover:text-accent transition-colors">${t.koreanName??t.name}</span>
              </div>
              ${t.koreanName&&t.koreanName!==t.name?c`
                <span class="text-[11px] text-text-dim font-mono leading-none tracking-wide">${t.name}</span>
              `:null}
              <span class="text-[12px] text-text-muted/90 leading-relaxed font-medium mt-0.5" style="display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden">
                ${t.focus??t.currentTask??t.status}
              </span>
            </div>
          </div>
        `)}
      </div>
    </div>
  `}function Go(){var n;const e=me.value,t=((n=e==null?void 0:e.summary)==null?void 0:n.room_health)??null;return c`
    <div class="flex flex-col gap-6">
      <${L_} snap=${e} roomHealth=${t} />
      <${N_} snap=${e} />

      <div class="p-6 rounded-3xl border border-card-border/50 bg-card/30 backdrop-blur-xl shadow-lg shadow-black/10">
        <${dm} />
      </div>

      <div class="p-6 rounded-3xl border border-card-border/50 bg-card/30 backdrop-blur-xl shadow-lg shadow-black/10">
        <${mm} />
      </div>

      <div class="opacity-90 hover:opacity-100 transition-opacity">
        <${Q_} />
      </div>

      <div class="p-6 rounded-3xl border border-card-border/50 bg-card/30 backdrop-blur-xl shadow-lg shadow-black/10">
        <${Ea} label="최근 활동" />
        <${U_} entries=${Tt} maxItems=${8} />
      </div>
    </div>
  `}class pm extends et{constructor(){super(...arguments);Ce(this,"state",{error:null})}static getDerivedStateFromError(n){return{error:n}}componentDidCatch(n){console.error(`[ErrorBoundary:${this.props.label??"unknown"}]`,n)}render(){return this.state.error?c`
        <div class="error-card rounded-xl my-3 rounded-lg border border-[var(--bad)]/30 bg-[rgba(10,22,40,0.92)] p-4">
          <strong class="text-[var(--bad)]">${this.props.label??"Component"} 렌더링 오류</strong>
          <pre class="text-xs whitespace-pre-wrap mt-2 opacity-70">${this.state.error.message}</pre>
          <button
            class="mt-2 px-3 py-1 cursor-pointer rounded border border-[var(--card rounded-xl-border)] bg-[var(--white-6)] text-[var(--text-body)] text-sm hover:bg-[var(--white-10)]"
            onClick=${()=>this.setState({error:null})}
          >다시 시도</button>
        </div>
      `:this.props.children}}function de({timestamp:e}){const t=T_(e),n=typeof e=="string"?e:new Date(e<1e12?e*1e3:e).toISOString();return c`<span class="time-ago" title=${n}>${t}</span>`}function fm(e){const t=e==null?void 0:e.trim();return t?t.length>10?t.slice(0,10):t:"dev"}function vm({currentTab:e}){var a;const t=le.value,n=(a=Y.value)==null?void 0:a.build;return c`
    <section class="grid gap-3 rounded-[22px] border border-[rgba(255,255,255,0.06)] bg-[linear-gradient(180deg,rgba(255,255,255,0.045),rgba(255,255,255,0.02))] p-3">
      <div class="flex items-start justify-between gap-3">
        <div>
          <div class="text-[10px] font-semibold uppercase tracking-[0.18em] text-[rgba(154,217,255,0.68)]">Room Pulse</div>
          <div class="mt-1 text-[15px] font-semibold tracking-[-0.02em] text-[var(--text-strong)]">
            ${t?"Live control room":"Signal recovering"}
          </div>
        </div>
        <div class="flex items-center gap-1.5">
          <span class="size-[8px] rounded-full inline-block ${t?"bg-[var(--ok)] shadow-[0_0_9px_rgba(74,222,128,0.64)]":"bg-[var(--bad)] shadow-[0_0_9px_rgba(239,68,68,0.42)]"}"></span>
          <span class="text-[10px] font-medium ${t?"text-[#92f3b4]":"text-[#ffb4bf]"}">${t?"connected":"offline"}</span>
        </div>
      </div>

      ${n?c`
            <div class="rounded-[18px] border border-[rgba(71,184,255,0.14)] bg-[rgba(71,184,255,0.08)] px-3 py-2 text-[10px] text-[rgba(191,231,255,0.78)]">
              build v${n.release_version} · ${fm(n.commit)}
            </div>
          `:null}

      <div class="grid grid-cols-2 gap-2 text-[11px]">
        <div class="rounded-[16px] border border-[rgba(255,255,255,0.05)] bg-[rgba(255,255,255,0.03)] px-3 py-2">
          <div class="text-[10px] text-[var(--text-muted)]">에이전트</div>
          <strong class="mt-1 block text-[18px] font-semibold tabular-nums text-[var(--accent)]">${rt.value.length}</strong>
        </div>
        <div class="rounded-[16px] border border-[rgba(255,255,255,0.05)] bg-[rgba(255,255,255,0.03)] px-3 py-2">
          <div class="text-[10px] text-[var(--text-muted)]">키퍼</div>
          <strong class="mt-1 block text-[18px] font-semibold tabular-nums text-[var(--ok)]">${qe.value.length}</strong>
        </div>
        <div class="rounded-[16px] border border-[rgba(255,255,255,0.05)] bg-[rgba(255,255,255,0.03)] px-3 py-2">
          <div class="text-[10px] text-[var(--text-muted)]">태스크</div>
          <strong class="mt-1 block text-[18px] font-semibold tabular-nums text-[var(--warn)]">${Ot.value.length}</strong>
        </div>
        <div class="rounded-[16px] border border-[rgba(255,255,255,0.05)] bg-[rgba(255,255,255,0.03)] px-3 py-2">
          <div class="text-[10px] text-[var(--text-muted)]">이벤트</div>
          <strong class="mt-1 block text-[18px] font-semibold tabular-nums text-[var(--text-strong)]">${Rs.value}</strong>
        </div>
      </div>

      <div class="grid grid-cols-2 gap-2">
        <button
          class="w-full rounded-[16px] border border-solid border-[rgba(71,184,255,0.26)] bg-[rgba(71,184,255,0.14)] px-3 py-2 text-[11px] font-medium text-[#dff3ff] cursor-pointer transition-colors duration-150 hover:bg-[rgba(71,184,255,0.2)]"
          onClick=${()=>{it(),vr(e)}}
        >
          Room sync
        </button>
        <button
          class="w-full rounded-[16px] border border-solid border-[var(--card-border)] px-3 py-2 bg-[rgba(255,255,255,0.04)] text-[var(--text-body)] text-[11px] font-medium cursor-pointer transition-colors duration-150 hover:bg-[rgba(255,255,255,0.08)]"
          onClick=${()=>J("operations",{section:"intervene"})}
        >
          운영 패널
        </button>
      </div>
    </section>
  `}const Kt=m(!1),gm=Lt(async()=>({default:(await _e(async()=>{const{Status:e}=await import("./status-B0VmVlgi.js");return{Status:e}},__vite__mapDeps([7,1,4,3,8,9,10,2,6]))).Status})),bm=Lt(async()=>({default:(await _e(async()=>{const{Work:e}=await import("./work-CDL_cOy_.js");return{Work:e}},__vite__mapDeps([11,1,4,12,9,2]))).Work})),hm=Lt(async()=>({default:(await _e(async()=>{const{Operations:e}=await import("./control-ChBArxyb.js");return{Operations:e}},__vite__mapDeps([13,1,8,9,3,4,12,0,2]))).Operations})),xm=Lt(async()=>({default:(await _e(async()=>{const{LabSurface:e}=await import("./lab-unified-CkqmzGH4.js");return{LabSurface:e}},__vite__mapDeps([14,1,10,5]))).LabSurface})),ym=Lt(async()=>({default:(await _e(async()=>{const{LogViewer:e}=await import("./logs-CZL9xhtx.js");return{LogViewer:e}},__vite__mapDeps([15,1]))).LogViewer}));function mt(e){return c`<div class="loading-state loading-pulse">${e} 불러오는 중...</div>`}function $m(){const e=en.value;if(e===0)return"";const t=Math.round((Date.now()-e)/1e3);return t<5?"":t<60?` (${t}s)`:` (${Math.round(t/60)}m)`}function km(){var r;const e=le.value,t=me.value,n=((r=t==null?void 0:t.attention_queue)==null?void 0:r.length)??0,a=ma.value,s=e?a>0?"재연결됨":"연결됨":`재연결 중...${$m()}`;return c`
    <div class="flex items-center gap-2 text-[length:var(--fs-sm)] whitespace-nowrap ${e?"text-[#9af3ba]":"text-[#f7b7b7]"}">
      <span class="size-[9px] rounded-full inline-block ${e?"bg-[var(--ok)] shadow-[0_0_9px_rgba(74,222,128,0.8)]":"bg-[var(--bad)]"}"></span>
      <span class="status-text">${s}</span>
      ${n>0?c`
        <span
          class="inline-flex items-center justify-center py-0.5 px-2 min-w-[80px] border border-solid border-[var(--card-border)] bg-[var(--white-4)] tabular-nums rounded-full attention-badge cursor-pointer"
          onClick=${()=>J("home")}
        >주의 ${n}건</span>
      `:null}
    </div>
  `}function Sm(e){const t=e==null?void 0:e.trim();return t?t.length>10?t.slice(0,10):t:"dev"}function Am(){const e=Y.value,t=e==null?void 0:e.build,n=t?`v${t.release_version} · ${Sm(t.commit)}`:e!=null&&e.version?`v${e.version} · dev`:"버전 정보 없음";return c`
    <div class="relative">
      <button
        class="text-[11px] py-[6px] px-[11px] rounded-full border border-solid border-[rgba(71,184,255,0.28)] bg-[rgba(71,184,255,0.12)] text-[#bfe7ff] cursor-pointer font-[inherit] shadow-[inset_0_1px_0_rgba(255,255,255,0.05)] transition-colors duration-150 hover:bg-[rgba(71,184,255,0.18)]"
        type="button"
        aria-expanded=${Kt.value}
        onClick=${()=>{Kt.value=!Kt.value}}
      >
        서버 빌드 · ${n}
      </button>
      ${Kt.value?c`
            <div class="absolute top-[calc(100%+10px)] right-0 min-w-[300px] py-3 px-3.5 border border-solid border-[var(--card-border)] rounded-[18px] bg-[rgba(6,14,28,0.97)] shadow-[0_24px_44px_rgba(0,0,0,0.36)] grid gap-2">
              <div class="flex justify-between gap-3 text-xs text-[color:var(--text-muted)]">
                <span>릴리즈</span>
                <strong class="text-[color:var(--text-strong)] text-right">${(t==null?void 0:t.release_version)??(e==null?void 0:e.version)??"unknown"}</strong>
              </div>
              <div class="flex justify-between gap-3 text-xs text-[color:var(--text-muted)]">
                <span>커밋</span>
                <strong class="text-[color:var(--text-strong)] text-right">${(t==null?void 0:t.commit)??"git 미감지 (dev)"}</strong>
              </div>
              <div class="flex justify-between gap-3 text-xs text-[color:var(--text-muted)]">
                <span>서버 시작</span>
                <strong class="text-[color:var(--text-strong)] text-right">${t!=null&&t.started_at?c`<${de} timestamp=${t.started_at} />`:"알 수 없음"}</strong>
              </div>
              <div class="flex justify-between gap-3 text-xs text-[color:var(--text-muted)]">
                <span>업타임</span>
                <strong class="text-[color:var(--text-strong)] text-right">${typeof(t==null?void 0:t.uptime_seconds)=="number"?`${t.uptime_seconds}s`:"알 수 없음"}</strong>
              </div>
              <div class="flex justify-between gap-3 text-xs text-[color:var(--text-muted)]">
                <span>쉘 스냅샷</span>
                <strong class="text-[color:var(--text-strong)] text-right">${e!=null&&e.generated_at?c`<${de} timestamp=${e.generated_at} />`:"알 수 없음"}</strong>
              </div>
            </div>
          `:null}
    </div>
  `}function Tm(){const e=E.value.tab,t=os(E.value);return c`
    <nav class="flex flex-col h-full">
      <div class="flex-1 overflow-y-auto px-4 py-5">
        <div class="mb-5 px-2">
          <div class="text-[10px] font-semibold uppercase tracking-[0.18em] text-[rgba(154,217,255,0.68)]">Navigation</div>
          <div class="mt-1 text-[15px] font-semibold tracking-[-0.02em] text-[var(--text-strong)]">MASC Core</div>
        </div>

        <div class="flex flex-col gap-4">
          ${oa.map(n=>{const a=n.id===e,s=as(n.id);return c`
              <div class="flex flex-col gap-1.5">
                <button
                  class="flex items-center gap-3 w-full rounded-2xl px-3 py-3 text-left cursor-pointer transition-all duration-150 ${a&&s.length===0?"bg-[rgba(71,184,255,0.14)] text-[#d9f2ff] shadow-[inset_0_1px_0_rgba(255,255,255,0.03)]":"bg-transparent text-[var(--text-strong)] hover:bg-[rgba(255,255,255,0.04)]"}"
                  onClick=${()=>J(n.defaultTab,n.defaultParams)}
                >
                  <span class="flex h-8 w-8 shrink-0 items-center justify-center rounded-xl border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.04)] text-[16px]">
                    ${n.icon}
                  </span>
                  <div class="flex-1 min-w-0">
                    <div class="text-[14px] font-semibold truncate leading-none ${a?"text-[#9ad9ff]":""}">${n.label}</div>
                  </div>
                </button>
                
                ${s.length>0?c`
                  <div class="flex flex-col gap-1 pl-12 pr-1">
                    ${s.map(r=>{const l=a&&(t==null?void 0:t.id)===r.id;return c`
                        <button
                          class="w-full rounded-xl px-3 py-2 text-left cursor-pointer text-[13px] transition-all duration-150 ${l?"bg-[rgba(71,184,255,0.12)] text-[#cfeaff] font-medium":"text-[var(--text-muted)] hover:bg-[rgba(255,255,255,0.04)] hover:text-[var(--text-body)]"}"
                          onClick=${()=>J(n.id,r.params)}
                        >
                          <div class="truncate">${r.label}</div>
                        </button>
                      `})}
                  </div>
                `:null}
              </div>
            `})}
        </div>
      </div>

      <div class="shrink-0 border-t border-[rgba(255,255,255,0.06)] p-4">
        <${vm} currentTab=${e} />
      </div>
    </nav>
  `}function Cm(){switch(E.value.tab){case"overview":return c`<${Go} />`;case"monitoring":return c`
        <${ye} fallback=${mt("모니터링 화면")}>
          <${gm} />
        <//>
      `;case"workspace":return c`
        <${ye} fallback=${mt("작업 화면")}>
          <${bm} />
        <//>
      `;case"command":return c`
        <${ye} fallback=${mt("지휘 통제 화면")}>
          <${hm} />
        <//>
      `;case"lab":return c`
        <${ye} fallback=${mt("실험실 화면")}>
          <${xm} />
        <//>
      `;case"logs":return c`
        <${ye} fallback=${mt("시스템 로그")}>
          <${ym} />
        <//>
      `;default:return c`<${Go} />`}}function Em(){if(Un.value&&!le.value&&!tt.value)return c`<div class="loading-state loading-pulse">대시보드 불러오는 중...</div>`;const e=[E.value.tab,E.value.params.section,E.value.params.surface,E.value.params.session_id,E.value.params.operation_id].filter(Boolean).join(":");return c`
    ${tt.value?c`
      <div class="text-center py-[6px] px-4 bg-[rgba(230,167,0,0.12)] border-b border-solid border-b-[rgba(230,167,0,0.3)] text-[#e6a700] text-[0.8rem] shrink-0 rounded-xl mb-4">서버 데이터 준비 중 — 잠시 후 자동 갱신됩니다</div>
    `:null}
    <${pm} key=${e} label=${e||"dashboard"}>
      <${Cm} />
    <//>
  `}const Pm={sm:"py-1 px-2 text-[10px]",md:"py-1.5 px-2.5 text-[11px]"},Rm={primary:"border border-solid border-[rgba(71,184,255,0.3)] bg-[var(--accent-12)] text-[#d7efff] hover:bg-[var(--accent-20)]",ghost:"border border-solid border-[var(--card-border)] bg-[var(--white-4)] text-[var(--text-body)] hover:bg-[var(--white-8)]",danger:"border border-solid border-[rgba(251,113,133,0.3)] bg-[rgba(251,113,133,0.08)] text-[#fda4af] hover:bg-[rgba(251,113,133,0.15)]",subtle:"border-none bg-transparent text-[var(--text-muted)] hover:text-[var(--text-body)] hover:bg-[var(--white-6)]"},zm="rounded-lg cursor-pointer transition-colors duration-150 font-medium";function Wo({variant:e="primary",size:t="md",class:n,disabled:a,block:s,onClick:r,children:l}){const d=[zm,Pm[t],Rm[e],s?"w-full":"",a?"opacity-50 pointer-events-none":"",n].filter(Boolean).join(" ");return c`
    <button class=${d} onClick=${r} disabled=${a}>${l}</button>
  `}function Om(e){if(!e)return null;const t=new Date(e);return Number.isNaN(t.getTime())?null:t.toLocaleTimeString()}function Im(e){switch(e.delivery){case"sending":return"sending";case"streaming":return e.streamState==="finalizing"?"finalizing":"streaming";case"timeout":return"timeout";case"error":return"error";case"history":return e.role;default:return"delivered"}}function In(e){return e.delivery==="error"||e.delivery==="timeout"?"error":e.role==="user"?"user":e.role==="assistant"?"assistant":"system"}function kr(e){return e.role==="user"?"사용자":e.label.trim()?e.label.trim():e.role}function Lm(e){return kr(e).slice(0,2).toUpperCase()}function Mm(e){var n;const t=(n=e==null?void 0:e.usage)==null?void 0:n.totalTokens;return typeof t=="number"&&Number.isFinite(t)?`${t} tok`:null}function jm(e){return e?[e.modelUsed??null,typeof e.latencyMs=="number"?`${e.latencyMs} ms`:null,Mm(e)].filter(t=>!!t):[]}function Jo(e){return typeof e!="number"||!Number.isFinite(e)?null:e===0?"$0.00":e<.01?`$${e.toFixed(4)}`:`$${e.toFixed(2)}`}function Dm(e){if(!e)return[];const t=["Goal","Progress","Next","Decisions","OpenQuestions","Constraints"];return e.split(`
`).map(n=>n.trim()).filter(Boolean).map(n=>{const a=t.find(s=>n.startsWith(`${s}:`));return a?{label:a,value:n.slice(a.length+1).trim()}:null}).filter(n=>!!(n&&n.value))}function Nm(e){var t;return[e.modelUsed?{label:"모델",value:e.modelUsed}:null,typeof e.latencyMs=="number"?{label:"지연",value:`${e.latencyMs} ms`}:null,typeof((t=e.usage)==null?void 0:t.totalTokens)=="number"?{label:"토큰",value:`${e.usage.totalTokens}`}:null,Jo(e.costUsd)?{label:"비용",value:Jo(e.costUsd)}:null,e.traceId?{label:"트레이스",value:e.traceId}:null,typeof e.generation=="number"?{label:"세대",value:`${e.generation}`}:null].filter(n=>!!n)}function qm({entry:e,showMetadata:t=!0}){var f;const[n,a]=We(!1),[s,r]=We(!1),l=jm(e.details),d=t&&!!e.details,_=e.details?Nm(e.details):[],p=Dm((f=e.details)==null?void 0:f.stateBlock);return ke(()=>{t||(a(!1),r(!1))},[t]),c`
    <article class=${`chat-bubble ${In(e)}`}>
      <div class="chat-bubble-head">
        <div class="chat-bubble-identity">
          <div class=${`chat-avatar ${In(e)}`}>${Lm(e)}</div>
          <div class="chat-bubble-identity-copy">
            <div class="chat-bubble-labels">
              <span class=${`chat-role-chip ${In(e)}`}>${e.label}</span>
              <span class="chat-delivery-chip rounded-full">${Im(e)}</span>
              ${e.timestamp?c`<span class="chat-time-chip rounded-full">${Om(e.timestamp)}</span>`:null}
            </div>
            <div class="chat-identity-title">${kr(e)}</div>
          </div>
        </div>
        ${d?c`
              <button
                type="button"
                class="chat-disclosure-btn rounded-full"
                onClick=${()=>{a(!n)}}
              >
                ${n?"상세 숨기기":"상세 보기"}
              </button>
            `:null}
      </div>

      ${t&&l.length>0?c`<div class="chat-detail-chip rounded-full-row">
            ${l.map(h=>c`<span class="chat-detail-chip rounded-full">${h}</span>`)}
          </div>`:null}

      <div class="chat-bubble-body">${e.text||(e.delivery==="streaming"?"…":"(empty reply)")}</div>
      ${e.error?c`<div class="chat-bubble-error">${e.error}</div>`:null}

      ${n&&e.details?c`
            <div class="chat-detail-panel rounded-xl">
              ${_.length>0?c`
                    <div class="grid grid-cols-[repeat(auto-fit,minmax(116px,1fr))] gap-2">
                      ${_.map(h=>c`
                        <div class="chat-overview-card rounded-xl">
                          <div class="chat-overview-label">${h.label}</div>
                          <div class="chat-overview-value">${h.value}</div>
                        </div>
                      `)}
                    </div>
                  `:null}
              ${e.details.skillPrimary?c`
                    <div class="chat-detail-callout">
                      <div class="chat-detail-callout-label">스킬 경로</div>
                      <div class="chat-detail-callout-value">${e.details.skillPrimary}</div>
                      ${e.details.skillReason?c`<div class="text-[#bfe8cf] leading-[1.55]">${e.details.skillReason}</div>`:null}
                    </div>
                  `:null}
              ${p.length>0?c`
                    <div class="chat-detail-section">
                      <div class="chat-detail-section-title">상태 스냅샷</div>
                      <div class="grid grid-cols-[repeat(auto-fit,minmax(116px,1fr))] gap-2">
                        ${p.map(h=>c`
                          <div class="chat-state-card rounded-xl">
                            <div class="chat-state-label">${h.label}</div>
                            <div class="chat-state-value">${h.value}</div>
                          </div>
                        `)}
                      </div>
                    </div>
                  `:null}
              ${e.details.rawPayload?c`
                    <div class="chat-detail-section">
                      <button
                        type="button"
                        class="chat-raw-toggle rounded-full"
                        onClick=${()=>{r(!s)}}
                      >
                        ${s?"원본 숨기기":"원본 보기"}
                      </button>
                      ${s?c`<pre>${JSON.stringify(e.details.rawPayload,null,2)}</pre>`:null}
                    </div>
                  `:null}
            </div>
          `:null}
    </article>
  `}function Fm({entries:e,emptyText:t,showMetadata:n}){const a=Lr(null),s=e.map(r=>`${r.id}:${r.text.length}:${r.delivery}`).join("|");return ke(()=>{const r=a.current;r&&(r.scrollTop=r.scrollHeight)},[s]),c`
    <div class="chat-transcript" ref=${a}>
      ${e.length===0?c`<div class="chat-empty-copy">${t}</div>`:e.map(r=>c`<${qm} key=${r.id} entry=${r} showMetadata=${n!==!1} />`)}
    </div>
  `}function Bm({draft:e,placeholder:t,disabled:n,streaming:a,streamStartedAt:s,onDraftChange:r,onSend:l,onAbort:d}){const[_,p]=We(0);ke(()=>{if(!a||!s){p(0);return}const v=()=>p(Math.round((Date.now()-s)/1e3));v();const b=setInterval(v,1e3);return()=>clearInterval(b)},[a,s]);const f=a?`Streaming${_>0?` ${_}s`:"..."}`:"전송",h=a&&_>60?" chat-stream-warning":"";return c`
    <div class="chat-composer">
      <textarea
        class="control-textarea rounded-lg min-h-[72px]"
        placeholder=${t}
        value=${e}
        onInput=${v=>{r(v.target.value)}}
        disabled=${n}
      ></textarea>
      <div class="flex gap-2 items-center">
        <${Wo}
          variant=${h?"danger":"primary"}
          onClick=${l}
          disabled=${n||a||e.trim()===""}
        >
          ${f}
        <//>
        ${a&&d?c`
              <${Wo}
                variant="ghost"
                onClick=${d}
              >
                중지
              <//>
            `:null}
      </div>
    </div>
  `}const Sr="masc_keeper_chat_metadata_visible";function Km(){try{return localStorage.getItem(Sr)==="true"}catch{return!1}}function Um(e){try{localStorage.setItem(Sr,e?"true":"false")}catch{}}function Hm(e){switch(e){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"model_error":return"model error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Gm(e){switch(e){case"manual_social_sweep":return"social sweep";case"probe":return"probe";case"recover":return"recover";default:return"message"}}function Vo(e){switch(e){case"healthy":return"healthy";case"recovering":return"recovering";case"desired_offline":return"desired offline";case"offline":return"offline";default:return null}}function Wm(e){if(!e)return null;const t=new Date(e);return Number.isNaN(t.getTime())?null:t.toLocaleTimeString()}function Jm(e){return typeof e!="number"||!Number.isFinite(e)||e<=0?null:e<60?`${Math.round(e)}s`:`${Math.ceil(e/60)}m`}function Ar(e){if(!e)return null;const t=ue.value[e.name];return(t==null?void 0:t.diagnostic)??e.diagnostic??null}function pt({label:e}){return c`
    <span class="inline-flex items-center py-0.5 px-2 rounded-full text-[10px] font-medium bg-[var(--accent-12)] text-[#9ad9ff] border border-[rgba(71,184,255,0.25)]">${e}</span>
  `}function Vm({keeper:e,showRawStatus:t=!1}){if(ke(()=>{e!=null&&e.name&&va(e.name)},[e==null?void 0:e.name]),!e)return c`<div class="text-xs text-[var(--text-muted)] leading-relaxed py-2">Select a keeper to inspect direct reply state.</div>`;const n=ue.value[e.name],a=Ar(e),s=nt.value[e.name];return c`
    <div class="py-3 px-4 rounded-xl border border-[var(--card-border)] bg-[rgba(5,14,31,0.55)]">
      <div class="flex flex-wrap gap-1.5 mb-2">
        ${Vo(a==null?void 0:a.continuity_state)?c`<${pt} label=${Vo(a==null?void 0:a.continuity_state)} />`:null}
        <${pt} label=${(a==null?void 0:a.health_state)??"unknown"} />
        <${pt} label=${Hm(a==null?void 0:a.quiet_reason)} />
        <${pt} label=${"next: "+Gm((a==null?void 0:a.next_action_path)??"direct_message")} />
        ${s?c`<${pt} label="refreshing" />`:null}
      </div>
      <div class="text-xs text-[var(--text-body)] leading-relaxed">
        ${(a==null?void 0:a.continuity_summary)??(a==null?void 0:a.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="text-xs text-[var(--text-body)] leading-relaxed mt-1">
        Reply: ${(a==null?void 0:a.last_reply_status)??"unknown"}
        ${a!=null&&a.last_reply_at?c` -- ${Wm(a.last_reply_at)}`:null}
        ${a!=null&&a.next_eligible_at_s?c` -- next eligible ${Jm(a.next_eligible_at_s)}`:null}
      </div>
      ${a!=null&&a.last_error?c`<div class="text-xs text-[#ffb4b4] leading-relaxed mt-1">${a.last_error}</div>`:null}
      ${t?c`<pre class="mt-3 py-3 px-4 rounded-lg border border-[var(--card-border)] bg-[rgba(2,10,24,0.82)] text-[#9ad8b6] text-[11px] leading-relaxed whitespace-pre-wrap break-words font-mono max-h-[240px] overflow-auto">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Xm({keeperName:e,placeholder:t}){const[n,a]=We(""),[s,r]=We(Km());ke(()=>{e&&va(e)},[e]),ke(()=>{Um(s)},[s]);const[l,d]=We(!1),p=(F.value[e]??[]).filter(g=>g.role==="user"||g.role==="assistant"),f=an.value[e]??!1,h=nt.value[e]??!1,v=re.value[e],b=async()=>{d(!0),await Vc(e)},A=async()=>{const g=n.trim();if(!(!e||!g)){a("");try{await Xc(e,g)}catch(y){if(y instanceof Error&&y.name==="AbortError")return;const R=y instanceof Error?y.message:`Failed to message ${e}`;Q(R,"error")}}};return c`
    <div class="flex flex-col gap-3">
      <div class="flex justify-end">
        <button
          type="button"
          class="py-1 px-3 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] text-[11px] text-[var(--text-muted)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-colors cursor-pointer"
          onClick=${()=>{r(!s)}}
        >
          ${s?"Hide metadata":"Show metadata"}
        </button>
      </div>
      ${!l&&p.length>=10?c`
        <button
          type="button"
          class="py-1.5 px-4 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] text-[11px] text-[var(--text-muted)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-colors cursor-pointer self-center"
          disabled=${h}
          onClick=${()=>{b()}}
        >
          ${h?"Loading...":`Load full history (showing ${p.length})`}
        </button>
      `:null}
      <${Fm}
        entries=${p}
        emptyText="No direct conversation history yet."
        showMetadata=${s}
      />
      <${Bm}
        draft=${n}
        placeholder=${t}
        disabled=${!e}
        streaming=${f}
        streamStartedAt=${on.value[e]??null}
        onDraftChange=${a}
        onSend=${()=>{A()}}
        onAbort=${()=>{Vn(e)}}
      />
      ${v?c`<div class="text-xs text-[#ffb4b4] leading-relaxed">${v}</div>`:null}
    </div>
  `}function Ym({actor:e,keeper:t,onSocialSweep:n}){if(!t)return null;const a=Ar(t),s=Wn.value[t.name]??!1,r=Jn.value[t.name]??!1,l=(a==null?void 0:a.next_action_path)??"direct_message",d=(a==null?void 0:a.recoverable)??l==="recover",_="py-1.5 px-4 rounded-lg text-xs font-medium cursor-pointer transition-colors border",p=`${_} border-[var(--card-border)] bg-[var(--white-3)] text-[var(--text-muted)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)]`,f=`${_} border-[rgba(71,184,255,0.4)] bg-[var(--accent-12)] text-[#9ad9ff] hover:bg-[rgba(71,184,255,0.2)]`,h=`${_} border-[rgba(251,191,36,0.3)] bg-[rgba(251,191,36,0.08)] text-[#fbbf24] hover:bg-[rgba(251,191,36,0.15)]`,v=`${_} border-[rgba(251,191,36,0.5)] bg-[rgba(251,191,36,0.15)] text-[#fbbf24] hover:bg-[rgba(251,191,36,0.2)]`;return c`
    <div class="flex flex-wrap gap-2">
      <button
        class=${l==="probe"?f:p}
        onClick=${()=>{Yc(t.name,e).catch(b=>{const A=b instanceof Error?b.message:`Failed to probe ${t.name}`;Q(A,"error")})}}
        disabled=${s||!e.trim()}
      >
        ${s?"Probing...":"Probe"}
      </button>
      <button
        class=${l==="recover"?v:h}
        onClick=${()=>{Qc(t.name,e).catch(b=>{const A=b instanceof Error?b.message:`Failed to recover ${t.name}`;Q(A,"error")})}}
        disabled=${r||!d||!e.trim()}
      >
        ${r?"Recovering...":"Recover"}
      </button>
      <button
        class=${l==="manual_social_sweep"?f:p}
        onClick=${n}
      >
        Social sweep
      </button>
    </div>
  `}const Ge=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Qm(e){if(!e)return 0;const t=Ge.findIndex(n=>n.level===e);return t>=0?t:0}function Zm({keeper:e}){const t=Qm(e.autonomy_level),n=Ge[t]??Ge[0];if(!n)return null;const a=(t+1)/Ge.length*100;return c`
    <div class="flex flex-col gap-2">
      <div>
        <div class="flex justify-between items-center mb-1.5">
          <span class="text-[13px] font-semibold" style="color:${n.color};">${n.label}</span>
          <span class="text-[11px] text-[var(--text-muted)]">${t+1} / ${Ge.length}</span>
        </div>
        <div class="w-full h-1.5 bg-[var(--white-6)] rounded-full overflow-hidden">
          <div class="h-full rounded-full transition-all duration-300" style="width:${a}%; background:${n.color};"></div>
        </div>
        <div class="flex justify-between mt-1.5">
          ${Ge.map((s,r)=>c`
            <span class="size-2 rounded-full inline-block transition-colors" style="background:${r<=t?s.color:"var(--white-10)"};"></span>
          `)}
        </div>
      </div>
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Autonomous actions</span>
        <span class="text-xs font-medium text-[var(--text-strong)]">${e.autonomous_action_count??0}</span>
      </div>
      ${e.last_autonomous_action_at?c`<div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
            <span class="text-xs text-[var(--text-muted)]">Last autonomous action</span>
            <span class="text-xs font-medium text-[var(--text-strong)]"><${de} timestamp=${e.last_autonomous_action_at} /></span>
          </div>`:null}
      ${e.active_goal_ids&&e.active_goal_ids.length>0?c`<div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
            <span class="text-xs text-[var(--text-muted)]">Active goals</span>
            <span class="text-xs font-medium text-[var(--text-strong)]">${e.active_goal_ids.length}</span>
          </div>`:null}
    </div>
  `}function Ze(e){return e?e>=1e6?`${(e/1e6).toFixed(1)}M`:e>=1e3?`${(e/1e3).toFixed(1)}K`:String(e):"-"}const wm={default:"border-[var(--card-border)] bg-[var(--white-3)]",ok:"border-[rgba(74,222,128,0.2)] bg-[rgba(74,222,128,0.06)]",warn:"border-[rgba(251,191,36,0.2)] bg-[rgba(251,191,36,0.06)]",bad:"border-[rgba(239,68,68,0.2)] bg-[rgba(239,68,68,0.06)]"},ep={default:"text-[var(--text-strong)]",ok:"text-[#4ade80]",warn:"text-[#fbbf24]",bad:"text-[#ef4444]"},tp={Generation:"🔄",Turns:"↻",Context:"📊",Activity:"⚡",Tokens:"🔤",Handoffs:"🤝",Compactions:"📦","Cost (USD)":"💰"};function ge({label:e,value:t,hint:n,tone:a="default",progress:s}){const r=tp[e]??"";return c`
    <div class="p-3.5 rounded-xl border ${wm[a]} flex flex-col gap-1.5 transition-colors">
      <div class="flex items-center justify-between">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">${e}</span>
        ${r?c`<span class="text-[11px] opacity-60">${r}</span>`:null}
      </div>
      <div class="text-2xl font-bold ${ep[a]} tabular-nums leading-none">${t}</div>
      ${s!=null?c`
        <div class="w-full h-1 bg-[var(--white-6)] rounded-full overflow-hidden mt-0.5">
          <div class="h-full rounded-full transition-all duration-500" style="width:${Math.min(s,100)}%;background:${s>85?"#ef4444":s>70?"#fbbf24":"#4ade80"}"></div>
        </div>
      `:null}
      ${n?c`<div class="text-[10px] text-[var(--text-dim)] leading-snug">${n}</div>`:null}
    </div>
  `}function np({keeper:e}){const t=e.metrics_series??[],n=t[t.length-1],a=n&&Number.isFinite(n.cost_usd)?`$${n.cost_usd.toFixed(4)}`:null,s=e.context_ratio!=null?Math.round(e.context_ratio*100):null,r=s==null?"default":s>85?"bad":s>70?"warn":s>0?"ok":"default",l=s!=null&&s>80?"Approaching limit":void 0,d=typeof e.activityLevel=="number"?e.activityLevel:null,_=d==null?"default":d>=4?"ok":d>=2?"warn":"default";return c`
    <div class="flex flex-col gap-3 mb-5">
      ${""}
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <${ge}
          label="Generation"
          value=${e.generation??"-"}
          hint="Succession count"
        />
        <${ge}
          label="Turns"
          value=${e.turn_count??"-"}
          hint="Total loop turns"
        />
        <${ge}
          label="Context"
          value=${s!=null?`${s}%`:"-"}
          hint=${l}
          tone=${r}
          progress=${s??void 0}
        />
        <${ge}
          label="Activity"
          value=${e.activityLevel??"-"}
          hint="Level 0-5"
          tone=${_}
        />
      </div>
      ${""}
      <div class="grid grid-cols-3 sm:grid-cols-4 gap-2">
        <${ge}
          label="Tokens"
          value=${Ze(e.context_tokens)}
        />
        <${ge}
          label="Handoffs"
          value=${e.handoff_count_total??"-"}
        />
        <${ge}
          label="Compactions"
          value=${e.compaction_count??"-"}
        />
        ${a?c`<${ge} label="Cost (USD)" value=${a} />`:null}
      </div>
    </div>
  `}function ap({keeper:e}){var f,h;const t=e.metrics_series??[];if(t.length<2){const v=(((f=e.context)==null?void 0:f.context_ratio)??0)*100,b=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return c`
      <div class="flex items-center gap-3 mb-5 p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
        <div class="flex-1 h-2 bg-[var(--white-6)] rounded-full overflow-hidden">
          <div class="h-full rounded-full transition-all duration-300" style="width:${v.toFixed(1)}%;background:${b}"></div>
        </div>
        <span class="text-sm font-semibold tabular-nums text-[var(--text-strong)]">${v.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,r=t.length,l=t.map((v,b)=>{const A=s+b/(r-1)*(n-2*s),g=a-s-(v.context_ratio??0)*(a-2*s);return{x:A,y:g,p:v}}),d=l.map(({x:v,y:b})=>`${v.toFixed(1)},${b.toFixed(1)}`).join(" "),_=(((h=t[t.length-1])==null?void 0:h.context_ratio)??0)*100,p=_>85?"#ef4444":_>70?"#f59e0b":"#22c55e";return c`
    <div class="flex items-center gap-3 mb-5 p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" class="rounded" style="background:#0b1220;">
        <line x1="${s}" y1="${(a-s-.5*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.5*(a-2*s)).toFixed(1)}" stroke="#444" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.7*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.7*(a-2*s)).toFixed(1)}" stroke="#444" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.85*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.85*(a-2*s)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:v})=>v.is_handoff).map(({x:v})=>c`
          <line x1="${v.toFixed(1)}" y1="${s}" x2="${v.toFixed(1)}" y2="${a-s}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${d}" fill="none" stroke="${p}" stroke-width="1.5"/>
        ${l.filter(({p:v})=>v.is_compaction).map(({x:v,y:b})=>c`
          <circle cx="${v.toFixed(1)}" cy="${b.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="text-sm font-semibold tabular-nums text-[var(--text-strong)]">${_.toFixed(1)}%</span>
    </div>`}const Ln=m("");function op({keeper:e}){var r,l,d,_,p;const t=Ln.value.toLowerCase(),n=[{title:"Name",key:"name",value:e.name},{title:"Emoji",key:"emoji",value:e.emoji??"-"},{title:"Korean",key:"koreanName",value:e.koreanName??"-"},{title:"Model",key:"model",value:e.model??"-"},{title:"Status",key:"status",value:e.status},{title:"Primary",key:"primaryValue",value:e.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(e.activityLevel??"-")},{title:"Gen",key:"generation",value:String(e.generation??"-")},{title:"Turns",key:"turn_count",value:String(e.turn_count??"-")},{title:"Context",key:"context_ratio",value:e.context_ratio!=null?`${Math.round(e.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:e.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((r=e.traits)==null?void 0:r.join(", "))||"-"},{title:"Interests",key:"interests",value:((l=e.interests)==null?void 0:l.join(", "))||"-"}],a=[];e.trace_id&&a.push({title:"Trace ID",value:e.trace_id,mono:!0}),e.agent_name&&a.push({title:"Agent",value:e.agent_name}),e.primary_model&&a.push({title:"Primary Model",value:e.primary_model,mono:!0}),e.active_model&&a.push({title:"Active Model",value:e.active_model,mono:!0}),e.next_model_hint&&a.push({title:"Next Model Hint",value:e.next_model_hint,mono:!0}),e.skill_primary&&a.push({title:"Skill (Primary)",value:e.skill_primary}),(d=e.skill_secondary)!=null&&d.length&&a.push({title:"Skill (Secondary)",value:e.skill_secondary.join(", ")}),e.skill_reason&&a.push({title:"Skill Reason",value:e.skill_reason}),e.context_source&&a.push({title:"Context Source",value:e.context_source}),e.context_tokens!=null&&a.push({title:"Context Tokens",value:Ze(e.context_tokens)}),e.context_max!=null&&a.push({title:"Context Max",value:Ze(e.context_max)}),e.memory_recent_note&&a.push({title:"Memory Note",value:e.memory_recent_note}),e.k2k_count!=null&&a.push({title:"K2K Count",value:String(e.k2k_count)}),e.conversation_tail_count!=null&&a.push({title:"Conv Tail",value:String(e.conversation_tail_count)}),e.handoff_count_total!=null&&a.push({title:"Total Handoffs",value:String(e.handoff_count_total)}),e.compaction_count!=null&&a.push({title:"Compactions",value:String(e.compaction_count)}),e.last_compaction_saved_tokens!=null&&a.push({title:"Last Compact Saved",value:Ze(e.last_compaction_saved_tokens)}),((_=e.context)==null?void 0:_.message_count)!=null&&a.push({title:"Message Count",value:String(e.context.message_count)}),((p=e.context)==null?void 0:p.has_checkpoint)!=null&&a.push({title:"Has Checkpoint",value:e.context.has_checkpoint?"Yes":"No"});const s=t?n.filter(f=>f.title.toLowerCase().includes(t)||f.key.includes(t)||f.value.toLowerCase().includes(t)):n;return c`
    <div class="max-h-[460px] overflow-y-auto">
      <input
        class="w-full py-2 px-3 mb-3 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] text-xs text-[var(--text-body)] placeholder:text-[var(--text-muted)] focus:outline-none focus:border-[var(--ok-40)]"
        type="text"
        placeholder="Search fields..."
        value=${Ln.value}
        onInput=${f=>{Ln.value=f.target.value}}
      />
      <div class="flex flex-col">
        ${s.map((f,h)=>c`
          <div class="grid grid-cols-[100px_80px_1fr] gap-2 py-2 px-2 text-xs rounded-md ${h%2===0?"bg-[var(--white-2)]":""}">
            <span class="font-semibold text-[var(--text-body)] truncate">${f.title}</span>
            <span class="font-mono text-[var(--cyan)] text-[11px] truncate">${f.key}</span>
            <span class="text-right text-[var(--text-body)] truncate">${f.value}</span>
          </div>
        `)}
        ${a.map((f,h)=>c`
          <div class="grid grid-cols-[100px_1fr] gap-2 py-2 px-2 text-xs rounded-md ${(s.length+h)%2===0?"bg-[var(--white-2)]":""}">
            <span class="font-semibold text-[var(--text-body)] truncate">${f.title}</span>
            <span class="text-right text-[var(--text-body)] truncate ${f.mono?"font-mono":""}">${f.value}</span>
          </div>
        `)}
      </div>
    </div>
  `}function sp({stats:e}){const t=e.max_hp>0?Math.round(e.hp/e.max_hp*100):0,n=e.max_mp>0?Math.round(e.mp/e.max_mp*100):0;return c`
    <div>
      <div class="flex gap-3 mb-3">
        <div class="flex-1">
          <div class="flex justify-between text-[11px] text-[var(--text-muted)] mb-1">
            <span>HP</span>
            <span>${e.hp}/${e.max_hp}</span>
          </div>
          <div class="h-2 bg-[var(--white-6)] rounded-full overflow-hidden">
            <div class="h-full rounded-full transition-all" style="width:${t}%; background:${t>50?"#4ade80":t>25?"#fbbf24":"#ef4444"};" />
          </div>
        </div>
        <div class="flex-1">
          <div class="flex justify-between text-[11px] text-[var(--text-muted)] mb-1">
            <span>MP</span>
            <span>${e.mp}/${e.max_mp}</span>
          </div>
          <div class="h-2 bg-[var(--white-6)] rounded-full overflow-hidden">
            <div class="h-full rounded-full" style="width:${n}%; background:#818cf8;" />
          </div>
        </div>
      </div>
      <div class="grid grid-cols-3 gap-2">
        ${[{label:"STR",value:e.strength},{label:"DEX",value:e.dexterity},{label:"CON",value:e.constitution},{label:"INT",value:e.intelligence},{label:"WIS",value:e.wisdom},{label:"CHA",value:e.charisma}].map(a=>c`
          <div class="text-center py-2 px-1.5 bg-[var(--white-3)] rounded-lg border border-[var(--card-border)]">
            <div class="text-[10px] text-[var(--text-muted)] uppercase tracking-wider">${a.label}</div>
            <div class="text-lg font-bold text-[var(--text-strong)] mt-0.5">${a.value}</div>
          </div>
        `)}
      </div>
      <div class="mt-3 text-xs text-[var(--text-muted)]">
        Level ${e.level} -- XP ${e.xp}
      </div>
    </div>
  `}function rp({items:e}){return e.length===0?c`<div class="py-2 px-3 text-xs text-[var(--text-muted)] italic">No equipment</div>`:c`
    <div class="flex flex-col gap-1.5">
      ${e.map((t,n)=>c`
        <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
          <span class="text-xs text-[var(--text-body)]">${t}</span>
          <span class="text-[10px] text-[var(--cyan)] font-mono">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function ip({rels:e}){const t=Object.entries(e);return t.length===0?c`<div class="py-2 px-3 text-xs text-[var(--text-muted)] italic">No relationships</div>`:c`
    <div class="max-h-[220px] overflow-y-auto flex flex-col gap-1.5">
      ${t.map(([n,a])=>c`
        <div class="flex items-center gap-2 py-2 px-3 bg-[var(--white-3)] rounded-lg">
          <span class="inline-flex items-center py-0.5 px-2 rounded-full text-[11px] font-medium bg-[var(--accent-12)] text-[#9ad9ff] border border-[rgba(71,184,255,0.25)]">${n}</span>
          <span class="text-[11px] text-[var(--text-muted)] font-mono">${a}</span>
        </div>
      `)}
    </div>
  `}function Xo({traits:e,label:t}){return e.length===0?null:c`
    <div class="mb-3">
      <div class="text-[10px] text-[var(--text-muted)] uppercase tracking-wider font-semibold mb-2">${t}</div>
      <div class="flex flex-wrap gap-1.5">
        ${e.map(n=>c`<span class="inline-flex items-center py-0.5 px-2.5 rounded-full text-[11px] font-medium bg-[var(--accent-12)] text-[#9ad9ff] border border-[rgba(71,184,255,0.25)]">${n}</span>`)}
      </div>
    </div>
  `}function Mn(e){return(e==null?void 0:e.trim().toLowerCase())??""}function Mt(e){var t,n;return e?((t=e.agent)==null?void 0:t.exists)===!1||Mn((n=e.diagnostic)==null?void 0:n.health_state)==="offline"||Mn(e.status)==="offline"||Mn(e.status)==="inactive"?"offline":"online":"unlinked"}function Ut(e){switch(e){case"offline":return"offline";case"none_recent":return"none_recent";case"not_applicable":return"not_applicable";case"unlinked":return"unlinked";default:return"not_collected"}}function lp(e){const t=Mt(e);return t==="unlinked"?"unlinked":t==="offline"?"offline":"not_collected"}function cp(e,t){const n=Mt(e);return n==="unlinked"?"unlinked":n==="offline"?"offline":t!=null&&t.trim()?"none_recent":"not_collected"}function up(e,t){const n=Mt(e);return n==="unlinked"?"unlinked":n==="offline"?"offline":t!=null&&t.trim()?"none_recent":"not_collected"}function dp(e){const t=Mt(e);return t==="unlinked"?"unlinked":t==="offline"?"offline":"none_recent"}function _p(e){const t=e==null?void 0:e.trim();J("operations",{section:"tools",...t?{q:t}:{}})}function mp(e){switch(e){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"social_sweep":return"social";default:return(e==null?void 0:e.trim())||"action"}}function pp(e){return e.recent_tool_names&&e.recent_tool_names.length>0?e.recent_tool_names:[]}function fp(e){const t=e.metrics_window;return(Array.isArray(t==null?void 0:t.top_tools)?t.top_tools:[]).map(a=>typeof a=="object"&&a!==null&&"tool"in a&&typeof a.tool=="string"?a.tool:null).filter(a=>a!==null)}function vp(e){const t=me.value;return t?t.keeper_briefs.find(n=>n.name===e.name||n.agent_name&&e.agent_name&&n.agent_name===e.agent_name)??null:null}function jn(e){return e==null||Number.isNaN(e)?"-":`${Math.round(e*100)}%`}function xe({label:e,value:t}){return c`
    <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
      <span class="text-xs text-[var(--text-muted)]">${e}</span>
      <span class="text-xs font-medium text-[var(--text-strong)]">${t}</span>
    </div>
  `}function gp({name:e}){return c`
    <span class="inline-flex items-center py-0.5 px-2 rounded-full text-[10px] font-medium bg-[var(--accent-12)] text-[#9ad9ff] border border-[rgba(71,184,255,0.25)]">${e}</span>
  `}function Ue({title:e,description:t,tools:n,fallback:a}){return c`
    <div class="flex flex-col gap-1.5 mt-3">
      <span class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">${e}</span>
      ${t?c`<span class="text-[11px] text-[var(--text-muted)] leading-snug">${t}</span>`:null}
      <div class="flex flex-wrap gap-1.5">
        ${n.length>0?n.map(s=>c`<${gp} name=${s} />`):c`<span class="text-[11px] text-[var(--text-muted)] italic">${a}</span>`}
      </div>
    </div>
  `}function bp({keeper:e}){const t=e.metrics_window,a=[{label:"Model fallback",value:jn(typeof(t==null?void 0:t.model_fallback_rate)=="number"?t.model_fallback_rate:void 0)},{label:"Proactive fallback",value:jn(typeof(t==null?void 0:t.proactive_fallback_rate)=="number"?t.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:jn(typeof(t==null?void 0:t.memory_pass_rate)=="number"?t.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(t==null?void 0:t.handoff_count)=="number"?t.handoff_count:e.handoff_count_total??"-"},{label:"Compactions",value:typeof(t==null?void 0:t.compaction_events)=="number"?t.compaction_events:e.compaction_count??"-"},{label:"Saved tokens",value:typeof(t==null?void 0:t.compaction_saved_tokens)=="number"?t.compaction_saved_tokens:e.last_compaction_saved_tokens??"-"},{label:"K2K events",value:e.k2k_count??"-"},{label:"Conv tail",value:e.conversation_tail_count??"-"},{label:"Tool calls",value:typeof(t==null?void 0:t.tool_call_count)=="number"?t.tool_call_count:"-"},{label:"Preview similarity",value:typeof(t==null?void 0:t.proactive_preview_similarity_avg)=="number"?`${(t.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory avg score",value:typeof(t==null?void 0:t.memory_avg_score)=="number"?t.memory_avg_score.toFixed(3):"-"},{label:"Fallback rate",value:typeof(t==null?void 0:t.fallback_rate)=="number"?`${(t.fallback_rate*100).toFixed(1)}%`:"-"}].filter(s=>!(s.value==="-"||s.value==="—"||s.value===""));return a.length===0?null:c`
    <div class="flex flex-col gap-1.5">
      ${a.map(s=>c`<${xe} label=${s.label} value=${s.value} />`)}
    </div>
  `}function hp({keeper:e}){var Fe,jt,La,Ma,ja,Da,Na;const t=((Fe=Xn.value)==null?void 0:Fe.room)??{},n=(((jt=Xn.value)==null?void 0:jt.available_actions)??[]).filter(Dt=>Dt.target_type==="keeper"||Dt.target_type==="room").slice(0,8),a=pp(e),s=fp(e),r=vp(e),l=r!=null&&r.allowed_tool_names&&r.allowed_tool_names.length>0?r.allowed_tool_names:e.allowed_tool_names??[],d=r!=null&&r.latest_tool_names&&r.latest_tool_names.length>0?r.latest_tool_names:e.latest_tool_names??[],_=(r==null?void 0:r.latest_tool_call_count)??e.latest_tool_call_count,p=(r==null?void 0:r.tool_audit_source)??e.tool_audit_source,f=(r==null?void 0:r.tool_audit_at)??e.tool_audit_at,h=((La=e.agent)==null?void 0:La.capabilities)??[],v=t.current_room??t.room_id??((Ma=Y.value)==null?void 0:Ma.room)??"default",b=t.project??((ja=Y.value)==null?void 0:ja.project)??"N/A",A=t.cluster??((Da=Y.value)==null?void 0:Da.cluster)??"N/A",g=Ut(lp(e)),y=Ut(cp(e,p)),R=Ut(up(e,p)),T=Ut(dp(e)),z=Mt(e),Z=((Na=e.agent)==null?void 0:Na.current_task)??(z==="offline"?"offline":"not_collected"),w=e.skill_primary??(z==="offline"?"offline":"not_collected"),pe=l[0]??d[0]??a[0]??null;return c`
    <div class="flex flex-col gap-1.5">
      <${xe} label="Room" value=${v} />
      <${xe} label="Project" value=${b} />
      <${xe} label="Cluster" value=${A} />
      <${xe} label="Current task" value=${Z} />
      <${xe} label="Skill route" value=${w} />

      <div class="flex justify-end mt-1">
        <button
          class="py-1.5 px-3 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] text-[11px] text-[var(--text-muted)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-colors cursor-pointer"
          onClick=${()=>{_p(pe)}}
        >
          Open tools panel
        </button>
      </div>

      <${Ue}
        title="Allowed tools"
        description="Currently permitted tools for this keeper runtime."
        tools=${l}
        fallback=${g}
      />

      <${Ue}
        title="Observed tools"
        description="Recent execution evidence from heartbeat or runtime telemetry."
        tools=${d}
        fallback=${y}
      />

      <${xe} label="Tool calls" value=${typeof _=="number"?_:y==="none_recent"?0:R} />
      <${xe} label="Evidence source" value=${p??R} />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Observed at</span>
        <span class="text-xs font-medium text-[var(--text-strong)]">${f?c`<${de} timestamp=${f} />`:R}</span>
      </div>

      <${Ue}
        title="Keeper recent tools"
        tools=${a}
        fallback=${T}
      />

      ${s.length>0?c`<${Ue} title="Window top tools" tools=${s} fallback="" />`:null}

      <${Ue}
        title="Capabilities"
        tools=${h}
        fallback="No registered capabilities"
      />

      <${Ue}
        title="Available actions nearby"
        tools=${n.map(Dt=>mp(Dt.action_type))}
        fallback="No operator action advertisements"
      />
    </div>
  `}const Ie=m({status:"idle"}),vn=m(""),bt=m(!1),Dn=m(!1),Pe=m(null),X=m(null);function xp(e){return{goal:e.prompt.goal,short_goal:e.prompt.short_goal,mid_goal:e.prompt.mid_goal,long_goal:e.prompt.long_goal,soul_profile:e.prompt.soul_profile,will:e.prompt.will,needs:e.prompt.needs,desires:e.prompt.desires,instructions:e.prompt.instructions,drift_enabled:e.drift.enabled,drift_min_turn_gap:e.drift.min_turn_gap}}function yp(e,t){const n={};return e.goal!==t.prompt.goal&&(n.new_goal=e.goal),e.short_goal!==t.prompt.short_goal&&(n.new_short_goal=e.short_goal),e.mid_goal!==t.prompt.mid_goal&&(n.new_mid_goal=e.mid_goal),e.long_goal!==t.prompt.long_goal&&(n.new_long_goal=e.long_goal),e.soul_profile!==t.prompt.soul_profile&&(n.new_soul_profile=e.soul_profile),e.will!==t.prompt.will&&(n.new_will=e.will),e.needs!==t.prompt.needs&&(n.new_needs=e.needs),e.desires!==t.prompt.desires&&(n.new_desires=e.desires),e.instructions!==t.prompt.instructions&&(n.new_instructions=e.instructions),e.drift_enabled!==t.drift.enabled&&(n.new_drift_enabled=e.drift_enabled),e.drift_min_turn_gap!==t.drift.min_turn_gap&&(n.new_drift_min_turn_gap=e.drift_min_turn_gap),n}async function $p(e){if(!(vn.value===e&&Ie.value.status==="loaded")){vn.value=e,Ie.value={status:"loading"};try{const t=await ol(e);Ie.value={status:"loaded",config:t}}catch(t){const n=t instanceof Error?t.message:"Failed to load config";Ie.value={status:"error",message:n}}}}function kp(){Ie.value={status:"idle"},vn.value="",bt.value=!1,X.value=null,Pe.value=null}function O({label:e,value:t}){return c`
    <div class="flex items-center justify-between py-2 px-3 rounded-xl border border-card-border/50 bg-card/20 backdrop-blur-sm hover:bg-card/40 transition-colors shadow-sm mb-1.5">
      <span class="text-[12px] font-medium text-text-muted">${e}</span>
      <span class="text-[12px] font-semibold text-text-strong">${t}</span>
    </div>
  `}function ee({title:e}){return c`
    <div class="text-[11px] font-bold uppercase tracking-widest text-accent mt-6 mb-3 pb-1.5 border-b border-accent/20 flex items-center gap-2">
      <span class="w-1.5 h-1.5 rounded-full bg-accent/50 shadow-[0_0_8px_rgba(71,184,255,0.6)]"></span>
      ${e}
    </div>
  `}function ft({value:e}){return e?c`<span class="text-[11px] font-bold px-2 py-0.5 rounded-md bg-ok/10 text-ok border border-ok/20 shadow-sm shadow-ok/5">ON</span>`:c`<span class="text-[11px] font-bold px-2 py-0.5 rounded-md bg-white/5 text-text-dim border border-white/10 shadow-sm">OFF</span>`}function Yo({models:e}){return e.length===0?c`<span class="text-[11px] text-text-muted italic">none</span>`:c`
    <div class="flex flex-wrap gap-1.5">
      ${e.map(t=>c`<span class="inline-flex items-center py-1 px-2.5 rounded-lg text-[11px] font-semibold bg-accent/10 text-accent border border-accent/20 shadow-sm hover:bg-accent/20 transition-colors cursor-default">${t}</span>`)}
    </div>
  `}function He({text:e}){if(!e||e.trim()==="")return c`<span class="text-[11px] text-text-muted italic">--</span>`;const t=e.length>200?e.slice(0,200)+"...":e;return c`<div class="text-[12px] text-text-body whitespace-pre-wrap max-h-[140px] overflow-y-auto custom-scrollbar border border-card-border bg-card/40 backdrop-blur-md p-3 rounded-xl mt-1.5 leading-relaxed shadow-inner hover:bg-card/60 transition-colors">${t}</div>`}const Sp=["balanced","safety","delivery","research","relationship","minimal"],Tr="w-full bg-card/60 backdrop-blur-md text-text-strong text-[13px] border border-card-border rounded-xl py-2 px-3 font-sans focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/50 transition-all duration-200 shadow-inner";function Cn(e,t){const n=X.value;n&&(X.value={...n,[e]:t})}function be({field:e,label:t,rows:n=3}){const a=X.value;if(!a)return null;const s=a[e];return c`
    <div class="mt-3">
      <div class="text-[11px] font-semibold uppercase tracking-wider text-text-muted mb-1.5">${t}</div>
      <textarea
        class="${Tr} resize-y custom-scrollbar"
        rows=${n}
        value=${s}
        onInput=${r=>Cn(e,r.target.value)}
      />
    </div>
  `}function Ap({field:e,label:t,options:n}){const a=X.value;if(!a)return null;const s=a[e];return c`
    <div class="mt-3">
      <div class="text-[11px] font-semibold uppercase tracking-wider text-text-muted mb-1.5">${t}</div>
      <select
        class="${Tr} appearance-none cursor-pointer hover:border-accent/30"
        value=${s}
        onChange=${r=>Cn(e,r.target.value)}
      >
        ${n.map(r=>c`<option value=${r} class="bg-bg-1">${r}</option>`)}
      </select>
    </div>
  `}function Tp({field:e,label:t}){const n=X.value;if(!n)return null;const a=n[e];return c`
    <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)] mt-1">
      <span class="text-xs text-[var(--text-muted)]">${t}</span>
      <input
        type="checkbox"
        checked=${a}
        class="cursor-pointer"
        onChange=${s=>Cn(e,s.target.checked)}
      />
    </div>
  `}function Cp({field:e,label:t,min:n,max:a}){const s=X.value;if(!s)return null;const r=s[e];return c`
    <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)] mt-1">
      <span class="text-xs text-[var(--text-muted)]">${t}</span>
      <input
        type="number"
        class="w-16 bg-[rgba(11,18,32,0.8)] text-[var(--text-body)] border border-[var(--card-border)] rounded-md py-1 px-2 text-xs"
        value=${r}
        min=${n}
        max=${a}
        onInput=${l=>{const d=parseInt(l.target.value,10);Number.isNaN(d)||Cn(e,Math.max(n,Math.min(a,d)))}}
      />
    </div>
  `}function Ep({keeperName:e}){const t=Ie.value;if((vn.value!==e||t.status==="idle")&&$p(e),t.status==="loading")return c`<div class="py-3 text-xs text-[var(--text-muted)]">Loading config...</div>`;if(t.status==="error")return c`<div class="py-3 text-xs text-[#ef4444]">${t.message}</div>`;if(t.status!=="loaded")return null;const n=t.config,a=bt.value,s=Dn.value;function r(){X.value=xp(n),Pe.value=null,bt.value=!0}function l(){bt.value=!1,X.value=null,Pe.value=null}async function d(){const v=X.value;if(!v)return;const b=yp(v,n);if(Object.keys(b).length===0){l();return}Dn.value=!0,Pe.value=null;try{const A=await sl(e,b);Ie.value={status:"loaded",config:A},bt.value=!1,X.value=null}catch(A){Pe.value=A instanceof Error?A.message:"Save failed"}finally{Dn.value=!1}}const _="py-1.5 px-4 rounded-lg text-xs font-semibold cursor-pointer border-none",p=c`
    <div class="flex gap-2 items-center mb-3">
      ${a?c`
        <button
          class="${_} bg-[#4ade80] text-[#000]"
          onClick=${d}
          disabled=${s}
        >${s?"Saving...":"Save"}</button>
        <button
          class="${_} bg-[var(--white-10)] text-[var(--text-body)]"
          onClick=${l}
          disabled=${s}
        >Cancel</button>
      `:c`
        <button
          class="${_} bg-[var(--purple)] text-[#000]"
          onClick=${r}
        >Edit</button>
      `}
      ${Pe.value?c`<span class="text-xs text-[#ef4444]">${Pe.value}</span>`:null}
    </div>
  `,f=a?c`
    <${ee} title="Prompt (editing)" />
    <${be} field="goal" label="Goal" rows=${3} />
    <${be} field="short_goal" label="Short-term goal" rows=${2} />
    <${be} field="mid_goal" label="Mid-term goal" rows=${2} />
    <${be} field="long_goal" label="Long-term goal" rows=${2} />
    <${Ap} field="soul_profile" label="Soul profile" options=${Sp} />
    <${be} field="will" label="Will" rows=${2} />
    <${be} field="needs" label="Needs" rows=${2} />
    <${be} field="desires" label="Desires" rows=${2} />
    <${be} field="instructions" label="Instructions" rows=${4} />
  `:c`
    <${ee} title="Prompt" />
    <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-0.5">Goal</div>
    <${He} text=${n.prompt.goal} />
    ${n.prompt.short_goal?c`
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">Short-term goal</div>
      <${He} text=${n.prompt.short_goal} />
    `:null}
    ${n.prompt.mid_goal?c`
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">Mid-term goal</div>
      <${He} text=${n.prompt.mid_goal} />
    `:null}
    ${n.prompt.long_goal?c`
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">Long-term goal</div>
      <${He} text=${n.prompt.long_goal} />
    `:null}
    ${n.prompt.soul_profile?c`
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">Soul profile</div>
      <${He} text=${n.prompt.soul_profile} />
    `:null}
    ${n.prompt.instructions?c`
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">Instructions</div>
      <${He} text=${n.prompt.instructions} />
    `:null}
  `,h=a?c`
    <${ee} title="Drift (editing)" />
    <${Tp} field="drift_enabled" label="Enabled" />
    <${Cp} field="drift_min_turn_gap" label="Min turn gap" min=${1} max=${50} />
    <${O} label="Count total" value=${String(n.drift.count_total)} />
    ${n.drift.last_reason?c`<${O} label="Last reason" value=${n.drift.last_reason} />`:null}
  `:c`
    <${ee} title="Drift" />
    <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
      <span class="text-xs text-[var(--text-muted)]">Enabled</span>
      <${ft} value=${n.drift.enabled} />
    </div>
    <${O} label="Min turn gap" value=${String(n.drift.min_turn_gap)} />
    <${O} label="Count total" value=${String(n.drift.count_total)} />
    ${n.drift.last_reason?c`<${O} label="Last reason" value=${n.drift.last_reason} />`:null}
  `;return c`
    <div class="flex flex-col gap-1.5">

      ${p}

      ${""}
      <${ee} title="Execution" />
      <${O} label="Active model" value=${n.execution.active_model||"--"} />
      <${O} label="Policy mode" value=${n.execution.policy_mode||"--"} />
      <${O} label="Shell mode" value=${n.execution.policy_shell_mode||"--"} />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Verify</span>
        <${ft} value=${n.execution.verify} />
      </div>
      <div class="mt-1.5">
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1">Models</div>
        <${Yo} models=${n.execution.models} />
      </div>
      ${n.execution.allowed_models.length>0?c`
        <div class="mt-1.5">
          <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1">Allowed models</div>
          <${Yo} models=${n.execution.allowed_models} />
        </div>
      `:null}

      ${""}
      <${ee} title="Compaction" />
      <${O} label="Profile" value=${n.compaction.profile||"--"} />
      <${O} label="Ratio gate" value=${(n.compaction.ratio_gate*100).toFixed(0)+"%"} />
      <${O} label="Message gate" value=${String(n.compaction.message_gate)} />
      <${O} label="Token gate" value=${Ze(n.compaction.token_gate)} />
      <${O} label="Cooldown" value=${n.compaction.cooldown_sec+"s"} />

      ${""}
      <${ee} title="Proactive" />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Enabled</span>
        <${ft} value=${n.proactive.enabled} />
      </div>
      <${O} label="Idle trigger" value=${n.proactive.idle_sec+"s"} />
      <${O} label="Cooldown" value=${n.proactive.cooldown_sec+"s"} />

      ${""}
      ${h}

      ${""}
      <${ee} title="Initiative" />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Enabled</span>
        <${ft} value=${n.initiative.enabled} />
      </div>
      <${O} label="Scope" value=${n.initiative.scope||"--"} />
      <${O} label="Idle trigger" value=${n.initiative.idle_sec+"s"} />
      <${O} label="Cooldown" value=${n.initiative.cooldown_sec+"s"} />
      <${O} label="Context mode" value=${n.initiative.context_mode||"--"} />

      ${""}
      <${ee} title="Handoff" />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Auto</span>
        <${ft} value=${n.handoff.auto} />
      </div>
      <${O} label="Threshold" value=${(n.handoff.threshold*100).toFixed(0)+"%"} />
      <${O} label="Cooldown" value=${n.handoff.cooldown_sec+"s"} />

      ${""}
      <${ee} title="Metrics" />
      <${O} label="Generation" value=${String(n.metrics.generation)} />
      <${O} label="Total turns" value=${String(n.metrics.total_turns)} />
      <${O} label="Total tokens" value=${Ze(n.metrics.total_tokens)} />
      <${O} label="Total cost" value=${"$"+n.metrics.total_cost_usd.toFixed(4)} />
      <${O} label="Compactions" value=${String(n.metrics.compaction_count)} />

      ${""}
      ${f}
    </div>
  `}const Pa=[{key:"idle",label:"idle"},{key:"thinking",label:"think"},{key:"tool_use",label:"tool"},{key:"compacting",label:"compact"},{key:"handoff",label:"handoff"},{key:"proactive",label:"proactive"}],Pp=Object.fromEntries(Pa.map((e,t)=>[e.key,t]));function Rp({stage:e}){const t=e??"offline",n=Pp[t]??-1;return t==="offline"?c`
      <div class="flex items-center py-1.5">
        <div class="pipeline-stage-node active stage-offline">
          <span class="pipeline-stage-dot transition-all duration-300"></span>
          <span class="pipeline-stage-label">offline</span>
        </div>
      </div>
    `:c`
    <div class="flex items-center py-1.5">
      ${Pa.map((a,s)=>{const r=a.key===t,l=s<n,d=["pipeline-stage-node",r?"active":"",l?"passed":"",r?`stage-${a.key}`:""].filter(Boolean).join(" ");return c`
          ${s>0?c`<span class="pipeline-stage-connector"></span>`:null}
          <div class=${d}>
            <span class="pipeline-stage-dot transition-all duration-300"></span>
            ${r?c`<span class="pipeline-stage-label">${a.label}</span>`:null}
          </div>
        `})}
    </div>
  `}function Sv({stage:e}){var a;const t=e??"offline",n=((a=Pa.find(s=>s.key===t))==null?void 0:a.label)??t;return c`
    <span class="pipeline-stage-badge rounded-full stage-${t}">
      ${n}
    </span>
  `}const Ra=m(null);function Av(e){Ra.value=e,Jc(e.name)}function Qo(){Ra.value=null,kp()}function Cr(){const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(t??n??"dashboard").trim()||"dashboard"}async function zp(){try{await zt({actor:Cr(),action_type:"social_sweep",target_type:"room",payload:{}}),await it(),Q("Social sweep finished","success")}catch(e){const t=e instanceof Error?e.message:"Failed to run social sweep";Q(t,"error")}}function Op(e){switch(e.trim().toLowerCase()){case"active":case"running":return{bg:"bg-[rgba(74,222,128,0.12)]",text:"text-[#4ade80]",dot:"bg-[#4ade80]"};case"working":return{bg:"bg-[rgba(74,222,128,0.12)]",text:"text-[#7ae09a]",dot:"bg-[#7ae09a]"};case"idle":case"quiet":return{bg:"bg-[rgba(251,191,36,0.12)]",text:"text-[#fbbf24]",dot:"bg-[#fbbf24]"};case"offline":case"inactive":return{bg:"bg-[rgba(148,163,184,0.12)]",text:"text-[#94a3b8]",dot:"bg-[#64748b]"};case"error":case"critical":return{bg:"bg-[rgba(239,68,68,0.12)]",text:"text-[#ef4444]",dot:"bg-[#ef4444]"};default:return{bg:"bg-[rgba(138,163,211,0.1)]",text:"text-[#86a0cf]",dot:"bg-[#86a0cf]"}}}function Ip({status:e}){const t=Op(e);return c`
    <span class="inline-flex items-center gap-1.5 py-1 px-3 rounded-full text-xs font-medium ${t.bg} ${t.text}">
      <span class="size-2 rounded-full ${t.dot}"></span>
      ${e}
    </span>
  `}function Lp({keeper:e}){return c`
    <div class="border-t border-[var(--border-slate-12)] pt-5">
      <h3 class="m-0 mb-3 text-[13px] font-semibold text-[var(--text-strong)] uppercase tracking-[0.06em]">Direct Comms</h3>

      <div class="flex flex-col gap-4">
        <div class="w-full">
          <${Xm}
            keeperName=${e.name}
            placeholder="Send a direct prompt to this keeper"
          />
        </div>

        <details class="group">
          <summary class="cursor-pointer py-2.5 px-4 text-xs text-[var(--text-muted)] tracking-wider uppercase list-none select-none rounded-lg hover:bg-[var(--white-3)] transition-colors">Runtime diagnostics</summary>
          <div class="flex flex-col gap-3 px-4 pb-4 pt-2">
            <${Vm} keeper=${e} />
            <${Ym}
              actor=${Cr()}
              keeper=${e}
              onSocialSweep=${()=>{zp()}}
            />
          </div>
        </details>
      </div>
    </div>
  `}function te({title:e,children:t}){return c`
    <div class="p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm hover:border-accent/30 hover:shadow-md transition-all duration-200">
      <div class="text-[11px] font-semibold uppercase tracking-widest text-text-muted mb-4 flex items-center gap-2">
        <span class="w-1.5 h-1.5 rounded-full bg-accent/50"></span>
        ${e}
      </div>
      ${t}
    </div>
  `}function Mp(){var t,n,a;const e=Ra.value;return e?c`
    <div
      class="keeper-detail-overlay fixed inset-0 z-[60] bg-black/60 backdrop-blur-sm isolate flex items-center justify-center p-6 animate-in fade-in duration-200"
      data-testid="keeper-detail-overlay"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&Qo()}}
    >
      <div class="w-full max-w-[1100px] max-h-[90vh] overflow-y-auto bg-[#0d1526] rounded-2xl border border-[var(--card-border)] shadow-[0_24px_64px_rgba(0,0,0,0.5)]">

        ${""}
        <div class="sticky top-0 z-10 flex items-center justify-between px-6 py-4 border-b border-[var(--card-border)] bg-[rgba(13,21,38,0.97)] backdrop-blur-md rounded-t-2xl">
          <div class="flex items-center gap-4">
            <div class="size-12 rounded-xl bg-[var(--white-5)] border border-[var(--white-8)] flex items-center justify-center text-2xl">${e.emoji}</div>
            <div class="flex flex-col gap-0.5">
              <div class="flex items-center gap-2.5">
                <h2 class="m-0 text-lg font-semibold text-[var(--text-strong)]">${e.name}</h2>
                <${Ip} status=${e.status} />
                ${e.model?c`
                  <span class="inline-flex items-center py-0.5 px-2 rounded text-[10px] font-mono bg-[var(--accent-12)] text-[#9ad9ff] border border-[rgba(71,184,255,0.2)]">${e.model}</span>
                `:null}
              </div>
              ${e.koreanName?c`<span class="text-xs text-[var(--text-muted)]">${e.koreanName}</span>`:null}
            </div>
          </div>
          <button
            onClick=${()=>Qo()}
            class="flex items-center justify-center size-8 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] text-[var(--text-muted)] hover:text-[var(--text-strong)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-sm"
            aria-label="Close"
          >
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="2" y1="2" x2="12" y2="12"/><line x1="12" y1="2" x2="2" y2="12"/></svg>
          </button>
        </div>

        ${""}
        <div class="p-6 flex flex-col gap-6">

        ${""}
        <${Rp} stage=${e.pipeline_stage} />

        ${""}
        <${np} keeper=${e} />

        ${""}
        <${ap} keeper=${e} />

        ${""}
        <${Lp} keeper=${e} />

        ${""}
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">

          <${te} title="Field Dictionary">
            <${op} keeper=${e} />
          <//>

          <${te} title="Profile">
            <${Xo} traits=${e.traits??[]} label="Traits" />
            <${Xo} traits=${e.interests??[]} label="Interests" />
            ${e.primaryValue?c`<div class="flex items-center gap-2 mt-3 text-xs text-[var(--text-muted)]">
                  <span class="text-[var(--text-muted)]">Core value:</span>
                  <span class="font-medium text-[var(--ok)]">${e.primaryValue}</span>
                </div>`:null}
            ${e.skill_primary?c`<div class="flex items-center gap-2 mt-2 text-xs text-[var(--text-muted)]">
                  <span>Skill path:</span>
                  <span class="font-medium text-[var(--cyan)]">${e.skill_primary}</span>
                </div>`:null}
            ${e.skill_reason?c`<div class="text-[11px] text-[var(--text-muted)] mt-1 leading-relaxed">${e.skill_reason}</div>`:null}
            ${e.last_heartbeat?c`<div class="flex items-center gap-2 mt-2 text-xs text-[var(--text-muted)]">
                  <span>Last heartbeat:</span>
                  <${de} timestamp=${e.last_heartbeat} />
                </div>`:null}
          <//>

          ${e.autonomy_level?c`
              <${te} title="Autonomy">
                <${Zm} keeper=${e} />
              <//>
            `:null}

          ${e.trpg_stats?c`
              <${te} title="TRPG Stats">
                <${sp} stats=${e.trpg_stats} />
              <//>
            `:null}

          ${e.inventory&&e.inventory.length>0?c`
              <${te} title="Equipment (${e.inventory.length})">
                <${rp} items=${e.inventory} />
              <//>
            `:null}

          ${e.relationships&&Object.keys(e.relationships).length>0?c`
              <${te} title="Relationships (${Object.keys(e.relationships).length})">
                <${ip} rels=${e.relationships} />
              <//>
            `:null}

          <${te} title="Runtime Signals">
            <${bp} keeper=${e} />
          <//>

          <${te} title="Neighborhood & Tool Audit">
            <${hp} keeper=${e} />
          <//>

          <${te} title="Config">
            <${Ep} keeperName=${e.name} />
          <//>

          <${te} title="Memory & Context">
            <div class="flex flex-col gap-2">
              <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
                <span class="text-xs text-[var(--text-muted)]">Context source</span>
                <span class="text-xs font-medium text-[var(--text-strong)]">${e.context_source??((t=e.context)==null?void 0:t.source)??"-"}</span>
              </div>
              <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
                <span class="text-xs text-[var(--text-muted)]">Context tokens</span>
                <span class="text-xs font-medium text-[var(--text-strong)]">
                  ${e.context_tokens??((n=e.context)==null?void 0:n.context_tokens)??"-"}
                  /
                  ${e.context_max??((a=e.context)==null?void 0:a.context_max)??"-"}
                </span>
              </div>
              ${e.memory_recent_note?c`
                  <div class="py-2 px-3 rounded-lg bg-[rgba(167,139,250,0.06)] border border-[rgba(167,139,250,0.12)] text-xs text-[var(--text-body)] leading-relaxed">
                    ${e.memory_recent_note}
                  </div>
                `:c`<div class="py-2 px-3 text-xs text-[var(--text-muted)] italic">No recent memory note</div>`}
            </div>
          <//>
        </div>
        </div>
      </div>
    </div>
  `:null}const jp={xs:"text-[10px]",sm:"text-[11px]",md:"text-[13px]"};function Dp({size:e="xs",class:t,right:n,children:a}){return c`
    <div class="flex items-center justify-between gap-2 ${t??""}">
      <h4 class="m-0 ${jp[e]} uppercase tracking-[0.06em] text-[var(--text-muted)] font-medium">${a}</h4>
      ${n??null}
    </div>
  `}const za="rounded-2xl border border-card-border shadow-sm",Np=`${za} p-6 bg-card/90 backdrop-blur-sm`,qp=`${za} p-6 bg-card/90 backdrop-blur-none`,Fp=`${za} p-5 bg-card/90 backdrop-blur-sm`,Bp={standard:Np,light:qp,compact:Fp};function Er({variant:e="standard",class:t,tone:n,testId:a,children:s}){const r=[Bp[e],n,t].filter(Boolean).join(" ");return c`<div class=${r} data-testid=${a}>${s}</div>`}function Kp({label:e,class:t,variant:n="light",children:a}){return c`
    <${Er} variant=${n} class="flex flex-col gap-4 ${t??""}">
      <${Dp}>${e}<//>
      ${a}
    <//>
  `}function Le({title:e,class:t,testId:n,children:a}){return e?c`
      <${Kp} label=${e} class=${t??""} variant="standard">
        ${a}
      <//>
    `:c`<${Er} class=${t} testId=${n}>${a}<//>`}function kt({message:e,icon:t,action:n,compact:a}){return c`
    <div class="flex flex-col items-center justify-center gap-2 ${a?"py-4":"py-8"} text-center">
      ${t?c`<span class="text-2xl opacity-40">${t}</span>`:null}
      <span class="text-[length:var(--fs-sm)] text-[var(--text-muted)] leading-relaxed">${e}</span>
      ${n??null}
    </div>
  `}function Up(e){switch(e.trim().toLowerCase()){case"active":case"running":return"가동 중";case"working":return"작업 중";case"watching":return"관찰 중";case"quiet":return"조용함";case"idle":return"유휴";case"ok":case"healthy":return"정상";case"warn":case"warning":case"degraded":return"주의";case"bad":case"critical":case"error":case"failed":return"위험";case"blocked":return"막힘";case"paused":return"일시정지";case"pending":return"대기";case"offline":case"inactive":return"오프라인";case"connected":return"연결됨";case"disconnected":return"끊김";case"ready":return"준비됨";case"done":case"completed":return"완료";case"unknown":return"알 수 없음";default:return e}}function Hp(e){switch(e){case"in_progress":case"running":return"bg-[var(--warn)]";case"interrupted":case"listening":return"bg-[#38bdf8]";case"inactive":case"offline":return"bg-[#5f7199]";case"active":return"bg-[var(--ok)]";case"busy":case"stopped":return"bg-[var(--text-slate)]";case"error":return"bg-[#fb7185]";default:return"bg-[var(--text-muted)]"}}function Oa({status:e,label:t}){return c`
    <span class="border border-solid border-[var(--card-border)] ${e} ${e==="offline"?"text-[#8da4cc]":""}">
      <span class="size-1.5 rounded-full inline-block ${Hp(e)}"></span>
      ${t??Up(e)}
    </span>
  `}function Pr(e,t){const n=e==null?void 0:e.trim(),a=t==null?void 0:t.trim();return a?n&&a===n?null:a:null}function Tv(e,t){const n=Pr(e,t);return n?`runtime · ${n}`:null}function Gp(e,t){const n=e==null?void 0:e.trim(),a=Pr(n,t);return n?a?`keeper key · ${n} · runtime agent · ${a}`:`keeper key · ${n}`:null}const Wp="masc_dashboard_agent_name",ct=m(null),gn=m(!1),Ct=m(""),bn=m([]),Et=m([]),hn=m(null),we=m(""),St=m(!1);function Jp(){const e=ct.value;return e?rt.value.find(t=>t.name===e)??null:null}function Rr(e){return e?Ot.value.filter(t=>t.assignee===e):[]}function Vp(e){return e?qe.value.find(t=>t.agent_name===e||t.name===e)??null:null}function Xp(e){if(!e)return null;const t=me.value;return t?t.agent_briefs.find(n=>n.agent_name===e)??null:null}function Yp(e){return e?da.value.find(t=>t.agent_name===e||t.name===e)??null:null}function Qp(e){return e?ua.value.find(t=>t.name===e)??null:null}function Zp(e){if(!e)return[];const t=e.toLowerCase();return Tt.value.filter(n=>{const a=n.text.toLowerCase();return n.agent.toLowerCase()===t||a.includes(t)||a.includes(`@${t}`)}).slice(0,15)}function Cv(e){ct.value=e,Ia()}function Zo(){ct.value=null,Ct.value="",bn.value=[],Et.value=[],hn.value=null,we.value="",E.value.tab==="monitoring"&&E.value.params.agent&&J("monitoring",{section:"agents"})}async function Ia(){const e=ct.value;if(e){gn.value=!0,Ct.value="",bn.value=[],Et.value=[],hn.value=null;try{const[t,n]=await Promise.all([il(80),Bi(e,4,20).catch(()=>null)]);bn.value=t.filter(r=>r.includes(e)).slice(0,20),hn.value=n;const a=Rr(e).slice(0,6);if(a.length===0)return;const s=await Promise.all(a.map(async r=>{try{const l=await ll(r.id,25);return{taskId:r.id,text:l.trim()}}catch(l){const d=l instanceof Error?l.message:"history load failed";return{taskId:r.id,text:`Failed to load history: ${d}`}}}));Et.value=s}catch(t){Ct.value=t instanceof Error?t.message:"Failed to load agent detail"}finally{gn.value=!1}}}async function wo(){var a;const e=ct.value,t=we.value.trim();if(!e||!t)return;const n=((a=localStorage.getItem(Wp))==null?void 0:a.trim())||"dashboard";St.value=!0;try{await rl(n,`@${e} ${t}`),we.value="",Q(`Mention sent to ${e}`,"success"),Ia()}catch(s){const r=s instanceof Error?s.message:"Failed to send mention";Q(r,"error")}finally{St.value=!1}}function Pt(e,t=160){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-1)}…`:n:null}function wp(e){return e.kind==="board"?"B":e.kind==="tasks"?"T":e.kind==="keepers"?"K":"S"}function ef({agentName:e}){const t=Zp(e);return c`
    <${Le} title="실시간 활동 스트림">
      ${t.length===0?c`<${kt} message="관련 이벤트 없음" compact />`:c`
            <div class="flex flex-col gap-0.5 max-h-[280px] overflow-y-auto">
              ${t.map((n,a)=>c`
                <div class="agent-journal-entry flex items-baseline gap-1.5 py-1 px-2 text-[13px] transition-[background] duration-100 rounded hover:bg-[var(--white-4)]" key=${a}>
                  <span class="agent-journal-kind">${wp(n)}</span>
                  <span class="agent-journal-type">${n.eventType}</span>
                  <span class="agent-journal-text">${Pt(n.text,120)??""}</span>
                  ${n.timestamp?c`<${de} timestamp=${n.timestamp} />`:null}
                </div>
              `)}
            </div>
          `}
    <//>
  `}function tf(e){return e==="joined"?"J":e.startsWith("task_")?"T":e==="broadcast"?"M":"E"}function nf(e){switch(e){case"joined":return"참가";case"task_claimed":return"태스크 수임";case"task_started":return"태스크 시작";case"task_completed":return"태스크 완료";case"task_cancelled":return"태스크 취소";case"broadcast":return"브로드캐스트";default:return e}}function af(){const e=hn.value;if(!e)return null;const t=e.events??[],n=e.summary;return c`
    <${Le} title="활동 타임라인 (${(n==null?void 0:n.total_events)??0} events)">
      ${n?c`
        <div class="flex gap-1.5 flex-wrap mb-2">
          ${n.tasks_completed>0?c`<span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">완료 ${n.tasks_completed}</span>`:null}
          ${n.tasks_claimed>0?c`<span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">수임 ${n.tasks_claimed}</span>`:null}
          ${n.messages_sent>0?c`<span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">메시지 ${n.messages_sent}</span>`:null}
          ${n.active_duration_minutes>0?c`<span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">${Math.round(n.active_duration_minutes)}분 활동</span>`:null}
        </div>
      `:null}
      ${t.length===0?c`<${kt} message="타임라인 이벤트 없음" compact />`:c`
            <div class="flex flex-col gap-0.5 max-h-[300px] overflow-y-auto">
              ${t.map((a,s)=>{const r=a.detail,l=r.title??r.content??"";return c`
                  <div class="agent-timeline-event flex items-baseline gap-1.5 py-1 px-2 text-[13px] transition-[background] duration-100 rounded hover:bg-[var(--white-4)]" key=${s}>
                    <span class="agent-journal-kind">${tf(a.type)}</span>
                    <span class="agent-timeline-type">${nf(a.type)}</span>
                    ${l?c`<span class="agent-timeline-detail">${Pt(l,80)}</span>`:null}
                    ${a.ts?c`<${de} timestamp=${a.ts} />`:null}
                  </div>
                `})}
            </div>
          `}
    <//>
  `}function of({agentName:e}){const t=Qp(e);return t?c`
    <${Le} title="Worker Status">
      <div class="flex flex-col gap-1.5">
        <div class="flex items-baseline gap-2 text-[13px]">
          <span class="text-[11px] text-[var(--text-muted)] min-w-[60px] shrink-0">State</span>
          <${Oa} status=${t.state} />
        </div>
        ${t.focus?c`
          <div class="flex items-baseline gap-2 text-[13px]">
            <span class="text-[11px] text-[var(--text-muted)] min-w-[60px] shrink-0">Focus</span>
            <span>${t.focus}</span>
          </div>
        `:null}
        ${t.recent_output_preview?c`
          <div class="flex items-baseline gap-2 text-[13px]">
            <span class="text-[11px] text-[var(--text-muted)] min-w-[60px] shrink-0">Output</span>
            <span class="agent-worker-brief__preview">${Pt(t.recent_output_preview,200)}</span>
          </div>
        `:null}
        ${t.related_session_id?c`
          <div class="flex items-baseline gap-2 text-[13px]">
            <span class="text-[11px] text-[var(--text-muted)] min-w-[60px] shrink-0">Session</span>
            <span class="font-mono" style="font-size: 11px">${t.related_session_id}</span>
          </div>
        `:null}
        ${t.last_signal_at?c`
          <div class="flex items-baseline gap-2 text-[13px]">
            <span class="text-[11px] text-[var(--text-muted)] min-w-[60px] shrink-0">Signal</span>
            <${de} timestamp=${t.last_signal_at} />
            ${t.signal_truth?c`<span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">${t.signal_truth}</span>`:null}
          </div>
        `:null}
      </div>
    <//>
  `:null}function sf({task:e}){return c`
    <div class="flex items-center gap-3 border border-card-border bg-card/40 hover:bg-card/60 transition-colors px-3 py-2.5 rounded-xl shadow-sm">
      <span class="text-[10px] font-medium py-1 px-2.5 border border-accent/20 bg-accent/10 text-accent whitespace-nowrap rounded-md shadow-sm">${e.id}</span>
      <span class="flex-1 text-[13px] text-text-strong font-medium truncate">${e.title}</span>
      <${Oa} status=${e.status} />
    </div>
  `}function rf({row:e}){return c`
    <div class="border border-card-border rounded-xl bg-card/40 p-4 shadow-sm hover:border-accent/30 transition-colors group">
      <div class="mb-3">
        <span class="text-[10px] font-medium py-1 px-2.5 border border-accent/20 bg-accent/10 text-accent whitespace-nowrap rounded-md shadow-sm group-hover:bg-accent/20 transition-colors">${e.taskId}</span>
      </div>
      <pre class="m-0 whitespace-pre-wrap text-[12px] leading-relaxed text-text-body font-mono opacity-90">${e.text||"No task history yet"}</pre>
    </div>
  `}function lf(){const e=ct.value;if(!e)return null;const t=Jp(),n=Vp(e),a=Yp(e),s=Xp(e),r=Rr(e),l=bn.value,d=(s==null?void 0:s.display_name)??(n==null?void 0:n.name)??e,_=d!==e?e:null,p=(t==null?void 0:t.status)??(s==null?void 0:s.status)??"unknown",f=!t&&(s==null?void 0:s.is_live)===!1,h=(t==null?void 0:t.last_seen)??(s==null?void 0:s.last_activity_at)??null,v=(s==null?void 0:s.signal_truth)==="live"?"live":(s==null?void 0:s.signal_truth)==="stale"?"stale":(s==null?void 0:s.signal_truth)==="archived"?"archived":(s==null?void 0:s.signal_truth)==="unknown"?"unknown":null,b=(s==null?void 0:s.evidence_source)??null,A=(t==null?void 0:t.emoji)??(n==null?void 0:n.emoji),g=(t==null?void 0:t.koreanName)??(n==null?void 0:n.koreanName),y=Pt(a==null?void 0:a.continuity_summary)??Pt(a==null?void 0:a.skill_route_summary)??null,R=Gp(n==null?void 0:n.name,n==null?void 0:n.agent_name);return c`
    <div
      class="agent-detail-overlay fixed inset-0 z-[60] bg-black/60 backdrop-blur-sm isolate flex items-center justify-center p-6 animate-in fade-in duration-200"
      data-testid="agent-detail-overlay"
      onClick=${T=>{T.target.classList.contains("agent-detail-overlay")&&Zo()}}
    >
      <div class="w-[min(1080px,100%)] max-h-[90vh] overflow-y-auto rounded-2xl border border-card-border bg-bg-1/95 backdrop-blur-2xl p-6 shadow-2xl shadow-black/50 ring-1 ring-white/5">
        <div class="flex justify-between items-start gap-4 mb-6">
          <div class="flex flex-col gap-3 flex-1">
            <div class="flex items-center gap-4">
              ${A?c`<div class="size-12 rounded-xl bg-white/5 border border-white/10 flex items-center justify-center text-3xl shadow-inner">${A}</div>`:""}
              <div>
                <h2 class="m-0 flex items-baseline gap-3 text-text-strong text-2xl font-bold tracking-tight">
                  ${d}
                  ${g?c`<span class="text-sm text-text-dim font-medium tracking-normal">(${g})</span>`:""}
                  ${_?c`<span class="font-mono text-xs text-text-dim bg-white/5 px-2 py-0.5 rounded-md">${_}</span>`:""}
                </h2>
                <div class="flex items-center gap-2 mt-2 flex-wrap">
                  <${Oa} status=${p} />
                  ${f?c`<span class="text-[10px] font-medium py-1 px-2 border border-accent/20 bg-accent/10 text-accent whitespace-nowrap rounded-md shadow-sm">archived session participant</span>`:null}
                  ${t!=null&&t.model?c`<span class="font-mono text-[10px] font-medium bg-white/10 border border-white/5 px-2 py-1 rounded-md text-text-muted shadow-sm">${t.model}</span>`:""}
                  ${!t&&(s!=null&&s.archived_reason)?c`<span class="text-xs text-text-dim italic">${s.archived_reason}</span>`:null}
                  ${v?c`<span class="text-[10px] font-medium py-1 px-2 border border-accent/20 bg-accent/10 text-accent whitespace-nowrap rounded-md shadow-sm">signal · ${v}</span>`:null}
                  ${b?c`<span class="text-[10px] font-medium py-1 px-2 border border-accent/20 bg-accent/10 text-accent whitespace-nowrap rounded-md shadow-sm">source · ${b}</span>`:null}
                </div>
              </div>
            </div>
            <div class="mt-2 flex gap-3 flex-wrap text-text-muted text-[13px] font-medium">
              ${t!=null&&t.current_task||s!=null&&s.current_work?c`<span class="bg-card/40 px-3 py-1.5 rounded-lg border border-card-border shadow-sm">Task: <span class="text-text-strong">${(t==null?void 0:t.current_task)??(s==null?void 0:s.current_work)}</span></span>`:null}
              ${h?c`<span class="bg-card/40 px-3 py-1.5 rounded-lg border border-card-border shadow-sm">Last seen: <span class="text-text-strong"><${de} timestamp=${h} /></span></span>`:null}
            </div>
            ${n||y||s!=null&&s.related_session_id?c`
                  <div class="mt-1 flex gap-3 flex-wrap text-text-muted text-[13px] font-medium">
                    ${n?c`<span class="flex items-center gap-1.5">Linked keeper: <strong class="text-text-strong">${n.name}</strong>${R?c`<span class="text-text-dim text-xs">· ${R}</span>`:""}</span>`:null}
                    ${s!=null&&s.related_session_id?c`<span class="flex items-center gap-1.5">Session: <strong class="font-mono text-text-strong text-xs bg-white/5 px-1.5 rounded">${s.related_session_id}</strong></span>`:null}
                    ${y?c`<span class="text-accent/90 bg-accent/10 px-2 py-0.5 rounded-md border border-accent/10">${y}</span>`:null}
                  </div>
                `:null}
          </div>
          <div class="flex gap-2 shrink-0">
            <button class="px-4 py-2 text-[13px] font-semibold rounded-xl border border-card-border bg-card/60 text-text-body hover:bg-white/10 hover:text-text-strong transition-all duration-200 shadow-sm disabled:opacity-50 disabled:cursor-not-allowed" onClick=${()=>{Ia()}} disabled=${gn.value}>
              ${gn.value?"새로고침 중...":"새로고침"}
            </button>
            <button class="px-4 py-2 text-[13px] font-semibold rounded-xl border border-transparent bg-white/10 text-text-strong hover:bg-white/20 transition-all duration-200 shadow-sm" onClick=${Zo}>닫기</button>
          </div>
        </div>

        ${Ct.value?c`<div class="p-4 mb-4 text-bad border border-bad/30 rounded-xl bg-bad/10 shadow-sm font-medium text-sm">${Ct.value}</div>`:null}

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-5">
          <${Le} title="할당된 작업">
            ${r.length===0?c`<div class="h-full min-h-[120px]"><${kt} message="할당된 작업이 없습니다" compact /></div>`:c`<div class="flex flex-col gap-3">${r.map(T=>c`<${sf} key=${T.id} task=${T} />`)}</div>`}
          <//>

          <${Le} title="최근 활동">
            ${l.length===0?c`<div class="h-full min-h-[120px]"><${kt} message="최근 활동 기록이 없습니다" compact /></div>`:c`<div class="max-h-[240px] overflow-y-auto flex flex-col gap-2 pr-1 custom-scrollbar">${l.map((T,z)=>c`<div key=${z} class="border border-card-border bg-card/40 px-3 py-2.5 font-mono text-[12px] text-text-body leading-relaxed rounded-xl shadow-sm hover:bg-card/60 transition-colors">${T}</div>`)}</div>`}
          <//>
        </div>

        <div class="flex flex-col gap-5">
          <${ef} agentName=${e} />
          <${af} />
          <${of} agentName=${e} />
          <${Le} title="작업 이력">
            ${Et.value.length===0?c`<${kt} message="작업 이력이 없습니다" compact />`:c`<div class="flex flex-col gap-3">${Et.value.map(T=>c`<${rf} key=${T.taskId} row=${T} />`)}</div>`}
          <//>

          <${Le} title="직접 멘션">
            <div class="grid grid-cols-[1fr_auto] gap-3">
              <input
                class="w-full px-4 py-2.5 rounded-xl border border-card-border bg-card/60 text-text-strong text-[13px] placeholder:text-text-dim focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/50 transition-all duration-200 shadow-inner"
                type="text"
                placeholder="@멘션 메시지 입력..."
                value=${we.value}
                onInput=${T=>{we.value=T.target.value}}
                onKeyDown=${T=>{T.key==="Enter"&&wo()}}
                disabled=${St.value}
              />
              <button
                class="px-5 py-2.5 text-[13px] font-semibold rounded-xl border border-transparent bg-accent text-bg-0 hover:bg-accent/90 transition-all duration-200 shadow-md shadow-accent/20 disabled:opacity-50 disabled:cursor-not-allowed"
                onClick=${()=>{wo()}}
                disabled=${St.value||we.value.trim()===""}
              >
                ${St.value?"전송 중...":"전송하기"}
              </button>
            </div>
          <//>
        </div>
      </div>
    </div>
  `}function cf(){ke(()=>{Wr(),Ls(),ae(),eu(()=>void Vt());const a=cu();return du(),()=>{hc(),a(),_u()}},[]),ke(()=>{mu(),vr(E.value.tab)},[E.value.tab,E.value.params.section,E.value.params.surface,E.value.params.q]);const e=E.value.tab,t=Nr.find(a=>a.id===e),n=os(E.value);return c`
    <div class="flex min-h-screen h-screen flex-col overflow-hidden bg-[var(--bg-0)] text-[var(--text-body)]">
      <header class="shrink-0 border-b border-[var(--card-border)] bg-[rgba(4,9,18,0.82)] px-6 py-4 backdrop-blur-xl z-10">
        <div class="mx-auto flex w-full max-w-[1680px] items-start justify-between gap-6 max-[860px]:flex-col max-[860px]:items-stretch">
          <div class="min-w-0">
            <div class="flex items-center gap-4">
              <div class="flex size-12 shrink-0 items-center justify-center rounded-2xl border border-[rgba(113,214,255,0.28)] bg-[linear-gradient(145deg,rgba(61,157,255,0.34),rgba(10,28,58,0.95))] text-[18px] font-semibold text-white shadow-lg">
                ${(t==null?void 0:t.icon)??"M"}
              </div>
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2 mb-1">
                  <span class="text-[10px] font-semibold uppercase tracking-[0.22em] text-[rgba(154,217,255,0.7)]">MASC</span>
                  ${t?c`
                        <span class="text-[10px] font-medium text-[rgba(154,217,255,0.4)]">/</span>
                        <span class="text-[10px] font-semibold uppercase tracking-[0.1em] text-[rgba(154,217,255,0.9)]">${t.label}</span>
                      `:null}
                </div>
                <h1 class="text-[22px] font-semibold tracking-[-0.03em] text-[var(--text-strong)] leading-none">
                  ${(n==null?void 0:n.label)??(t==null?void 0:t.label)??"Multi-Agent Room Console"}
                </h1>
                <p class="mt-1.5 max-w-[760px] text-[12px] leading-relaxed text-[var(--text-muted)]">
                  ${(n==null?void 0:n.description)??(t==null?void 0:t.description)??"Rooms, keepers, governance, and operational signals in one place."}
                </p>
              </div>
            </div>
          </div>

          <div class="flex shrink-0 flex-col items-end gap-2">
            <${km} />
            <${Am} />
          </div>
        </div>
      </header>

      <div class="flex flex-1 gap-5 overflow-hidden p-5 max-[1100px]:flex-col max-[1100px]:p-4">
        <aside class="w-72 shrink-0 overflow-y-auto rounded-3xl border border-[var(--card-border)] bg-[linear-gradient(180deg,rgba(9,17,31,0.94),rgba(7,14,26,0.9))] shadow-xl max-[1100px]:w-full max-[1100px]:max-h-[360px]">
          <${Tm} />
        </aside>

        <main class="min-w-0 flex-1 overflow-hidden rounded-3xl border border-[var(--card-border)] bg-[linear-gradient(180deg,rgba(8,15,28,0.92),rgba(9,14,25,0.88))] shadow-xl max-[1100px]:min-h-0">
          <div class="mx-auto h-full max-w-[1600px] overflow-y-auto p-6 lg:p-8">
            <${Em} />
          </div>
        </main>
      </div>

      <${Mp} />
      <${lf} />
      <${fl} />
    </div>
  `}const es=document.getElementById("app");es&&Mr(c`<${cf} />`,es);export{i as $,Wo as A,kf as B,Le as C,cl as D,kt as E,Ef as F,Q as G,Pf as H,Cf as I,Sf as J,Lf as K,As as L,Wa as M,Vl as N,gf as O,Jl as P,tc as Q,di as R,_a as S,de as T,_f as U,bf as V,hf as W,xf as X,u as Y,o as Z,_e as _,Nd as a,So as a$,S_ as a0,Gu as a1,Hu as a2,po as a3,fo as a4,Np as a5,iv as a6,ec as a7,Yl as a8,Oa as a9,Xm as aA,oo as aB,Av as aC,tv as aD,Sn as aE,ao as aF,ae as aG,at as aH,cn as aI,nv as aJ,k_ as aK,av as aL,H as aM,Zn as aN,bo as aO,xa as aP,Y as aQ,Ot as aR,yo as aS,$o as aT,Bf as aU,ur as aV,Ao as aW,To as aX,Be as aY,ov as aZ,ko as a_,sv as aa,Of as ab,zf as ac,Cs as ad,Ga as ae,Va as af,Ps as ag,uc as ah,Kn as ai,W as aj,pm as ak,Df as al,C_ as am,jf as an,fu as ao,Mf as ap,un as aq,ln as ar,Se as as,rv as at,ot as au,ga as av,mf as aw,pf as ax,ff as ay,vf as az,cr as b,il as b$,Sa as b0,ka as b1,wn as b2,Hf as b3,Uf as b4,Eo as b5,Co as b6,Kf as b7,ea as b8,ta as b9,lv as bA,pv as bB,dv as bC,_v as bD,vv as bE,hv as bF,cv as bG,uv as bH,me as bI,Yn as bJ,Qn as bK,pn as bL,fn as bM,bv as bN,gv as bO,Ff as bP,_o as bQ,zn as bR,On as bS,s_ as bT,yv as bU,Nf as bV,qf as bW,Sv as bX,Tt as bY,bi as bZ,Zm as b_,Wf as ba,Vf as bb,Jf as bc,Yf as bd,Qf as be,Zf as bf,wf as bg,fr as bh,Gf as bi,Aa as bj,h_ as bk,vo as bl,go as bm,xo as bn,Xf as bo,E_ as bp,Cv as bq,fv as br,$v as bs,xv as bt,kv as bu,A_ as bv,mv as bw,Ut as bx,dp as by,V as bz,ho as c,Bi as c0,$f as c1,ll as c2,Gp as c3,rl as c4,da as c5,ua as c6,Tv as c7,Hl as c8,Ss as c9,Gl as ca,Wl as cb,Ul as cc,If as cd,ct as ce,T_ as cf,le as cg,Rs as ch,Af as ci,Tf as cj,Fd as d,qd as e,Xt as f,yf as g,Rf as h,xc as i,Hn as j,Gn as k,qe as l,c as m,ev as n,Xn as o,p_ as p,J as q,E as r,x_ as s,Xl as t,Ja as u,En as v,b_ as w,cc as x,rt as y,im as z};
