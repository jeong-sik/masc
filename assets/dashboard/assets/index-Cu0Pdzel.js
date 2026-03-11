var Xr=Object.defineProperty;var Zr=(t,e,n)=>e in t?Xr(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var ye=(t,e,n)=>Zr(t,typeof e!="symbol"?e+"":e,n);import{e as tl,_ as el,c as g,b as ht,y as nt,d as fo,A as nl,G as sl}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const l of o.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=tl.bind(el);const al=["mission","execution","live","memory","governance","planning","intervene","command","lab"],go={tab:"mission",params:{},postId:null};function Ii(t){return!!t&&al.includes(t)}function La(t){try{return decodeURIComponent(t)}catch{return t}}function Ma(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function il(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function $o(t,e){if(t[0]==="chains"){const o={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(o.operation=La(t[2])),{tab:"command",params:o,postId:null}}if(t[0]==="lab"){const o={...e};return t[1]&&(o.surface=La(t[1])),{tab:"lab",params:o,postId:null}}const n=t[0],s=e.tab;return{tab:Ii(n)?n:Ii(s)?s:"mission",params:e,postId:null}}function $s(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return go;const n=La(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const d=n.indexOf("?");d>=0&&(s=n.slice(0,d),a=n.slice(d+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=Ma(a),l=il(s);return $o(l,o)}function ol(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...go,params:Ma(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Ma(e.replace(/^\?/,""));return $o(s,a)}function ho(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const E=g($s(window.location.hash));window.addEventListener("hashchange",()=>{E.value=$s(window.location.hash)});function dt(t,e){const n={tab:t,params:e??{}};window.location.hash=ho(n)}function rl(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function ll(){if(window.location.hash&&window.location.hash!=="#"){E.value=$s(window.location.hash);return}const t=ol(window.location.pathname,window.location.search);if(t){E.value=t;const e=ho(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",E.value=$s(window.location.hash)}const Ri="masc_dashboard_sse_session_id",cl=1e3,dl=15e3,Zt=g(!1),Vs=g(0),yo=g(null),hs=g([]);function ul(){let t=sessionStorage.getItem(Ri);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Ri,t)),t}const pl=200;function ml(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};hs.value=[a,...hs.value].slice(0,pl)}function Da(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Pi(t,e){const n=Da(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function gt(t,e,n,s,a={}){ml(t,e,n,{eventType:s,...a})}let At=null,Re=null,za=0;function bo(){Re&&(clearTimeout(Re),Re=null)}function vl(){if(Re)return;za++;const t=Math.min(za,5),e=Math.min(dl,cl*Math.pow(2,t));Re=setTimeout(()=>{Re=null,ko()},e)}function ko(){bo(),At&&(At.close(),At=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",ul());const a=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(a);At=o,o.onopen=()=>{At===o&&(za=0,Zt.value=!0)},o.onerror=()=>{At===o&&(Zt.value=!1,o.close(),At=null,vl())},o.onmessage=l=>{try{const d=JSON.parse(l.data);Vs.value++,yo.value=d,_l(d)}catch{}}}function _l(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":gt(n,"Joined","system","agent_joined");break;case"agent_left":gt(n,"Left","system","agent_left");break;case"broadcast":gt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":gt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":gt(n,Pi("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Da(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":gt(n,Pi("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Da(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":gt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":gt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":gt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":gt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:gt(n,e,"system","unknown")}}function fl(){bo(),At&&(At.close(),At=null),Zt.value=!1}function _(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function r(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function c(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function q(t){return typeof t=="boolean"?t:void 0}function B(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Ct(t,e=[]){if(Array.isArray(t))return t;if(!_(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Fe(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function xo(){return new URLSearchParams(window.location.search)}function So(){const t=xo(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function Ao(){return{...So(),"Content-Type":"application/json"}}const gl=15e3,ai=3e4,$l=6e4,Ni=new Set([408,425,429,500,502,503,504]);class En extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);ye(this,"method");ye(this,"path");ye(this,"status");ye(this,"statusText");ye(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function ii(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const l=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new En({method:l,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function hl(){var e,n;const t=xo();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function et(t){const e=await ii(t,{headers:So()},gl);if(!e.ok)throw new En({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function yl(t){return new Promise(e=>setTimeout(e,t))}function bl(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function kl(t){if(t instanceof En)return t.timeout||typeof t.status=="number"&&Ni.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=bl(t.message);return e!==null&&Ni.has(e)}async function Co(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!kl(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${o}ms`,a),await yl(o),s+=1}}async function Mt(t,e,n,s=ai){const a=await ii(t,{method:"POST",headers:{...Ao(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new En({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function xl(t,e,n,s=ai){const a=await ii(t,{method:"POST",headers:{...Ao(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new En({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function Sl(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Al(t){var e,n,s,a,o,l,d;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const m=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(m)}return((d=(l=(o=t.result)==null?void 0:o.content)==null?void 0:l[0])==null?void 0:d.text)??""}async function ee(t,e){const n=await xl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},$l),s=Sl(n);return Al(s)}function Cl(){return et("/api/v1/dashboard/shell")}function wl(){return et("/api/v1/dashboard/execution")}function Tl(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),et(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function Il(){return et("/api/v1/dashboard/governance")}function Rl(){return et("/api/v1/dashboard/semantics")}function Pl(){return et("/api/v1/dashboard/mission")}function Nl(t=!1){return et(`/api/v1/dashboard/mission/briefing${t?"?force=1":""}`)}function Ll(){return et("/api/v1/dashboard/planning")}function Ml(){return et("/api/v1/operator")}function wo(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return et(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Dl(){return et("/api/v1/command-plane")}function zl(){return et("/api/v1/command-plane/summary")}function El(){return et("/api/v1/chains/summary")}function jl(t){return et(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Ol(){return et("/api/v1/command-plane/help")}function Fl(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return et(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function ql(t,e){return Mt(t,e)}function Kl(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return ai}}function Ys(t){return Mt("/api/v1/operator/action",t,void 0,Kl(t))}function Ul(t,e){return Mt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function on(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function Bl(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Hl(t){if(!_(t))return null;const e=y(t.id,"").trim(),n=y(t.author,"").trim(),s=y(t.content,"").trim();if(!e||!n)return null;const a=W(t.score,0),o=W(t.votes_up,0),l=W(t.votes_down,0),d=W(t.votes,a||o-l),m=W(t.comment_count,W(t.reply_count,0)),v=(()=>{const S=t.flair;if(typeof S=="string"&&S.trim())return S.trim();if(_(S)){const T=y(S.name,"").trim();if(T)return T}return y(t.flair_name,"").trim()||void 0})(),u=y(t.created_at_iso,"").trim()||on(t.created_at),p=y(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?on(t.updated_at):u),h=y(t.title,"").trim()||Bl(s),x=Array.isArray(t.tags)?t.tags.filter(S=>typeof S=="string"&&S.trim()!==""):[];return{id:e,author:n,title:h,content:s,tags:x,votes:d,vote_balance:a,comment_count:m,created_at:u,updated_at:p,flair:v,hearth:y(t.hearth,"").trim()||null,visibility:y(t.visibility,"").trim()||void 0,expires_at:y(t.expires_at_iso,"").trim()||(t.expires_at!==void 0&&t.expires_at!==0?on(t.expires_at):"")||null,hearth_count:W(t.hearth_count,0)}}function Wl(t){if(!_(t))return null;const e=y(t.id,"").trim(),n=y(t.post_id,"").trim(),s=y(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:y(t.content,""),created_at:on(t.created_at)}}async function Gl(t){return Co("fetchBoardPost",async()=>{const e=await et(`/api/v1/board/${t}?format=flat`),n=_(e.post)?e.post:e,s=Hl(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},o=(Array.isArray(e.comments)?e.comments:[]).map(Wl).filter(l=>l!==null);return{...s,comments:o}})}function To(t,e){return Mt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:hl()})}function Jl(t,e,n){return Mt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Vl(t){const e=y(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function ot(...t){for(const e of t){const n=y(e,"");if(n.trim())return n.trim()}return""}function Li(t){const e=Vl(ot(t.outcome,t.result,t.result_code));if(!e)return;const n=ot(t.reason,t.reason_code,t.description,t.detail),s=ot(t.summary,t.summary_ko,t.summary_en,t.note),a=ot(t.details,t.details_text,t.text,t.note),o=ot(t.winner,t.winner_name,t.actor_winner,t.winner_actor),l=ot(t.winner_actor_id,t.winner_actor,t.actor_winner_id),d=ot(t.raw_reason,t.raw_reason_code,t.error_message),m=(()=>{const p=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof p=="string"?[p]:Array.isArray(p)?p.map(f=>{if(typeof f=="string")return f.trim();if(_(f)){const h=y(f.summary,"").trim();if(h)return h;const x=y(f.text,"").trim();if(x)return x;const S=y(f.type,"").trim();return S||y(f.event_id,"").trim()}return""}).filter(f=>f.length>0):[]})(),v=(()=>{const p=W(t.turn,Number.NaN);if(Number.isFinite(p))return p;const f=W(t.turn_number,Number.NaN);if(Number.isFinite(f))return f;const h=W(t.current_turn,Number.NaN);if(Number.isFinite(h))return h;const x=W(t.round,Number.NaN);return Number.isFinite(x)?x:void 0})(),u=ot(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:l||void 0,evidence:m.length>0?m:void 0,raw_reason:d||void 0,turn:v,phase:u||void 0}}function Yl(t,e){const n=_(t.state)?t.state:{};if(y(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(l=>_(l)?y(l.type,"")==="session.outcome":!1),o=_(n.session_outcome)?n.session_outcome:{};if(_(o)&&Object.keys(o).length>0){const l=Li(o);if(l)return l}if(_(a))return Li(_(a.payload)?a.payload:{})}function y(t,e=""){return typeof t=="string"?t:e}function W(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Ql(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Ea(t,e=!1){return typeof t=="boolean"?t:e}function Xe(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(_(e)){const n=y(e.name,"").trim(),s=y(e.id,"").trim(),a=y(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Xl(t){const e={};if(!_(t)&&!Array.isArray(t))return e;if(_(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),o=y(s,"").trim();!a||!o||(e[a]=o)}),e;for(const n of t){if(!_(n))continue;const s=ot(n.to,n.target,n.actor_id,n.name,n.id),a=ot(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function Zl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function mt(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const tc=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function ec(t){const e=_(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const o=s.trim();o&&(tc.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function nc(t,e){if(t!=="dice.rolled")return;const n=W(e.raw_d20,0),s=W(e.total,0),a=W(e.bonus,0),o=y(e.action,"roll"),l=W(e.dc,0);return{notation:l>0?`${o} (DC ${l})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function sc(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function ac(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function ic(t,e,n,s){const a=n||e||y(s.actor_id,"")||y(s.actor_name,"");switch(t){case"turn.action.proposed":{const o=y(s.proposed_action,y(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=y(s.reply,y(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return y(s.reply,y(s.content,y(s.text,"Narration")));case"dice.rolled":{const o=y(s.action,"roll"),l=W(s.total,0),d=W(s.dc,0),m=y(s.label,""),v=a||"actor",u=d>0?` vs DC ${d}`:"",p=m?` (${m})`:"";return`${v} ${o}: ${l}${u}${p}`}case"turn.started":return`Turn ${W(s.turn,1)} started`;case"phase.changed":return`Phase: ${y(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${y(s.name,_(s.actor)?y(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${y(s.keeper_name,y(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${y(s.keeper_name,y(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${W(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${W(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||y(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||y(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${y(s.reason_code,"unknown")}`;case"memory.signal":{const o=_(s.entity_refs)?s.entity_refs:{},l=y(o.requested_tier,""),d=y(o.effective_tier,""),m=Ea(o.guardrail_applied,!1),v=y(s.summary_en,y(s.summary_ko,"Memory signal"));if(!l&&!d)return v;const u=l&&d?`${l}->${d}`:d||l;return`${v} [${u}${m?" (guardrail)":""}]`}case"world.event":{if(y(s.event_type,"")==="canon.check"){const l=y(s.status,"unknown"),d=y(s.contract_id,"n/a");return`Canon ${l}: ${d}`}return y(s.description,y(s.summary,"World event"))}case"combat.attack":return y(s.summary,y(s.result,"Attack resolved"));case"combat.defense":return y(s.summary,y(s.result,"Defense resolved"));case"session.outcome":return y(s.summary,y(s.outcome,"Session ended"));default:{const o=sc(s);return o?`${t}: ${o}`:t}}}function oc(t,e){const n=_(t)?t:{},s=y(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=y(n.actor_name,"").trim()||e[a]||y(_(n.payload)?n.payload.actor_name:"",""),l=_(n.payload)?n.payload:{},d=y(n.ts,y(n.timestamp,new Date().toISOString())),m=y(n.phase,y(l.phase,"")),v=y(n.category,"");return{type:s,actor:o||a||y(l.actor_name,""),actor_id:a||y(l.actor_id,""),actor_name:o,seq:n.seq,room_id:y(n.room_id,""),phase:m||void 0,category:v||ac(s),visibility:y(n.visibility,y(l.visibility,"public")),event_id:y(n.event_id,""),content:ic(s,a,o,l),dice_roll:nc(s,l),timestamp:d}}function rc(t,e,n){var O,Y;const s=y(t.room_id,"")||n||"default",a=_(t.state)?t.state:{},o=_(a.party)?a.party:{},l=_(a.actor_control)?a.actor_control:{},d=_(a.join_gate)?a.join_gate:{},m=_(a.contribution_ledger)?a.contribution_ledger:{},v=Object.entries(o).map(([K,Z])=>{const k=_(Z)?Z:{},bt=mt(k,"max_hp",void 0,10),Ut=mt(k,"hp",void 0,bt),ae=mt(k,"max_mp",void 0,0),ie=mt(k,"mp",void 0,0),z=mt(k,"level",void 0,1),kt=mt(k,"xp",void 0,0),oe=Ea(k.alive,Ut>0),Ye=l[K],Qe=typeof Ye=="string"?Ye:void 0,Hn=Zl(k.role,K,Qe),Wn=Ql(k.generation),Gn=ot(k.joined_at,k.joinedAt,k.started_at,k.startedAt),Jn=ot(k.claimed_at,k.claimedAt,k.assigned_at,k.assignedAt,k.assigned_time),F=ot(k.last_seen,k.lastSeen,k.last_seen_at,k.lastSeenAt,k.last_active,k.lastActive),he=ot(k.scene,k.current_scene,k.currentScene,k.world_scene,k.scene_name,k.sceneName),Qr=ot(k.location,k.current_location,k.currentLocation,k.position,k.zone,k.area);return{id:K,name:y(k.name,K),role:Hn,keeper:Qe,archetype:y(k.archetype,""),persona:y(k.persona,""),portrait:y(k.portrait,"")||void 0,background:y(k.background,"")||void 0,traits:Xe(k.traits),skills:Xe(k.skills),stats_raw:ec(k),status:oe?"active":"dead",generation:Wn,joined_at:Gn||void 0,claimed_at:Jn||void 0,last_seen:F||void 0,scene:he||void 0,location:Qr||void 0,inventory:Xe(k.inventory),notes:Xe(k.notes),relationships:Xl(k.relationships),stats:{hp:Ut,max_hp:bt,mp:ie,max_mp:ae,level:z,xp:kt,strength:mt(k,"strength","str",10),dexterity:mt(k,"dexterity","dex",10),constitution:mt(k,"constitution","con",10),intelligence:mt(k,"intelligence","int",10),wisdom:mt(k,"wisdom","wis",10),charisma:mt(k,"charisma","cha",10)}}}),u=v.filter(K=>K.status!=="dead"),p=Yl(t,e),f={phase_open:Ea(d.phase_open,!0),min_points:W(d.min_points,3),window:y(d.window,"round_boundary_only"),last_opened_turn:typeof d.last_opened_turn=="number"?d.last_opened_turn:null,last_closed_turn:typeof d.last_closed_turn=="number"?d.last_closed_turn:null},h=Object.entries(m).map(([K,Z])=>{const k=_(Z)?Z:{};return{actor_id:K,score:W(k.score,0),last_reason:y(k.last_reason,"")||null,reasons:Xe(k.reasons)}}),x=v.reduce((K,Z)=>(K[Z.id]=Z.name,K),{}),S=e.map(K=>oc(K,x)),C=W(a.turn,1),T=y(a.phase,"round"),w=y(a.map,""),A=_(a.world)?a.world:{},R=w||y(A.ascii_map,y(A.map,"")),P=S.filter((K,Z)=>{const k=e[Z];if(!_(k))return!1;const bt=_(k.payload)?k.payload:{};return W(bt.turn,-1)===C}),G=(P.length>0?P:S).slice(-12),H=y(a.status,"active");return{session:{id:s,room:s,status:H==="ended"?"ended":H==="paused"?"paused":"active",round:C,actors:u,created_at:((O=S[0])==null?void 0:O.timestamp)??new Date().toISOString()},current_round:{round_number:C,phase:T,events:G,timestamp:((Y=S[S.length-1])==null?void 0:Y.timestamp)??new Date().toISOString()},map:R||void 0,join_gate:f,contribution_ledger:h,outcome:p,party:u,story_log:S,history:[]}}async function lc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await et(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function cc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([et(`/api/v1/trpg/state${e}`),lc(t)]);return rc(n,s,t)}function dc(t){return Mt("/api/v1/trpg/rounds/run",{room_id:t})}function uc(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function pc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Mt("/api/v1/trpg/dice/roll",e)}function mc(t,e){const n=uc();return Mt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function vc(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Mt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function _c(t,e,n){return Mt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function fc(t,e,n){const s=await ee("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function gc(t){const e=await ee("trpg.mid_join.request",t);return JSON.parse(e)}async function $c(t,e){await ee("masc_broadcast",{agent_name:t,message:e})}async function hc(t=40){return(await ee("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function yc(t,e=20){return ee("masc_task_history",{task_id:t,limit:e})}async function bc(t){const e=await ee("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function kc(t){return Co("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await et(`/api/v1/council/debates/${e}/summary`);if(!_(n))return null;const s=y(n.id,"").trim();return s?{id:s,topic:y(n.topic,""),status:y(n.status,"open"),support_count:W(n.support_count,0),oppose_count:W(n.oppose_count,0),neutral_count:W(n.neutral_count,0),total_arguments:W(n.total_arguments,0),created_at:on(n.created_at_iso??n.created_at),summary_text:y(n.summary_text,"")}:null})}function xc(t,e,n){return ee("masc_keeper_msg",{name:t,message:e})}const Sc=g(""),Ot=g({}),rt=g({}),ja=g({}),Oa=g({}),Fa=g({}),qa=g({}),Ft=g({});function it(t,e,n){t.value={...t.value,[e]:n}}function Ac(t){var n;const e=(n=r(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Cc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function aa(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!_(s))continue;const a=r(s.name);if(!a)continue;const o=r(s[e]);e==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function wc(t){if(!_(t))return null;const e=r(t.name);return e?{name:e,trigger:r(t.trigger),outcome:r(t.outcome),summary:r(t.summary),reason:r(t.reason)}:null}function Tc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Ic(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Io(t,e,n){return r(t)??Ic(e,n)}function Ro(t,e){return typeof t=="boolean"?t:e==="recover"}function ys(t){if(!_(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:r(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:Fe(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:c(t.next_eligible_at_s)??null,recoverable:Ro(t.recoverable,n),summary:Io(t.summary,e,r(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Po(t){return _(t)?{hour:c(t.hour),checked:c(t.checked)??0,acted:c(t.acted)??0,acted_names:B(t.acted_names),activity_report:r(t.activity_report),quiet_hours_overridden:q(t.quiet_hours_overridden),skipped_reason:r(t.skipped_reason),acted_rows:aa(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:aa(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:aa(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(wc).filter(e=>e!==null):[]}:null}function Rc(t){return _(t)?{enabled:q(t.enabled)??!1,interval_s:c(t.interval_s)??0,quiet_start:c(t.quiet_start),quiet_end:c(t.quiet_end),quiet_active:q(t.quiet_active),use_planner:q(t.use_planner),delegate_llm:q(t.delegate_llm),agent_count:c(t.agent_count),agents:B(t.agents),last_tick_ago_s:c(t.last_tick_ago_s)??null,last_tick_ago:r(t.last_tick_ago),total_ticks:c(t.total_ticks),total_checkins:c(t.total_checkins),last_skip_reason:r(t.last_skip_reason)??null,last_tick_result:Po(t.last_tick_result),active_self_heartbeats:B(t.active_self_heartbeats)}:null}function Pc(t){return _(t)?{status:t.status,diagnostic:ys(t.diagnostic)}:null}function Nc(t){return _(t)?{recovered:q(t.recovered)??!1,skipped_reason:r(t.skipped_reason)??null,before:ys(t.before),after:ys(t.after),down:t.down,up:t.up}:null}function Lc(t,e){var w,A;if(!(t!=null&&t.name))return null;const n=r((w=t.agent)==null?void 0:w.status)??r(t.status)??"unknown",s=r((A=t.agent)==null?void 0:A.error)??null,a=t.presence_keepalive??!0,o=t.keepalive_running??!1,l=t.turn_count??0,d=t.last_turn_ago_s??null,m=t.proactive_enabled??!1,v=t.proactive_cooldown_sec??0,u=t.last_proactive_ago_s??null,p=m&&u!=null?Math.max(0,v-u):null,f=l<=0||d==null?"never":d>900?"stale":"fresh",h=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,x=s??(a&&!o?"keeper keepalive is not running":null),S=n==="offline"||n==="inactive"?"offline":x?"degraded":f==="stale"?"stale":f==="never"?"idle":"healthy",C=x?Tc(x):e!=null&&e.quiet_active&&f!=="fresh"?"quiet_hours":a&&!o?"disabled":l<=0?"never_started":p!=null&&p>0?"min_gap":f==="fresh"||f==="stale"?"no_recent_activity":"unknown",T=S==="offline"||S==="degraded"||S==="stale"?"recover":C==="quiet_hours"?"manual_lodge_poke":C==="unknown"?"probe":"direct_message";return{health_state:S,quiet_reason:C,next_action_path:T,last_reply_status:f,last_reply_at:h,last_reply_preview:null,last_error:x,next_eligible_at_s:p!=null&&p>0?p:null,recoverable:Ro(void 0,T),summary:Io(void 0,S,C),keepalive_running:o}}function Mc(t,e){if(!_(t))return null;const n=Ac(t.role),s=r(t.content)??r(t.preview);if(!s)return null;const a=Fe(t.ts_unix)??Fe(t.timestamp);return{id:`${n}-${a??"entry"}-${e}`,role:n,label:Cc(n),text:s,timestamp:a,delivery:"history"}}function Dc(t,e,n){const s=_(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,l)=>Mc(o,l)).filter(o=>o!==null):[];return{name:t,diagnostic:ys(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function Mi(t,e){const n=rt.value[t]??[];rt.value={...rt.value,[t]:[...n,e].slice(-50)}}function zc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Ec(t,e){const s=(rt.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(o=>zc(a,o)));rt.value={...rt.value,[t]:[...e,...s].slice(-50)}}function Qs(t,e){Ot.value={...Ot.value,[t]:e},Ec(t,e.history)}function Di(t,e){const n=Ot.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Qs(t,{...n,diagnostic:{...s,...e}})}async function oi(){try{await jn()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function jc(t){Sc.value=t.trim()}async function No(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Ot.value[n])return Ot.value[n];it(ja,n,!0),it(Ft,n,null);try{const s=await ee("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=Dc(n,s,a);return Qs(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return it(Ft,n,a),null}finally{it(ja,n,!1)}}async function Oc(t,e){const n=t.trim(),s=e.trim();if(!n||!s)return;const a=`local-${Date.now()}`;Mi(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),it(Oa,n,!0),it(Ft,n,null);try{const o=await xc(n,s);rt.value={...rt.value,[n]:(rt.value[n]??[]).map(l=>l.id===a?{...l,delivery:"delivered"}:l)},Mi(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Di(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await oi()}catch(o){const l=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw rt.value={...rt.value,[n]:(rt.value[n]??[]).map(d=>d.id===a?{...d,delivery:"error",error:l}:d)},Di(n,{last_reply_status:"error",last_error:l}),it(Ft,n,l),o}finally{it(Oa,n,!1)}}async function Fc(t,e){const n=t.trim();if(!n)return null;it(Fa,n,!0),it(Ft,n,null);try{const s=await Ys({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=Pc(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const l=Ot.value[n];Qs(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??rt.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await oi(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw it(Ft,n,a),s}finally{it(Fa,n,!1)}}async function qc(t,e){const n=t.trim();if(!n)return null;it(qa,n,!0),it(Ft,n,null);try{const s=await Ys({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Nc(s.result),o=(a==null?void 0:a.after)??null;if(o){const l=Ot.value[n];Qs(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??rt.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await oi(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw it(Ft,n,a),s}finally{it(qa,n,!1)}}function re(t){return(t??"").trim().toLowerCase()}function ut(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ls(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Vn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ze(t){return t.last_heartbeat??Vn(t.last_turn_ago_s)??Vn(t.last_proactive_ago_s)??Vn(t.last_handoff_ago_s)??Vn(t.last_compaction_ago_s)}function Kc(t){const e=t.title.trim();return e||ls(t.content)}function Uc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Bc(t,e,n,s,a={}){var A;const o=re(t),l=e.filter(R=>re(R.assignee)===o&&(R.status==="claimed"||R.status==="in_progress")).length,d=n.filter(R=>re(R.from)===o).sort((R,P)=>ut(P.timestamp)-ut(R.timestamp))[0],m=s.filter(R=>re(R.agent)===o||re(R.author)===o).sort((R,P)=>ut(P.timestamp)-ut(R.timestamp))[0],v=(a.boardPosts??[]).filter(R=>re(R.author)===o).sort((R,P)=>ut(P.updated_at||P.created_at)-ut(R.updated_at||R.created_at))[0],u=(a.keepers??[]).filter(R=>re(R.name)===o&&Ze(R)!==null).sort((R,P)=>ut(Ze(P)??0)-ut(Ze(R)??0))[0],p=d?ut(d.timestamp):0,f=m?ut(m.timestamp):0,h=v?ut(v.updated_at||v.created_at):0,x=u?ut(Ze(u)??0):0,S=a.lastSeen?ut(a.lastSeen):0,C=((A=a.currentTask)==null?void 0:A.trim())||(l>0?`${l} claimed tasks`:null);if(p===0&&f===0&&h===0&&x===0&&S===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:C};const w=[d?{timestamp:d.timestamp,ts:p,text:ls(d.content)}:null,v?{timestamp:v.updated_at||v.created_at,ts:h,text:`Post: ${ls(Kc(v))}`}:null,u?{timestamp:Ze(u),ts:x,text:Uc(u)}:null,m?{timestamp:new Date(m.timestamp).toISOString(),ts:f,text:ls(m.text)}:null].filter(R=>R!==null).sort((R,P)=>P.ts-R.ts)[0];return w&&w.ts>=S?{activeAssignedCount:l,lastActivityAt:w.timestamp,lastActivityText:w.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:C??"Presence heartbeat"}}const yt=g([]),It=g([]),qe=g([]),Kt=g([]),_t=g(null),Hc=g(null),Ka=g(new Map),gn=g([]),$n=g("recent"),Ce=g(!0),Lo=g(null),jt=g(""),Pe=g([]),rn=g(!1),Mo=g(new Map),ri=g("unknown"),Ne=g(null),Ua=g(!1),hn=g(!1),Ba=g(!1),ln=g(!1),li=g(null),bs=g(!1),ks=g(null),Do=g(null),Ha=g(null),Wc=g(null),Gc=g(null),Jc=g(null);ht(()=>yt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const zo=ht(()=>{const t=It.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),ci=ht(()=>{const t=new Map,e=It.value,n=qe.value,s=hs.value,a=gn.value,o=Kt.value;for(const l of yt.value)t.set(l.name.trim().toLowerCase(),Bc(l.name,e,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:o}));return t});function Vc(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const Yc=ht(()=>{const t=new Map;for(const e of Kt.value)t.set(e.name,Vc(e));return t}),Qc=12e4;function Xc(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}const Zc=ht(()=>{const t=Date.now(),e=new Set,n=Ka.value;for(const s of Kt.value){const a=Xc(s,n);a!=null&&t-a>Qc&&e.add(s.name)}return e});let ia=null;function td(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function Eo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function ed(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function nd(t){if(!_(t))return null;const e=r(t.name);return e?{name:e,agent_type:r(t.agent_type),status:Eo(t.status),current_task:r(t.current_task)??null,joined_at:r(t.joined_at),last_seen:r(t.last_seen),capabilities:B(t.capabilities),emoji:r(t.emoji),koreanName:r(t.koreanName)??r(t.korean_name),model:r(t.model),traits:B(t.traits),interests:B(t.interests),activityLevel:c(t.activityLevel)??c(t.activity_level),primaryValue:r(t.primaryValue)??r(t.primary_value)}:null}function sd(t){if(!_(t))return null;const e=r(t.id),n=r(t.title);return!e||!n?null:{id:e,title:n,status:ed(t.status),priority:c(t.priority),assignee:r(t.assignee),description:r(t.description),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function ad(t){if(!_(t))return null;const e=r(t.from)??r(t.from_agent)??"system",n=r(t.content)??"",s=r(t.timestamp)??new Date().toISOString();return{id:r(t.id),seq:c(t.seq),from:e,content:n,timestamp:s,type:r(t.type)}}function zi(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function id(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>zi(s)-zi(a)).slice(-500)}function od(t){return Array.isArray(t)?t.map(e=>{if(!_(e))return null;const n=c(e.ts_unix);if(n==null)return null;const s=_(e.handoff)?e.handoff:null;return{ts:n,context_ratio:c(e.context_ratio)??0,context_tokens:c(e.context_tokens)??0,context_max:c(e.context_max)??0,latency_ms:c(e.latency_ms)??0,generation:c(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:c(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:c(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?c(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Ei(t){if(!_(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);if(!e||!n||!s)return null;const a=r(t.quiet_reason)??null,o=r(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:Fe(t.last_reply_at)??r(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:c(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function rd(t,e){return(Array.isArray(t)?t:_(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!_(s))return null;const a=_(s.agent)?s.agent:null,o=_(s.context)?s.context:null,l=_(s.metrics_window)?s.metrics_window:void 0,d=r(s.name);if(!d)return null;const m=c(s.context_ratio)??c(o==null?void 0:o.context_ratio),v=r(s.status)??r(a==null?void 0:a.status)??"offline",u=Eo(v),p=r(s.model)??r(s.active_model)??r(s.primary_model),f=B(s.skill_secondary),h=o?{source:r(o.source),context_ratio:c(o.context_ratio),context_tokens:c(o.context_tokens),context_max:c(o.context_max),message_count:c(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,x=a?{name:r(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:r(a.error),agent_type:r(a.agent_type),status:r(a.status),current_task:r(a.current_task)??null,joined_at:r(a.joined_at),last_seen:r(a.last_seen),last_seen_ago_s:c(a.last_seen_ago_s),capabilities:B(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,S=od(s.metrics_series),C={name:d,emoji:r(s.emoji),koreanName:r(s.koreanName)??r(s.korean_name),agent_name:r(s.agent_name),trace_id:r(s.trace_id),model:p,primary_model:r(s.primary_model),active_model:r(s.active_model),next_model_hint:r(s.next_model_hint)??null,status:u,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:c(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:c(s.proactive_idle_sec),proactive_cooldown_sec:c(s.proactive_cooldown_sec),last_heartbeat:r(s.last_heartbeat)??r(a==null?void 0:a.last_seen),generation:c(s.generation),turn_count:c(s.turn_count)??c(s.total_turns),keeper_age_s:c(s.keeper_age_s),last_turn_ago_s:c(s.last_turn_ago_s),last_handoff_ago_s:c(s.last_handoff_ago_s),last_compaction_ago_s:c(s.last_compaction_ago_s),last_proactive_ago_s:c(s.last_proactive_ago_s),last_proactive_preview:r(s.last_proactive_preview)??null,context_ratio:m,context_tokens:c(s.context_tokens)??c(o==null?void 0:o.context_tokens),context_max:c(s.context_max)??c(o==null?void 0:o.context_max),context_source:r(s.context_source)??r(o==null?void 0:o.source),context:h,traits:B(s.traits),interests:B(s.interests),primaryValue:r(s.primaryValue)??r(s.primary_value),activityLevel:c(s.activityLevel)??c(s.activity_level),memory_recent_note:r(s.memory_recent_note)??null,recent_input_preview:r(s.recent_input_preview)??null,recent_output_preview:r(s.recent_output_preview)??null,recent_tool_names:B(s.recent_tool_names)??[],conversation_tail_count:c(s.conversation_tail_count),k2k_count:c(s.k2k_count),handoff_count_total:c(s.handoff_count_total)??c(s.trace_history_count),compaction_count:c(s.compaction_count),last_compaction_saved_tokens:c(s.last_compaction_saved_tokens),diagnostic:Ei(s.diagnostic),skill_primary:r(s.skill_primary)??null,skill_secondary:f,skill_reason:r(s.skill_reason)??null,metrics_series:S.length>0?S:void 0,metrics_window:l,agent:x};return C.diagnostic=Ei(s.diagnostic)??Lc(C,(e==null?void 0:e.lodge)??null),C}).filter(s=>s!==null)}function jo(t){return _(t)?{...t,lodge:Rc(t.lodge)??void 0}:null}function ld(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function cd(t){if(!_(t))return null;const e=c(t.iteration);if(e==null)return null;const n=c(t.metric_before)??0,s=c(t.metric_after)??n,a=_(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:c(t.delta)??s-n,changes:r(t.changes)??"",failed_attempts:r(t.failed_attempts)??"",next_suggestion:r(t.next_suggestion)??"",elapsed_ms:c(t.elapsed_ms)??0,cost_usd:c(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:c(a.tool_call_count)??0,tool_names:B(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function dd(t){var o,l;if(!_(t))return null;const e=r(t.loop_id);if(!e)return null;const n=c(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(cd).filter(d=>d!==null):[],a=c(t.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:r(t.profile)??"unknown",status:ld(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:r(t.error_message)??r(t.error_reason)??null,stop_reason:r(t.stop_reason)??r(t.reason)??null,current_iteration:c(t.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:c(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(t.target)??"",stagnation_streak:c(t.stagnation_streak)??0,stagnation_limit:c(t.stagnation_limit)??0,elapsed_seconds:c(t.elapsed_seconds)??0,updated_at:Fe(t.updated_at)??null,stopped_at:Fe(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:c(t.latest_tool_call_count)??0,latest_tool_names:B(t.latest_tool_names)??[],session_id:r(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function jn(){Ua.value=!0;try{await Promise.all([Fo(),Et()]),Do.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{Ua.value=!1}}async function Oo(){bs.value=!0,ks.value=null;try{const t=await Rl();li.value=t,Jc.value=new Date().toISOString()}catch(t){ks.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{bs.value=!1}}function ud(t){var e;return((e=li.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function pd(t){var n;const e=((n=li.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(o=>o.id===t);if(a)return a}return null}function md(t){var s,a;Pe.value=(Array.isArray(t.goals)?t.goals:[]).map(o=>{if(!_(o))return null;const l=r(o.id),d=r(o.title),m=r(o.horizon),v=r(o.status),u=r(o.created_at),p=r(o.updated_at);return!l||!d||!m||!v||!u||!p?null:{id:l,horizon:m,title:d,metric:r(o.metric)??null,target_value:r(o.target_value)??null,due_date:r(o.due_date)??null,priority:c(o.priority)??3,status:v,parent_goal_id:r(o.parent_goal_id)??null,last_review_note:r(o.last_review_note)??null,last_review_at:r(o.last_review_at)??null,created_at:u,updated_at:p}}).filter(o=>o!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const o of n){const l=dd(o);l&&e.set(l.loop_id,l)}Mo.value=e,Ne.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,ri.value=Ne.value?"error":e.size===0?"idle":"ready"}async function Fo(){try{const t=await Cl(),e=jo(t.status);e&&(_t.value=e)}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Et(){var t;try{const e=await wl(),n=jo(e.status),s=(t=_t.value)==null?void 0:t.room;n&&(_t.value=n);const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;yt.value=(Array.isArray(e.agents)?e.agents:[]).map(nd).filter(l=>l!==null),It.value=(Array.isArray(e.tasks)?e.tasks:[]).map(sd).filter(l=>l!==null);const o=(Array.isArray(e.messages)?e.messages:[]).map(ad).filter(l=>l!==null);qe.value=a?o:id(qe.value,o),Kt.value=rd(e.keepers,n??_t.value),Hc.value=null,Do.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function Rt(){hn.value=!0;try{const t=await Tl($n.value,{excludeSystem:Ce.value});gn.value=t.posts??[],Ha.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{hn.value=!1}}async function Pt(){var t;Ba.value=!0;try{const e=jt.value||((t=_t.value)==null?void 0:t.room)||"default";jt.value||(jt.value=e);const n=await cc(e);Lo.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Ba.value=!1}}async function yn(){rn.value=!0,ln.value=!0;try{const t=await Ll();md(t),Wc.value=new Date().toISOString(),Gc.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),ri.value="error",Ne.value=t instanceof Error?t.message:String(t)}finally{rn.value=!1,ln.value=!1}}async function qo(){return yn()}let cs=null;function vd(t){cs=t}let ds=null;function _d(t){ds=t}let us=null;function fd(t){us=t}const ue={};function le(t,e,n=500){ue[t]&&clearTimeout(ue[t]),ue[t]=setTimeout(()=>{e(),delete ue[t]},n)}function gd(){const t=yo.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Ka.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Ka.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&le("execution",Et),td(e.type)&&(ia||(ia=setTimeout(()=>{jn(),ds==null||ds(),us==null||us(),ia=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&le("execution",Et),e.type==="broadcast"&&le("execution",Et),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&le("execution",Et),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&le("board",Rt),e.type.startsWith("decision_")&&le("council",()=>cs==null?void 0:cs()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&le("mdal",qo,350)}});return()=>{t();for(const e of Object.keys(ue))clearTimeout(ue[e]),delete ue[e]}}let cn=null;function $d(){cn||(cn=setInterval(()=>{Zt.value,jn()},1e4))}function hd(){cn&&(clearInterval(cn),cn=null)}function yd({metric:t}){return i`
    <article class="semantic-metric-row">
      <div class="semantic-metric-head">
        <strong>${t.label}</strong>
        <span class="semantic-code">${t.id}</span>
      </div>
      <p>${t.what_it_measures}</p>
      <div class="semantic-grid compact">
        <span>Why</span><span>${t.why_it_exists}</span>
        <span>Source</span><span>${t.source_path}</span>
        <span>Trigger</span><span>${t.update_trigger}</span>
        <span>Agent Effect</span><span>${t.agent_behavior_effect}</span>
        <span>Ecosystem</span><span>${t.ecosystem_effect}</span>
        <span>Interpret</span><span>${t.interpretation}</span>
        <span>Bad Smell</span><span>${t.bad_smell}</span>
        <span>Next</span><span>${t.next_action}</span>
      </div>
    </article>
  `}function bd({panel:t}){return i`
    <div class="semantic-body">
      <div class="semantic-grid">
        <span>Purpose</span><span>${t.purpose}</span>
        <span>Solves</span><span>${t.problem_solved}</span>
        <span>When</span><span>${t.when_active}</span>
        <span>Agent Role</span><span>${t.agent_role}</span>
        <span>Ecosystem</span><span>${t.ecosystem_function}</span>
      </div>
      ${t.related_tools.length>0?i`<div class="semantic-tag-row">
            ${t.related_tools.map(e=>i`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
      ${t.metrics.length>0?i`<div class="semantic-metric-list">
            ${t.metrics.map(e=>i`<${yd} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function M({panelId:t,compact:e=!1,label:n="Why"}){const s=pd(t);return s?i`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${bd} panel=${s} />
    </details>
  `:bs.value?i`<span class="semantic-inline-state">Loading semantics…</span>`:null}function ft({surfaceId:t,compact:e=!1}){const n=ud(t);return n?i`
    <section class="semantic-surface-card ${e?"compact":""}">
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
  `:bs.value?i`<div class="semantic-surface-card ${e?"compact":""}">Loading semantics…</div>`:ks.value?i`<div class="semantic-surface-card ${e?"compact":""}">${ks.value}</div>`:null}function I({title:t,class:e,semanticId:n,children:s}){return i`
    <div class="card ${e??""}">
      ${t?i`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?i`<${M} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${s}
    </div>
  `}function di(t){const e=t.indexOf("-");if(e<0)return{model:t,nickname:t,isKeeper:t==="keeper"};const n=t.slice(0,e),s=t.slice(e+1);return{model:n,nickname:s,isKeeper:n==="keeper"}}function kd(t){return t==="keeper"||t.startsWith("keeper-")}const ui=g(null),Wa=g(!1),xs=g(null),Ko=g(null),we=g(!1),de=g(null);let Le=null;function ji(){Le!==null&&(window.clearTimeout(Le),Le=null)}function xd(t=1500){Le===null&&(Le=window.setTimeout(()=>{Le=null,bn(!1)},t))}function j(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function b(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function D(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Me(t){return typeof t=="boolean"?t:void 0}function X(t,e=[]){if(Array.isArray(t))return t;if(!j(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Ge(t){if(!j(t))return null;const e=b(t.kind),n=b(t.summary),s=b(t.target_type);return!e||!n||!s?null:{kind:e,severity:b(t.severity)??"warn",summary:n,target_type:s,target_id:b(t.target_id)??null,actor:b(t.actor)??null,evidence:t.evidence}}function fe(t){if(!j(t))return null;const e=b(t.action_type),n=b(t.target_type),s=b(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:b(t.target_id)??null,severity:b(t.severity)??"warn",reason:s,confirm_required:Me(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Sd(t){if(!j(t))return null;const e=b(t.session_id);return e?{session_id:e,goal:b(t.goal),status:b(t.status),health:b(t.health),scale_profile:b(t.scale_profile),control_profile:b(t.control_profile),planned_worker_count:D(t.planned_worker_count),active_agent_count:D(t.active_agent_count),last_turn_age_sec:D(t.last_turn_age_sec)??null,attention_count:D(t.attention_count),recommended_action_count:D(t.recommended_action_count),top_attention:Ge(t.top_attention),top_recommendation:fe(t.top_recommendation)}:null}function Ad(t){if(!j(t))return null;const e=b(t.session_id);if(!e)return null;const n=j(t.status)?t.status:t,s=j(n.summary)?n.summary:void 0;return{session_id:e,status:b(t.status)??b(s==null?void 0:s.status)??(j(n.session)?b(n.session.status):void 0),progress_pct:D(t.progress_pct)??D(s==null?void 0:s.progress_pct),elapsed_sec:D(t.elapsed_sec)??D(s==null?void 0:s.elapsed_sec),remaining_sec:D(t.remaining_sec)??D(s==null?void 0:s.remaining_sec),done_delta_total:D(t.done_delta_total)??D(s==null?void 0:s.done_delta_total),summary:j(t.summary)?t.summary:s,team_health:j(t.team_health)?t.team_health:j(n.team_health)?n.team_health:void 0,communication_metrics:j(t.communication_metrics)?t.communication_metrics:j(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:j(t.orchestration_state)?t.orchestration_state:j(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:j(t.cascade_metrics)?t.cascade_metrics:j(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:j(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,o])=>{const l=b(o);return l?[a,l]:null}).filter(a=>a!==null)):j(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const l=b(o);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:j(t.session)?t.session:j(n.session)?n.session:void 0,recent_events:X(t.recent_events,["events"]).filter(j)}}function Cd(t){if(!j(t))return null;const e=b(t.name);return e?{name:e,agent_name:b(t.agent_name),status:b(t.status),autonomy_level:b(t.autonomy_level),context_ratio:D(t.context_ratio),generation:D(t.generation),active_goal_ids:X(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:b(t.last_autonomous_action_at)??null,last_turn_ago_s:D(t.last_turn_ago_s),model:b(t.model)}:null}function wd(t){if(!j(t))return null;const e=b(t.confirm_token)??b(t.token);return e?{confirm_token:e,actor:b(t.actor),action_type:b(t.action_type),target_type:b(t.target_type),target_id:b(t.target_id)??null,delegated_tool:b(t.delegated_tool),created_at:b(t.created_at),preview:t.preview}:null}function Td(t){if(!j(t))return null;const e=b(t.action_type),n=b(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:b(t.description),confirm_required:Me(t.confirm_required)}}function Id(t){const e=j(t)?t:{};return{room_health:b(e.room_health),cluster:b(e.cluster),project:b(e.project),current_room:b(e.current_room)??null,paused:Me(e.paused),tempo_interval_s:D(e.tempo_interval_s),active_agents:D(e.active_agents),keeper_pressure:D(e.keeper_pressure),active_operations:D(e.active_operations),pending_approvals:D(e.pending_approvals),incident_count:D(e.incident_count),recommended_action_count:D(e.recommended_action_count),top_attention:Ge(e.top_attention),top_action:fe(e.top_action)}}function Rd(t){const e=j(t)?t:{},n=j(e.swarm_overview)?e.swarm_overview:{};return{health:b(e.health),active_operations:D(e.active_operations),pending_approvals:D(e.pending_approvals),swarm_overview:{active_lanes:D(n.active_lanes),moving_lanes:D(n.moving_lanes),stalled_lanes:D(n.stalled_lanes),projected_lanes:D(n.projected_lanes),last_movement_at:b(n.last_movement_at)??null},top_attention:Ge(e.top_attention),top_action:fe(e.top_action),session_cards:X(e.session_cards).map(Sd).filter(s=>s!==null)}}function Pd(t){const e=j(t)?t:{};return{sessions:X(e.sessions,["items"]).map(Ad).filter(n=>n!==null),keepers:X(e.keepers,["items"]).map(Cd).filter(n=>n!==null),pending_confirms:X(e.pending_confirms).map(wd).filter(n=>n!==null),available_actions:X(e.available_actions).map(Td).filter(n=>n!==null)}}function Nd(t){if(!j(t))return null;const e=b(t.id),n=b(t.kind),s=b(t.summary),a=b(t.target_type);return!e||!n||!s||!a?null:{id:e,kind:n,severity:b(t.severity)??"warn",summary:s,target_type:a,target_id:b(t.target_id)??null,top_action:fe(t.top_action),related_session_ids:X(t.related_session_ids).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),related_agent_names:X(t.related_agent_names).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),evidence_preview:X(t.evidence_preview).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),last_seen_at:b(t.last_seen_at)??null}}function Ld(t){if(!j(t))return null;const e=b(t.session_id),n=b(t.goal);return!e||!n?null:{session_id:e,goal:n,room:b(t.room)??null,status:b(t.status),health:b(t.health),member_names:X(t.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:b(t.started_at)??null,elapsed_sec:D(t.elapsed_sec)??null,last_event_at:b(t.last_event_at)??null,last_event_summary:b(t.last_event_summary)??null,communication_summary:b(t.communication_summary)??null,active_count:D(t.active_count),required_count:D(t.required_count),related_attention_count:D(t.related_attention_count)??0,top_attention:Ge(t.top_attention),top_recommendation:fe(t.top_recommendation)}}function Md(t){if(!j(t))return null;const e=b(t.agent_name);return e?{agent_name:e,status:b(t.status),where:b(t.where)??null,with_whom:X(t.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:b(t.current_work)??null,related_session_id:b(t.related_session_id)??null,related_attention_count:D(t.related_attention_count)??0,recent_output_preview:b(t.recent_output_preview)??null,recent_input_preview:b(t.recent_input_preview)??null,recent_event:b(t.recent_event)??null,recent_tool_names:X(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean)}:null}function Dd(t){if(!j(t))return null;const e=b(t.name);return e?{name:e,agent_name:b(t.agent_name)??null,status:b(t.status),generation:D(t.generation),context_ratio:D(t.context_ratio)??null,last_turn_ago_s:D(t.last_turn_ago_s)??null,current_work:b(t.current_work)??null,last_autonomous_action_at:b(t.last_autonomous_action_at)??null}:null}function zd(t){if(!j(t))return null;const e=b(t.id),n=b(t.signal_type),s=b(t.summary),a=b(t.target_type);return!e||!n||!s||!a?null:{id:e,signal_type:n==="action"?"action":"attention",severity:b(t.severity)??"warn",summary:s,target_type:a,target_id:b(t.target_id)??null,attention:Ge(t.attention),action:fe(t.action)}}function Ed(t){const e=j(t)?t:{};return{generated_at:b(e.generated_at),summary:Id(e.summary),incidents:X(e.incidents).map(Ge).filter(n=>n!==null),recommended_actions:X(e.recommended_actions).map(fe).filter(n=>n!==null),command_focus:Rd(e.command_focus),operator_targets:Pd(e.operator_targets),attention_queue:X(e.attention_queue).map(Nd).filter(n=>n!==null),session_briefs:X(e.session_briefs).map(Ld).filter(n=>n!==null),agent_briefs:X(e.agent_briefs).map(Md).filter(n=>n!==null),keeper_briefs:X(e.keeper_briefs).map(Dd).filter(n=>n!==null),internal_signals:X(e.internal_signals).map(zd).filter(n=>n!==null)}}function jd(t){if(!j(t))return null;const e=b(t.id),n=b(t.label),s=b(t.summary);if(!e||!n||!s)return null;const a=b(t.status)??"unclear";return{id:e,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,evidence:X(t.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function Od(t){const e=j(t)?t:{},n=j(e.basis)?e.basis:{},s=b(e.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:b(e.generated_at),cached:Me(e.cached),stale:Me(e.stale),refreshing:Me(e.refreshing),status:a,summary:b(e.summary)??null,model:b(e.model)??null,ttl_sec:D(e.ttl_sec),criteria:X(e.criteria).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),basis:{current_room:b(n.current_room)??null,crew_count:D(n.crew_count),agent_count:D(n.agent_count),keeper_count:D(n.keeper_count)},sections:X(e.sections).map(jd).filter(o=>o!==null),error:b(e.error)??null,last_error:b(e.last_error)??null}}async function ps(){Wa.value=!0,xs.value=null;try{const t=await Pl();ui.value=Ed(t)}catch(t){xs.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{Wa.value=!1}}async function bn(t=!1){we.value=!0,de.value=null;try{const e=await Nl(t),n=Od(e);Ko.value=n,n.refreshing||n.status==="pending"?xd():ji()}catch(e){de.value=e instanceof Error?e.message:"Failed to load mission briefing",ji()}finally{we.value=!1}}function ne({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Uo(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const o=Math.floor(a/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function tt({timestamp:t}){const e=Uo(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return i`<span class="time-ago" title=${n}>${e}</span>`}let Fd=0;const pe=g([]);function N(t,e="success",n=4e3){const s=++Fd;pe.value=[...pe.value,{id:s,message:t,type:e}],setTimeout(()=>{pe.value=pe.value.filter(a=>a.id!==s)},n)}function qd(t){pe.value=pe.value.filter(e=>e.id!==t)}function Kd(){const t=pe.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>qd(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Ud="masc_dashboard_agent_name",Je=g(null),Ss=g(!1),kn=g(""),As=g([]),xn=g([]),De=g(""),dn=g(!1);function Ke(t){Je.value=t,pi()}function Oi(){Je.value=null,kn.value="",As.value=[],xn.value=[],De.value=""}function Bd(){const t=Je.value;return t?yt.value.find(e=>e.name===t)??null:null}function Bo(t){return t?It.value.filter(e=>e.assignee===t):[]}function Ho(t){return t?Kt.value.find(e=>e.agent_name===t||e.name===t)??null:null}function Hd(t){if(!t)return[];const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Wd(t){const e=Ho(t);return e?e.recent_tool_names&&e.recent_tool_names.length>0?e.recent_tool_names:[]:[]}async function pi(){const t=Je.value;if(t){Ss.value=!0,kn.value="",As.value=[],xn.value=[];try{const e=await hc(80);As.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Bo(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await yc(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const l=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));xn.value=s}catch(e){kn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Ss.value=!1}}}async function Fi(){var s;const t=Je.value,e=De.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Ud))==null?void 0:s.trim())||"dashboard";dn.value=!0;try{await $c(n,`@${t} ${e}`),De.value="",N(`Mention sent to ${t}`,"success"),pi()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";N(o,"error")}finally{dn.value=!1}}function Gd({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${ne} status=${t.status} />
    </div>
  `}function Jd({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Vd(){var p,f,h,x,S,C,T;const t=Je.value;if(!t)return null;const e=Bd(),n=Ho(t),s=Bo(t),a=As.value,o=Wd(t),l=Hd(n),d=(e==null?void 0:e.capabilities)??[],m=((p=_t.value)==null?void 0:p.room)??"default",v=((f=_t.value)==null?void 0:f.project)??"확인 없음",u=((h=_t.value)==null?void 0:h.cluster)??"확인 없음";return i`
    <div
      class="agent-detail-overlay"
      onClick=${w=>{w.target.classList.contains("agent-detail-overlay")&&Oi()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${e!=null&&e.emoji?i`<span style="font-size:2rem">${e.emoji}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${t}
                  ${e!=null&&e.koreanName?i`<span style="font-size:0.75em;color:#888">(${e.koreanName})</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  ${e?i`
                        <${ne} status=${e.status} />
                        ${e.model?i`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                        ${e.primaryValue?i`<span style="font-size:0.75rem;color:#a78bfa">${e.primaryValue}</span>`:""}
                      `:i`<span>Agent snapshot not found in current state</span>`}
                </div>
              </div>
            </div>
            ${(e==null?void 0:e.activityLevel)!=null?i`
              <div style="display:flex;align-items:center;gap:8px;font-size:0.8rem">
                <span style="color:#888">Activity</span>
                <div style="flex:1;max-width:120px;height:6px;background:#1a1a2e;border-radius:3px;overflow:hidden">
                  <div style="width:${Math.min(e.activityLevel*10,100)}%;height:100%;background:${e.activityLevel>=8?"#22c55e":e.activityLevel>=5?"#f59e0b":"#666"};border-radius:3px"></div>
                </div>
                <span style="color:#888">${e.activityLevel}/10</span>
              </div>
            `:""}
            ${(((x=e==null?void 0:e.traits)==null?void 0:x.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(S=e==null?void 0:e.traits)==null?void 0:S.map(w=>i`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${w}</span>`)}
              </div>
            `:""}
            ${(((C=e==null?void 0:e.interests)==null?void 0:C.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(T=e==null?void 0:e.interests)==null?void 0:T.map(w=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${w}</span>`)}
              </div>
            `:""}
            ${d.length>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${d.map(w=>i`<span style="font-size:0.7rem;background:#183153;color:#7dd3fc;padding:2px 8px;border-radius:10px">${w}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?i`
                    ${e.current_task?i`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?i`<span>Last seen: <${tt} timestamp=${e.last_seen} /></span>`:null}
                    <span>Room: ${m}</span>
                    <span>Project: ${v}</span>
                    <span>Cluster: ${u}</span>
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{pi()}} disabled=${Ss.value}>
              ${Ss.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Oi}>Close</button>
          </div>
        </div>

        ${kn.value?i`<div class="council-error">${kn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${I} title="Assigned Tasks">
            ${s.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${s.map(w=>i`<${Gd} key=${w.id} task=${w} />`)}</div>`}
          <//>

          <${I} title="Recent Activity">
            ${a.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${a.map((w,A)=>i`<div key=${A} class="agent-activity-line">${w}</div>`)}</div>`}
          <//>
        </div>

        <${I} title="Capabilities & Tools">
          <div style="display:flex; flex-direction:column; gap:12px;">
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Capabilities</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${d.length>0?d.map(w=>i`<span class="pill">${w}</span>`):i`<span class="empty-state" style="font-size:12px;">No capability metadata</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Recent tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${o.length>0?o.map(w=>i`<span class="pill">${w}</span>`):i`<span class="empty-state" style="font-size:12px;">No tool telemetry</span>`}
              </div>
            </div>
            ${o.length===0&&l.length>0?i`
                  <div>
                    <div style="font-size:12px; color:#888; margin-bottom:6px;">Window top tools</div>
                    <div style="display:flex; flex-wrap:wrap; gap:6px;">
                      ${l.map(w=>i`<span class="pill">${w}</span>`)}
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
          ${xn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${xn.value.map(w=>i`<${Jd} key=${w.taskId} row=${w} />`)}</div>`}
        <//>

        <${I} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${De.value}
              onInput=${w=>{De.value=w.target.value}}
              onKeyDown=${w=>{w.key==="Enter"&&Fi()}}
              disabled=${dn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Fi()}}
              disabled=${dn.value||De.value.trim()===""}
            >
              ${dn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const Nt=g(null),Wo=g(null),Lt=g(null),Sn=g(!1),te=g(null),An=g(!1),Ue=g(null),J=g(!1),Cs=g([]);let Yd=1;function Qd(t){return _(t)?{id:r(t.id),seq:c(t.seq),from:r(t.from)??r(t.from_agent)??"system",content:r(t.content)??"",timestamp:r(t.timestamp)??new Date().toISOString(),type:r(t.type)}:null}function Xd(t){return _(t)?{room_id:r(t.room_id),current_room:r(t.current_room)??r(t.room),project:r(t.project),cluster:r(t.cluster),paused:q(t.paused),pause_reason:r(t.pause_reason)??null,paused_by:r(t.paused_by)??null,paused_at:r(t.paused_at)??null}:{}}function qi(t){if(!_(t))return;const e=Object.entries(t).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Go(t){if(!_(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function Jo(t){if(!_(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:q(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Zd(t){return _(t)?{actor:r(t.actor)??null,spawn_agent:r(t.spawn_agent)??null,spawn_role:r(t.spawn_role)??null,spawn_model:r(t.spawn_model)??null,worker_class:r(t.worker_class)??null,parent_actor:r(t.parent_actor)??null,capsule_mode:r(t.capsule_mode)??null,runtime_pool:r(t.runtime_pool)??null,lane_id:r(t.lane_id)??null,controller_level:r(t.controller_level)??null,control_domain:r(t.control_domain)??null,supervisor_actor:r(t.supervisor_actor)??null,model_tier:r(t.model_tier)??null,task_profile:r(t.task_profile)??null,risk_level:r(t.risk_level)??null,routing_confidence:c(t.routing_confidence)??null,routing_reason:r(t.routing_reason)??null,status:r(t.status)??"unknown",turn_count:c(t.turn_count)??0,empty_note_turn_count:c(t.empty_note_turn_count)??0,has_turn:q(t.has_turn)??!1,last_turn_ts_iso:r(t.last_turn_ts_iso)??null}:null}function tu(t){if(!_(t))return null;const e=r(t.session_id);return e?{session_id:e,goal:r(t.goal),status:r(t.status),health:r(t.health),scale_profile:r(t.scale_profile),control_profile:r(t.control_profile),planned_worker_count:c(t.planned_worker_count),active_agent_count:c(t.active_agent_count),last_turn_age_sec:c(t.last_turn_age_sec)??null,attention_count:c(t.attention_count),recommended_action_count:c(t.recommended_action_count),top_attention:Go(t.top_attention),top_recommendation:Jo(t.top_recommendation)}:null}function Vo(t){const e=_(t)?t:{};return{trace_id:r(e.trace_id),target_type:r(e.target_type)??"room",target_id:r(e.target_id)??null,health:r(e.health),swarm_status:_(e.swarm_status)?e.swarm_status:void 0,attention_items:Ct(e.attention_items).map(Go).filter(n=>n!==null),recommended_actions:Ct(e.recommended_actions).map(Jo).filter(n=>n!==null),session_cards:Ct(e.session_cards).map(tu).filter(n=>n!==null),worker_cards:Ct(e.worker_cards).map(Zd).filter(n=>n!==null)}}function eu(t){if(!_(t))return null;const e=_(t.status)?t.status:void 0,n=_(t.summary)?t.summary:_(e==null?void 0:e.summary)?e.summary:void 0,s=_(t.session)?t.session:_(e==null?void 0:e.session)?e.session:void 0,a=r(t.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const o=qi(t.report_paths)??qi(e==null?void 0:e.report_paths),l=Ct(t.recent_events,["events"]).filter(_);return{session_id:a,status:r(t.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:c(t.progress_pct)??c(n==null?void 0:n.progress_pct),elapsed_sec:c(t.elapsed_sec)??c(n==null?void 0:n.elapsed_sec),remaining_sec:c(t.remaining_sec)??c(n==null?void 0:n.remaining_sec),done_delta_total:c(t.done_delta_total)??c(n==null?void 0:n.done_delta_total),summary:n,team_health:_(t.team_health)?t.team_health:_(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:_(t.communication_metrics)?t.communication_metrics:_(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:_(t.orchestration_state)?t.orchestration_state:_(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:_(t.cascade_metrics)?t.cascade_metrics:_(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:s,recent_events:l}}function nu(t){if(!_(t))return null;const e=r(t.name);if(!e)return null;const n=_(t.context)?t.context:void 0;return{name:e,agent_name:r(t.agent_name),status:r(t.status),autonomy_level:r(t.autonomy_level),context_ratio:c(t.context_ratio)??c(n==null?void 0:n.context_ratio),generation:c(t.generation),active_goal_ids:B(t.active_goal_ids),last_autonomous_action_at:r(t.last_autonomous_action_at)??null,last_turn_ago_s:c(t.last_turn_ago_s),model:r(t.model)??r(t.active_model)??r(t.primary_model)}}function su(t){if(!_(t))return null;const e=r(t.confirm_token)??r(t.token);return e?{confirm_token:e,actor:r(t.actor),action_type:r(t.action_type),target_type:r(t.target_type),target_id:r(t.target_id)??null,delegated_tool:r(t.delegated_tool),created_at:r(t.created_at),preview:t.preview}:null}function au(t){const e=_(t)?t:{};return{room:Xd(e.room),sessions:Ct(e.sessions,["items","sessions"]).map(eu).filter(n=>n!==null),keepers:Ct(e.keepers,["items","keepers"]).map(nu).filter(n=>n!==null),recent_messages:Ct(e.recent_messages,["messages"]).map(Qd).filter(n=>n!==null),pending_confirms:Ct(e.pending_confirms,["items","confirms"]).map(su).filter(n=>n!==null),available_actions:Ct(e.available_actions,["actions"]).filter(_).map(n=>({action_type:r(n.action_type)??"unknown",target_type:r(n.target_type)??"unknown",description:r(n.description),confirm_required:q(n.confirm_required)}))}}function Yn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Ki(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function ws(t){Cs.value=[{...t,id:Yd++,at:new Date().toISOString()},...Cs.value].slice(0,20)}function Yo(t){return t.confirm_required?Yn(t.preview)||"Confirmation required":Yn(t.result)||Yn(t.executed_action)||Yn(t.delegated_tool_result)||t.status}async function st(){Sn.value=!0,te.value=null;try{const t=await Ml();Nt.value=au(t)}catch(t){te.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Sn.value=!1}}async function qt(){An.value=!0,Ue.value=null;try{const t=await wo({targetType:"room"});Wo.value=Vo(t)}catch(t){Ue.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{An.value=!1}}async function Be(t){if(!t){Lt.value=null;return}An.value=!0,Ue.value=null;try{const e=await wo({targetType:"team_session",targetId:t,includeWorkers:!0});Lt.value=Vo(e)}catch(e){Ue.value=e instanceof Error?e.message:"Failed to load session digest"}finally{An.value=!1}}async function iu(t){var e;J.value=!0,te.value=null;try{const n=await Ys(t);return ws({actor:t.actor,action_type:t.action_type,target_label:Ki(t),outcome:n.confirm_required?"preview":"executed",message:Yo(n),delegated_tool:n.delegated_tool}),await st(),await qt(),(e=Lt.value)!=null&&e.target_id&&await Be(Lt.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw te.value=s,ws({actor:t.actor,action_type:t.action_type,target_label:Ki(t),outcome:"error",message:s}),n}finally{J.value=!1}}async function ou(t,e){var n;J.value=!0,te.value=null;try{const s=await Ul(t,e);return ws({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Yo(s),delegated_tool:s.delegated_tool}),await st(),await qt(),(n=Lt.value)!=null&&n.target_id&&await Be(Lt.value.target_id),s}catch(s){const a=s instanceof Error?s.message:"Operator confirmation failed";throw te.value=a,ws({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),s}finally{J.value=!1}}fd(()=>{var t;st(),qt(),(t=Lt.value)!=null&&t.target_id&&Be(Lt.value.target_id)});function ru(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function lu(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function cu(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Ui(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function Qo(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function du(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Xo(t){if(!t)return null;const e=Ot.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function uu({keeper:t,showRawStatus:e=!1}){if(nt(()=>{t!=null&&t.name&&No(t.name)},[t==null?void 0:t.name]),!t)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Ot.value[t.name],s=Xo(t),a=ja.value[t.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${ru(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${lu((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?i` · ${Qo(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?i` · next eligible ${du(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function pu({keeperName:t,placeholder:e}){const[n,s]=fo("");nt(()=>{t&&No(t)},[t]);const a=rt.value[t]??[],o=Oa.value[t]??!1,l=Ft.value[t],d=async()=>{const m=n.trim();if(!(!t||!m)){s("");try{await Oc(t,m)}catch(v){const u=v instanceof Error?v.message:`Failed to message ${t}`;N(u,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(m=>i`
              <div class="keeper-conversation-item" key=${m.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Ui(m)}`}>${m.label}</span>
                  <span class=${`keeper-role-chip ${Ui(m)}`}>${cu(m)}</span>
                  ${m.timestamp?i`<span class="keeper-conversation-time">${Qo(m.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${m.text}</div>
                ${m.error?i`<div class="keeper-conversation-error">${m.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${e}
          value=${n}
          onInput=${m=>{s(m.target.value)}}
          disabled=${o||!t}
        ></textarea>
        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${()=>{d()}}
            disabled=${o||n.trim()===""||!t}
          >
            ${o?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${l?i`<div class="control-status-copy control-error-copy">${l}</div>`:null}
      </div>
    </div>
  `}function mu({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=Xo(e),a=Fa.value[e.name]??!1,o=qa.value[e.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",d=(s==null?void 0:s.recoverable)??l==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{Fc(e.name,t).catch(m=>{const v=m instanceof Error?m.message:`Failed to probe ${e.name}`;N(v,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{qc(e.name,t).catch(m=>{const v=m instanceof Error?m.message:`Failed to recover ${e.name}`;N(v,"error")})}}
        disabled=${o||!d||!t.trim()}
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
  `}const mi=g(null);function vi(t){mi.value=t,jc(t.name)}function Bi(){mi.value=null}const xe=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function vu(t){if(!t)return 0;const e=xe.findIndex(n=>n.level===t);return e>=0?e:0}function _u({keeper:t}){const e=vu(t.autonomy_level),n=xe[e]??xe[0];if(!n)return null;const s=(e+1)/xe.length*100;return i`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${xe.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${xe.map((a,o)=>i`
            <span style="width:8px; height:8px; border-radius:50%; background:${o<=e?a.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${t.autonomous_action_count??0}</strong>
      </div>
      ${t.last_autonomous_action_at?i`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${tt} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?i`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function ms(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function fu(t){switch(t){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(t==null?void 0:t.trim())||"action"}}function gu(t){return t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]}function $u(t){const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function hu({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${ms(t.context_tokens)}</div>
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
      <div class="kpi-tile">
        <div class="kpi-value">${s}</div>
        <div class="kpi-label">Cost (USD)</div>
      </div>
    </div>
  `}function yu({keeper:t}){var u,p;const e=t.metrics_series??[];if(e.length<2){const f=(((u=t.context)==null?void 0:u.context_ratio)??0)*100,h=f>85?"#ef4444":f>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${f.toFixed(1)}%;background:${h}"></div>
        </div>
        <span class="chart-pct">${f.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=e.length,l=e.map((f,h)=>{const x=a+h/(o-1)*(n-2*a),S=s-a-(f.context_ratio??0)*(s-2*a);return{x,y:S,p:f}}),d=l.map(({x:f,y:h})=>`${f.toFixed(1)},${h.toFixed(1)}`).join(" "),m=(((p=e[e.length-1])==null?void 0:p.context_ratio)??0)*100,v=m>85?"#ef4444":m>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:f})=>f.is_handoff).map(({x:f})=>i`
          <line x1="${f.toFixed(1)}" y1="${a}" x2="${f.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${d}" fill="none" stroke="${v}" stroke-width="1.5"/>
        ${l.filter(({p:f})=>f.is_compaction).map(({x:f,y:h})=>i`
          <circle cx="${f.toFixed(1)}" cy="${h.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${m.toFixed(1)}%</span>
    </div>`}const oa=g("");function bu({keeper:t}){var a,o,l,d;const e=oa.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],s=e?n.filter(m=>m.title.toLowerCase().includes(e)||m.key.includes(e)||m.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${oa.value}
        onInput=${m=>{oa.value=m.target.value}}
      />
      ${s.map(m=>i`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${m.title}</span>
          <span class="keeper-field-key">${m.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${m.value}</span>
        </div>
      `)}
      ${t.trace_id?i`<div class="keeper-field-row"><span class="keeper-field-title">Trace ID</span><span class="keeper-field-key mono">${t.trace_id}</span></div>`:""}
      ${t.agent_name?i`<div class="keeper-field-row"><span class="keeper-field-title">Agent</span><span style="flex:1; text-align:right; color:#ccc;">${t.agent_name}</span></div>`:""}
      ${t.primary_model?i`<div class="keeper-field-row"><span class="keeper-field-title">Primary Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.primary_model}</span></div>`:""}
      ${t.active_model?i`<div class="keeper-field-row"><span class="keeper-field-title">Active Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.active_model}</span></div>`:""}
      ${t.next_model_hint?i`<div class="keeper-field-row"><span class="keeper-field-title">Next Model Hint</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.next_model_hint}</span></div>`:""}
      ${t.skill_primary?i`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Primary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_primary}</span></div>`:""}
      ${t.skill_secondary?i`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Secondary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_secondary}</span></div>`:""}
      ${t.skill_reason?i`<div class="keeper-field-row"><span class="keeper-field-title">Skill Reason</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_reason}</span></div>`:""}
      ${t.context_source?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Source</span><span style="flex:1; text-align:right; color:#ccc;">${t.context_source}</span></div>`:""}
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${ms(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${ms(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${ms(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((d=t.context)==null?void 0:d.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function ku({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(s=>i`
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
  `}function xu({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Su({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Hi({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function ra(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Au({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:ra(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:ra(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:ra(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(s=>i`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function Cu({keeper:t}){var v,u,p,f,h,x,S;const e=((v=Nt.value)==null?void 0:v.room)??{},n=(((u=Nt.value)==null?void 0:u.available_actions)??[]).filter(C=>C.target_type==="keeper"||C.target_type==="room").slice(0,8),s=gu(t),a=$u(t),o=((p=t.agent)==null?void 0:p.capabilities)??[],l=e.current_room??e.room_id??((f=_t.value)==null?void 0:f.room)??"default",d=e.project??((h=_t.value)==null?void 0:h.project)??"확인 없음",m=e.cluster??((x=_t.value)==null?void 0:x.cluster)??"확인 없음";return i`
    <div class="keeper-signal-list">
      <div class="keeper-signal-row">
        <span>Room</span>
        <strong>${l}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Project</span>
        <strong>${d}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Cluster</span>
        <strong>${m}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Current task</span>
        <strong>${((S=t.agent)==null?void 0:S.current_task)??"없음"}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Skill route</span>
        <strong>${t.skill_primary??"미확인"}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Recent tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${s.length>0?s.map(C=>i`<span class="pill">${C}</span>`):i`<span style="font-size:12px; color:#888;">도구 텔레메트리 없음</span>`}
        </div>
      </div>
      ${s.length===0&&a.length>0?i`
            <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
              <span style="font-size:12px; color:#888;">Window top tools</span>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${a.map(C=>i`<span class="pill">${C}</span>`)}
              </div>
            </div>
          `:null}
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Capabilities</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${o.length>0?o.map(C=>i`<span class="pill">${C}</span>`):i`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(C=>i`<span class="pill">${fu(C.action_type)}</span>`):i`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function Zo(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function wu(){try{const t=await Ys({actor:Zo(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Po(t.result);await jn(),e!=null&&e.skipped_reason?N(e.skipped_reason,"warning"):N(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";N(e,"error")}}function Tu({keeper:t}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${uu} keeper=${t} />
          <${mu}
            actor=${Zo()}
            keeper=${t}
            onPokeLodge=${()=>{wu()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${pu}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function Iu(){var e,n,s;const t=mi.value;return t?i`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Bi()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${""}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${t.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${t.name}</h2>
              ${t.koreanName?i`<div style="font-size:13px; color:#888;">${t.koreanName}</div>`:null}
            </div>
            <${ne} status=${t.status} />
            ${t.model?i`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Bi()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${hu} keeper=${t} />

        ${""}
        <${yu} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${I} title="Field Dictionary">
            <${bu} keeper=${t} />
          <//>

          ${""}
          <${I} title="Profile">
            <${Hi} traits=${t.traits??[]} label="Traits" />
            <${Hi} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${tt} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?i`
              <${I} title="Autonomy">
                <${_u} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?i`
              <${I} title="TRPG Stats">
                <${ku} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${I} title="Equipment (${t.inventory.length})">
                <${xu} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${I} title="Relationships (${Object.keys(t.relationships).length})">
                <${Su} rels=${t.relationships} />
              <//>
            `:null}

          <${I} title="Runtime Signals">
            <${Au} keeper=${t} />
          <//>

          <${I} title="Neighborhood & Tools">
            <${Cu} keeper=${t} />
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
              ${t.memory_recent_note?i`
                  <div class="keeper-memory-note">
                    ${t.memory_recent_note}
                  </div>
                `:i`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${Tu} keeper=${t} />
      </div>
    </div>
  `:null}const Ts="masc_dashboard_workflow_context",Ru=900*1e3;function $t(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function Bt(t){const e=$t(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function tr(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function Ga(t){return _(t)?t:null}function Pu(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function Nu(t){if(!t)return null;try{const e=JSON.parse(t);if(!_(e))return null;const n=$t(e.id),s=$t(e.source_surface),a=$t(e.source_label),o=$t(e.summary),l=$t(e.created_at);return!n||s!=="mission"||!a||!o||!l?null:{id:n,source_surface:"mission",source_label:a,action_type:$t(e.action_type),target_type:$t(e.target_type),target_id:$t(e.target_id),focus_kind:$t(e.focus_kind),summary:o,payload_preview:$t(e.payload_preview),suggested_payload:Ga(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:l}}catch{return null}}function _i(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=Ru}function Lu(){const t=tr(),e=Nu((t==null?void 0:t.getItem(Ts))??null);return e?_i(e)?e:(t==null||t.removeItem(Ts),null):null}const er=g(Lu());function Mu(t){const e=t&&_i(t)?t:null;er.value=e;const n=tr();if(!n)return;if(!e){n.removeItem(Ts);return}const s=Pu(e);s&&n.setItem(Ts,s)}function Du(t){if(!t)return null;const e=Ga(t.suggested_payload);if(e)return e;if(_(t.preview)){const n=Ga(t.preview.payload);if(n)return n}return null}function zu(t){if(!t)return null;const e=Bt(t.message);if(e)return e;const n=Bt(t.task_title)??Bt(t.title),s=Bt(t.task_description)??Bt(t.description),a=Bt(t.reason),o=Bt(t.priority)??Bt(t.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function nr(t,e,n,s,a,o){return["mission",t,e??"action",n??"target",s??"room",a??"focus",o].join(":")}function Ve(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=Du(t),o=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,l=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,d=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,m=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:nr(n,(t==null?void 0:t.action_type)??null,o,l,d,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:o,target_id:l,focus_kind:d,summary:m,payload_preview:zu(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function Eu(t,e){return e.source==="mission"&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)}function On(t){const{params:e}=t;if(e.source!=="mission")return null;const n=er.value;if(n&&_i(n)&&Eu(n,e))return n;const s=new Date().toISOString();return{id:nr("상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,s),source_surface:"mission",source_label:"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,summary:e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function ju(t){return{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function sr(t){const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.target_type==="room"?"summary":"swarm"}function Ou(t){return{source:"mission",surface:sr(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function fi(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function Xs(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";default:return(t==null?void 0:t.trim())||"추천 액션"}}function Fu(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}const Jt=g(null),zt=g(null);function Q(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function lt(t){return t==="bad"||t==="offline"||t==="critical"||t==="risk"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"||t==="watch"?"warn":"ok"}function _e(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:n<86400?`${Math.round(n/3600)}h 전`:`${Math.round(n/86400)}d 전`}function qu(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:t<86400?`${Math.round(t/3600)}h`:`${Math.round(t/86400)}d`}function Ku(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function Uu(t){return fi(t?Ve(t,null,"상황판 추천 액션"):null)}function Zs(t,e=Ve()){Mu(e),dt(t,t==="intervene"?ju(e):Ou(e))}function ar(t){Zs("intervene",Ve(null,t,"상황판 incident"))}function ir(t){Zs("command",Ve(null,t,"상황판 incident"))}function gi(t,e,n="상황판 추천 액션"){Zs("intervene",Ve(t,e,n))}function or(t,e,n="상황판 추천 액션"){Zs("command",Ve(t,e,n))}function Wi(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),dt(t,n)}function Bu(t){return{kind:t.kind,severity:t.severity,summary:t.summary,target_type:t.target_type,target_id:t.target_id??null,actor:null,evidence:t.evidence_preview}}function rr(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>(s.from??"").trim().toLowerCase()===n).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function Hu(t){return t.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")}function Wu(t,e){if(!e)return!1;const n=Hu(e);return new RegExp(`(?:^|[^a-z0-9_])@${n}(?![a-z0-9_-])`,"i").test(t)}function Gu(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>{if((s.from??"").trim().toLowerCase()===n)return!1;const o=(s.content??"").trim().toLowerCase();return Wu(o,n)}).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function Ju(t){return Kt.value.find(e=>e.agent_name===t||e.name===t)??null}function lr(t){return yt.value.find(e=>e.name===t)??null}function cr(t,e){const n=Q(t,100);if(!n)return null;const s=e.find(o=>o.id===n);if(s)return`${s.id} · ${Q(s.title,92)}`;const a=e.find(o=>o.title===n);return a?`${a.id} · ${Q(a.title,92)}`:n}function Vu(t){var d,m;const e=lr(t.agent_name),n=Ju(t.agent_name),s=rr(t.agent_name,qe.value),a=Gu(t.agent_name,qe.value),o=di(t.agent_name),l=(n==null?void 0:n.skill_primary)??(e!=null&&e.capabilities&&e.capabilities.length>0?e.capabilities.slice(0,3).join(", "):null)??o.model??(e==null?void 0:e.agent_type)??null;return{brief:t,agent:e,keeper:n,where:t.where??"room",withWhom:t.with_whom,currentWork:t.current_work??cr((e==null?void 0:e.current_task)??null,It.value)??"명시된 current task 없음",how:l,recentInput:Q(t.recent_input_preview,120)??Q(a==null?void 0:a.content,120)??Q(n==null?void 0:n.recent_input_preview,120)??null,recentOutput:Q(t.recent_output_preview,120)??Q(s==null?void 0:s.content,120)??Q(n==null?void 0:n.recent_output_preview,120)??Q((d=n==null?void 0:n.diagnostic)==null?void 0:d.last_reply_preview,120)??null,recentEvent:Q(t.recent_event,120)??Q((m=n==null?void 0:n.diagnostic)==null?void 0:m.summary,120)??null,recentTools:t.recent_tool_names.length>0?t.recent_tool_names:(n==null?void 0:n.recent_tool_names)??[]}}function Yu(t){var n,s;const e=Kt.value.find(a=>a.name===t.name||a.agent_name===t.agent_name)??null;return{brief:t,keeper:e,currentWork:Q(t.current_work,110)??Q(e==null?void 0:e.skill_primary,110)??Q(e==null?void 0:e.last_proactive_reason,110)??"명시된 keeper focus 없음",recentInput:Q(e==null?void 0:e.recent_input_preview,120)??null,recentOutput:Q(e==null?void 0:e.recent_output_preview,120)??Q((n=e==null?void 0:e.diagnostic)==null?void 0:n.last_reply_preview,120)??Q(e==null?void 0:e.last_proactive_preview,120)??null,recentEvent:Q(e==null?void 0:e.last_proactive_reason,120)??Q((s=e==null?void 0:e.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(e==null?void 0:e.recent_tool_names)??[]}}function Qu(){const t=ui.value;return t?new Map(t.session_briefs.map(e=>[e.session_id,e])):new Map}function Xu(t){const e=lr(t),n=rr(t,qe.value),s=di(t);return{name:t,model:s.model,nickname:s.nickname,currentTask:cr((e==null?void 0:e.current_task)??null,It.value)??"agent snapshot 없음",output:Q(n==null?void 0:n.content,96)}}function Zu(t){Jt.value=Jt.value===t?null:t,zt.value=null}function dr(t){zt.value=zt.value===t?null:t}function tp(){Jt.value=null,zt.value=null}function ep({cluster:t,project:e,room:n,generatedAt:s}){return i`
    <div class="mission-context-bar">
      <div class="mission-context-item">
        <span>cluster</span>
        <strong>${t??"확인 없음"}</strong>
      </div>
      <div class="mission-context-item">
        <span>project</span>
        <strong>${e??"확인 없음"}</strong>
      </div>
      <div class="mission-context-item">
        <span>room</span>
        <strong>${n??"default"}</strong>
      </div>
      <div class="mission-context-item">
        <span>generated</span>
        <strong>${s?_e(s):"fresh"}</strong>
      </div>
    </div>
  `}function be({label:t,value:e,detail:n,tone:s}){return i`
    <article class="mission-stat-card ${lt(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function np(){const t=Ko.value,e=lt((t==null?void 0:t.status)??(de.value?"bad":"warn")),n=(t==null?void 0:t.status)==="error"||(t==null?void 0:t.status)==="unavailable"&&!(t!=null&&t.cached);return i`
    <${I} title="LLM 판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>heuristic 대신 별도 판단 계층</h3>
        <p>핵심 해석 3줄만 먼저 보여주고, 근거는 접어서 둡니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${e}">
          ${(t==null?void 0:t.status)??(de.value?"error":"loading")}
        </span>
        ${t!=null&&t.model?i`<span class="command-chip">${t.model}</span>`:null}
        ${t!=null&&t.generated_at?i`<span class="command-chip">${_e(t.generated_at)}</span>`:null}
        ${t!=null&&t.cached?i`<span class="command-chip">cached</span>`:null}
        ${t!=null&&t.stale?i`<span class="command-chip warn">stale</span>`:null}
      </div>

      ${de.value?i`<div class="empty-state error">${de.value}</div>`:null}
      ${t!=null&&t.error?i`<div class="empty-state error">${t.error}</div>`:null}
      ${t!=null&&t.summary?i`<div class="mission-inline-note">${t.summary}</div>`:null}

      ${t&&t.sections.length>0?i`
            <div class="mission-briefing-grid">
              ${t.sections.slice(0,3).map(s=>i`
                <article class="mission-briefing-section ${lt(s.status)}">
                  <div class="mission-card-head">
                    <strong>${s.label}</strong>
                    <span class="command-chip ${lt(s.status)}">${s.status}</span>
                  </div>
                  <p>${s.summary}</p>
                  ${s.evidence.length>0?i`
                        <details class="mission-card-disclosure compact">
                          <summary>근거 보기</summary>
                          <div class="mission-pill-row">
                            ${s.evidence.map(a=>i`<span class="mission-pill">${a}</span>`)}
                          </div>
                        </details>
                      `:null}
                </article>
              `)}
            </div>
          `:!we.value&&!de.value?i`<div class="empty-state">판단 레이어 결과가 아직 없습니다.</div>`:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{bn(n)}} disabled=${we.value}>
          ${we.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{bn(!0)}} disabled=${we.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function sp({item:t,selected:e,sessionLookup:n}){const s=Bu(t),a=t.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),o=t.top_action??null;return i`
    <article class="mission-attention-card ${lt((o==null?void 0:o.severity)??t.severity)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Zu(t.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.summary}</strong>
            <div class="mission-card-target">${t.kind}${t.target_id?` · ${t.target_id}`:""}</div>
          </div>
          <span class="command-chip ${lt((o==null?void 0:o.severity)??t.severity)}">${o?Ku(o):t.severity}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>영향 session</span>
            <strong>${t.related_session_ids.length}</strong>
            <small>${t.related_session_ids.slice(0,2).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>영향 agent</span>
            <strong>${t.related_agent_names.length}</strong>
            <small>${t.related_agent_names.slice(0,3).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 신호</span>
            <strong>${t.last_seen_at?_e(t.last_seen_at):"n/a"}</strong>
            <small>${t.target_type}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${o?Xs(o.action_type):"판단 필요"}</strong>
            <small>${o?Uu(o):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${o?i`<div class="mission-inline-note">${o.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?i`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>i`
                  <button class="mission-link-row" onClick=${()=>dr(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${l.status??"unknown"} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:i`<div class="empty-state">직접 연결된 session이 아직 없습니다.</div>`}

        ${t.related_agent_names.length>0?i`
              <div class="mission-pill-row">
                ${t.related_agent_names.slice(0,8).map(l=>i`
                  <button class="mission-pill action" onClick=${()=>Ke(l)}>${l}</button>
                `)}
              </div>
            `:null}

        ${t.evidence_preview.length>0?i`
              <details class="mission-card-disclosure compact">
                <summary>evidence preview</summary>
                <div class="mission-evidence-list">
                  ${t.evidence_preview.map(l=>i`<span>${l}</span>`)}
                </div>
              </details>
            `:null}
      </details>

      <div class="mission-card-actions">
        ${o?i`
              <button class="control-btn ghost" onClick=${()=>gi(o,s,"Mission attention")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>or(o,s,"Mission attention")}>
                원인 보기
              </button>
            `:i`
              <button class="control-btn ghost" onClick=${()=>ar(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>ir(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function ap({brief:t,selected:e}){var o,l;const n=t.member_names.slice(0,6).map(Xu),s=t.top_recommendation??null,a=t.top_attention??null;return i`
    <article class="mission-crew-card ${lt(((o=t.top_attention)==null?void 0:o.severity)??t.health??t.status)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>dr(t.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.goal}</strong>
            <div class="mission-card-target">${t.session_id}${t.room?` · ${t.room}`:""}</div>
          </div>
          <span class="command-chip ${lt(((l=t.top_attention)==null?void 0:l.severity)??t.health??t.status)}">${t.status??"unknown"}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${t.member_names.length}</strong>
            <small>${t.member_names.slice(0,3).join(", ")||"n/a"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${qu(t.elapsed_sec)}</strong>
            <small>${t.started_at?`${_e(t.started_at)} 시작`:"시작 시각 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>커뮤니케이션</span>
            <strong>${t.communication_summary?"요약됨":"n/a"}</strong>
            <small>${t.communication_summary??"요약 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>커버리지</span>
            <strong>${t.active_count??0}/${t.required_count||1}</strong>
            <small>active / required</small>
          </div>
        </div>
      </button>

      <div class="mission-crew-event">
        <span>최근 사건</span>
        <strong>${t.last_event_summary??"최근 session event가 없습니다."}</strong>
        <small>${t.last_event_at?_e(t.last_event_at):"시각 없음"}</small>
      </div>

      ${t.top_attention?i`<div class="mission-inline-note">attention: ${t.top_attention.summary}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>session detail</summary>
        ${n.length>0?i`
              <div class="mission-pill-row">
                ${n.map(d=>i`
                  <button class="mission-pill action" onClick=${()=>Ke(d.name)}>
                    ${d.model!==d.nickname?`${d.model} · `:""}${d.nickname}
                  </button>
                `)}
              </div>
            `:null}

        ${n.length>0?i`
              <details class="mission-card-disclosure compact">
                <summary>member output preview</summary>
                <div class="mission-link-list">
                  ${n.map(d=>i`
                    <button class="mission-link-row" onClick=${()=>Ke(d.name)}>
                      <strong>${d.nickname}</strong>
                      <span>${d.currentTask}</span>
                      <small>${d.output??"최근 출력 없음"}</small>
                    </button>
                  `)}
                </div>
              </details>
            `:null}
      </details>

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Wi("intervene",t.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Wi("command",t.session_id)}>세션 원인 보기</button>
        ${s?i`<button class="control-btn ghost" onClick=${()=>gi(s,a,"Mission session brief")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function ip({row:t}){var s,a,o,l,d;const e=di(t.brief.agent_name),n=t.withWhom.length>0?t.withWhom.slice(0,3).join(", "):"단독 또는 room-level";return i`
    <article class="mission-activity-card ${lt(t.brief.status??((s=t.agent)==null?void 0:s.status))}">
      <button class="mission-card-select" onClick=${()=>Ke(t.brief.agent_name)}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((a=t.agent)==null?void 0:a.emoji)??((o=t.keeper)==null?void 0:o.emoji)??""}</span>
            <div>
              <strong>${t.brief.agent_name}</strong>
              <span>${e.model!==e.nickname?`${e.model} · `:""}${e.nickname}</span>
            </div>
          </div>
          <span class="command-chip ${lt(t.brief.status??((l=t.agent)==null?void 0:l.status))}">${t.brief.status??((d=t.agent)==null?void 0:d.status)??"unknown"}</span>
        </div>

        <div class="mission-activity-meta">
          <span>어디서 · ${t.where}</span>
          <span>누구와 · ${n}</span>
          <span>attention · ${t.brief.related_attention_count}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${t.currentWork}</strong>
          ${t.how?i`<small>어떻게 · ${t.how}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>recent trace</summary>
        <div class="mission-activity-foot">
          ${t.recentEvent?i`<span>최근 일 · ${t.recentEvent}</span>`:i`<span>최근 사건 요약 없음</span>`}
          <span>관련 session · ${t.brief.related_session_id??"없음"}</span>
        </div>

        <details class="mission-card-disclosure compact">
          <summary>input / output / tools</summary>
          <div class="mission-io-stack">
            <div class="mission-io-item">
              <span>최근 input</span>
              <strong>${t.recentInput??"표시 가능한 recent input 없음"}</strong>
            </div>
            <div class="mission-io-item">
              <span>최근 output</span>
              <strong>${t.recentOutput??"표시 가능한 recent output 없음"}</strong>
            </div>
          </div>
          <div class="mission-activity-foot">
            <span>최근 도구 · ${t.recentTools.length>0?t.recentTools.join(", "):"도구 텔레메트리 없음"}</span>
          </div>
        </details>
      </details>
    </article>
  `}function op({row:t}){var n,s,a,o,l,d,m,v,u,p;const e=[`gen ${t.brief.generation??((n=t.keeper)==null?void 0:n.generation)??0}`,t.brief.context_ratio!=null?`ctx ${Math.round(t.brief.context_ratio*100)}%`:((s=t.keeper)==null?void 0:s.context_ratio)!=null?`ctx ${Math.round(t.keeper.context_ratio*100)}%`:null,t.brief.last_turn_ago_s!=null?`last turn ${Math.round(t.brief.last_turn_ago_s)}s`:null].filter(f=>f!==null).join(" · ");return i`
    <article class="mission-activity-card ${lt(t.brief.status??((a=t.keeper)==null?void 0:a.status))}">
      <button class="mission-card-select" onClick=${()=>{t.keeper&&vi(t.keeper)}}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((o=t.keeper)==null?void 0:o.emoji)??""}</span>
            <div>
              <strong>${t.brief.name}</strong>
              ${(l=t.keeper)!=null&&l.koreanName?i`<span>${t.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <span class="command-chip ${lt(t.brief.status??((d=t.keeper)==null?void 0:d.status))}">${t.brief.status??((m=t.keeper)==null?void 0:m.status)??"unknown"}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 heartbeat · ${(v=t.keeper)!=null&&v.last_heartbeat?_e(t.keeper.last_heartbeat):"n/a"}</span>
          <span>${e||"continuity 정보 없음"}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${t.currentWork}</strong>
          ${(u=t.keeper)!=null&&u.skill_reason?i`<small>판단 요약 · ${Q(t.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>continuity detail</summary>
        <div class="mission-activity-foot">
          <span>agent · ${t.brief.agent_name??((p=t.keeper)==null?void 0:p.agent_name)??"n/a"}</span>
          ${t.recentEvent?i`<span>최근 일 · ${t.recentEvent}</span>`:null}
        </div>
        <details class="mission-card-disclosure compact">
          <summary>input / output / tools</summary>
          <div class="mission-io-stack">
            <div class="mission-io-item">
              <span>최근 input</span>
              <strong>${t.recentInput??"표시 가능한 recent input 없음"}</strong>
            </div>
            <div class="mission-io-item">
              <span>최근 output</span>
              <strong>${t.recentOutput??"표시 가능한 recent output 없음"}</strong>
            </div>
          </div>
          <div class="mission-activity-foot">
            <span>최근 도구 · ${t.recentTools.length>0?t.recentTools.join(", "):"도구 사용 없음"}</span>
          </div>
        </details>
      </details>
    </article>
  `}function rp({item:t}){const e=t.action??null,n=t.attention??null;return i`
    <article class="mission-action-card ${lt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${lt(t.severity)}">
          ${t.signal_type==="action"&&e?Xs(e.action_type):(n==null?void 0:n.kind)??"signal"}
        </span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      ${e?i`<div class="mission-action-preview">${e.reason}</div>`:null}
      <div class="mission-card-actions">
        ${e?i`
              <button class="control-btn ghost" onClick=${()=>gi(e,n,"Mission internal signal")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>or(e,n,"Mission internal signal")}>이 이슈의 원인 보기</button>
            `:n?i`
                <button class="control-btn ghost" onClick=${()=>ar(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>ir(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function Gi(){var f,h,x,S,C,T,w;const t=ui.value;if(Wa.value&&!t)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(xs.value&&!t)return i`<div class="empty-state error">${xs.value}</div>`;if(!t)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;Jt.value&&!t.attention_queue.some(A=>A.id===Jt.value)&&(Jt.value=null),zt.value&&!t.session_briefs.some(A=>A.session_id===zt.value)&&(zt.value=null);const e=t.attention_queue.find(A=>A.id===Jt.value)??null,n=zt.value,s=Qu(),a=e?new Set(e.related_session_ids):null,o=e?new Set(e.related_agent_names):null,l=(a?t.session_briefs.filter(A=>a.has(A.session_id)):t.session_briefs).slice(0,e?8:6),d=t.agent_briefs.filter(A=>!kd(A.agent_name)).filter(A=>n?A.related_session_id===n:o&&a?o.has(A.agent_name)||(A.related_session_id?a.has(A.related_session_id):!1):!0).slice(0,n||e?10:8).map(Vu),m=t.keeper_briefs.slice(0,6).map(Yu),v=t.attention_queue.slice(0,6),u=t.internal_signals.slice(0,3),p=d.filter(A=>A.recentOutput).length+m.filter(A=>A.recentOutput).length;return i`
    <section class="dashboard-panel mission-view">
      <${ft} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>원인 분석과 개입 판단을 먼저 보는 landing 입니다. 문제 → 영향 session → 관련 actor 순서로 좁혀서 읽습니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${lt(t.summary.room_health)}">${t.summary.room_health??"ok"}</span>
          <span class="command-chip">${t.summary.project??"room"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?_e(t.generated_at):"fresh"}</span>
        </div>
      </div>

      <${ep}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <${np} />

      <div class="mission-stat-grid">
        <${be} label="주의 큐" value=${v.length} detail="개입 판단이 필요한 issue" tone=${((f=v[0])==null?void 0:f.severity)??"ok"} />
        <${be} label="영향 session" value=${l.length} detail="현재 선택 기준으로 좁힌 흐름" tone=${((x=(h=l[0])==null?void 0:h.top_attention)==null?void 0:x.severity)??((S=l[0])==null?void 0:S.health)??"ok"} />
        <${be} label="영향 agent" value=${d.length} detail="선택된 흐름에 연결된 actor" tone=${((C=d[0])==null?void 0:C.brief.status)??"ok"} />
        <${be} label="Keeper watch" value=${m.length} detail="continuity lane 관찰 대상" tone=${((T=m[0])==null?void 0:T.brief.status)??"ok"} />
        <${be} label="최근 output" value=${p} detail="선택된 영역에서 바로 읽을 수 있는 출력 수" tone=${p>0?"ok":"warn"} />
        <${be} label="내부 신호" value=${u.length} detail="room/system 진단은 하단 보조 lane" tone=${((w=u[0])==null?void 0:w.severity)??"ok"} />
      </div>

      ${e||n?i`
            <div class="mission-selection-bar">
              <span>현재 drill-down · ${e?e.summary:"session 선택"}${n?` · ${n}`:""}</span>
              <button class="control-btn ghost" onClick=${tp}>선택 해제</button>
            </div>
          `:null}

      <${I} title="Attention Queue" class="mission-list-card" semanticId="mission.attention_queue">
        <div class="mission-section-head">
          <h3>이슈에서 시작</h3>
          <p>문제와 경고를 먼저 보고, 여기서 session과 agent로 좁혀갑니다.</p>
        </div>
        <div class="mission-lane-stack">
          ${v.length>0?v.map(A=>i`<${sp} key=${A.id} item=${A} selected=${Jt.value===A.id} sessionLookup=${s} />`):i`<div class="empty-state">지금 Mission attention queue가 비어 있습니다.</div>`}
        </div>
      <//>

      <div class="mission-human-grid">
        <${I} title="Affected Sessions" class="mission-list-card" semanticId="mission.session_briefs">
          <div class="mission-section-head">
            <h3>영향받는 session</h3>
            <p>attention과 직접 연결된 흐름만 먼저 보여주고, member preview는 한 단계 더 열었을 때만 보여줍니다.</p>
          </div>
          <div class="mission-list-stack">
            ${l.length>0?l.map(A=>i`<${ap} key=${A.session_id} brief=${A} selected=${zt.value===A.session_id} />`):i`<div class="empty-state">현재 선택과 연결된 session이 없습니다.</div>`}
          </div>
        <//>

        <${I} title="Impacted Agents" class="mission-list-card" semanticId="mission.agent_activity">
          <div class="mission-section-head">
            <h3>관련 agent</h3>
            <p>선택된 incident 또는 session과 연결된 actor만 보여주고, input-output은 접어서 둡니다.</p>
          </div>
          <div class="mission-activity-list">
            ${d.length>0?d.map(A=>i`<${ip} key=${A.brief.agent_name} row=${A} />`):i`<div class="empty-state">현재 선택과 연결된 agent가 없습니다.</div>`}
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
            ${m.length>0?m.map(A=>i`<${op} key=${A.brief.name} row=${A} />`):i`<div class="empty-state">지금 보이는 keeper가 없습니다.</div>`}
          </div>
        <//>

        <${I} title="Internal Signals" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>room / system 보조 신호</h3>
            <p>artifact scope drift 같은 시스템 진단은 메인 판단 근거가 아니라 보조 lane으로만 유지합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${u.length>0?u.map(A=>i`<${rp} key=${A.id} item=${A} />`):i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>dt("execution")}>실행 관찰면 보기</button>
            <button class="control-btn ghost" onClick=${()=>dt("command")}>지휘 진단면 보기</button>
          </div>
        <//>
      </div>
    </section>
  `}const $i=g(null),Dt=g(null),Is=g(!1),Rs=g(!1),Ps=g(null),Ns=g(null),Ja=g(null),Ls=g(null),U=g("warroom"),Fn=g(null),Va=g(!1),Ms=g(null),ge=g(null),Ds=g(!1),zs=g(null),qn=g(null),Ya=g(!1),Es=g(null),Cn=g(null),js=g(!1),wn=g(null),ze=g(null);let sn=null;function hi(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"}function ur(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function lp(){const e=ur().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function cp(){const e=ur().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function dp(t){if(_(t))return{policy_class:r(t.policy_class),approval_class:r(t.approval_class),tool_allowlist:B(t.tool_allowlist),model_allowlist:B(t.model_allowlist),requires_human_for:B(t.requires_human_for),autonomy_level:r(t.autonomy_level),escalation_timeout_sec:c(t.escalation_timeout_sec),kill_switch:q(t.kill_switch),frozen:q(t.frozen)}}function up(t){if(_(t))return{headcount_cap:c(t.headcount_cap),active_operation_cap:c(t.active_operation_cap),max_cost_usd:c(t.max_cost_usd),max_tokens:c(t.max_tokens)}}function yi(t){if(!_(t))return null;const e=r(t.unit_id),n=r(t.label),s=r(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:r(t.parent_unit_id)??null,leader_id:r(t.leader_id)??null,roster:B(t.roster),capability_profile:B(t.capability_profile),source:r(t.source),created_at:r(t.created_at),updated_at:r(t.updated_at),policy:dp(t.policy),budget:up(t.budget)}}function pr(t){if(!_(t))return null;const e=yi(t.unit);return e?{unit:e,leader_status:r(t.leader_status),roster_total:c(t.roster_total),roster_live:c(t.roster_live),active_operation_count:c(t.active_operation_count),health:r(t.health),reasons:B(t.reasons),children:Array.isArray(t.children)?t.children.map(pr).filter(n=>n!==null):[]}:null}function pp(t){if(_(t))return{total_units:c(t.total_units),company_count:c(t.company_count),platoon_count:c(t.platoon_count),squad_count:c(t.squad_count),leaf_agent_unit_count:c(t.leaf_agent_unit_count),live_agent_count:c(t.live_agent_count),managed_unit_count:c(t.managed_unit_count),active_operation_count:c(t.active_operation_count)}}function mr(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),source:r(e.source),summary:pp(e.summary),units:Array.isArray(e.units)?e.units.map(pr).filter(n=>n!==null):[]}}function mp(t){if(!_(t))return null;const e=r(t.kind),n=r(t.status);return!e||!n?null:{kind:e,chain_id:r(t.chain_id)??null,goal:r(t.goal)??null,run_id:r(t.run_id)??null,status:n,viewer_path:r(t.viewer_path)??null,last_sync_at:r(t.last_sync_at)??null}}function ta(t){if(!_(t))return null;const e=r(t.operation_id),n=r(t.objective),s=r(t.assigned_unit_id),a=r(t.trace_id),o=r(t.status);return!e||!n||!s||!a||!o?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:r(t.autonomy_level),policy_class:r(t.policy_class),budget_class:r(t.budget_class),detachment_session_id:r(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(t.checkpoint_ref)??null,active_goal_ids:B(t.active_goal_ids),note:r(t.note)??null,created_by:r(t.created_by),source:r(t.source),status:o,chain:mp(t.chain),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function vp(t){if(!_(t))return null;const e=ta(t.operation);return e?{operation:e,assigned_unit_label:r(t.assigned_unit_label)}:null}function tn(t){if(_(t))return{tone:r(t.tone),pending_ops:c(t.pending_ops),blocked_ops:c(t.blocked_ops),in_flight_ops:c(t.in_flight_ops),pipeline_stalls:c(t.pipeline_stalls),bus_traffic:c(t.bus_traffic),l1_hit_rate:c(t.l1_hit_rate),invalidation_count:c(t.invalidation_count),current_pending:c(t.current_pending),current_in_flight:c(t.current_in_flight),cdb_wakeups:c(t.cdb_wakeups),total_stolen:c(t.total_stolen),avg_best_score:c(t.avg_best_score),avg_candidate_count:c(t.avg_candidate_count),best_first_operations:c(t.best_first_operations),active_sessions:c(t.active_sessions),commit_rate:c(t.commit_rate),total_speculations:c(t.total_speculations)}}function _p(t){if(!_(t))return;const e=_(t.pipeline)?t.pipeline:void 0,n=_(t.cache)?t.cache:void 0,s=_(t.ooo)?t.ooo:void 0,a=_(t.speculative)?t.speculative:void 0,o=_(t.search_fabric)?t.search_fabric:void 0,l=_(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:c(e.total_ops),completed_ops:c(e.completed_ops),stalled_cycles:c(e.stalled_cycles),hazards_detected:c(e.hazards_detected),forwarding_used:c(e.forwarding_used),pipeline_flushes:c(e.pipeline_flushes),ipc:c(e.ipc)}:void 0,cache:n?{total_reads:c(n.total_reads),total_writes:c(n.total_writes),l1_hit_rate:c(n.l1_hit_rate),invalidation_count:c(n.invalidation_count),writeback_count:c(n.writeback_count),bus_traffic:c(n.bus_traffic)}:void 0,ooo:s?{agent_count:c(s.agent_count),total_added:c(s.total_added),total_issued:c(s.total_issued),total_completed:c(s.total_completed),total_stolen:c(s.total_stolen),cdb_wakeups:c(s.cdb_wakeups),stall_cycles:c(s.stall_cycles),global_cdb_events:c(s.global_cdb_events),current_pending:c(s.current_pending),current_in_flight:c(s.current_in_flight)}:void 0,speculative:a?{total_speculations:c(a.total_speculations),total_commits:c(a.total_commits),total_aborts:c(a.total_aborts),commit_rate:c(a.commit_rate),total_fast_calls:c(a.total_fast_calls),total_cost_usd:c(a.total_cost_usd),active_sessions:c(a.active_sessions)}:void 0,search_fabric:o?{total_operations:c(o.total_operations),best_first_operations:c(o.best_first_operations),legacy_operations:c(o.legacy_operations),blocked_operations:c(o.blocked_operations),ready_operations:c(o.ready_operations),research_pipeline_operations:c(o.research_pipeline_operations),avg_candidate_count:c(o.avg_candidate_count),avg_best_score:c(o.avg_best_score),top_stage:r(o.top_stage)??null}:void 0,signals:l?{issue_pressure:tn(l.issue_pressure),cache_contention:tn(l.cache_contention),scheduler_efficiency:tn(l.scheduler_efficiency),routing_confidence:tn(l.routing_confidence),speculative_posture:tn(l.speculative_posture)}:void 0}}function vr(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:c(n.total),active:c(n.active),paused:c(n.paused),managed:c(n.managed),projected:c(n.projected)}:void 0,microarch:_p(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(vp).filter(s=>s!==null):[]}}function _r(t){if(!_(t))return null;const e=r(t.detachment_id),n=r(t.operation_id),s=r(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:r(t.leader_id)??null,roster:B(t.roster),session_id:r(t.session_id)??null,checkpoint_ref:r(t.checkpoint_ref)??null,runtime_kind:r(t.runtime_kind)??null,runtime_ref:r(t.runtime_ref)??null,source:r(t.source),status:r(t.status),last_event_at:r(t.last_event_at)??null,last_progress_at:r(t.last_progress_at)??null,heartbeat_deadline:r(t.heartbeat_deadline)??null,created_at:r(t.created_at),updated_at:r(t.updated_at)}}function fp(t){if(!_(t))return null;const e=_r(t.detachment);return e?{detachment:e,assigned_unit_label:r(t.assigned_unit_label),operation:ta(t.operation)}:null}function fr(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:c(n.total),active:c(n.active),projected:c(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(fp).filter(s=>s!==null):[]}}function gp(t){if(!_(t))return null;const e=r(t.decision_id),n=r(t.trace_id),s=r(t.requested_action),a=r(t.scope_type),o=r(t.scope_id);return!e||!n||!s||!a||!o?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:r(t.operation_id)??null,target_unit_id:r(t.target_unit_id)??null,requested_by:r(t.requested_by),status:r(t.status),reason:r(t.reason)??null,source:r(t.source),detail:t.detail,created_at:r(t.created_at),decided_at:r(t.decided_at)??null,expires_at:r(t.expires_at)??null}}function gr(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:c(n.total),pending:c(n.pending),approved:c(n.approved),denied:c(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(gp).filter(s=>s!==null):[]}}function $p(t){if(!_(t))return null;const e=yi(t.unit);return e?{unit:e,roster_total:c(t.roster_total),roster_live:c(t.roster_live),headcount_cap:c(t.headcount_cap),active_operations:c(t.active_operations),active_operation_cap:c(t.active_operation_cap),utilization:c(t.utilization)}:null}function hp(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map($p).filter(n=>n!==null):[]}}function yp(t){if(!_(t))return null;const e=r(t.alert_id);return e?{alert_id:e,severity:r(t.severity),kind:r(t.kind),scope_type:r(t.scope_type),scope_id:r(t.scope_id),title:r(t.title),detail:r(t.detail),timestamp:r(t.timestamp)}:null}function $r(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:c(n.total),bad:c(n.bad),warn:c(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(yp).filter(s=>s!==null):[]}}function hr(t){if(!_(t))return null;const e=r(t.event_id),n=r(t.trace_id),s=r(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:r(t.operation_id)??null,unit_id:r(t.unit_id)??null,actor:r(t.actor)??null,source:r(t.source),timestamp:r(t.timestamp),detail:t.detail}}function bp(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),events:Array.isArray(e.events)?e.events.map(hr).filter(n=>n!==null):[]}}function kp(t){if(!_(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function xp(t){if(!_(t))return null;const e=r(t.lane_id),n=r(t.label),s=r(t.kind),a=r(t.phase),o=r(t.motion_state),l=r(t.source_of_truth),d=r(t.movement_reason),m=r(t.current_step);if(!e||!n||!s||!a||!o||!l||!d||!m)return null;const v=_(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:q(t.present)??!1,phase:a,motion_state:o,source_of_truth:l,last_movement_at:r(t.last_movement_at)??null,movement_reason:d,current_step:m,blockers:B(t.blockers),counts:{operations:c(v.operations),detachments:c(v.detachments),workers:c(v.workers),approvals:c(v.approvals),alerts:c(v.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(kp).filter(u=>u!==null):[]}}function Sp(t){if(!_(t))return null;const e=r(t.event_id),n=r(t.lane_id),s=r(t.kind),a=r(t.timestamp),o=r(t.title),l=r(t.detail),d=r(t.tone),m=r(t.source);return!e||!n||!s||!a||!o||!l||!d||!m?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:o,detail:l,tone:d,source:m}}function Ap(t){if(!_(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,lane_ids:B(t.lane_ids),count:c(t.count)??0}}function yr(t){if(!_(t))return;const e=_(t.overview)?t.overview:{},n=_(t.gaps)?t.gaps:{},s=_(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:r(t.generated_at),overview:{active_lanes:c(e.active_lanes),moving_lanes:c(e.moving_lanes),stalled_lanes:c(e.stalled_lanes),projected_lanes:c(e.projected_lanes),last_movement_at:r(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(xp).filter(a=>a!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(Sp).filter(a=>a!==null):[],gaps:{count:c(n.count),items:Array.isArray(n.items)?n.items.map(Ap).filter(a=>a!==null):[]},recommended_next_action:s?{tool:r(s.tool)??"masc_operator_snapshot",label:r(s.label)??"Observe operator state",reason:r(s.reason)??"",lane_id:r(s.lane_id)??null}:void 0}}function Cp(t){if(!_(t))return;const e=_(t.workers)?t.workers:{},n=q(t.pass);return{status:r(t.status)??"missing",source:r(t.source)??"none",run_id:r(t.run_id)??null,captured_at:r(t.captured_at)??null,...n!==void 0?{pass:n}:{},...c(t.peak_hot_slots)!=null?{peak_hot_slots:c(t.peak_hot_slots)}:{},...c(t.ctx_per_slot)!=null?{ctx_per_slot:c(t.ctx_per_slot)}:{},workers:{expected:c(e.expected),joined:c(e.joined),current_task_bound:c(e.current_task_bound),fresh_heartbeats:c(e.fresh_heartbeats),done:c(e.done),final:c(e.final)},artifact_ref:r(t.artifact_ref)??null,missing_reason:r(t.missing_reason)??null}}function wp(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),topology:mr(e.topology),operations:vr(e.operations),detachments:fr(e.detachments),alerts:$r(e.alerts),decisions:gr(e.decisions),capacity:hp(e.capacity),traces:bp(e.traces),swarm_status:yr(e.swarm_status)}}function Tp(t){const e=_(t)?t:{},n=mr(e.topology),s=vr(e.operations),a=fr(e.detachments),o=$r(e.alerts),l=gr(e.decisions);return{version:r(e.version),generated_at:r(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:yr(e.swarm_status),swarm_proof:Cp(e.swarm_proof)}}function Ip(t){return _(t)?{chain_id:r(t.chain_id)??null,started_at:c(t.started_at)??null,progress:c(t.progress)??null,elapsed_sec:c(t.elapsed_sec)??null}:null}function br(t){if(!_(t))return null;const e=r(t.event);return e?{event:e,chain_id:r(t.chain_id)??null,timestamp:r(t.timestamp)??null,duration_ms:c(t.duration_ms)??null,message:r(t.message)??null,tokens:c(t.tokens)??null}:null}function Rp(t){if(!_(t))return null;const e=ta(t.operation);return e?{operation:e,runtime:Ip(t.runtime),history:br(t.history),mermaid:r(t.mermaid)??null,preview_run:kr(t.preview_run)}:null}function Pp(t){const e=_(t)?t:{};return{status:r(e.status)??"disconnected",base_url:r(e.base_url)??null,message:r(e.message)??null}}function Np(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),connection:Pp(e.connection),summary:n?{linked_operations:c(n.linked_operations),active_chains:c(n.active_chains),running_operations:c(n.running_operations),recent_failures:c(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(Rp).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(br).filter(s=>s!==null):[]}}function Lp(t){if(!_(t))return null;const e=r(t.id);return e?{id:e,type:r(t.type),status:r(t.status),duration_ms:c(t.duration_ms)??null,error:r(t.error)??null}:null}function kr(t){if(!_(t))return null;const e=r(t.run_id),n=r(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:c(t.duration_ms),success:q(t.success),mermaid:r(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(Lp).filter(s=>s!==null):[]}:null}function Mp(t){const e=_(t)?t:{};return{run:kr(e.run)}}function Dp(t){if(!_(t))return null;const e=r(t.title),n=r(t.path);return!e||!n?null:{title:e,path:n}}function zp(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function Ep(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.tool),a=r(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:B(t.success_signals),pitfalls:B(t.pitfalls)}}function jp(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary),a=r(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(Ep).filter(o=>o!==null):[]}}function Op(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:B(t.tools)}}function Fp(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.symptom),a=r(t.why),o=r(t.fix_tool),l=r(t.fix_summary);return!e||!n||!s||!a||!o||!l?null:{id:e,title:n,symptom:s,why:a,fix_tool:o,fix_summary:l}}function qp(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.path_id),a=r(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:B(t.notes)}}function Kp(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(Dp).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(zp).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(jp).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Op).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Fp).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(qp).filter(n=>n!==null):[]}}function Up(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.status),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{id:e,title:n,status:s,detail:a,next_tool:o}}function Bp(t){if(!_(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.title),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{code:e,severity:n,title:s,detail:a,next_tool:o}}function Hp(t){if(!_(t))return null;const e=r(t.from),n=r(t.content),s=r(t.timestamp),a=c(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function Wp(t){if(!_(t))return null;const e=r(t.name),n=r(t.role),s=r(t.lane),a=r(t.status),o=r(t.claim_marker),l=r(t.done_marker),d=r(t.final_marker);if(!e||!n||!s||!a||!o||!l||!d)return null;const m=(()=>{if(!_(t.last_message))return null;const v=c(t.last_message.seq),u=r(t.last_message.content),p=r(t.last_message.timestamp);return v==null||!u||!p?null:{seq:v,content:u,timestamp:p}})();return{name:e,role:n,lane:s,joined:q(t.joined)??!1,live_presence:q(t.live_presence)??!1,completed:q(t.completed)??!1,status:a,current_task:r(t.current_task)??null,bound_task_id:r(t.bound_task_id)??null,bound_task_title:r(t.bound_task_title)??null,bound_task_status:r(t.bound_task_status)??null,current_task_matches_run:q(t.current_task_matches_run)??!1,squad_member:q(t.squad_member)??!1,detachment_member:q(t.detachment_member)??!1,last_seen:r(t.last_seen)??null,heartbeat_age_sec:c(t.heartbeat_age_sec)??null,heartbeat_fresh:q(t.heartbeat_fresh)??!1,claim_marker_seen:q(t.claim_marker_seen)??!1,done_marker_seen:q(t.done_marker_seen)??!1,final_marker_seen:q(t.final_marker_seen)??!1,claim_marker:o,done_marker:l,final_marker:d,last_message:m}}function Gp(t){if(!_(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!_(n))return null;const s=r(n.timestamp),a=c(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:r(t.slot_url)??null,provider_base_url:r(t.provider_base_url)??null,provider_reachable:q(t.provider_reachable)??null,provider_status_code:c(t.provider_status_code)??null,provider_model_id:r(t.provider_model_id)??null,actual_model_id:r(t.actual_model_id)??null,expected_slots:c(t.expected_slots),actual_slots:c(t.actual_slots),expected_ctx:c(t.expected_ctx),actual_ctx:c(t.actual_ctx),slot_reachable:q(t.slot_reachable)??null,slot_status_code:c(t.slot_status_code)??null,runtime_blocker:r(t.runtime_blocker)??null,detail:r(t.detail)??null,checked_at:r(t.checked_at)??null,total_slots:c(t.total_slots),ctx_per_slot:c(t.ctx_per_slot),active_slots_now:c(t.active_slots_now),peak_active_slots:c(t.peak_active_slots),sample_count:c(t.sample_count),last_sample_at:r(t.last_sample_at)??null,timeline:e}}function Jp(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),run_id:r(e.run_id),room_id:r(e.room_id),operation_id:r(e.operation_id)??null,recommended_next_tool:r(e.recommended_next_tool),summary:n?{expected_workers:c(n.expected_workers),joined_workers:c(n.joined_workers),live_workers:c(n.live_workers),squad_roster_size:c(n.squad_roster_size),detachment_roster_size:c(n.detachment_roster_size),current_task_bound:c(n.current_task_bound),fresh_heartbeats:c(n.fresh_heartbeats),claim_markers_seen:c(n.claim_markers_seen),done_markers_seen:c(n.done_markers_seen),final_markers_seen:c(n.final_markers_seen),completed_workers:c(n.completed_workers),peak_hot_slots:c(n.peak_hot_slots),hot_window_ok:q(n.hot_window_ok),pass_hot_concurrency:q(n.pass_hot_concurrency),pass_end_to_end:q(n.pass_end_to_end),pending_decisions:c(n.pending_decisions),pass:q(n.pass)}:void 0,provider:Gp(e.provider),operation:ta(e.operation),squad:yi(e.squad),detachment:_r(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Wp).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Up).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Bp).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Hp).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(hr).filter(s=>s!==null):[],truth_notes:B(e.truth_notes)}}function ve(t){U.value=t,hi(t)&&Vp()}async function xr(){Is.value=!0,Ps.value=null;try{const t=await zl();$i.value=Tp(t)}catch(t){Ps.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{Is.value=!1}}function bi(t){ze.value=t}async function ki(){Rs.value=!0,Ns.value=null;try{const t=await Dl();Dt.value=wp(t)}catch(t){Ns.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{Rs.value=!1}}async function Vp(){Dt.value||Rs.value||await ki()}async function Vt(){await xr(),hi(U.value)&&await ki()}async function Yt(){var t;Ya.value=!0,Es.value=null;try{const e=await El(),n=Np(e);qn.value=n;const s=ze.value;n.operations.length===0?ze.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(ze.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Es.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{Ya.value=!1}}function Yp(){sn=null,Cn.value=null,js.value=!1,wn.value=null}async function Qp(t){sn=t,js.value=!0,wn.value=null;try{const e=await jl(t);if(sn!==t)return;Cn.value=Mp(e)}catch(e){if(sn!==t)return;Cn.value=null,wn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{sn===t&&(js.value=!1)}}async function Xp(){Va.value=!0,Ms.value=null;try{const t=await Ol();Fn.value=Kp(t)}catch(t){Ms.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Va.value=!1}}async function wt(t=lp(),e=cp()){Ds.value=!0,zs.value=null;try{const n=await Fl(t,e);ge.value=Jp(n)}catch(n){zs.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{Ds.value=!1}}async function se(t,e,n){Ja.value=t,Ls.value=null;try{await ql(e,n),await xr(),(Dt.value||hi(U.value))&&await ki(),await wt(),await Yt()}catch(s){throw Ls.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{Ja.value=null}}function Zp(t){return se(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function tm(t){return se(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function em(t){return se(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function nm(t={}){return se("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function sm(t){return se(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function am(t){return se(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function im(t,e){return se(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function om(t,e){return se(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}_d(()=>{Vt(),Yt(),(U.value==="swarm"||U.value==="warroom"||ge.value!==null)&&wt(),U.value==="warroom"&&st()});const rm="modulepreload",lm=function(t){return"/dashboard/"+t},Ji={},cm=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(v){return Promise.all(v.map(u=>Promise.resolve(u).then(p=>({status:"fulfilled",value:p}),p=>({status:"rejected",reason:p}))))};document.getElementsByTagName("link");const d=document.querySelector("meta[property=csp-nonce]"),m=(d==null?void 0:d.nonce)||(d==null?void 0:d.getAttribute("nonce"));a=l(n.map(v=>{if(v=lm(v),v in Ji)return;Ji[v]=!0;const u=v.endsWith(".css"),p=u?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${v}"]${p}`))return;const f=document.createElement("link");if(f.rel=u?"stylesheet":rm,u||(f.as="script"),f.crossOrigin="",f.href=v,m&&f.setAttribute("nonce",m),document.head.appendChild(f),u)return new Promise((h,x)=>{f.addEventListener("load",h),f.addEventListener("error",()=>x(new Error(`Unable to preload CSS for ${v}`)))})}))}function o(l){const d=new Event("vite:preloadError",{cancelable:!0});if(d.payload=l,window.dispatchEvent(d),!d.defaultPrevented)throw l}return a.then(l=>{for(const d of l||[])d.status==="rejected"&&o(d.reason);return e().catch(o)})};function Sr(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function V(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function dm(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Ar(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function L(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let Vi=!1,um=0;function pm(){return++um}let la=null;async function mm(){la||(la=cm(()=>import("./mermaid.core-CKpPr1oY.js").then(e=>e.bE),[]).then(e=>e.default));const t=await la;return Vi||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),Vi=!0),t}function Qt(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Kn(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function an(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function Un(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function ce(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:Un(t/e*100)}function vm(t,e){const n=Un(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function Cr(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const _m=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],wr=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],fm=wr.map(t=>t.id),gm=["chain_start","node_start","node_complete","chain_complete","chain_error"],$m={warroom:{title:"라이브 워룸",description:"실제 run, worker, message, trace를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function Yi(t){return!!t&&fm.includes(t)}function hm(){const t=E.value.params;return t.source!=="mission"?{}:{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function Tr(t){const e=hm();if(t==="operations")return e;if(t==="chains"){const n=ze.value;return n?{...e,surface:t,operation:n}:{...e,surface:t}}return{...e,surface:t}}function ym(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function bm(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function at(t){return Ja.value===t}function Bn(){return $i.value}function km(t){var a,o,l,d,m,v,u;const e=$i.value,n=ge.value,s=qn.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"live run, worker, message, trace를 한 화면에서 보고 필요한 detail 표면으로 바로 점프합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(o=e==null?void 0:e.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((m=(d=e==null?void 0:e.swarm_status)==null?void 0:d.recommended_next_action)==null?void 0:m.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(u=(v=s==null?void 0:s.operations[0])==null?void 0:v.preview_run)!=null&&u.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function xm(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function Sm(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function Am(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Ir(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function Cm(){const e=Ir().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Rr(){const e=Ir().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function wm(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function Tm(t){return t.status==="claimed"||t.status==="in_progress"}function Im(t){const e=Fn.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function ca(t){var e;return((e=Fn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function Rm(t){const e=Fn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function Xt(t){try{await t()}catch{}}function xi(t){return(t==null?void 0:t.trim().toLowerCase())??""}function Te(t){const e=xi(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function da(t){const e=xi(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function Pm(){var e,n,s;const t=ge.value;return t?!!(t.run_id||(e=t.operation)!=null&&e.operation_id||(n=t.detachment)!=null&&n.detachment_id||(((s=t.summary)==null?void 0:s.expected_workers)??0)>0||t.workers.length>0||t.recent_messages.length>0||t.recent_trace_events.length>0):!1}function Nm(t){const e=xi(t.status);return e==="active"||e==="running"}function Lm(){var o,l,d,m;const t=((o=Nt.value)==null?void 0:o.sessions)??[],e=ge.value,n=((l=e==null?void 0:e.detachment)==null?void 0:l.session_id)??null;if(n){const v=t.find(u=>u.session_id===n);if(v)return v}const s=((d=e==null?void 0:e.operation)==null?void 0:d.operation_id)??Rr();if(s){const v=t.find(u=>u.command_plane_operation_id===s);if(v)return v}const a=((m=e==null?void 0:e.detachment)==null?void 0:m.detachment_id)??null;if(a){const v=t.find(u=>u.command_plane_detachment_id===a);if(v)return v}return t.find(Nm)??t[0]??null}function Mm(){const t=On(E.value);return t?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${Xs(t.action_type)}</span>
        <span class="command-chip">${fi(t)}</span>
        <span class="command-chip">${Fu(E.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?i`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function Dm(){const t=U.value,e=$m[t],n=km(t);return i`
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
  `}function Qn({label:t,value:e,subtext:n,percent:s,color:a}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${vm(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(Un(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function Xn({label:t,value:e,detail:n,percent:s,tone:a}){return i`
    <article class="command-signal-rail ${L(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${L(a)}" style=${`width: ${Math.max(8,Math.round(Un(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function zm(){var O,Y,K,Z;const t=Bn(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,o=t==null?void 0:t.alerts.summary,l=(O=t==null?void 0:t.swarm_status)==null?void 0:O.overview,d=t==null?void 0:t.swarm_proof,m=t==null?void 0:t.operations.microarch,v=(e==null?void 0:e.managed_unit_count)??0,u=(e==null?void 0:e.total_units)??0,p=(n==null?void 0:n.active)??0,f=(s==null?void 0:s.active)??0,h=(l==null?void 0:l.moving_lanes)??0,x=(l==null?void 0:l.active_lanes)??0,S=(d==null?void 0:d.workers.done)??0,C=(d==null?void 0:d.workers.expected)??0,T=(o==null?void 0:o.bad)??0,w=(o==null?void 0:o.warn)??0,A=(a==null?void 0:a.pending)??0,R=(a==null?void 0:a.total)??0,P=p+f,G=((Y=m==null?void 0:m.cache)==null?void 0:Y.l1_hit_rate)??((Z=(K=m==null?void 0:m.signals)==null?void 0:K.cache_contention)==null?void 0:Z.l1_hit_rate)??0,H=p>0||f>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",$=p>0||h>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${H}</h3>
        <p>${$}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${L(p>0?"ok":"warn")}">활성 작전 ${p}</span>
          <span class="command-chip ${L(h>0?"ok":(x>0,"warn"))}">이동 레인 ${h}/${Math.max(x,h)}</span>
          <span class="command-chip ${L(T>0?"bad":w>0?"warn":"ok")}">치명 알림 ${T}</span>
          <span class="command-chip ${L(A>0?"warn":"ok")}">승인 대기 ${A}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${Qn}
          label="관리 단위 범위"
          value=${`${v}/${Math.max(u,v)}`}
          subtext=${u>0?`${u-v}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${ce(v,Math.max(u,v))}
          color="#67e8f9"
        />
        <${Qn}
          label="실행 열도"
          value=${String(P)}
          subtext=${`${p}개 작전 + ${f}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${ce(P,Math.max(v,P||1))}
          color="#4ade80"
        />
        <${Qn}
          label="스웜 이동감"
          value=${`${h}/${Math.max(x,h)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${V(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${ce(h,Math.max(x,h||1))}
          color="#fbbf24"
        />
        <${Qn}
          label="증거 수집률"
          value=${`${S}/${Math.max(C,S)}`}
          subtext=${d!=null&&d.status?`증거 소스 ${d.source} · ${d.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${ce(S,Math.max(C,S||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${Xn}
        label="승인 대기열"
        value=${`${A}건 대기`}
        detail=${`현재 정책 창에서 ${R}개 결정을 추적 중입니다`}
        percent=${ce(A,Math.max(R,A||1))}
        tone=${A>0?"warn":"ok"}
      />
      <${Xn}
        label="알림 압력"
        value=${`${T} bad / ${w} warn`}
        detail=${T>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${ce(T*2+w,Math.max((T+w)*2,1))}
        tone=${T>0?"bad":w>0?"warn":"ok"}
      />
      <${Xn}
        label="디스패치 점유"
          value=${`${f}개 가동`}
        detail=${v>0?`${v}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${ce(f,Math.max(v,f||1))}
        tone=${f>0?"ok":"warn"}
      />
      <${Xn}
        label="캐시 신뢰도"
        value=${G?Kn(G):"n/a"}
        detail=${G?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Un((G??0)*100)}
        tone=${G>=.75?"ok":G>=.4?"warn":"bad"}
      />
    </div>
  `}function Em(){var f,h,x,S,C;const t=Bn(),e=qn.value,n=On(E.value),s=xm(n),a=t==null?void 0:t.topology.summary,o=t==null?void 0:t.operations.summary,l=(f=t==null?void 0:t.swarm_status)==null?void 0:f.overview,d=t==null?void 0:t.operations.microarch,m=t==null?void 0:t.decisions.summary,v=t==null?void 0:t.alerts.summary,u=(h=d==null?void 0:d.signals)==null?void 0:h.issue_pressure,p=d==null?void 0:d.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((x=t==null?void 0:t.detachments.summary)==null?void 0:x.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(m==null?void 0:m.pending)??0}</strong><small>${(m==null?void 0:m.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(v==null?void 0:v.bad)??0}</strong><small>${(v==null?void 0:v.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((S=e==null?void 0:e.summary)==null?void 0:S.active_chains)??0}</strong><small>${((C=e==null?void 0:e.summary)==null?void 0:C.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${V(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(u==null?void 0:u.pending_ops)??0}</strong><small>${(p==null?void 0:p.l1_hit_rate)!=null?`${Kn(p.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(u==null?void 0:u.tone)??"n/a"}</small></div>
    </div>
  `}function jm(){var O,Y,K,Z,k,bt,Ut,ae,ie;const t=Bn(),e=Dt.value,n=_t.value,s=Am(),a=s?yt.value.find(z=>z.name===s)??null:null,o=s?It.value.filter(z=>z.assignee===s&&Tm(z)):[],l=((O=t==null?void 0:t.operations.summary)==null?void 0:O.active)??0,d=((Y=t==null?void 0:t.detachments.summary)==null?void 0:Y.total)??0,m=((K=t==null?void 0:t.decisions.summary)==null?void 0:K.pending)??0,v=e==null?void 0:e.detachments.detachments.find(z=>{const kt=z.detachment.heartbeat_deadline,oe=kt?Date.parse(kt):Number.NaN;return z.detachment.status==="stalled"||!Number.isNaN(oe)&&oe<=Date.now()}),u=e==null?void 0:e.alerts.alerts.find(z=>z.severity==="bad"),p=!!(n!=null&&n.room||n!=null&&n.project),f=(a==null?void 0:a.current_task)??null,h=wm(a==null?void 0:a.last_seen),x=h!=null?h<=120:null,S=[p?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:It.value.length>0?"masc_claim":"masc_add_task"}:f?x===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${f} 이지만 heartbeat가 stale 합니다 (${h}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${f}${h!=null?` · 마지막 활동 ${h}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((Z=t.topology.summary)==null?void 0:Z.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((k=t.topology.summary)==null?void 0:k.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((bt=t.topology.summary)==null?void 0:bt.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},m>0?{title:"디스패치 준비도",tone:"warn",detail:`${m}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&d===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:v||u?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${v?` · detachment ${v.detachment.detachment_id} 가 stalled 상태입니다`:""}${u?` · alert ${u.title??u.alert_id}`:""}${!e&&!v&&!u?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:m>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${d}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],C=p?!s||!a?"masc_join":o.length===0?It.value.length>0?"masc_claim":"masc_add_task":f?x===!1?"masc_heartbeat":!t||(((Ut=t.topology.summary)==null?void 0:Ut.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":m>0?"masc_policy_approve":l>0&&d===0||v||u?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",T=Im(C),A=Rm(C==="masc_set_room"?["repo-root-room"]:C==="masc_plan_set_task"?["claimed-not-current"]:C==="masc_heartbeat"?["heartbeat-stale"]:C==="masc_dispatch_tick"?["no-detachments"]:C==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),R=ca("room_task_hygiene"),P=ca("cpv2_benchmark"),G=ca("supervisor_session"),H=((ae=Fn.value)==null?void 0:ae.docs)??[],$=[R,P,G].filter(z=>z!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${M} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(T==null?void 0:T.title)??C}</strong>
            <span class="command-chip ok">${C}</span>
          </div>
          <p>${(T==null?void 0:T.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(ie=T==null?void 0:T.success_signals)!=null&&ie.length?i`<div class="command-tag-row">
                ${T.success_signals.map(z=>i`<span class="command-tag ok">${z}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${S.map(z=>i`
            <article class="command-readiness-row ${L(z.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${z.title}</strong>
                  <span class="command-chip ${L(z.tone)}">${z.tone}</span>
                </div>
                <p>${z.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${z.tool}</div>
            </article>
          `)}
        </div>

        ${A.length>0?i`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${A.length}</span>
                </div>
                <div class="command-guide-list">
                  ${A.map(z=>i`
                    <article class="command-guide-inline">
                      <strong>${z.title}</strong>
                      <div>${z.symptom}</div>
                      <div class="command-card-sub">${z.fix_tool} 로 해결: ${z.fix_summary}</div>
                    </article>
                  `)}
                </div>
              </div>
            `:null}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">운영 경로</div>
          <${M} panelId="command.summary" compact=${!0} />
        </div>
        ${Va.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:Ms.value?i`<div class="empty-state error">${Ms.value}</div>`:i`
                <div class="command-path-grid">
                  ${$.map(z=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${z.title}</strong>
                        <span class="command-chip">${z.id}</span>
                      </div>
                      <p>${z.summary}</p>
                      <div class="command-card-sub">${z.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${z.steps.slice(0,4).map(kt=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${kt.tool}</span>
                            <span>${kt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${H.length>0?i`<div class="command-doc-links">
                      ${H.map(z=>i`<span class="command-tag">${z.title}: ${z.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Om(){return i`
    <${zm} />
    <${Em} />
    <${jm} />
  `}function Fm(){return Rs.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:Ns.value?i`<div class="empty-state error">${Ns.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function Pr({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,o=t.unit.policy;return i`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${bm(t.unit.kind)}</span>
            <span class="command-chip ${L(t.health)}">${t.health??"ok"}</span>
            ${o!=null&&o.frozen?i`<span class="command-chip warn">frozen</span>`:null}
            ${o!=null&&o.kill_switch?i`<span class="command-chip bad">kill-switch</span>`:null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${t.unit.unit_id}</span>
            <span>Leader ${t.unit.leader_id??"unassigned"} / ${t.leader_status??"unknown"}</span>
            <span>Roster ${n}/${s}</span>
            <span>Ops ${a}</span>
            <span>Autonomy ${(o==null?void 0:o.autonomy_level)??"n/a"}</span>
          </div>
          ${t.reasons&&t.reasons.length>0?i`<div class="command-tag-row">
                ${t.reasons.map(l=>i`<span class="command-tag warn">${l}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?i`<div class="command-tree-children">
            ${t.children.map(l=>i`<${Pr} node=${l} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function qm({alert:t}){return i`
    <article class="command-alert ${L(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${L(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${V(t.timestamp)}</span>
      </div>
      ${t.detail?i`<p>${t.detail}</p>`:null}
    </article>
  `}function Si({event:t}){return i`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${V(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${Sr(t.detail)}</pre>
    </article>
  `}function Km(){const t=Dt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${M} panelId="command.topology" compact=${!0} />
      </div>
      ${t&&t.topology.units.length>0?i`${t.topology.units.map(e=>i`<${Pr} node=${e} />`)}`:i`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function Um(){const t=Dt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${M} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>i`<${qm} alert=${e} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function Bm(){const t=Dt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${M} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?i`<div class="command-trace-stack">
            ${t.traces.events.map(e=>i`<${Si} event=${e} />`)}
          </div>`:i`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function Nr(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function Lr({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const o=a.motion_state;o in e?e[o]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return i`
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
  `}function Hm({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${a.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?i`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function Wm({lane:t}){const e=t.counts??{},n=Nr(t),s=e.workers??0,a=e.operations??0,o=e.detachments??0,l=a+o,d=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return i`
    <article class="swarm-lane-strip ${L(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${L(n)}">${t.phase}</span>
          <span class="command-chip ${L(n)}">${t.motion_state}</span>
          <span class="command-chip">${V(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${L(n)}" style=${`width:${d}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${s>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${Hm} total=${s} />
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
      ${t.blockers.length>0?i`<div class="swarm-lane-blockers">막힘: ${t.blockers.join(" · ")}</div>`:null}
      ${t.hard_flags.length>0?i`
            <div class="swarm-lane-flags">
              ${t.hard_flags.map(m=>i`<span class="command-chip ${L(m.severity)}">${m.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Mr({lanes:t}){const e=t.slice(0,4);return e.length===0?null:i`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=Nr(n),a=n.counts.workers??0,o=n.counts.operations??0,l=n.counts.detachments??0;return i`
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
  `}function Gm({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${L(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?i`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function Jm({gap:t}){return i`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${L(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function Vm({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${L(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${L(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?i`
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${V(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.artifact_ref?i`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?i`<p>${t.missing_reason}</p>`:null}
          `:i`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function Ym(){const t=Bn(),e=On(E.value),n=Sm(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,o=(s==null?void 0:s.lanes.filter(p=>p.present))??[],l=(s==null?void 0:s.gaps.items)??[],d=(s==null?void 0:s.timeline.slice(0,8))??[],m=s==null?void 0:s.overview,v=s==null?void 0:s.recommended_next_action,u=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${M} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${Mr} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(m==null?void 0:m.active_lanes)??0}</strong><small>${(m==null?void 0:m.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(m==null?void 0:m.stalled_lanes)??0}</strong><small>${(m==null?void 0:m.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${V(m==null?void 0:m.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${V(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(v==null?void 0:v.label)??"운영자 상태 확인"}</strong><small>${(v==null?void 0:v.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${Lr} lanes=${o} />`:null}

            <div class="command-swarm-layout ${u?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(p=>i`<${Wm} lane=${p} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight ${n==="recommendation"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>${(v==null?void 0:v.label)??"운영자 상태 확인"}</strong>
                    <span class="command-chip">${(v==null?void 0:v.lane_id)??"전체"}</span>
                  </div>
                  <p>${(v==null?void 0:v.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="command-card-foot">${(v==null?void 0:v.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${Vm} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${L(l.some(p=>p.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?i`<div class="swarm-event-rail">${l.slice(0,4).map(p=>i`<${Jm} gap=${p} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${d.length}</span>
                  </div>
                  ${d.length>0?i`<div class="swarm-event-rail">${d.map(p=>i`<${Gm} event=${p} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function Qm({item:t}){return i`
    <article class="command-guide-card ${L(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${L(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Dr({blocker:t}){return i`
    <article class="command-alert ${L(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${L(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function Xm({worker:t}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${L(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${t.last_message?i`<div class="command-card-foot">${V(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function Zm(){var m,v,u,p,f,h,x,S,C,T,w,A,R,P,G,H,$,O,Y,K,Z;const t=ge.value,e=Cm(),n=Rr(),s=(m=t==null?void 0:t.provider)!=null&&m.runtime_blocker?"blocked":(v=t==null?void 0:t.provider)!=null&&v.provider_reachable?"ready":"check",a=((u=t==null?void 0:t.provider)==null?void 0:u.actual_slots)??((p=t==null?void 0:t.provider)==null?void 0:p.total_slots)??0,o=((f=t==null?void 0:t.provider)==null?void 0:f.expected_slots)??"n/a",l=((h=t==null?void 0:t.provider)==null?void 0:h.actual_ctx)??((x=t==null?void 0:t.provider)==null?void 0:x.ctx_per_slot)??0,d=((S=t==null?void 0:t.provider)==null?void 0:S.expected_ctx)??"n/a";return i`
    <div class="command-section-stack">
      <${Ym} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${M} panelId="command.swarm" compact=${!0} />
          </div>
          ${Ds.value?i`<div class="empty-state">Loading swarm live state…</div>`:zs.value?i`<div class="empty-state error">${zs.value}</div>`:t?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((C=t.summary)==null?void 0:C.joined_workers)??0}/${((T=t.summary)==null?void 0:T.expected_workers)??0}</strong><small>${((w=t.summary)==null?void 0:w.live_workers)??0}개 가동 · ${((A=t.summary)==null?void 0:A.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${o} · ctx ${l}/${d}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(R=t.summary)!=null&&R.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((P=t.provider)==null?void 0:P.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(G=t.summary)!=null&&G.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((H=t.operation)==null?void 0:H.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${(($=t.squad)==null?void 0:$.label)??"없음"}</span>
                      <span>실행체</span><span>${((O=t.detachment)==null?void 0:O.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((Y=t.summary)==null?void 0:Y.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((K=t.summary)==null?void 0:K.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((Z=t.provider)==null?void 0:Z.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?i`<div class="command-tag-row">
                          ${t.truth_notes.map(k=>i`<span class="command-tag">${k}</span>`)}
                        </div>`:null}
                  `:i`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${M} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?i`<div class="command-card-stack">
                ${t.checklist.map(k=>i`<${Qm} item=${k} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${M} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?i`<div class="command-card-stack">
                ${t.workers.map(k=>i`<${Xm} worker=${k} />`)}
              </div>`:i`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${M} panelId="command.swarm" compact=${!0} />
          </div>
          ${t!=null&&t.provider?i`
                <div class="command-card-grid">
                  <span>Provider</span><span>${t.provider.provider_base_url??"n/a"}</span>
                  <span>Provider Reachable</span><span>${t.provider.provider_reachable==null?"n/a":t.provider.provider_reachable?"yes":"no"}</span>
                  <span>Requested Model</span><span>${t.provider.provider_model_id??"n/a"}</span>
                  <span>Actual Model</span><span>${t.provider.actual_model_id??"n/a"}</span>
                  <span>Slot URL</span><span>${t.provider.slot_url??"n/a"}</span>
                  <span>Expected Slots</span><span>${t.provider.expected_slots??"n/a"}</span>
                  <span>Actual Slots</span><span>${t.provider.actual_slots??t.provider.total_slots??0}</span>
                  <span>Expected Ctx</span><span>${t.provider.expected_ctx??"n/a"}</span>
                  <span>Actual Ctx</span><span>${t.provider.actual_ctx??t.provider.ctx_per_slot??0}</span>
                  <span>Active Now</span><span>${t.provider.active_slots_now??0}</span>
                  <span>Peak Active</span><span>${t.provider.peak_active_slots??0}</span>
                  <span>Sample Count</span><span>${t.provider.sample_count??0}</span>
                  <span>Last Sample</span><span>${t.provider.last_sample_at?V(t.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${t.provider.checked_at?V(t.provider.checked_at):"n/a"}</span>
                </div>
                ${t.provider.detail?i`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?i`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(k=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${k.active_slots} active</strong>
                              <span class="command-chip">${V(k.timestamp)}</span>
                            </div>
                            <div class="command-card-sub">slots ${k.active_slot_ids.join(", ")||"none"}</div>
                          </div>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:i`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${M} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?i`<div class="command-card-stack">
                ${t.blockers.map(k=>i`<${Dr} blocker=${k} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${M} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?i`<div class="command-trace-stack">
                ${t.recent_messages.map(k=>i`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${k.from}</strong>
                        <span class="command-chip">${V(k.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${k.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${k.content}</pre>
                  </article>
                `)}
              </div>`:i`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${M} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${t.recent_trace_events.map(k=>i`<${Si} event=${k} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function tv(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"none",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}s`:t.heartbeat_fresh?"clean":"n/a",detail:[t.bound_task_status??null,t.detachment_member?"detachment":null,t.squad_member?"squad":null].filter(Boolean).join(" · ")||"live swarm worker",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function ev(t,e){const n=t.actor??t.spawn_role??`worker-${e+1}`,s=t.spawn_role??t.worker_class??t.spawn_agent??"worker",a=t.lane_id??t.capsule_mode??t.control_domain??"session",o=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:s,lane:a,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"session lane",heartbeat:t.last_turn_ts_iso?V(t.last_turn_ts_iso):"n/a",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?Kn(t.routing_confidence):null].filter(Boolean).join(" · ")||"session worker",markers:o,note:t.routing_reason??null}}function Qi(t){return L(t.severity)}function nv({worker:t}){return i`
    <article class="command-card compact warroom-worker-card ${L(Te(t.status))}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${L(Te(t.status))}">${t.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Source</span><span>${t.source}</span>
        <span>Task</span><span>${t.task}</span>
        <span>Heartbeat</span><span>${t.heartbeat}</span>
        <span>Detail</span><span>${t.detail}</span>
      </div>
      <div class="command-tag-row">
        ${t.markers.map(e=>i`<span class="command-tag">${e}</span>`)}
      </div>
      ${t.note?i`<div class="command-card-foot">${t.note}</div>`:null}
    </article>
  `}function Ht({label:t,surface:e,params:n={}}){return i`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(e){ve(e),dt("command",{...Tr(e),...n});return}dt("intervene")}}
    >
      ${t}
    </button>
  `}function sv(){var H,$,O,Y,K,Z,k,bt,Ut,ae,ie,z,kt,oe,Ye,Qe,Hn,Wn,Gn,Jn;const t=Bn(),e=ge.value,n=Nt.value,s=Lt.value,a=Lm(),o=e!=null&&e.operation?((H=qn.value)==null?void 0:H.operations.find(F=>{var he;return F.operation.operation_id===((he=e.operation)==null?void 0:he.operation_id)}))??null:null,l=(e==null?void 0:e.workers)??[],d=(s==null?void 0:s.worker_cards)??[],m=l.length>0?l.map(tv):d.map(ev),v=Pm(),u=(($=t==null?void 0:t.decisions.summary)==null?void 0:$.pending)??0,p=(n==null?void 0:n.pending_confirms)??[],f=(e==null?void 0:e.blockers)??[],h=(s==null?void 0:s.recommended_actions)??[],x=(s==null?void 0:s.attention_items)??[],S=((O=e==null?void 0:e.recent_messages[0])==null?void 0:O.timestamp)??null,C=((Y=e==null?void 0:e.recent_trace_events[0])==null?void 0:Y.timestamp)??null,T=S??C??null,w=a==null?void 0:a.summary,A=((K=e==null?void 0:e.summary)==null?void 0:K.expected_workers)??(typeof(w==null?void 0:w.planned_worker_count)=="number"?w.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,R=((Z=e==null?void 0:e.summary)==null?void 0:Z.joined_workers)??(typeof(w==null?void 0:w.active_agent_count)=="number"?w.active_agent_count:void 0)??m.length,P=f.length>0||u>0||p.length>0?"warn":v||a?"ok":"warn",G=((k=t==null?void 0:t.swarm_status)==null?void 0:k.lanes.filter(F=>F.present))??[];return nt(()=>{st()},[]),nt(()=>{a!=null&&a.session_id&&Be(a.session_id)},[a==null?void 0:a.session_id,n,(bt=e==null?void 0:e.detachment)==null?void 0:bt.session_id]),!v&&!a?Ds.value||Sn.value?i`<div class="empty-state">live war room 불러오는 중…</div>`:i`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">라이브 워룸</div>
          <${M} panelId="command.warroom" compact=${!0} />
        </div>
        <div class="command-warroom-empty-copy">
          <strong>현재 live run 없음</strong>
          <p>활성 operation 또는 team session이 시작되면 이 화면이 자동으로 붙잡습니다.</p>
        </div>
        <div class="command-action-row">
          <${Ht} label="작전 보기" surface="operations" />
          <${Ht} label="스웜 보기" surface="swarm" />
          <${Ht} label="개입 열기" />
          <${Ht} label="제어 보기" surface="control" />
        </div>
      </section>
    `:i`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${L(P)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">Live War Room</span>
            <strong>${((Ut=e==null?void 0:e.operation)==null?void 0:Ut.objective)??(a==null?void 0:a.session_id)??"active run"}</strong>
            <div class="command-card-sub">
              ${((ae=e==null?void 0:e.operation)==null?void 0:ae.operation_id)??"operation 없음"}
              ${a!=null&&a.session_id?` · session ${a.session_id}`:""}
              ${(ie=e==null?void 0:e.detachment)!=null&&ie.detachment_id?` · detachment ${e.detachment.detachment_id}`:""}
            </div>
          </div>
          <div class="command-action-row">
            <${Ht}
              label="스웜 상세"
              surface="swarm"
              params=${{...(z=e==null?void 0:e.operation)!=null&&z.operation_id?{operation_id:e.operation.operation_id}:{},...e!=null&&e.run_id?{run_id:e.run_id}:{}}}
            />
            <${Ht} label="트레이스" surface="trace" />
            ${o?i`<${Ht}
                  label="체인"
                  surface="chains"
                  params=${{operation:o.operation.operation_id}}
                />`:null}
            <${Ht} label="Intervene" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>Workers</span>
            <strong>${R??0}/${A??0}</strong>
            <small>${((kt=e==null?void 0:e.summary)==null?void 0:kt.completed_workers)??0} 완료 · ${m.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>Runtime</span>
            <strong>${(oe=e==null?void 0:e.provider)!=null&&oe.runtime_blocker?"blocked":(Ye=e==null?void 0:e.provider)!=null&&Ye.provider_reachable?"ready":a?da(a.status):"check"}</strong>
            <small>slots ${((Qe=e==null?void 0:e.provider)==null?void 0:Qe.active_slots_now)??0}/${((Hn=e==null?void 0:e.provider)==null?void 0:Hn.actual_slots)??((Wn=e==null?void 0:e.provider)==null?void 0:Wn.total_slots)??0} · ctx ${((Gn=e==null?void 0:e.provider)==null?void 0:Gn.actual_ctx)??((Jn=e==null?void 0:e.provider)==null?void 0:Jn.ctx_per_slot)??0}</small>
          </div>
          <div class="monitor-stat-card ${L(f.length>0||u>0?"warn":"ok")}">
            <span>Pressure</span>
            <strong>${f.length+u+p.length}</strong>
            <small>blockers ${f.length} · approvals ${u} · confirms ${p.length}</small>
          </div>
          <div class="monitor-stat-card">
            <span>Last signal</span>
            <strong>${V(T)}</strong>
            <small>${S?"message":C?"trace":"waiting"}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${M} panelId="command.warroom" compact=${!0} />
            </div>
            ${G.length>0?i`
                  <${Mr} lanes=${G} />
                  <${Lr} lanes=${G} />
                `:a?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${L(Te(a.status))}">${da(a.status)}</span>
                      </div>
                      <p>command-plane live run은 아직 옅지만, session 쪽 worker와 digest를 기준으로 워룸을 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${an(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${an(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:i`<div class="empty-state">보이는 lane이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Worker Roster</div>
              <${M} panelId="command.warroom" compact=${!0} />
            </div>
            ${m.length>0?i`<div class="command-card-stack">
                  ${m.map(F=>i`<${nv} worker=${F} />`)}
                </div>`:i`<div class="empty-state">활성 worker 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Live Feed</div>
              <${M} panelId="command.warroom" compact=${!0} />
            </div>
            ${e&&e.recent_messages.length>0?i`<div class="command-trace-stack">
                  ${e.recent_messages.map(F=>i`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${F.from}</strong>
                          <span class="command-chip">${V(F.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${F.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${F.content}</pre>
                    </article>
                  `)}
                </div>`:h.length>0||x.length>0?i`<div class="command-card-stack">
                    ${h.slice(0,4).map(F=>i`
                      <article class="command-guide-card ${Qi(F)}">
                        <div class="command-guide-head">
                          <strong>${F.action_type}</strong>
                          <span class="command-chip ${Qi(F)}">${F.target_type}</span>
                        </div>
                        <p>${F.reason}</p>
                      </article>
                    `)}
                    ${x.slice(0,3).map(F=>i`
                      <article class="command-alert ${L(F.severity)}">
                        <div class="command-card-head">
                          <strong>${F.kind}</strong>
                          <span class="command-chip ${L(F.severity)}">${F.severity}</span>
                        </div>
                        <p>${F.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?i`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((F,he)=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>session-event-${he+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${Sr(F)}</pre>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">메시지나 attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Trace Feed</div>
              <${M} panelId="command.trace" compact=${!0} />
            </div>
            ${e&&e.recent_trace_events.length>0?i`<div class="command-trace-stack">
                  ${e.recent_trace_events.map(F=>i`<${Si} event=${F} />`)}
                </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Pressure</div>
              <${M} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${f.length>0?f.map(F=>i`<${Dr} blocker=${F} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${u>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending approvals</strong>
                        <span class="command-chip warn">${u}</span>
                      </div>
                      <p>strict action이 묶여 있습니다. 실제 승인 처리는 control 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${p.length>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending confirms</strong>
                        <span class="command-chip warn">${p.length}</span>
                      </div>
                      <p>operator preview가 사람 확인을 기다리고 있습니다.</p>
                      <div class="command-tag-row">
                        ${p.slice(0,3).map(F=>i`<span class="command-tag">${F.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
            </div>
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Focus Detail</div>
              <${M} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${e!=null&&e.operation?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${e.operation.objective}</strong>
                          <div class="command-card-sub">${e.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${L(Te(e.operation.status))}">${e.operation.status}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Unit</span><span>${e.operation.assigned_unit_id}</span>
                        <span>Trace</span><span>${e.operation.trace_id}</span>
                        <span>Autonomy</span><span>${e.operation.autonomy_level??"n/a"}</span>
                        <span>Updated</span><span>${V(e.operation.updated_at)}</span>
                      </div>
                    </article>
                  `:null}
              ${e!=null&&e.detachment?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${e.detachment.detachment_id}</strong>
                          <div class="command-card-sub">${e.detachment.assigned_unit_id}</div>
                        </div>
                        <span class="command-chip ${L(Te(e.detachment.status))}">${e.detachment.status??"active"}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Leader</span><span>${e.detachment.leader_id??"unassigned"}</span>
                        <span>Roster</span><span>${e.detachment.roster.length}</span>
                        <span>Session</span><span>${e.detachment.session_id??"none"}</span>
                        <span>Heartbeat</span><span>${Ar(e.detachment.heartbeat_deadline)}</span>
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
                        <span class="command-chip ${L(Te(a.status))}">${da(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${an(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${an(a.remaining_sec)}</span>
                        <span>Done delta</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function av({source:t}){const e=nl(null),[n,s]=fo(null);return nt(()=>{let a=!1;const o=e.current;return o?(o.innerHTML="",s(null),(async()=>{try{const d=await mm(),{svg:m}=await d.render(`command-chain-${pm()}`,t);if(a||!e.current)return;e.current.innerHTML=m}catch(d){if(a)return;s(d instanceof Error?d.message:"Mermaid render failed")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function iv({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return i`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${Qt(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?i`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?i`<span class="command-tag ${Qt(s==null?void 0:s.status)}">${Kn(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${Cr(t.history)}</div>
    </button>
  `}function ov({item:t}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${Qt(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${V(t.timestamp)}</div>
      <div class="command-card-sub">${Cr(t)}</div>
    </article>
  `}function rv({node:t}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${Qt(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?i`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function lv({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,o=e.chain,l=(o==null?void 0:o.run_id)??null;return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${L(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Autonomy</span><span>${e.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${e.budget_class??"standard"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Updated</span><span>${V(e.updated_at)}</span>
      </div>
      ${o?i`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${Qt(o.status)}">${o.status}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">run ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?i`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{ve("swarm"),dt("command",{surface:"swarm",operation_id:e.operation_id,...l?{run_id:l}:{}})}}
        >
          Swarm Live
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{bi(e.operation_id),ve("chains"),dt("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?i`
              <button class="control-btn ghost" disabled=${at(n)} onClick=${()=>Xt(()=>Zp(e.operation_id))}>
                ${at(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${at(a)} onClick=${()=>Xt(()=>em(e.operation_id))}>
                ${at(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?i`
              <button class="control-btn ghost" disabled=${at(s)} onClick=${()=>Xt(()=>tm(e.operation_id))}>
                ${at(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function cv({card:t}){var n;const e=t.detachment;return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${L(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${V(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Ar(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${V(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?i`<span class="command-tag ${dm(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function dv(){const t=Dt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${M} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?i`<div class="command-card-stack">
              ${t.operations.operations.map(e=>i`<${lv} card=${e} />`)}
            </div>`:i`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${M} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>i`<${cv} card=${e} />`)}
            </div>`:i`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function uv(){var d,m,v,u,p,f,h,x,S,C,T,w,A,R,P,G;const t=qn.value,e=(t==null?void 0:t.operations)??[],n=ze.value,s=e.find(H=>H.operation.operation_id===n)??e[0]??null,a=((d=s==null?void 0:s.operation.chain)==null?void 0:d.run_id)??null,o=((m=Cn.value)==null?void 0:m.run)??(s==null?void 0:s.preview_run)??null,l=!((v=Cn.value)!=null&&v.run)&&!!(s!=null&&s.preview_run);return nt(()=>{a?Qp(a):Yp()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${M} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${Qt(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${Qt(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(t==null?void 0:t.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((u=t==null?void 0:t.summary)==null?void 0:u.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((p=t==null?void 0:t.summary)==null?void 0:p.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((f=t==null?void 0:t.summary)==null?void 0:f.recent_failures)??0}</span>
            <span>Last Event</span><span>${V((h=t==null?void 0:t.summary)==null?void 0:h.last_history_event_at)}</span>
          </div>
        </article>

        ${Es.value?i`<div class="empty-state error">${Es.value}</div>`:null}

        ${Ya.value&&!t?i`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?i`
                <div class="command-chain-list">
                  ${e.map(H=>i`
                    <${iv}
                      overlay=${H}
                      selected=${(s==null?void 0:s.operation.operation_id)===H.operation.operation_id}
                      onSelect=${()=>bi(H.operation.operation_id)}
                    />
                  `)}
                </div>
              `:i`<div class="empty-state">No chain-backed operations yet.</div>`}

        <div class="command-chain-history">
          <div class="command-guide-head">
            <strong>Recent history</strong>
            <span class="command-chip">${(t==null?void 0:t.recent_history.length)??0}</span>
          </div>
          ${t&&t.recent_history.length>0?i`
                <div class="command-card-stack">
                  ${t.recent_history.slice(0,6).map(H=>i`<${ov} item=${H} />`)}
                </div>
              `:i`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chain Detail</div>
          <${M} panelId="command.chains" compact=${!0} />
        </div>
        ${s?i`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${Qt((x=s.operation.chain)==null?void 0:x.status)}">
                    ${((S=s.operation.chain)==null?void 0:S.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((C=s.operation.chain)==null?void 0:C.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((T=s.operation.chain)==null?void 0:T.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${Kn((w=s.runtime)==null?void 0:w.progress)}</span>
                  <span>Elapsed</span><span>${an((A=s.runtime)==null?void 0:A.elapsed_sec)}</span>
                  <span>Updated</span><span>${V(((R=s.operation.chain)==null?void 0:R.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(P=s.operation.chain)!=null&&P.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((G=s.operation.chain)==null?void 0:G.chain_id)??"graph"}</span>
                      </div>
                      <${av} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"failed":l?"preview":"captured":"pending"}
                  </span>
                </div>
                ${js.value?i`<div class="empty-state">Loading run detail…</div>`:wn.value?i`<div class="empty-state error">${wn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${o.chain_id}</span>
                            <span>Run</span><span>${o.run_id??"preview only"}</span>
                            <span>Duration</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${o.nodes.length}</span>
                          </div>
                          ${l?i`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(H=>i`<${rv} node=${H} />`)}
                          </div>
                        `:i`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:i`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function pv({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return i`
    <article class="command-card ${L(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${L(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${V(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!s?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${at(e)} onClick=${()=>Xt(()=>sm(t.decision_id))}>
                ${at(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${at(n)} onClick=${()=>Xt(()=>am(t.decision_id))}>
                ${at(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function mv({row:t}){var d,m,v;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((d=e.policy)!=null&&d.frozen),o=!!((m=e.policy)!=null&&m.kill_switch),l=Math.round((t.utilization??0)*100);return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${L(l>100?"bad":l>70?"warn":"ok")}">${l}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>Headcount Cap</span><span>${t.headcount_cap??0}</span>
        <span>Ops</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${((v=e.policy)==null?void 0:v.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${a?"yes":"no"}</span>
        <span>Kill Switch</span><span>${o?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${at(n)} onClick=${()=>Xt(()=>im(e.unit_id,!a))}>
          ${at(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${at(s)} onClick=${()=>Xt(()=>om(e.unit_id,!o))}>
          ${at(s)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function vv(){const t=Dt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${M} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>i`<${pv} decision=${e} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${M} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>i`<${mv} row=${e} />`)}
            </div>`:i`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function _v(){return i`
    <div class="command-surface-tabs grouped">
      ${_m.map(t=>i`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${wr.filter(e=>e.group===t.id).map(e=>i`
                <button
                  class="command-surface-tab ${U.value===e.id?"active":""}"
                  onClick=${()=>{ve(e.id),dt("command",Tr(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function fv(){if(U.value==="warroom")return i`<${sv} />`;if(U.value==="summary")return i`<${Om} />`;if(U.value==="swarm")return i`<${Zm} />`;if(!Dt.value)return i`<${Fm} />`;switch(U.value){case"chains":return i`<${uv} />`;case"topology":return i`<${Km} />`;case"alerts":return i`<${Um} />`;case"trace":return i`<${Bm} />`;case"control":return i`<${vv} />`;case"operations":default:return i`<${dv} />`}}function gv(){return nt(()=>{Vt(),Yt(),Xp(),wt()},[]),nt(()=>{if(E.value.tab!=="command")return;const t=E.value.params.surface,e=E.value.params.operation,n=On(E.value);if(Yi(t))ve(t);else if(n){const s=sr(n);Yi(s)&&ve(s)}else t||ve("warroom");e&&bi(e),(t==="swarm"||t==="warroom"||U.value==="warroom")&&wt(),(t==="warroom"||U.value==="warroom")&&st()},[E.value.tab,E.value.params.surface,E.value.params.operation,E.value.params.operation_id,E.value.params.run_id,E.value.params.source,E.value.params.action_type,E.value.params.target_type,E.value.params.target_id,E.value.params.focus_kind]),nt(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,Vt(),Yt(),(U.value==="swarm"||U.value==="warroom")&&wt(),U.value==="warroom"&&st()},250))},n=new EventSource(ym()),s=gm.map(a=>{const o=()=>e();return n.addEventListener(a,o),{type:a,handler:o}});return n.onerror=()=>{e()},()=>{s.forEach(({type:a,handler:o})=>{n.removeEventListener(a,o)}),n.close(),t&&window.clearTimeout(t)}},[]),nt(()=>{const t=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const e=U.value;e!=="swarm"&&e!=="warroom"||(Vt(),wt(),e==="warroom"&&st())},5e3);return()=>{window.clearInterval(t)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Xt(()=>nm())}}
            disabled=${at("dispatch:tick")}
          >
            ${at("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Vt(),Yt(),wt(),U.value==="warroom"&&st()}}
            disabled=${Is.value}
          >
            ${Is.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Ps.value?i`<div class="empty-state error">${Ps.value}</div>`:null}
      ${Ls.value?i`<div class="empty-state error">${Ls.value}</div>`:null}
      <${ft} surfaceId="command" />
      <${Mm} />
      ${U.value==="warroom"?null:i`<${Dm} />`}
      <${_v} />
      <${fv} />
    </section>
  `}const zr="masc_dashboard_agent_name";function $v(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(zr))==null?void 0:s.trim())||"dashboard"}const ea=g($v()),Ee=g(""),Qa=g("운영 점검"),je=g(""),Tn=g(""),In=g("2"),Rn=g(""),Tt=g("note"),Pn=g(""),Nn=g(""),Ln=g(""),Mn=g("2"),Os=g("운영자 중지 요청"),Fs=g(""),Oe=g(""),Zn=g(null);function hv(t){const e=t.trim()||"dashboard";ea.value=e,localStorage.setItem(zr,e)}function Xi(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function yv(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function He(t){return typeof t=="string"?t.trim().toLowerCase():""}function bv(t){var s;const e=He(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=He((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function ua(t){const e=He(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function Zi(t){return t.some(e=>He(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function kv(t){return t.target_type==="team_session"}function xv(t){return t.target_type==="keeper"}function ts(t){switch(t){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";case"keeper_msg":return"keeper 메시지";default:return(t==null?void 0:t.trim())||"액션"}}function es(t){switch(t){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";default:return(t==null?void 0:t.trim())||"target"}}function en(t){switch(He(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function to(t){return t?"확인 후 실행":"즉시 실행"}function Sv(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";default:return t}}function ct(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function Av(t){if(t.action_type==="team_task_inject")return"task";if(t.action_type==="team_broadcast")return"broadcast";if(t.action_type==="team_note")return"note";if(t.action_type==="team_turn"){const e=ct(t.suggested_payload,"turn_kind");if(e==="broadcast"||e==="task")return e}return"note"}function Cv(t){const e=t.suggested_payload;if(t.target_type==="room"){if(t.action_type==="broadcast"){Ee.value=ct(e,"message")??t.summary;return}t.action_type==="task_inject"&&(je.value=ct(e,"title")??"운영자 주입 작업",Tn.value=ct(e,"description")??t.summary,In.value=ct(e,"priority")??In.value);return}if(t.target_type==="team_session"){if(t.target_id&&(Rn.value=t.target_id),t.action_type==="team_stop"){Os.value=ct(e,"reason")??t.summary;return}Tt.value=Av(t);const n=ct(e,"message");n&&(Pn.value=n),Tt.value==="task"&&(Nn.value=ct(e,"task_title")??ct(e,"title")??"운영자 주입 작업",Ln.value=ct(e,"task_description")??ct(e,"description")??t.summary,Mn.value=ct(e,"task_priority")??ct(e,"priority")??Mn.value);return}t.target_type==="keeper"&&(t.target_id&&(Fs.value=t.target_id),Oe.value=ct(e,"message")??t.summary)}function wv(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function $e(t){const e=ea.value.trim()||"dashboard";try{const n=await iu({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?N("확인 대기열에 올렸습니다","warning"):N(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return N(s,"error"),null}}async function eo(){const t=Ee.value.trim();if(!t)return;await $e({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(Ee.value="")}async function Tv(){await $e({action_type:"room_pause",target_type:"room",payload:{reason:Qa.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function no(){await $e({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function Iv(){const t=je.value.trim();if(!t)return;await $e({action_type:"task_inject",target_type:"room",payload:{title:t,description:Tn.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(In.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(je.value="",Tn.value="")}async function Rv(){var l;const t=Nt.value,e=Rn.value||((l=t==null?void 0:t.sessions[0])==null?void 0:l.session_id)||"";if(!e){N("먼저 세션을 고르세요","warning");return}const n={},s=Pn.value.trim();s&&(n.message=s);let a="team_note";Tt.value==="broadcast"?a="team_broadcast":Tt.value==="task"&&(a="team_task_inject"),Tt.value==="task"&&(n.task_title=Nn.value.trim()||"운영자 주입 작업",n.task_description=Ln.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(Mn.value,10)||2),await $e({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Pn.value="",Tt.value==="task"&&(Nn.value="",Ln.value=""))}async function Pv(){var n;const t=Nt.value,e=Rn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){N("먼저 세션을 고르세요","warning");return}await $e({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Os.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function Nv(){var a;const t=Nt.value,e=Fs.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=Oe.value.trim();if(!e){N("먼저 keeper를 고르세요","warning");return}if(!n)return;await $e({action_type:"keeper_message",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`${e}에게 메시지를 보냈습니다`})&&(Oe.value="")}async function Lv(t){const e=ea.value.trim()||"dashboard";try{await ou(e,t),N("확인 실행을 완료했습니다","success")}catch(n){const s=n instanceof Error?n.message:"확인 실행에 실패했습니다";N(s,"error")}}function Mv(){var P,G,H;const t=Nt.value,e=E.value.tab==="intervene"?On(E.value):null,n=Wo.value,s=Lt.value,a=(t==null?void 0:t.room)??{},o=(t==null?void 0:t.sessions)??[],l=(t==null?void 0:t.keepers)??[],d=(t==null?void 0:t.pending_confirms)??[],m=(t==null?void 0:t.recent_messages)??[],v=(n==null?void 0:n.recommended_actions)??[],u=(t==null?void 0:t.available_actions)??[],p=o.find($=>$.session_id===Rn.value)??o[0]??null,f=l.find($=>$.name===Fs.value)??l[0]??null,h=(n==null?void 0:n.attention_items)??[],x=h.filter(kv),S=h.filter(xv),C=o.filter($=>bv($)!=="ok"),T=l.filter($=>ua($)!=="ok"),w=m.slice(0,5),A=wv(e,o,l);nt(()=>{qt()},[]),nt(()=>{if(E.value.tab!=="intervene"){Zn.value=null;return}if(!e){Zn.value=null;return}Zn.value!==e.id&&(Zn.value=e.id,Cv(e))},[E.value.tab,E.value.params.source,E.value.params.action_type,E.value.params.target_type,E.value.params.target_id,E.value.params.focus_kind,e==null?void 0:e.id]),nt(()=>{const $=(p==null?void 0:p.session_id)??null;Be($)},[p==null?void 0:p.session_id]);const R=[{key:"room",label:"Room 게이트",value:a.paused?"일시정지":"열림",detail:a.paused?`재개 전환 대기 중${a.pause_reason?` · ${a.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:a.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:d.length,detail:d.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:d.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:x.length>0?x.length:o.length,detail:x.length>0?((P=x[0])==null?void 0:P.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":o.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:x.length>0?Zi(x):o.length===0?"warn":C.some($=>He($.status)==="paused")?"bad":C.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:S.length>0?S.length:T.length,detail:S.length>0?((G=S[0])==null?void 0:G.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":T.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:S.length>0?Zi(S):T.some($=>ua($)==="bad")?"bad":T.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${ft} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">Intervene</div>
            <${M} panelId="intervene.action_studio" compact=${!0} />
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
            value=${ea.value}
            onInput=${$=>hv($.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{st(),qt(),Be((p==null?void 0:p.session_id)??null)}}
            disabled=${Sn.value||J.value}
          >
            ${Sn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${te.value?i`<section class="ops-banner error">${te.value}</section>`:null}
      ${Ue.value?i`<section class="ops-banner error">${Ue.value}</section>`:null}
      ${e?i`
        <section class="ops-banner ${A?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${Xs(e.action_type)}</span>
            <span>${fi(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?i`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${A?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const $=[];if(d.length>0&&$.push({label:`확인 대기 ${d.length}건 처리`,desc:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:"bad",onClick:()=>{const O=document.querySelector(".ops-pending-section");O==null||O.scrollIntoView({behavior:"smooth"})}}),a.paused&&$.push({label:"Room 재개",desc:`현재 일시정지 상태${a.pause_reason?` (${a.pause_reason})`:""}`,tone:"warn",onClick:()=>void no()}),T.length>0){const O=T.filter(Y=>ua(Y)==="bad");$.push({label:O.length>0?`Keeper ${O.length}개 오프라인`:`Keeper ${T.length}개 점검 필요`,desc:O.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:O.length>0?"bad":"warn",onClick:()=>{const Y=document.querySelector(".ops-keeper-section");Y==null||Y.scrollIntoView({behavior:"smooth"})}})}return $.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${$.slice(0,3).map(O=>i`
                <button class="ops-action-guide-item ${O.tone}" onClick=${O.onClick}>
                  <strong>${O.label}</strong>
                  <span>${O.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `})()}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${M} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 room인지, session인지, keeper인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${R.map($=>i`
            <div key=${$.key} class="ops-priority-card ${$.tone}">
              <span class="ops-priority-label">${$.label}</span>
              <strong>${$.value}</strong>
              <div class="ops-priority-detail">${$.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">Room 개입</div>
              <${M} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">전체 room에 영향 주는 액션입니다. 방송, 정지/재개, 작업 주입을 여기서 처리합니다.</p>

            <div class="ops-stat-grid">
              <div class="ops-stat">
                <span>Room</span>
                <strong>${a.current_room??a.room_id??"default"}</strong>
              </div>
              <div class="ops-stat">
                <span>프로젝트</span>
                <strong>${a.project??"확인 없음"}</strong>
              </div>
              <div class="ops-stat">
                <span>클러스터</span>
                <strong>${a.cluster??"확인 없음"}</strong>
              </div>
              <div class="ops-stat ${a.paused?"warn":"ok"}">
                <span>상태</span>
                <strong>${a.paused?"일시정지":"진행 중"}</strong>
              </div>
            </div>

            <label class="control-label" for="ops-broadcast">Room 방송</label>
            <div class="control-row">
              <input
                id="ops-broadcast"
                class="control-input"
                type="text"
                placeholder="@agent 또는 room 전체 공지"
                value=${Ee.value}
                onInput=${$=>{Ee.value=$.target.value}}
                onKeyDown=${$=>{$.key==="Enter"&&eo()}}
                disabled=${J.value}
              />
              <button class="control-btn" onClick=${()=>{eo()}} disabled=${J.value||Ee.value.trim()===""}>
                보내기
              </button>
            </div>

            <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
            <div class="control-row ops-split-row">
              <input
                id="ops-pause-reason"
                class="control-input"
                type="text"
                value=${Qa.value}
                onInput=${$=>{Qa.value=$.target.value}}
                disabled=${J.value}
              />
              <button class="control-btn ghost" onClick=${()=>{Tv()}} disabled=${J.value}>
                일시정지
              </button>
              <button class="control-btn ghost" onClick=${()=>{no()}} disabled=${J.value}>
                재개
              </button>
            </div>

            <div class="ops-section-head">작업 주입</div>
            <input
              class="control-input"
              type="text"
              placeholder="작업 제목"
              value=${je.value}
              onInput=${$=>{je.value=$.target.value}}
              disabled=${J.value}
            />
            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="작업 설명"
              value=${Tn.value}
              onInput=${$=>{Tn.value=$.target.value}}
              disabled=${J.value}
            ></textarea>
            <div class="control-row ops-split-row">
              <select
                class="control-input ops-select"
                value=${In.value}
                onChange=${$=>{In.value=$.target.value}}
                disabled=${J.value}
              >
                <option value="1">P1</option>
                <option value="2">P2</option>
                <option value="3">P3</option>
                <option value="4">P4</option>
                <option value="5">P5</option>
              </select>
              <button class="control-btn" onClick=${()=>{Iv()}} disabled=${J.value||je.value.trim()===""}>
                주입
              </button>
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">추천 개입</div>
              <${M} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
            ${An.value&&!n?i`
              <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
            `:v.length>0?i`
              <div class="ops-log-list">
                ${v.map($=>i`
                  <article key=${`${$.action_type}:${$.target_type}:${$.target_id??"room"}`} class="ops-log-entry ${$.severity}">
                    <div class="ops-log-head">
                      <strong>${ts($.action_type)}</strong>
                      <span>${es($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                      <span>${to($.confirm_required)}</span>
                    </div>
                    <div class="ops-log-body">${$.reason}</div>
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
              <${M} panelId="intervene.pending_confirmations" compact=${!0} />
            </div>
            <p class="ops-context-note">미리보기만 끝났고 아직 사람이 눌러줘야 하는 액션만 남깁니다.</p>
            ${d.length>0?i`
              <div class="ops-confirmation-list">
                ${d.map($=>i`
                  <article key=${$.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${ts($.action_type)}</strong>
                      <span>${es($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                      <span>${$.delegated_tool??"위임 도구 확인 필요"}</span>
                    </div>
                    ${$.preview?i`<pre class="ops-code-block compact">${Xi($.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{Lv($.confirm_token)}} disabled=${J.value}>
                        실행
                      </button>
                      <span class="ops-token">${$.confirm_token}</span>
                    </div>
                  </article>
                `)}
              </div>
            `:i`<div class="ops-empty">지금 승인 대기는 없습니다.</div>`}
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 Room 메시지</div>
              <${M} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
            ${w.length>0?i`
              <div class="ops-feed-list">
                ${w.map($=>i`
                  <article key=${$.seq??$.id??$.timestamp} class="ops-feed-item">
                    <div class="ops-feed-meta">
                      <strong>${$.from}</strong>
                      <span>${$.timestamp}</span>
                    </div>
                    <div class="ops-feed-content">${$.content}</div>
                  </article>
                `)}
              </div>
            `:i`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">Session 개입</div>
              <${M} panelId="intervene.session_queue" compact=${!0} />
            </div>
            <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

            <div class="ops-entity-list">
              ${o.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:o.map($=>{var O;return i`
                <button
                  key=${$.session_id}
                  class="ops-entity-card ${(p==null?void 0:p.session_id)===$.session_id?"active":""}"
                  onClick=${()=>{Rn.value=$.session_id}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${$.session_id}</strong>
                    <span class="status-badge ${$.status??"idle"}">${en($.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round($.progress_pct??0)}%</span>
                    <span>${$.done_delta_total??0}건 완료</span>
                    <span>${(O=$.team_health)!=null&&O.status?en(String($.team_health.status)):"상태 확인 필요"}</span>
                  </div>
                </button>
              `})}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">선택한 Session 요약</div>
              <${M} panelId="intervene.session_digest" compact=${!0} />
            </div>
            <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
            ${p&&s?i`
              <div class="ops-log-list">
                ${s.attention_items.length>0?s.attention_items.map($=>i`
                  <article key=${`${$.kind}:${$.target_id??"session"}`} class="ops-log-entry ${$.severity}">
                    <div class="ops-log-head">
                      <strong>${$.kind}</strong>
                      <span>${es($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                    </div>
                    <div class="ops-log-body">${$.summary}</div>
                  </article>
                `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
                ${s.worker_cards.length>0?s.worker_cards.map($=>i`
                  <article key=${`${$.actor??$.spawn_role??"worker"}:${$.spawn_agent??$.runtime_pool??"runtime"}`} class="ops-log-entry">
                    <div class="ops-log-head">
                      <strong>${$.actor??$.spawn_role??"worker"}</strong>
                      <span>${en($.status)}</span>
                      <span>${$.spawn_agent??$.runtime_pool??"runtime 확인 필요"}</span>
                    </div>
                    <div class="ops-log-body">
                      ${$.worker_class??"worker"}${$.lane_id?` · ${$.lane_id}`:""}${$.routing_reason?` · ${$.routing_reason}`:""}
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
              <${M} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>

            ${p?i`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${p.session_id}</div>
                <div class="ops-detail-meta">
                  <span>상태: ${en(p.status)}</span>
                  <span>경과: ${p.elapsed_sec??0}초</span>
                  <span>남은 시간: ${p.remaining_sec??0}초</span>
                </div>
                ${p.recent_events&&p.recent_events.length>0?i`
                  <pre class="ops-code-block compact">${Xi(p.recent_events.slice(-3))}</pre>
                `:null}
              </div>
            `:i`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

            <label class="control-label" for="ops-turn-kind">세션 액션</label>
            <div class="control-row ops-split-row">
              <select
                id="ops-turn-kind"
                class="control-input ops-select"
                value=${Tt.value}
                onChange=${$=>{Tt.value=$.target.value}}
                disabled=${J.value||!p}
              >
                <option value="note">노트</option>
                <option value="broadcast">방송</option>
                <option value="task">작업</option>
              </select>
              <button class="control-btn" onClick=${()=>{Rv()}} disabled=${J.value||!p}>
                적용
              </button>
            </div>
            <div class="ops-context-note">현재 선택: ${Sv(Tt.value)}</div>

            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="세션에 남길 메시지"
              value=${Pn.value}
              onInput=${$=>{Pn.value=$.target.value}}
              disabled=${J.value||!p}
            ></textarea>

            ${Tt.value==="task"?i`
              <input
                class="control-input"
                type="text"
                placeholder="주입할 작업 제목"
                value=${Nn.value}
                onInput=${$=>{Nn.value=$.target.value}}
                disabled=${J.value||!p}
              />
              <textarea
                class="control-textarea"
                rows=${2}
                placeholder="주입할 작업 설명"
                value=${Ln.value}
                onInput=${$=>{Ln.value=$.target.value}}
                disabled=${J.value||!p}
              ></textarea>
              <select
                class="control-input ops-select"
                value=${Mn.value}
                onChange=${$=>{Mn.value=$.target.value}}
                disabled=${J.value||!p}
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
                value=${Os.value}
                onInput=${$=>{Os.value=$.target.value}}
                disabled=${J.value||!p}
              />
              <button class="control-btn ghost" onClick=${()=>{Pv()}} disabled=${J.value||!p}>
                세션 중지
              </button>
            </div>
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel ops-keeper-section">
            <div class="card-title-row">
              <div class="card-title">Keeper 개입</div>
              <${M} panelId="intervene.keeper_queue" compact=${!0} />
            </div>
            <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

            <div class="ops-entity-list">
              ${l.length===0?i`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:l.map($=>i`
                <button
                  key=${$.name}
                  class="ops-entity-card ${(f==null?void 0:f.name)===$.name?"active":""}"
                  onClick=${()=>{Fs.value=$.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${$.name}</strong>
                    <span class="status-badge ${$.status??"idle"}">${en($.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${$.model??"model 확인 필요"}</span>
                    <span>${typeof $.context_ratio=="number"?`${Math.round($.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                    <span>${yv($.last_turn_ago_s)}</span>
                  </div>
                </button>
              `)}
            </div>
          </section>

          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">선택한 Keeper 액션</div>
              <${M} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">선택한 keeper에만 직접 메시지를 보내서 probe, 수정, 재지시를 합니다.</p>

            ${f?i`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${f.name}</div>
                <div class="ops-detail-meta">
                  <span>자율성: ${f.autonomy_level??"확인 없음"}</span>
                  <span>세대: ${f.generation??0}</span>
                  <span>활성 목표: ${((H=f.active_goal_ids)==null?void 0:H.length)??0}</span>
                </div>
              </div>
            `:i`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

            <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
            <textarea
              id="ops-keeper-message"
              class="control-textarea"
              rows=${6}
              placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
              value=${Oe.value}
              onInput=${$=>{Oe.value=$.target.value}}
              disabled=${J.value||!f}
            ></textarea>
            <div class="control-row">
              <button class="control-btn" onClick=${()=>{Nv()}} disabled=${J.value||!f||Oe.value.trim()===""}>
                keeper에 보내기
              </button>
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">가능한 액션 목록</div>
              <${M} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
            <div class="ops-log-list">
              ${u.length?u.map($=>i`
                    <article key=${`${$.action_type}:${$.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${ts($.action_type)}</strong>
                        <span>${es($.target_type)}</span>
                        <span>${to($.confirm_required)}</span>
                      </div>
                      <div class="ops-log-body">${$.description??"설명이 아직 없습니다."}</div>
                    </article>
                  `):i`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 개입 로그</div>
              <${M} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <div class="ops-log-list">
              ${Cs.value.length===0?i`
                <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
              `:Cs.value.map($=>i`
                <article key=${$.id} class="ops-log-entry ${$.outcome}">
                  <div class="ops-log-head">
                    <strong>${ts($.action_type)}</strong>
                    <span>${$.target_label}</span>
                    <span>${$.at}</span>
                  </div>
                  <div class="ops-log-body">${$.message}</div>
                </article>
              `)}
            </div>
          </section>
        </div>
      </div>
    </section>
  `}function Dv({text:t}){if(!t)return null;const e=zv(t);return i`<div class="markdown-content">${e}</div>`}function zv(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],d=a.slice(l.length).trim(),m=[];for(s++;s<e.length&&!e[s].startsWith(l);)m.push(e[s]),s++;s++,n.push(i`<pre><code class=${d?`language-${d}`:""}>${m.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],d=a.trim().replace(/^<think>/,"").trim();for(d&&d!=="</think>"&&l.push(d),s++;s<e.length&&!e[s].includes("</think>");)l.push(e[s]),s++;if(s<e.length){const v=e[s].replace("</think>","").trim();v&&l.push(v),s++}const m=l.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${pa(m)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<e.length&&e[s].startsWith("> ");)l.push(e[s].slice(2)),s++;n.push(i`<blockquote>${pa(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<e.length;){const l=e[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;o.push(l),s++}o.length>0&&n.push(i`<p>${pa(o.join(`
`))}</p>`)}return n}function pa(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&e.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Er=[{id:"recent",label:"Latest"},{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],vs=g(null),_s=g([]),We=g(!1),me=g(null),un=g(""),pn=g(!1),Ie=g(!0),Ai=20,Se=g(Ai);function Ev(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const jv=g(Ev());function Ov(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function so(t){return t.updated_at!==t.created_at}function Fv(t){const e=`${t.title} ${t.author} ${t.tags.join(" ")} ${t.flair??""}`.toLowerCase();return/\b(test|smoke|harness|sandbox|dummy|sample|tmp|qa|e2e)\b/.test(e)||e.includes("테스트")||e.includes("실험")}function qv(t){const e=(t.hearth??"").toLowerCase();return t.visibility!=="internal"||!t.expires_at||!e?!1:!!(e.startsWith("mdal")||e.includes("harness"))}function jr(t){return Ie.value?t.filter(e=>qv(e)?!1:e.hearth||e.visibility||e.expires_at?!0:!Fv(e)):t}async function Ci(t){me.value=t,vs.value=null,_s.value=[],We.value=!0;try{const e=await Gl(t);if(me.value!==t)return;vs.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth:e.hearth,visibility:e.visibility,expires_at:e.expires_at,hearth_count:e.hearth_count},_s.value=e.comments??[]}catch{me.value===t&&(vs.value=null,_s.value=[])}finally{me.value===t&&(We.value=!1)}}async function ao(t){const e=un.value.trim();if(e){pn.value=!0;try{await Jl(t,jv.value,e),un.value="",N("Comment posted","success"),await Ci(t),Rt()}catch{N("Failed to post comment","error")}finally{pn.value=!1}}}function Kv(){const t=$n.value,e=Ie.value?"Hiding automation posts":"Show automation posts";return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Er.map(n=>i`
          <button
            class="board-sort-btn ${t===n.id?"active":""}"
            onClick=${()=>{$n.value=n.id,Se.value=Ai,Rt()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Ie.value?"is-active":""}"
          onClick=${()=>{Ie.value=!Ie.value}}
        >
          ${e}
        </button>
        <button
          class="control-btn ghost ${Ce.value?"is-active":""}"
          onClick=${()=>{Ce.value=!Ce.value,Rt()}}
        >
          ${Ce.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${Rt} disabled=${hn.value}>
          ${hn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function ma(){var s;const t=((s=Er.find(a=>a.id===$n.value))==null?void 0:s.label)??$n.value,e=jr(gn.value),n=gn.value.length-e.length;return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Visible posts</span>
        <strong>${e.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Sort</span>
        <strong>${t}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise filter</span>
        <strong>${Ie.value?`automation ${n} hidden`:"full feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${Ce.value?"Auto reports hidden":"Full memory feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Ha.value?i`<${tt} timestamp=${Ha.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Uv({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await To(t.id,n),Rt()}catch{N("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>rl(t.id)}>
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
                ${so(t)?i`<span class="board-meta-chip">Updated</span>`:null}
                ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${tt} timestamp=${t.created_at} /></span>
            ${so(t)?i`<span>Updated <${tt} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${Ov(t.content)}</div>
      </div>
    </div>
  `}function Bv({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${tt} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Hv({postId:t}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${un.value}
        onInput=${e=>{un.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&ao(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${pn.value}
      />
      <button
        onClick=${()=>ao(t)}
        disabled=${pn.value||un.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${pn.value?"...":"Post"}
      </button>
    </div>
  `}function Wv({post:t}){me.value!==t.id&&!We.value&&Ci(t.id);const e=async n=>{try{await To(t.id,n),Rt()}catch{N("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>dt("memory")}>← Back to Memory</button>
      <${I} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${Dv} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${t.author}</span>
            <${tt} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
          </div>
          ${t.hearth||t.visibility||t.expires_at?i`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                  ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
                  ${t.expires_at?i`<span class="board-meta-chip">expires <${tt} timestamp=${t.expires_at} /></span>`:null}
                </div>
              `:null}
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${I} title="Comments" semanticId="memory.feed">
        ${We.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${Bv} comments=${_s.value} />`}
        <${Hv} postId=${t.id} />
      <//>
    </div>
  `}function Gv(){const t=jr(gn.value),e=E.value.params.post??null,n=e?t.find(s=>s.id===e)??(me.value===e?vs.value:null):null;return e&&!n&&me.value!==e&&!We.value&&Ci(e),e?n?i`
          <${ft} surfaceId="memory" />
          <${ma} />
          <${Wv} post=${n} />
        `:i`
          <div>
            <${ft} surfaceId="memory" />
            <${ma} />
            <button class="back-btn" onClick=${()=>dt("memory")}>← Back to Memory</button>
            ${We.value?i`<div class="loading-indicator">Loading post...</div>`:i`<div class="empty-state">Post not found</div>`}
          </div>
        `:i`
    <div>
      <${ft} surfaceId="memory" />
      <${ma} />
      <${Kv} />
      ${hn.value?i`<div class="loading-indicator">Loading memory feed...</div>`:t.length===0?i`<div class="empty-state">No posts in durable memory right now</div>`:i`
              <${I} title="Posts / Comments" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.slice(0,Se.value).map(s=>i`<${Uv} key=${s.id} post=${s} />`)}
                </div>
                ${t.length>Se.value?i`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{Se.value=Se.value+Ai}}
                    >
                      Show more (${t.length-Se.value} remaining)
                    </button>
                  </div>
                `:null}
              <//>
            `}
    </div>
  `}function Or({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,o=2*Math.PI*s,l=o*((100-t*100)/100);let d="mitosis-safe";return t>=.8?d="mitosis-critical":t>=.5&&(d="mitosis-warn"),i`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${d}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${o}" 
          stroke-dashoffset="${l}" 
        />
      </svg>
      <span class="mitosis-text ${d}">${Math.round(t*100)}%</span>
    </div>
  `}const va=600*1e3,Jv=1200*1e3,io=.8;function Wt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ke(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Vv(t){switch(t){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function Yv(t){switch(t){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function Qv(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Xv(t){var e,n,s,a;return((n=(e=t.agent)==null?void 0:e.current_task)==null?void 0:n.trim())||((s=t.skill_primary)==null?void 0:s.trim())||((a=t.last_proactive_reason)==null?void 0:a.trim())||"현재 포커스 없음"}function Zv(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function t_(t){var m,v;const e=ci.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,s=n?Math.max(0,Date.now()-Wt(n)):Number.POSITIVE_INFINITY,a=!!((m=t.current_task)!=null&&m.trim())||e.activeAssignedCount>0;let o="watching",l="ok",d="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",l="bad",d=n?"Offline or inactive":"No recent presence"):s>Jv?(o="quiet",l="bad",d=a?"Working without a fresh signal":"No fresh agent signal"):a?(o="working",l=s>va?"warn":"ok",d=s>va?"Execution looks quiet for too long":"Task and live signal aligned"):s>va?(o="quiet",l="warn",d="Quiet but still reachable"):t.status==="idle"&&(o="watching",l="ok",d="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:l,focus:((v=t.current_task)==null?void 0:v.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:d}}function e_(t){const e=Yc.value.get(t.name)??"idle",n=Zc.value.has(t.name),s=t.context_ratio??0;let a="healthy",o="ok",l="하트비트와 컨텍스트 상태가 안정적입니다";return t.status==="offline"||n||e==="handoff-imminent"?(a="critical",o="bad",l=n?"하트비트 지연":e==="handoff-imminent"?"핸드오프 임박":"keeper 오프라인"):(e==="preparing"||e==="compacting"||s>=io)&&(a="warning",o="warn",l=s>=io?"컨텍스트 압력이 높습니다":e==="compacting"?"컴팩팅 진행 중":"핸드오프 준비 중"),{keeper:t,lifecycle:e,state:a,tone:o,focus:Xv(t),note:l}}function nn({label:t,value:e,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function n_({item:t}){const e=t.kind==="agent"?()=>Ke(t.agent.name):()=>vi(t.keeper);return i`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"에이전트":"keeper"}
        </span>
        ${t.timestamp?i`<span><${tt} timestamp=${t.timestamp} /></span>`:i`<span>신호 없음</span>`}
      </div>
    </button>
  `}function oo({row:t}){const{agent:e,motion:n}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Ke(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Or} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${ne} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${Vv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?i`<span>신호 <${tt} timestamp=${t.lastSignalAt} /></span>`:i`<span>최근 신호 없음</span>`}
        <span>${t.activeTaskCount>0?`활성 작업 ${t.activeTaskCount}개`:"활성 작업 없음"}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
        ${e.last_seen?i`<span>마지막 감지 <${tt} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?i`<div class="monitor-footnote">최근 상세: ${n.lastActivityText}</div>`:null}
    </button>
  `}function s_({row:t}){const{keeper:e}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>vi(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Or} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${ne} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Yv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?i`<span>하트비트 <${tt} timestamp=${e.last_heartbeat} /></span>`:i`<span>하트비트 없음</span>`}
        <span>${Zv(e)}</span>
        <span>라이프사이클 ${t.lifecycle}</span>
        <span>컨텍스트 ${Qv(e.context_ratio)}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?i`<div class="monitor-footnote">스킬 라우팅: ${e.skill_reason}</div>`:null}
    </button>
  `}function a_(){const t=[...yt.value].map(t_).sort((u,p)=>{const f=ke(p.tone)-ke(u.tone);if(f!==0)return f;const h=p.activeTaskCount-u.activeTaskCount;return h!==0?h:Wt(p.lastSignalAt)-Wt(u.lastSignalAt)}),e=[...Kt.value].map(e_).sort((u,p)=>{const f=ke(p.tone)-ke(u.tone);if(f!==0)return f;const h=(p.keeper.context_ratio??0)-(u.keeper.context_ratio??0);return h!==0?h:Wt(p.keeper.last_heartbeat)-Wt(u.keeper.last_heartbeat)}),n=t.filter(u=>u.state!=="offline"),s=t.filter(u=>u.state==="offline"),a=n.length,o=t.filter(u=>u.state==="working").length,l=t.filter(u=>u.lastSignalAt&&Date.now()-Wt(u.lastSignalAt)<=12e4).length,d=t.filter(u=>u.tone!=="ok"),m=e.filter(u=>u.tone!=="ok"),v=[...m.map(u=>({kind:"keeper",key:`keeper-${u.keeper.name}`,tone:u.tone,title:u.keeper.name,subtitle:`${u.note} · ${u.focus}`,timestamp:u.keeper.last_heartbeat??null,keeper:u.keeper})),...d.map(u=>({kind:"agent",key:`agent-${u.agent.name}`,tone:u.tone,title:u.agent.name,subtitle:`${u.note} · ${u.focus}`,timestamp:u.lastSignalAt,agent:u.agent}))].sort((u,p)=>{const f=ke(p.tone)-ke(u.tone);return f!==0?f:Wt(p.timestamp)-Wt(u.timestamp)}).slice(0,8);return i`
    <div class="agents-monitor">
      <${ft} surfaceId="execution" />
      <div class="stats-grid">
        <${nn} label="온라인 worker" value=${a} color="#4ade80" caption="활성 + 대기 실행 주체" />
        <${nn} label="지금 작업 중" value=${o} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${nn} label="신선한 신호" value=${l} color="#22d3ee" caption="최근 2분 이내 신호" />
        <${nn} label="worker 경고" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="실행 주체 경고" />
        <${nn} label="연속성 경고" value=${m.length} color=${m.length>0?"#fb7185":"#4ade80"} caption="keeper 연속성 경고" />
      </div>

      <${I} title="Execution Priorities" class="section" semanticId="execution.priority_queue">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">지금 실행 관점에서 먼저 봐야 할 대상</h2>
          <p class="monitor-subheadline">worker 드리프트와 keeper 연속성 위험은 여기서 함께 우선순위를 매기고, 아래 섹션에서 각각 따로 진단합니다.</p>
        </div>
        <div class="monitor-alert-list">
          ${v.length===0?i`<div class="empty-state">지금은 실행 경고가 없습니다</div>`:v.map(u=>i`<${n_} key=${u.key} item=${u} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${I} title="Workers" class="section" semanticId="execution.workers">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">단기 실행 모니터</h2>
            <p class="monitor-subheadline">현재 살아 있는 worker를 먼저 묶어서, 누가 일을 잃었는지 오프라인 이력보다 먼저 보이게 합니다.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?i`<div class="empty-state">보이는 활성 worker가 없습니다</div>`:n.map(u=>i`<${oo} key=${u.agent.name} row=${u} />`)}
          </div>
        <//>

        <${I} title="Continuity" class="section" semanticId="execution.continuity">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">장기 keeper 연속성</h2>
            <p class="monitor-subheadline">하트비트, 컨텍스트 압력, 핸드오프 상태를 worker 실행 드리프트와 분리해서 봅니다.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?i`<div class="empty-state">활성 keeper가 없습니다</div>`:e.map(u=>i`<${s_} key=${u.keeper.name} row=${u} />`)}
          </div>
        <//>

        <${I} title="Offline Workers" class="section" semanticId="execution.offline">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">라이브 루프에서 빠진 worker</h2>
            <p class="monitor-subheadline">오프라인 row를 분리해서, 활성 실행 모니터가 묻히지 않게 합니다.</p>
          </div>
          <div class="monitor-list">
            ${s.length===0?i`<div class="empty-state">지금은 오프라인 worker가 없습니다</div>`:s.map(u=>i`<${oo} key=${u.agent.name} row=${u} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const qs=g("all"),Ks=g("all"),Xa=g(new Set);function i_(t){const e=new Set(Xa.value);e.has(t)?e.delete(t):e.add(t),Xa.value=e}const Fr=ht(()=>{let t=Pe.value;return qs.value!=="all"&&(t=t.filter(e=>e.horizon===qs.value)),Ks.value!=="all"&&(t=t.filter(e=>e.status===Ks.value)),t}),o_=ht(()=>{const t={short:[],mid:[],long:[]};for(const e of Fr.value){const n=t[e.horizon];n&&n.push(e)}return t}),r_=ht(()=>{const t=Array.from(Mo.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function l_(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function wi(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function fs(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function c_(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function ro(t){return t.toFixed(4)}function lo(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function d_(t){switch(t){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function co(t,e){return(t.priority??4)-(e.priority??4)}function u_(t,e){const n=t.updated_at??t.created_at??"";return(e.updated_at??e.created_at??"").localeCompare(n)}function p_(t,e){return t.length<=e?t:t.slice(0,e)+"..."}function m_({goal:t}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${fs(t.horizon)}">
            ${wi(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${l_(t.priority)}</span>
          ${t.metric?i`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?i`<span class="goal-due">Due: <${tt} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?i`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${ne} status=${t.status} />
        <div class="goal-updated">
          <${tt} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function _a({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return i`
    <${I} title="${wi(t)} Goals (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${m_} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function v_(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>i`
          <button
            class="goal-filter-btn ${qs.value===t?"active":""}"
            onClick=${()=>{qs.value=t}}
          >
            ${t==="all"?"All":wi(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>i`
          <button
            class="goal-filter-btn ${Ks.value===t?"active":""}"
            onClick=${()=>{Ks.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function __(){const t=Pe.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return i`
    <div class="goal-summary">
      <div class="goal-summary-item">
        <div class="goal-summary-value">${t.length}</div>
        <div class="goal-summary-label">Total</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#4ade80">${e}</div>
        <div class="goal-summary-label">Active</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#888">${n}</div>
        <div class="goal-summary-label">Completed</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${fs("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${fs("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${fs("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function f_({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return i`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${ne} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${ro(t.baseline_metric)}</span>
          <span>Current ${ro(t.current_metric)}</span>
          <span class=${lo(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${lo(t)}
          </span>
          <span>Elapsed ${c_(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"No explicit target provided"}</div>
        ${t.stop_reason||t.error_message?i`
              <div class="planning-loop-footnote">
                ${t.error_message??t.stop_reason}
              </div>
            `:null}
        <div class="planning-loop-footnote">
          ${t.strict_mode?"Strict hard evidence":"Legacy"} · ${t.worker_engine??"unknown engine"} · ${n}
        </div>
        ${e?i`
              <div class="planning-loop-footnote">
                Latest iteration #${e.iteration}: ${e.changes||e.next_suggestion||"No narrative"}
              </div>
            `:i`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function fa({task:t}){const e=t.priority??4,n=e<=1?"p1":e===2?"p2":e===3?"p3":"p4",s=Xa.value.has(t.id),a=!!t.description;return i`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${d_(e)}</span>
        <div class="kanban-card-title">${t.title}</div>
      </div>
      ${a?i`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>i_(t.id)}
        >
          ${s?t.description:p_(t.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${t.created_at?i`<${tt} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function g_(){const{todo:t,inProgress:e,done:n}=zo.value,s=[...t].sort(co),a=[...e].sort(co),o=[...n].sort(u_);return i`
    <${I} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${s.length===0?i`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:s.map(l=>i`<${fa} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${a.length===0?i`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:a.map(l=>i`<${fa} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${o.length===0?i`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:o.slice(0,20).map(l=>i`<${fa} key=${l.id} task=${l} />`)}
          ${o.length>20?i`<div class="empty-state" style="opacity: 0.5;">...and ${o.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function $_(){const{todo:t,inProgress:e,done:n}=zo.value,s=t.length+e.length+n.length,a=[...t,...e].filter(u=>(u.priority??4)<=2).length,o=o_.value,l=r_.value,d=Pe.value.length>0,m=l.length>0,v=ri.value;return i`
    <div>
      <${ft} surfaceId="planning" />

      <!-- Step 1: Task-based stats grid -->
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Total tasks</div>
          <div class="stat-value">${s}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">TODO</div>
          <div class="stat-value" style="color:#e0e0e0">${t.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">In Progress</div>
          <div class="stat-value" style="color:#fbbf24">${e.length}</div>
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
          onClick=${()=>{yn(),qo()}}
          disabled=${rn.value||ln.value}
        >
          ${rn.value||ln.value?"Refreshing...":"Refresh planning data"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${g_} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${d}>
        <summary>
          Goal Pipeline
          <span class="monitor-pill">${Pe.value.length}</span>
        </summary>
        <div>
          ${d?i`
            <${__} />
            <${v_} />
            ${rn.value&&Pe.value.length===0?i`<div class="loading-indicator">Loading goals...</div>`:Fr.value.length===0?i`<div class="empty-state">No goals match the current filters</div>`:i`
                    <${_a} horizon="short" items=${o.short??[]} />
                    <${_a} horizon="mid" items=${o.mid??[]} />
                    <${_a} horizon="long" items=${o.long??[]} />
                  `}
          `:i`
            <div class="empty-state">
              No goals defined. Use <code>masc_goal_upsert</code> to create goals.
            </div>
          `}
        </div>
      </details>

      <!-- MDAL Loops in collapsible details -->
      <details class="overview-section-collapsible" open=${m}>
        <summary>
          MDAL Loops
          <span class="monitor-pill">${l.length}</span>
        </summary>
        <div>
          ${ln.value&&l.length===0?i`<div class="loading-indicator">Loading MDAL loops...</div>`:l.length===0&&(v==="error"||Ne.value)?i`<div class="empty-state">MDAL snapshot could not be loaded${Ne.value?`: ${Ne.value}`:""}. Check backend health.</div>`:l.length===0?i`<div class="empty-state">No active loops. Use <code>masc_mdal_start</code> to start a loop.</div>`:i`
                  <div class="planning-loop-list">
                    ${l.map(u=>i`<${f_} key=${u.loop_id} loop=${u} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const mn=g("debates"),Us=g([]),Bs=g([]),Hs=g(!1),vn=g(!1),Dn=g(""),_n=g(""),Ws=g(null),xt=g(null),Za=g(!1);async function na(){Hs.value=!0,Dn.value="";try{const t=await Il();Us.value=Array.isArray(t.debates)?t.debates:[],Bs.value=Array.isArray(t.sessions)?t.sessions:[]}catch(t){Dn.value=t instanceof Error?t.message:"Failed to load governance state"}finally{Hs.value=!1}}vd(na);async function uo(){const t=_n.value.trim();if(t){vn.value=!0;try{const e=await bc(t);_n.value="",N(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await na()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";N(n,"error")}finally{vn.value=!1}}}async function h_(t){Ws.value=t,xt.value=null,Za.value=!0;try{xt.value=await kc(t)}catch(e){Dn.value=e instanceof Error?e.message:"Failed to load debate detail"}finally{Za.value=!1}}function y_(){return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${Us.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Voting sessions</span>
        <strong>${Bs.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Active view</span>
        <strong>${mn.value==="debates"?"Debates":"Voting"}</strong>
      </div>
    </div>
  `}function b_({debate:t}){const e=Ws.value===t.id;return i`
    <button class="council-row ${e?"selected":""}" onClick=${()=>h_(t.id)}>
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Arguments: ${t.argument_count}</span>
          ${t.created_at?i`<span><${tt} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </button>
  `}function k_({session:t}){return i`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.created_at?i`<span><${tt} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function x_(){const t=mn.value;return i`
    <div class="overview-sub-tabs" style="margin-bottom:12px;">
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{mn.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{mn.value="voting"}}>Voting</button>
    </div>
  `}function S_(){return i`
    <div>
      <${I} title="Start Debate" class="section" semanticId="governance.debates">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${_n.value}
            onInput=${t=>{_n.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&uo()}}
            disabled=${vn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${uo}
            disabled=${vn.value||_n.value.trim()===""}
          >
            ${vn.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${na} disabled=${Hs.value}>
            ${Hs.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Dn.value?i`<div class="council-error">${Dn.value}</div>`:null}
      <//>

      <${I} title="Debates" class="section" semanticId="governance.debates">
        <div class="council-list">
          ${Us.value.length===0?i`<div class="empty-state">No debates yet</div>`:Us.value.map(t=>i`<${b_} key=${t.id} debate=${t} />`)}
        </div>
      <//>

      <${I} title=${Ws.value?`Debate Detail (${Ws.value})`:"Debate Detail"} class="section" semanticId="governance.debates">
        ${Za.value?i`<div class="loading-indicator">Loading debate detail...</div>`:xt.value?i`
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Status: ${xt.value.status}</span>
                  <span>Total arguments: ${xt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Support: ${xt.value.support_count}</span>
                  <span>Oppose: ${xt.value.oppose_count}</span>
                  <span>Neutral: ${xt.value.neutral_count}</span>
                </div>
                ${xt.value.summary_text?i`<pre class="council-detail">${xt.value.summary_text}</pre>`:null}
              `:i`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function A_(){return i`
    <${I} title="Voting Sessions" class="section" semanticId="governance.voting">
      <div class="council-list">
        ${Bs.value.length===0?i`<div class="empty-state">No active sessions</div>`:Bs.value.map(t=>i`<${k_} key=${t.id} session=${t} />`)}
      </div>
    <//>
  `}function C_(){return nt(()=>{na()},[]),i`
    <div>
      <${ft} surfaceId="governance" />
      <${y_} />
      <${x_} />
      ${mn.value==="debates"?i`<${S_} />`:i`<${A_} />`}
    </div>
  `}const Ae=g(""),ga=g("ability_check"),$a=g("10"),ha=g("12"),ns=g(""),ss=g("idle"),Gt=g(""),as=g("keeper-late"),ya=g("player"),ba=g(""),vt=g("idle"),ka=g(null),is=g(""),xa=g(""),Sa=g("player"),Aa=g(""),Ca=g(""),wa=g(""),fn=g("20"),Ta=g("20"),Ia=g(""),os=g("idle"),ti=g(null),qr=g("overview"),Ra=g("all"),Pa=g("all"),Na=g("all"),w_=12e4,sa=g(null),po=g(Date.now());function T_(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function I_(t,e){return e>0?Math.round(t/e*100):0}const R_={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},P_={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function rs(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function N_(t){const e=t.trim().toLowerCase();return R_[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function L_(t){const e=t.trim().toLowerCase();return P_[e]??"상황에 따라 선택되는 전술 액션입니다."}function pt(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function St(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function zn(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const M_=new Set(["str","dex","con","int","wis","cha"]);function D_(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!_(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const l=a.trim();if(l){if(typeof o=="number"&&Number.isFinite(o)){s[l]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const d=Number.parseFloat(o.trim());if(Number.isFinite(d)){s[l]=Math.max(0,Math.trunc(d));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function z_(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(fn.value.trim(),10);Number.isFinite(s)&&s>n&&(fn.value=String(n))}function ei(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function E_(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function j_(t){qr.value=t}function Kr(t){const e=sa.value;return e==null||e<=t}function O_(t){const e=sa.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Gs(){sa.value=null}function Ur(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function F_(t,e){Ur(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(sa.value=Date.now()+w_,N("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function gs(t){return Kr(t)?(N("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function ni(t,e,n){return Ur([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function q_({hp:t,max:e}){const n=I_(t,e),s=T_(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function K_({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function U_({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Br({actor:t}){var m,v,u,p;const e=(m=t.archetype)==null?void 0:m.trim(),n=(v=t.persona)==null?void 0:v.trim(),s=(u=t.portrait)==null?void 0:u.trim(),a=(p=t.background)==null?void 0:p.trim(),o=t.traits??[],l=t.skills??[],d=Object.entries(t.stats_raw??{}).filter(([f,h])=>Number.isFinite(h)).filter(([f])=>!M_.has(f.toLowerCase()));return i`
    <div class="trpg-actor">
      ${s?i`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${f=>{const h=f.target;h&&(h.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${ne} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${U_} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${q_} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${K_} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${rs(e)}</div>`:null}
      ${a?i`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${d.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${d.map(([f,h])=>i`
                <span class="trpg-custom-stat-chip">${rs(f)} ${h}</span>
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
                  <span class="trpg-annot-name">${rs(f)}</span>
                  <span class="trpg-annot-desc">${N_(f)}</span>
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
                  <span class="trpg-annot-name">${rs(f)}</span>
                  <span class="trpg-annot-desc">${L_(f)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function B_({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function Hr({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?i`<div class="empty-state" style="font-size:13px">${e}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${E_(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${ei(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${tt} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function H_({events:t}){const e="__none__",n=Ra.value,s=Pa.value,a=Na.value,o=Array.from(new Set(t.map(ei).map(p=>p.trim()).filter(p=>p!==""))).sort((p,f)=>p.localeCompare(f)),l=Array.from(new Set(t.map(p=>(p.type??"").trim()).filter(p=>p!==""))).sort((p,f)=>p.localeCompare(f)),d=t.some(p=>(p.type??"").trim()===""),m=Array.from(new Set(t.map(p=>(p.phase??"").trim()).filter(p=>p!==""))).sort((p,f)=>p.localeCompare(f)),v=t.some(p=>(p.phase??"").trim()===""),u=t.filter(p=>{if(n!=="all"&&ei(p)!==n)return!1;const f=(p.type??"").trim(),h=(p.phase??"").trim();if(s===e){if(f!=="")return!1}else if(s!=="all"&&f!==s)return!1;if(a===e){if(h!=="")return!1}else if(a!=="all"&&h!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${p=>{Ra.value=p.target.value}}>
          <option value="all">all</option>
          ${o.map(p=>i`<option value=${p}>${p}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${p=>{Pa.value=p.target.value}}>
          <option value="all">all</option>
          ${d?i`<option value=${e}>(none)</option>`:null}
          ${l.map(p=>i`<option value=${p}>${p}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${p=>{Na.value=p.target.value}}>
          <option value="all">all</option>
          ${v?i`<option value=${e}>(none)</option>`:null}
          ${m.map(p=>i`<option value=${p}>${p}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Ra.value="all",Pa.value="all",Na.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${u.length} / 전체 ${t.length}
      </span>
    </div>
    <${Hr} events=${u.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function W_({outcome:t}){if(!t)return null;const e=o=>{const l=o.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function Wr({state:t}){const e=t.history??[];return e.length===0?null:i`
    <div class="trpg-round-list">
      ${e.slice(-10).map(n=>i`
        <div class="trpg-round-item ${n.status}">
          <span>Session ${n.id.slice(0,8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${n.round} — ${n.status}
          </span>
        </div>
      `)}
    </div>
  `}function G_({state:t,nowMs:e}){var v;const n=jt.value||((v=t.session)==null?void 0:v.room)||"",s=ss.value,a=t.party??[];if(!a.find(u=>u.id===Ae.value)&&a.length>0){const u=a[0];u&&(Ae.value=u.id)}const l=async()=>{var p,f;if(!n){N("Room ID가 비어 있습니다.","error");return}if(!gs(e))return;const u=((p=t.current_round)==null?void 0:p.phase)??((f=t.session)==null?void 0:f.status)??"unknown";if(ni("라운드 실행",n,u)){ss.value="running";try{const h=await dc(n);ti.value=h,ss.value="ok";const x=_(h.summary)?h.summary:null,S=x?zn(x,"advanced",!1):!1,C=x?pt(x,"progress_reason",""):"";N(S?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${C?`: ${C}`:""}`,S?"success":"warning"),Pt()}catch(h){ti.value=null,ss.value="error";const x=h instanceof Error?h.message:"라운드 실행에 실패했습니다.";N(x,"error")}finally{Gs()}}},d=async()=>{var p,f;if(!n||!gs(e))return;const u=((p=t.current_round)==null?void 0:p.phase)??((f=t.session)==null?void 0:f.status)??"unknown";if(ni("턴 강제 진행",n,u))try{await mc(n),N("턴을 다음 단계로 이동했습니다.","success"),Pt()}catch{N("턴 이동에 실패했습니다.","error")}finally{Gs()}},m=async()=>{if(!n||!gs(e))return;const u=Ae.value.trim();if(!u){N("먼저 Actor를 선택하세요.","warning");return}const p=Number.parseInt($a.value,10),f=Number.parseInt(ha.value,10);if(Number.isNaN(p)||Number.isNaN(f)){N("stat/dc는 숫자여야 합니다.","warning");return}const h=Number.parseInt(ns.value,10),x=ns.value.trim()===""||Number.isNaN(h)?void 0:h;try{await pc({roomId:n,actorId:u,action:ga.value.trim()||"ability_check",statValue:p,dc:f,rawD20:x}),N("주사위 판정을 기록했습니다.","success"),Pt()}catch{N("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${u=>{jt.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Ae.value}
            onChange=${u=>{Ae.value=u.target.value}}
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
              value=${ga.value}
              onInput=${u=>{ga.value=u.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${$a.value}
              onInput=${u=>{$a.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${ha.value}
              onInput=${u=>{ha.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${ns.value}
              onInput=${u=>{ns.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&m()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${m}>Roll</button>
            <button
              class="trpg-run-btn recommend"
              onClick=${l}
              disabled=${s==="running"}
            >
              ${s==="running"?"실행 중...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${d}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${s!=="idle"?i`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function J_({state:t}){var a;const e=jt.value||((a=t.session)==null?void 0:a.room)||"",n=os.value,s=async()=>{if(!e){N("Room ID가 비어 있습니다.","warning");return}const o=is.value.trim(),l=xa.value.trim();if(!l&&!o){N("이름 또는 Actor ID를 입력하세요.","warning");return}const d=Number.parseInt(fn.value.trim(),10),m=Number.parseInt(Ta.value.trim(),10),v=Number.isFinite(m)?Math.max(1,m):20,u=Number.isFinite(d)?Math.max(0,Math.min(v,d)):v;let p={};try{p=D_(Ia.value)}catch(f){N(f instanceof Error?f.message:"능력치 JSON 오류","error");return}os.value="spawning";try{const f=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,h=await vc(e,{actor_id:o||void 0,name:l||void 0,role:Sa.value,idempotencyKey:f,portrait:Ca.value.trim()||void 0,background:wa.value.trim()||void 0,hp:u,max_hp:v,alive:u>0,stats:Object.keys(p).length>0?p:void 0}),x=typeof h.actor_id=="string"?h.actor_id.trim():"";if(!x)throw new Error("생성 응답에 actor_id가 없습니다.");const S=Aa.value.trim();S&&await _c(e,x,S),Ae.value=x,Gt.value=x,o||(is.value=""),os.value="ok",N(`Actor 생성 완료: ${x}`,"success"),await Pt()}catch(f){os.value="error",N(f instanceof Error?f.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${xa.value}
            onInput=${o=>{xa.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Sa.value}
            onChange=${o=>{Sa.value=o.target.value}}
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
            value=${Aa.value}
            onInput=${o=>{Aa.value=o.target.value}}
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
              value=${is.value}
              onInput=${o=>{is.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Ca.value}
              onInput=${o=>{Ca.value=o.target.value}}
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
              value=${fn.value}
              onInput=${o=>{fn.value=o.target.value}}
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
              value=${Ta.value}
              onInput=${o=>{const l=o.target.value;Ta.value=l,z_(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${wa.value}
              onInput=${o=>{wa.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Ia.value}
              onInput=${o=>{Ia.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function V_({state:t,nowMs:e}){var f;const n=jt.value||((f=t.session)==null?void 0:f.room)||"",s=t.join_gate,a=ka.value,o=_(a)?a:null,l=(t.party??[]).filter(h=>h.role!=="dm"),d=Gt.value.trim(),m=l.some(h=>h.id===d),v=m?d:d?"__manual__":"",u=async()=>{const h=Gt.value.trim(),x=as.value.trim();if(!n||!h){N("Room/Actor가 필요합니다.","warning");return}vt.value="checking";try{const S=await fc(n,h,x||void 0);ka.value=S,vt.value="ok",N("참가 가능 여부를 갱신했습니다.","success")}catch(S){vt.value="error";const C=S instanceof Error?S.message:"참가 가능 여부 확인에 실패했습니다.";N(C,"error")}},p=async()=>{var T,w;const h=Gt.value.trim(),x=as.value.trim(),S=ba.value.trim();if(!n||!h||!x){N("Room/Actor/Keeper가 필요합니다.","warning");return}if(!gs(e))return;const C=((T=t.current_round)==null?void 0:T.phase)??((w=t.session)==null?void 0:w.status)??"unknown";if(ni("Mid-Join 승인 요청",n,C)){vt.value="requesting";try{const A=await gc({room_id:n,actor_id:h,keeper_name:x,role:ya.value,...S?{name:S}:{}});ka.value=A;const R=_(A)?zn(A,"granted",!1):!1,P=_(A)?pt(A,"reason_code",""):"";R?N("Mid-Join이 승인되었습니다.","success"):N(`Mid-Join이 거절되었습니다${P?`: ${P}`:""}`,"warning"),vt.value=R?"ok":"error",Pt()}catch(A){vt.value="error";const R=A instanceof Error?A.message:"Mid-Join 요청에 실패했습니다.";N(R,"error")}finally{Gs()}}};return i`
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
            value=${v}
            onChange=${h=>{const x=h.target.value;if(x==="__manual__"){(m||!d)&&(Gt.value="");return}Gt.value=x}}
          >
            <option value="">Actor 선택</option>
            ${l.map(h=>i`
              <option value=${h.id}>${h.name} (${h.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${v==="__manual__"?i`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${Gt.value}
                onInput=${h=>{Gt.value=h.target.value}}
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
            value=${as.value}
            onInput=${h=>{as.value=h.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${ya.value}
            onChange=${h=>{ya.value=h.target.value}}
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
            value=${ba.value}
            onInput=${h=>{ba.value=h.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${u} disabled=${vt.value==="checking"||vt.value==="requesting"}>
              ${vt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${p} disabled=${vt.value==="checking"||vt.value==="requesting"}>
              ${vt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${zn(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${St(o,"effective_score",0)}/${St(o,"required_points",0)}</span>
            ${pt(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${pt(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Gr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Jr({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Vr(){const t=ti.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=_(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(_).slice(-8),o=t.canon_check,l=_(o)?o:null,d=l&&Array.isArray(l.warnings)?l.warnings.filter(P=>typeof P=="string").slice(0,3):[],m=l&&Array.isArray(l.violations)?l.violations.filter(P=>typeof P=="string").slice(0,3):[],v=n?zn(n,"advanced",!1):!1,u=n?pt(n,"progress_reason",""):"",p=n?pt(n,"progress_detail",""):"",f=n?St(n,"player_successes",0):0,h=n?St(n,"player_required_successes",0):0,x=n?zn(n,"dm_success",!1):!1,S=n?St(n,"timeouts",0):0,C=n?St(n,"unavailable",0):0,T=n?St(n,"reprompts",0):0,w=n?St(n,"npc_attacks",0):0,A=n?St(n,"keeper_timeout_sec",0):0,R=n?St(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${v?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${v?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${x?"DM ok":"DM stalled"} / players ${f}/${h}
          </span>
        </div>
        ${u?i`<div style="margin-top:4px; font-size:12px;">${u}</div>`:null}
        ${p?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${p}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${w}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${A||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${R}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(P=>{const G=pt(P,"status","unknown"),H=pt(P,"actor_id","-"),$=pt(P,"role","-"),O=pt(P,"reason",""),Y=pt(P,"action_type",""),K=pt(P,"reply","");return i`
                <div class="trpg-round-item ${G.includes("fallback")||G.includes("timeout")?"failed":"active"}">
                  <span>${H} (${$})</span>
                  <span style="margin-left:auto; font-size:11px;">${G}</span>
                  ${Y?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${Y}</div>`:null}
                  ${O?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${O}</div>`:null}
                  ${K?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${K.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${pt(l,"status","unknown")}</strong>
            </div>
            ${m.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${m.map(P=>i`<div>violation: ${P}</div>`)}
                </div>`:null}
            ${d.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${d.map(P=>i`<div>warning: ${P}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Y_({state:t,nowMs:e}){var l,d,m;const n=jt.value||((l=t.session)==null?void 0:l.room)||"",s=((d=t.current_round)==null?void 0:d.phase)??((m=t.session)==null?void 0:m.status)??"unknown",a=Kr(e),o=O_(e);return i`
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
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>F_(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{Gs(),N("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Q_({active:t}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>j_(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function X_({state:t}){const e=t.party??[],n=t.story_log??[];return i`
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
          <${Hr} events=${n.slice(-20)} />
        <//>

        ${t.map?i`
            <${I} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${B_} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${I} title="현재 라운드" semanticId="lab.trpg">
          <${Jr} state=${t} />
        <//>

        <${I} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${Gr} state=${t} />
        <//>

        <${I} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>i`<${Br} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?i`
            <${I} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${Wr} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Z_({state:t}){const e=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${I} title=${`이벤트 타임라인 (${e.length})`}>
          <${H_} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${I} title="최근 라운드 결과" semanticId="lab.trpg">
          <${Vr} />
        <//>

        <${I} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${Jr} state=${t} />
        <//>
      </div>
    </div>
  `}function tf({state:t,nowMs:e}){const n=t.party??[];return i`
    <div>
      <${Y_} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${I} title="조작 패널" semanticId="lab.trpg">
            <${G_} state=${t} nowMs=${e} />
          <//>

          <${I} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${J_} state=${t} />
          <//>

          <${I} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${V_} state=${t} nowMs=${e} />
          <//>

          <${I} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${Vr} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${I} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${Gr} state=${t} />
          <//>

          <${I} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${Br} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?i`
              <${I} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${Wr} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function ef(){var d,m,v,u,p;const t=Lo.value,e=Ba.value;if(nt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const f=window.setInterval(()=>{po.value=Date.now()},1e3);return()=>{window.clearInterval(f)}},[]),e&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Pt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,o=qr.value,l=po.value;return i`
    <div>
      <${ft} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${jt.value||((d=t.session)==null?void 0:d.room)||"-"} · phase: ${((m=t.current_round)==null?void 0:m.phase)??((v=t.session)==null?void 0:v.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Pt()}>새로고침</button>
      </div>

      <${W_} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((u=t.session)==null?void 0:u.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((p=t.current_round)==null?void 0:p.round_number)??0}</div>
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

      <${Q_} active=${o} />

      ${o==="overview"?i`<${X_} state=${t} />`:o==="timeline"?i`<${Z_} state=${t} />`:i`<${tf} state=${t} nowMs=${l} />`}
    </div>
  `}function nf(){return i`
    <div>
      <${ft} surfaceId="lab" />
      <${I} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${I} title="TRPG" class="section" semanticId="lab.trpg">
        <${ef} />
      <//>
    </div>
  `}const Js=g(new Set(["broadcast","tasks","keepers","system"]));function sf(t){const e=new Set(Js.value);e.has(t)?e.delete(t):e.add(t),Js.value=e}const Ti=g(null);function Yr(t){Ti.value=t}function af(t){return t.kind==="board"?"broadcast":t.kind==="tasks"?"tasks":t.kind==="keepers"?"keepers":"system"}const of=ht(()=>{const t=Js.value;return hs.value.filter(e=>t.has(af(e)))}),rf=12e4,lf=ht(()=>{const t=ci.value,e=Date.now();return yt.value.map(n=>{const s=n.name.trim().toLowerCase(),a=t.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?o=e-new Date(l).getTime()>rf?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),cf=ht(()=>{const t=ci.value;return yt.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle").map(e=>{const n=e.name.trim().toLowerCase(),s=t.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:e.name,emoji:e.emoji??"",koreanName:e.koreanName??null,currentTask:e.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((e,n)=>{const s={hot:0,normal:1,calm:2};return s[e.pressure]-s[n.pressure]})});function mo(t){return t.kind==="board"?"live-event-broadcast":t.kind==="tasks"?"live-event-task":t.kind==="keepers"?"live-event-keeper":"live-event-system"}function df(t){const e=t.eventType;return e==="broadcast"?"broadcast":e==="agent_joined"?"joined":e==="agent_left"?"left":e==="task_update"?"task":e==="board_post"?"post":e==="board_comment"?"comment":e==="keeper_heartbeat"?"heartbeat":e==="keeper_handoff"?"handoff":e==="keeper_compaction"?"compact":e==="keeper_guardrail"?"guardrail":t.kind==="board"?"board":t.kind==="tasks"?"task":t.kind==="keepers"?"keeper":"system"}function uf(t){switch(t){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function pf(){const t=lf.value,e=Ti.value;return t.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${t.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${uf(n.state)} ${e===n.name?"pulse-selected":""}"
          onClick=${()=>Yr(e===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const mf=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function vf(){const t=Js.value;return i`
    <div class="activity-filter-bar">
      ${mf.map(e=>i`
        <button
          key=${e.kind}
          class="activity-filter-btn ${e.cssClass} ${t.has(e.kind)?"active":""}"
          onClick=${()=>sf(e.kind)}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function _f(){const t=of.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${t.length} events</span>
      </div>
      <${vf} />
      <div class="activity-stream-list">
        ${t.length===0?i`<div class="activity-empty">No events matching filters</div>`:t.map((e,n)=>i`
            <div
              key=${`${e.timestamp}-${n}`}
              class="activity-item ${mo(e)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${mo(e)}">${df(e)}</span>
                <span class="activity-agent">${e.agent}</span>
                <span class="activity-time">${Uo(e.timestamp)}</span>
              </div>
              <div class="activity-item-text">${e.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function ff(t){switch(t){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function gf(t){switch(t){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function $f(){const t=cf.value,e=Ti.value;return i`
    <div class="focus-sidebar">
      <div class="focus-sidebar-head">
        <h3>Agents</h3>
        <span class="focus-count">${t.length} active</span>
      </div>
      <div class="focus-sidebar-list">
        ${t.length===0?i`<div class="focus-empty">No active agents</div>`:t.map(n=>i`
            <div
              key=${n.name}
              class="focus-agent-card ${e===n.name?"focus-agent-selected":""}"
              onClick=${()=>Yr(e===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?i`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${ff(n.pressure)}">
                  ${gf(n.pressure)}
                  ${n.assignedCount>0?i` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?i`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?i`<span class="focus-activity-text">${n.lastActivityText}</span>`:i`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?i`<${tt} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function hf(){const t=Zt.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>Live Monitor</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${t?"connected":"disconnected"}"></span>
            ${t?"Connected":"Offline"}
          </span>
          <span class="live-stat">${yt.value.length} agents</span>
          <span class="live-stat">${Vs.value} events</span>
        </div>
      </div>

      <${pf} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${_f} />
        </div>
        <div class="live-panel-side">
          <${$f} />
        </div>
      </div>
    </div>
  `}const vo=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],si=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"live",label:"Live",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}];function yf(){const t=Zt.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Vs.value} events</span>
    </div>
  `}function bf({currentTab:t,currentSectionLabel:e}){const n=Zt.value;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>Snapshot</h3>
        <${M} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${n?"ok":"bad"}">${n?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agents</span>
          <strong>${yt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keepers</span>
          <strong>${Kt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Tasks</span>
          <strong>${It.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Events</span>
          <strong>${Vs.value}</strong>
        </div>
      </div>
      <div class="rail-snapshot-copy">
        <span>Connection ${n?"healthy":"recovering"}</span>
        <span>${e} workspace active</span>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{jn(),Oo(),t==="command"&&(Vt(),Yt(),(U.value==="swarm"||U.value==="warroom")&&wt(),U.value==="warroom"&&st()),t==="mission"&&(ps(),bn()),t==="execution"&&Et(),t==="intervene"&&(st(),qt()),t==="memory"&&Rt(),t==="planning"&&yn(),t==="lab"&&Pt()}}
        >
          Refresh Now
        </button>
        <button class="rail-secondary-btn" onClick=${()=>dt("intervene")}>
          Open Intervene
        </button>
      </div>
    </section>
  `}function kf(){const t=Nt.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${M} panelId="side_rail.quick_actions" compact=${!0} />
        <span class="rail-section-chip ${e>0?"warn":"ok"}">${e>0?"확인 필요":"준비됨"}</span>
      </div>
      <div class="rail-snapshot-copy">
        <span>구조화된 개입은 전용 화면에서 처리합니다</span>
        <span>rail은 요약만, 실제 조작은 Intervene에서</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>확인 대기</span>
          <strong>${e}</strong>
        </div>
        <div class="rail-stat-card">
          <span>세션</span>
          <strong>${n}</strong>
        </div>
        <div class="rail-stat-card">
          <span>keepers</span>
          <strong>${s}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{st(),qt()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>dt("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function xf(){const t=E.value.tab,e=si.find(s=>s.id===t),n=vo.find(s=>s.id===(e==null?void 0:e.group));return i`
    <aside class="dashboard-rail">
      <${ft} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          <${M} panelId="side_rail.navigate" compact=${!0} />
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${vo.map(s=>i`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${si.filter(a=>a.group===s.id).map(a=>i`
                  <button
                    class="rail-tab-btn ${t===a.id?"active":""}"
                    onClick=${()=>dt(a.id)}
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
          <div class="rail-view-note-label">Current focus</div>
          <strong>${(e==null?void 0:e.label)??t}</strong>
          <p>${(e==null?void 0:e.description)??"Live operational view"}</p>
        </div>
      </section>

      <${bf} currentTab=${t} currentSectionLabel=${(n==null?void 0:n.label)??"Observe"} />
      <${kf} />
    </aside>
  `}function Sf(){switch(E.value.tab){case"mission":return i`<${Gi} />`;case"execution":return i`<${a_} />`;case"live":return i`<${hf} />`;case"memory":return i`<${Gv} />`;case"governance":return i`<${C_} />`;case"planning":return i`<${$_} />`;case"intervene":return i`<${Mv} />`;case"command":return i`<${gv} />`;case"lab":return i`<${nf} />`;default:return i`<${Gi} />`}}function Af(){nt(()=>{ll(),ko(),Fo(),Et(),Oo(),ps();const n=gd();return $d(),()=>{fl(),n(),hd()}},[]),nt(()=>{const n=setInterval(()=>{const s=E.value.tab;s==="command"?(Vt(),Yt(),(U.value==="swarm"||U.value==="warroom")&&wt(),U.value==="warroom"&&st()):s==="mission"?ps():s==="execution"?Et():s==="intervene"?(st(),qt()):s==="memory"?Rt():s==="planning"?yn():s==="lab"&&Pt()},15e3);return()=>{clearInterval(n)}},[]),nt(()=>{const n=E.value.tab;n==="command"&&(Vt(),Yt(),(U.value==="swarm"||U.value==="warroom")&&wt(),U.value==="warroom"&&st()),n==="mission"&&(ps(),bn()),n==="execution"&&Et(),n==="intervene"&&(st(),qt()),n==="memory"&&Rt(),n==="planning"&&yn(),n==="lab"&&Pt()},[E.value.tab]);const t=E.value.tab,e=si.find(n=>n.id===t);return i`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">${(e==null?void 0:e.description)??"Operator-first decision and execution console"}</p>
        </div>
        <div class="header-right">
          <${yf} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${xf} />
        <main class="dashboard-main">
          ${Ua.value&&!Zt.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${Sf} />`}
        </main>
      </div>

      <${Iu} />
      <${Vd} />
      <${Kd} />
    </div>
  `}const _o=document.getElementById("app");_o&&sl(i`<${Af} />`,_o);export{cm as _};
