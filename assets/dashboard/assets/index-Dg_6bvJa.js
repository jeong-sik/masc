var Ur=Object.defineProperty;var Hr=(t,e,n)=>e in t?Ur(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var ve=(t,e,n)=>Hr(t,typeof e!="symbol"?e+"":e,n);import{e as Wr,_ as Br,c as g,b as $t,y as Z,d as Za,A as Gr,G as Jr}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const l of o.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=Wr.bind(Br);const Vr=["mission","execution","live","memory","governance","planning","intervene","command","lab"],lo={tab:"mission",params:{},postId:null};function bi(t){return!!t&&Vr.includes(t)}function Ta(t){try{return decodeURIComponent(t)}catch{return t}}function Ia(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Yr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function co(t,e){if(t[0]==="chains"){const o={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(o.operation=Ta(t[2])),{tab:"command",params:o,postId:null}}if(t[0]==="lab"){const o={...e};return t[1]&&(o.surface=Ta(t[1])),{tab:"lab",params:o,postId:null}}const n=t[0],s=e.tab;return{tab:bi(n)?n:bi(s)?s:"mission",params:e,postId:null}}function cs(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return lo;const n=Ta(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const d=n.indexOf("?");d>=0&&(s=n.slice(0,d),a=n.slice(d+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=Ia(a),l=Yr(s);return co(l,o)}function Xr(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...lo,params:Ia(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Ia(e.replace(/^\?/,""));return co(s,a)}function uo(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const D=g(cs(window.location.hash));window.addEventListener("hashchange",()=>{D.value=cs(window.location.hash)});function lt(t,e){const n={tab:t,params:e??{}};window.location.hash=uo(n)}function Qr(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function Zr(){if(window.location.hash&&window.location.hash!=="#"){D.value=cs(window.location.hash);return}const t=Xr(window.location.pathname,window.location.search);if(t){D.value=t;const e=uo(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",D.value=cs(window.location.hash)}const ki="masc_dashboard_sse_session_id",tl=1e3,el=15e3,Jt=g(!1),Fs=g(0),po=g(null),ds=g([]);function nl(){let t=sessionStorage.getItem(ki);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(ki,t)),t}const sl=200;function al(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};ds.value=[a,...ds.value].slice(0,sl)}function Ra(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function xi(t,e){const n=Ra(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function ft(t,e,n,s,a={}){al(t,e,n,{eventType:s,...a})}let xt=null,xe=null,Pa=0;function mo(){xe&&(clearTimeout(xe),xe=null)}function il(){if(xe)return;Pa++;const t=Math.min(Pa,5),e=Math.min(el,tl*Math.pow(2,t));xe=setTimeout(()=>{xe=null,vo()},e)}function vo(){mo(),xt&&(xt.close(),xt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",nl());const a=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(a);xt=o,o.onopen=()=>{xt===o&&(Pa=0,Jt.value=!0)},o.onerror=()=>{xt===o&&(Jt.value=!1,o.close(),xt=null,il())},o.onmessage=l=>{try{const d=JSON.parse(l.data);Fs.value++,po.value=d,ol(d)}catch{}}}function ol(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":ft(n,"Joined","system","agent_joined");break;case"agent_left":ft(n,"Left","system","agent_left");break;case"broadcast":ft(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":ft(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":ft(n,xi("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Ra(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":ft(n,xi("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Ra(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":ft(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":ft(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":ft(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":ft(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:ft(n,e,"system","unknown")}}function rl(){mo(),xt&&(xt.close(),xt=null),Jt.value=!1}function u(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function r(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function c(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function E(t){return typeof t=="boolean"?t:void 0}function O(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Y(t,e=[]){if(Array.isArray(t))return t;if(!u(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Ne(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function _o(){return new URLSearchParams(window.location.search)}function fo(){const t=_o(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function go(){return{...fo(),"Content-Type":"application/json"}}const ll=15e3,ti=3e4,cl=6e4,Si=new Set([408,425,429,500,502,503,504]);class Tn extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);ve(this,"method");ve(this,"path");ve(this,"status");ve(this,"statusText");ve(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function ei(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const l=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Tn({method:l,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function dl(){var e,n;const t=_o();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function Q(t){const e=await ei(t,{headers:fo()},ll);if(!e.ok)throw new Tn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function ul(t){return new Promise(e=>setTimeout(e,t))}function pl(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function ml(t){if(t instanceof Tn)return t.timeout||typeof t.status=="number"&&Si.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=pl(t.message);return e!==null&&Si.has(e)}async function $o(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!ml(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${o}ms`,a),await ul(o),s+=1}}async function Pt(t,e,n,s=ti){const a=await ei(t,{method:"POST",headers:{...go(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Tn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function vl(t,e,n,s=ti){const a=await ei(t,{method:"POST",headers:{...go(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Tn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function _l(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function fl(t){var e,n,s,a,o,l,d;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const p=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(p)}return((d=(l=(o=t.result)==null?void 0:o.content)==null?void 0:l[0])==null?void 0:d.text)??""}async function Xt(t,e){const n=await vl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},cl),s=_l(n);return fl(s)}function gl(){return Q("/api/v1/dashboard/shell")}function $l(){return Q("/api/v1/dashboard/execution")}function hl(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),Q(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function yl(){return Q("/api/v1/dashboard/governance")}function bl(){return Q("/api/v1/dashboard/semantics")}function kl(){return Q("/api/v1/dashboard/mission")}function xl(t=!1){return Q(`/api/v1/dashboard/mission/briefing${t?"?force=1":""}`)}function Sl(){return Q("/api/v1/dashboard/planning")}function Al(){return Q("/api/v1/operator")}function ho(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return Q(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Cl(){return Q("/api/v1/command-plane")}function wl(){return Q("/api/v1/command-plane/summary")}function Tl(){return Q("/api/v1/chains/summary")}function Il(t){return Q(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Rl(){return Q("/api/v1/command-plane/help")}function Pl(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return Q(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function Nl(t,e){return Pt(t,e)}function Ll(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return ti}}function qs(t){return Pt("/api/v1/operator/action",t,void 0,Ll(t))}function Ml(t,e){return Pt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function Ve(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function Dl(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function El(t){if(!u(t))return null;const e=y(t.id,"").trim(),n=y(t.author,"").trim(),s=y(t.content,"").trim();if(!e||!n)return null;const a=U(t.score,0),o=U(t.votes_up,0),l=U(t.votes_down,0),d=U(t.votes,a||o-l),p=U(t.comment_count,U(t.reply_count,0)),_=(()=>{const x=t.flair;if(typeof x=="string"&&x.trim())return x.trim();if(u(x)){const w=y(x.name,"").trim();if(w)return w}return y(t.flair_name,"").trim()||void 0})(),m=y(t.created_at_iso,"").trim()||Ve(t.created_at),v=y(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Ve(t.updated_at):m),h=y(t.title,"").trim()||Dl(s),k=Array.isArray(t.tags)?t.tags.filter(x=>typeof x=="string"&&x.trim()!==""):[];return{id:e,author:n,title:h,content:s,tags:k,votes:d,vote_balance:a,comment_count:p,created_at:m,updated_at:v,flair:_,hearth:y(t.hearth,"").trim()||null,visibility:y(t.visibility,"").trim()||void 0,expires_at:y(t.expires_at_iso,"").trim()||(t.expires_at!==void 0&&t.expires_at!==0?Ve(t.expires_at):"")||null,hearth_count:U(t.hearth_count,0)}}function zl(t){if(!u(t))return null;const e=y(t.id,"").trim(),n=y(t.post_id,"").trim(),s=y(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:y(t.content,""),created_at:Ve(t.created_at)}}async function jl(t){return $o("fetchBoardPost",async()=>{const e=await Q(`/api/v1/board/${t}?format=flat`),n=u(e.post)?e.post:e,s=El(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},o=(Array.isArray(e.comments)?e.comments:[]).map(zl).filter(l=>l!==null);return{...s,comments:o}})}function yo(t,e){return Pt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:dl()})}function Ol(t,e,n){return Pt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Fl(t){const e=y(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function st(...t){for(const e of t){const n=y(e,"");if(n.trim())return n.trim()}return""}function Ai(t){const e=Fl(st(t.outcome,t.result,t.result_code));if(!e)return;const n=st(t.reason,t.reason_code,t.description,t.detail),s=st(t.summary,t.summary_ko,t.summary_en,t.note),a=st(t.details,t.details_text,t.text,t.note),o=st(t.winner,t.winner_name,t.actor_winner,t.winner_actor),l=st(t.winner_actor_id,t.winner_actor,t.actor_winner_id),d=st(t.raw_reason,t.raw_reason_code,t.error_message),p=(()=>{const v=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof v=="string"?[v]:Array.isArray(v)?v.map(f=>{if(typeof f=="string")return f.trim();if(u(f)){const h=y(f.summary,"").trim();if(h)return h;const k=y(f.text,"").trim();if(k)return k;const x=y(f.type,"").trim();return x||y(f.event_id,"").trim()}return""}).filter(f=>f.length>0):[]})(),_=(()=>{const v=U(t.turn,Number.NaN);if(Number.isFinite(v))return v;const f=U(t.turn_number,Number.NaN);if(Number.isFinite(f))return f;const h=U(t.current_turn,Number.NaN);if(Number.isFinite(h))return h;const k=U(t.round,Number.NaN);return Number.isFinite(k)?k:void 0})(),m=st(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:l||void 0,evidence:p.length>0?p:void 0,raw_reason:d||void 0,turn:_,phase:m||void 0}}function ql(t,e){const n=u(t.state)?t.state:{};if(y(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(l=>u(l)?y(l.type,"")==="session.outcome":!1),o=u(n.session_outcome)?n.session_outcome:{};if(u(o)&&Object.keys(o).length>0){const l=Ai(o);if(l)return l}if(u(a))return Ai(u(a.payload)?a.payload:{})}function y(t,e=""){return typeof t=="string"?t:e}function U(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Kl(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Na(t,e=!1){return typeof t=="boolean"?t:e}function Ke(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(u(e)){const n=y(e.name,"").trim(),s=y(e.id,"").trim(),a=y(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Ul(t){const e={};if(!u(t)&&!Array.isArray(t))return e;if(u(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),o=y(s,"").trim();!a||!o||(e[a]=o)}),e;for(const n of t){if(!u(n))continue;const s=st(n.to,n.target,n.actor_id,n.name,n.id),a=st(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function Hl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function ut(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const Wl=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Bl(t){const e=u(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const o=s.trim();o&&(Wl.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function Gl(t,e){if(t!=="dice.rolled")return;const n=U(e.raw_d20,0),s=U(e.total,0),a=U(e.bonus,0),o=y(e.action,"roll"),l=U(e.dc,0);return{notation:l>0?`${o} (DC ${l})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function Jl(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Vl(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Yl(t,e,n,s){const a=n||e||y(s.actor_id,"")||y(s.actor_name,"");switch(t){case"turn.action.proposed":{const o=y(s.proposed_action,y(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=y(s.reply,y(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return y(s.reply,y(s.content,y(s.text,"Narration")));case"dice.rolled":{const o=y(s.action,"roll"),l=U(s.total,0),d=U(s.dc,0),p=y(s.label,""),_=a||"actor",m=d>0?` vs DC ${d}`:"",v=p?` (${p})`:"";return`${_} ${o}: ${l}${m}${v}`}case"turn.started":return`Turn ${U(s.turn,1)} started`;case"phase.changed":return`Phase: ${y(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${y(s.name,u(s.actor)?y(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${y(s.keeper_name,y(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${y(s.keeper_name,y(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${U(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${U(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||y(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||y(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${y(s.reason_code,"unknown")}`;case"memory.signal":{const o=u(s.entity_refs)?s.entity_refs:{},l=y(o.requested_tier,""),d=y(o.effective_tier,""),p=Na(o.guardrail_applied,!1),_=y(s.summary_en,y(s.summary_ko,"Memory signal"));if(!l&&!d)return _;const m=l&&d?`${l}->${d}`:d||l;return`${_} [${m}${p?" (guardrail)":""}]`}case"world.event":{if(y(s.event_type,"")==="canon.check"){const l=y(s.status,"unknown"),d=y(s.contract_id,"n/a");return`Canon ${l}: ${d}`}return y(s.description,y(s.summary,"World event"))}case"combat.attack":return y(s.summary,y(s.result,"Attack resolved"));case"combat.defense":return y(s.summary,y(s.result,"Defense resolved"));case"session.outcome":return y(s.summary,y(s.outcome,"Session ended"));default:{const o=Jl(s);return o?`${t}: ${o}`:t}}}function Xl(t,e){const n=u(t)?t:{},s=y(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=y(n.actor_name,"").trim()||e[a]||y(u(n.payload)?n.payload.actor_name:"",""),l=u(n.payload)?n.payload:{},d=y(n.ts,y(n.timestamp,new Date().toISOString())),p=y(n.phase,y(l.phase,"")),_=y(n.category,"");return{type:s,actor:o||a||y(l.actor_name,""),actor_id:a||y(l.actor_id,""),actor_name:o,seq:n.seq,room_id:y(n.room_id,""),phase:p||void 0,category:_||Vl(s),visibility:y(n.visibility,y(l.visibility,"public")),event_id:y(n.event_id,""),content:Yl(s,a,o,l),dice_roll:Gl(s,l),timestamp:d}}function Ql(t,e,n){var z,G;const s=y(t.room_id,"")||n||"default",a=u(t.state)?t.state:{},o=u(a.party)?a.party:{},l=u(a.actor_control)?a.actor_control:{},d=u(a.join_gate)?a.join_gate:{},p=u(a.contribution_ledger)?a.contribution_ledger:{},_=Object.entries(o).map(([F,J])=>{const b=u(J)?J:{},ht=ut(b,"max_hp",void 0,10),Ot=ut(b,"hp",void 0,ht),te=ut(b,"max_mp",void 0,0),ee=ut(b,"mp",void 0,0),M=ut(b,"level",void 0,1),yt=ut(b,"xp",void 0,0),ne=Na(b.alive,Ot>0),Fe=l[F],qe=typeof Fe=="string"?Fe:void 0,En=Hl(b.role,F,qe),zn=Kl(b.generation),jn=st(b.joined_at,b.joinedAt,b.started_at,b.startedAt),On=st(b.claimed_at,b.claimedAt,b.assigned_at,b.assignedAt,b.assigned_time),j=st(b.last_seen,b.lastSeen,b.last_seen_at,b.lastSeenAt,b.last_active,b.lastActive),me=st(b.scene,b.current_scene,b.currentScene,b.world_scene,b.scene_name,b.sceneName),Kr=st(b.location,b.current_location,b.currentLocation,b.position,b.zone,b.area);return{id:F,name:y(b.name,F),role:En,keeper:qe,archetype:y(b.archetype,""),persona:y(b.persona,""),portrait:y(b.portrait,"")||void 0,background:y(b.background,"")||void 0,traits:Ke(b.traits),skills:Ke(b.skills),stats_raw:Bl(b),status:ne?"active":"dead",generation:zn,joined_at:jn||void 0,claimed_at:On||void 0,last_seen:j||void 0,scene:me||void 0,location:Kr||void 0,inventory:Ke(b.inventory),notes:Ke(b.notes),relationships:Ul(b.relationships),stats:{hp:Ot,max_hp:ht,mp:ee,max_mp:te,level:M,xp:yt,strength:ut(b,"strength","str",10),dexterity:ut(b,"dexterity","dex",10),constitution:ut(b,"constitution","con",10),intelligence:ut(b,"intelligence","int",10),wisdom:ut(b,"wisdom","wis",10),charisma:ut(b,"charisma","cha",10)}}}),m=_.filter(F=>F.status!=="dead"),v=ql(t,e),f={phase_open:Na(d.phase_open,!0),min_points:U(d.min_points,3),window:y(d.window,"round_boundary_only"),last_opened_turn:typeof d.last_opened_turn=="number"?d.last_opened_turn:null,last_closed_turn:typeof d.last_closed_turn=="number"?d.last_closed_turn:null},h=Object.entries(p).map(([F,J])=>{const b=u(J)?J:{};return{actor_id:F,score:U(b.score,0),last_reason:y(b.last_reason,"")||null,reasons:Ke(b.reasons)}}),k=_.reduce((F,J)=>(F[J.id]=J.name,F),{}),x=e.map(F=>Xl(F,k)),S=U(a.turn,1),w=y(a.phase,"round"),A=y(a.map,""),N=u(a.world)?a.world:{},T=A||y(N.ascii_map,y(N.map,"")),I=x.filter((F,J)=>{const b=e[J];if(!u(b))return!1;const ht=u(b.payload)?b.payload:{};return U(ht.turn,-1)===S}),H=(I.length>0?I:x).slice(-12),K=y(a.status,"active");return{session:{id:s,room:s,status:K==="ended"?"ended":K==="paused"?"paused":"active",round:S,actors:m,created_at:((z=x[0])==null?void 0:z.timestamp)??new Date().toISOString()},current_round:{round_number:S,phase:w,events:H,timestamp:((G=x[x.length-1])==null?void 0:G.timestamp)??new Date().toISOString()},map:T||void 0,join_gate:f,contribution_ledger:h,outcome:v,party:m,story_log:x,history:[]}}async function Zl(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await Q(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function tc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([Q(`/api/v1/trpg/state${e}`),Zl(t)]);return Ql(n,s,t)}function ec(t){return Pt("/api/v1/trpg/rounds/run",{room_id:t})}function nc(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function sc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Pt("/api/v1/trpg/dice/roll",e)}function ac(t,e){const n=nc();return Pt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function ic(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Pt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function oc(t,e,n){return Pt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function rc(t,e,n){const s=await Xt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function lc(t){const e=await Xt("trpg.mid_join.request",t);return JSON.parse(e)}async function cc(t,e){await Xt("masc_broadcast",{agent_name:t,message:e})}async function dc(t=40){return(await Xt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function uc(t,e=20){return Xt("masc_task_history",{task_id:t,limit:e})}async function pc(t){const e=await Xt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function mc(t){return $o("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await Q(`/api/v1/council/debates/${e}/summary`);if(!u(n))return null;const s=y(n.id,"").trim();return s?{id:s,topic:y(n.topic,""),status:y(n.status,"open"),support_count:U(n.support_count,0),oppose_count:U(n.oppose_count,0),neutral_count:U(n.neutral_count,0),total_arguments:U(n.total_arguments,0),created_at:Ve(n.created_at_iso??n.created_at),summary_text:y(n.summary_text,"")}:null})}function vc(t,e,n){return Xt("masc_keeper_msg",{name:t,message:e})}const _c=g(""),Dt=g({}),it=g({}),La=g({}),Ma=g({}),Da=g({}),Ea=g({}),Et=g({});function nt(t,e,n){t.value={...t.value,[e]:n}}function fc(t){var n;const e=(n=r(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function gc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Zs(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!u(s))continue;const a=r(s.name);if(!a)continue;const o=r(s[e]);e==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function $c(t){if(!u(t))return null;const e=r(t.name);return e?{name:e,trigger:r(t.trigger),outcome:r(t.outcome),summary:r(t.summary),reason:r(t.reason)}:null}function hc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function yc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function bo(t,e,n){return r(t)??yc(e,n)}function ko(t,e){return typeof t=="boolean"?t:e==="recover"}function us(t){if(!u(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:r(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:Ne(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:c(t.next_eligible_at_s)??null,recoverable:ko(t.recoverable,n),summary:bo(t.summary,e,r(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function xo(t){return u(t)?{hour:c(t.hour),checked:c(t.checked)??0,acted:c(t.acted)??0,acted_names:O(t.acted_names),activity_report:r(t.activity_report),quiet_hours_overridden:E(t.quiet_hours_overridden),skipped_reason:r(t.skipped_reason),acted_rows:Zs(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:Zs(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:Zs(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map($c).filter(e=>e!==null):[]}:null}function bc(t){return u(t)?{enabled:E(t.enabled)??!1,interval_s:c(t.interval_s)??0,quiet_start:c(t.quiet_start),quiet_end:c(t.quiet_end),quiet_active:E(t.quiet_active),use_planner:E(t.use_planner),delegate_llm:E(t.delegate_llm),agent_count:c(t.agent_count),agents:O(t.agents),last_tick_ago_s:c(t.last_tick_ago_s)??null,last_tick_ago:r(t.last_tick_ago),total_ticks:c(t.total_ticks),total_checkins:c(t.total_checkins),last_skip_reason:r(t.last_skip_reason)??null,last_tick_result:xo(t.last_tick_result),active_self_heartbeats:O(t.active_self_heartbeats)}:null}function kc(t){return u(t)?{status:t.status,diagnostic:us(t.diagnostic)}:null}function xc(t){return u(t)?{recovered:E(t.recovered)??!1,skipped_reason:r(t.skipped_reason)??null,before:us(t.before),after:us(t.after),down:t.down,up:t.up}:null}function Sc(t,e){var A,N;if(!(t!=null&&t.name))return null;const n=r((A=t.agent)==null?void 0:A.status)??r(t.status)??"unknown",s=r((N=t.agent)==null?void 0:N.error)??null,a=t.presence_keepalive??!0,o=t.keepalive_running??!1,l=t.turn_count??0,d=t.last_turn_ago_s??null,p=t.proactive_enabled??!1,_=t.proactive_cooldown_sec??0,m=t.last_proactive_ago_s??null,v=p&&m!=null?Math.max(0,_-m):null,f=l<=0||d==null?"never":d>900?"stale":"fresh",h=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,k=s??(a&&!o?"keeper keepalive is not running":null),x=n==="offline"||n==="inactive"?"offline":k?"degraded":f==="stale"?"stale":f==="never"?"idle":"healthy",S=k?hc(k):e!=null&&e.quiet_active&&f!=="fresh"?"quiet_hours":a&&!o?"disabled":l<=0?"never_started":v!=null&&v>0?"min_gap":f==="fresh"||f==="stale"?"no_recent_activity":"unknown",w=x==="offline"||x==="degraded"||x==="stale"?"recover":S==="quiet_hours"?"manual_lodge_poke":S==="unknown"?"probe":"direct_message";return{health_state:x,quiet_reason:S,next_action_path:w,last_reply_status:f,last_reply_at:h,last_reply_preview:null,last_error:k,next_eligible_at_s:v!=null&&v>0?v:null,recoverable:ko(void 0,w),summary:bo(void 0,x,S),keepalive_running:o}}function Ac(t,e){if(!u(t))return null;const n=fc(t.role),s=r(t.content)??r(t.preview);if(!s)return null;const a=Ne(t.ts_unix)??Ne(t.timestamp);return{id:`${n}-${a??"entry"}-${e}`,role:n,label:gc(n),text:s,timestamp:a,delivery:"history"}}function Cc(t,e,n){const s=u(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,l)=>Ac(o,l)).filter(o=>o!==null):[];return{name:t,diagnostic:us(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function Ci(t,e){const n=it.value[t]??[];it.value={...it.value,[t]:[...n,e].slice(-50)}}function wc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Tc(t,e){const s=(it.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(o=>wc(a,o)));it.value={...it.value,[t]:[...e,...s].slice(-50)}}function Ks(t,e){Dt.value={...Dt.value,[t]:e},Tc(t,e.history)}function wi(t,e){const n=Dt.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Ks(t,{...n,diagnostic:{...s,...e}})}async function ni(){try{await In()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Ic(t){_c.value=t.trim()}async function So(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Dt.value[n])return Dt.value[n];nt(La,n,!0),nt(Et,n,null);try{const s=await Xt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=Cc(n,s,a);return Ks(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return nt(Et,n,a),null}finally{nt(La,n,!1)}}async function Rc(t,e){const n=t.trim(),s=e.trim();if(!n||!s)return;const a=`local-${Date.now()}`;Ci(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),nt(Ma,n,!0),nt(Et,n,null);try{const o=await vc(n,s);it.value={...it.value,[n]:(it.value[n]??[]).map(l=>l.id===a?{...l,delivery:"delivered"}:l)},Ci(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),wi(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await ni()}catch(o){const l=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw it.value={...it.value,[n]:(it.value[n]??[]).map(d=>d.id===a?{...d,delivery:"error",error:l}:d)},wi(n,{last_reply_status:"error",last_error:l}),nt(Et,n,l),o}finally{nt(Ma,n,!1)}}async function Pc(t,e){const n=t.trim();if(!n)return null;nt(Da,n,!0),nt(Et,n,null);try{const s=await qs({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=kc(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const l=Dt.value[n];Ks(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??it.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ni(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw nt(Et,n,a),s}finally{nt(Da,n,!1)}}async function Nc(t,e){const n=t.trim();if(!n)return null;nt(Ea,n,!0),nt(Et,n,null);try{const s=await qs({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=xc(s.result),o=(a==null?void 0:a.after)??null;if(o){const l=Dt.value[n];Ks(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??it.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ni(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw nt(Et,n,a),s}finally{nt(Ea,n,!1)}}function se(t){return(t??"").trim().toLowerCase()}function ct(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Zn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Fn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ue(t){return t.last_heartbeat??Fn(t.last_turn_ago_s)??Fn(t.last_proactive_ago_s)??Fn(t.last_handoff_ago_s)??Fn(t.last_compaction_ago_s)}function Lc(t){const e=t.title.trim();return e||Zn(t.content)}function Mc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Dc(t,e,n,s,a={}){var N;const o=se(t),l=e.filter(T=>se(T.assignee)===o&&(T.status==="claimed"||T.status==="in_progress")).length,d=n.filter(T=>se(T.from)===o).sort((T,I)=>ct(I.timestamp)-ct(T.timestamp))[0],p=s.filter(T=>se(T.agent)===o||se(T.author)===o).sort((T,I)=>ct(I.timestamp)-ct(T.timestamp))[0],_=(a.boardPosts??[]).filter(T=>se(T.author)===o).sort((T,I)=>ct(I.updated_at||I.created_at)-ct(T.updated_at||T.created_at))[0],m=(a.keepers??[]).filter(T=>se(T.name)===o&&Ue(T)!==null).sort((T,I)=>ct(Ue(I)??0)-ct(Ue(T)??0))[0],v=d?ct(d.timestamp):0,f=p?ct(p.timestamp):0,h=_?ct(_.updated_at||_.created_at):0,k=m?ct(Ue(m)??0):0,x=a.lastSeen?ct(a.lastSeen):0,S=((N=a.currentTask)==null?void 0:N.trim())||(l>0?`${l} claimed tasks`:null);if(v===0&&f===0&&h===0&&k===0&&x===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:S};const A=[d?{timestamp:d.timestamp,ts:v,text:Zn(d.content)}:null,_?{timestamp:_.updated_at||_.created_at,ts:h,text:`Post: ${Zn(Lc(_))}`}:null,m?{timestamp:Ue(m),ts:k,text:Mc(m)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:f,text:Zn(p.text)}:null].filter(T=>T!==null).sort((T,I)=>I.ts-T.ts)[0];return A&&A.ts>=x?{activeAssignedCount:l,lastActivityAt:A.timestamp,lastActivityText:A.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:S??"Presence heartbeat"}}const _t=g([]),Ct=g([]),Le=g([]),jt=g([]),mt=g(null),Ec=g(null),za=g(new Map),rn=g([]),ln=g("recent"),he=g(!0),Ao=g(null),Mt=g(""),Se=g([]),Ye=g(!1),Co=g(new Map),si=g("unknown"),Ae=g(null),ja=g(!1),cn=g(!1),Oa=g(!1),Xe=g(!1),ai=g(null),ps=g(!1),ms=g(null),wo=g(null),Fa=g(null),zc=g(null),jc=g(null),Oc=g(null);$t(()=>_t.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const To=$t(()=>{const t=Ct.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Us=$t(()=>{const t=new Map,e=Ct.value,n=Le.value,s=ds.value,a=rn.value,o=jt.value;for(const l of _t.value)t.set(l.name.trim().toLowerCase(),Dc(l.name,e,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:o}));return t});function Fc(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const qc=$t(()=>{const t=new Map;for(const e of jt.value)t.set(e.name,Fc(e));return t}),Kc=12e4;function Uc(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}const Hc=$t(()=>{const t=Date.now(),e=new Set,n=za.value;for(const s of jt.value){const a=Uc(s,n);a!=null&&t-a>Kc&&e.add(s.name)}return e});let ta=null;function Wc(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function Io(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Bc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Gc(t){if(!u(t))return null;const e=r(t.name);return e?{name:e,agent_type:r(t.agent_type),status:Io(t.status),current_task:r(t.current_task)??null,joined_at:r(t.joined_at),last_seen:r(t.last_seen),capabilities:O(t.capabilities),emoji:r(t.emoji),koreanName:r(t.koreanName)??r(t.korean_name),model:r(t.model),traits:O(t.traits),interests:O(t.interests),activityLevel:c(t.activityLevel)??c(t.activity_level),primaryValue:r(t.primaryValue)??r(t.primary_value)}:null}function Jc(t){if(!u(t))return null;const e=r(t.id),n=r(t.title);return!e||!n?null:{id:e,title:n,status:Bc(t.status),priority:c(t.priority),assignee:r(t.assignee),description:r(t.description),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function Vc(t){if(!u(t))return null;const e=r(t.from)??r(t.from_agent)??"system",n=r(t.content)??"",s=r(t.timestamp)??new Date().toISOString();return{id:r(t.id),seq:c(t.seq),from:e,content:n,timestamp:s,type:r(t.type)}}function Ti(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function Yc(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>Ti(s)-Ti(a)).slice(-500)}function Xc(t){return Array.isArray(t)?t.map(e=>{if(!u(e))return null;const n=c(e.ts_unix);if(n==null)return null;const s=u(e.handoff)?e.handoff:null;return{ts:n,context_ratio:c(e.context_ratio)??0,context_tokens:c(e.context_tokens)??0,context_max:c(e.context_max)??0,latency_ms:c(e.latency_ms)??0,generation:c(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:c(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:c(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?c(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Ii(t){if(!u(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);if(!e||!n||!s)return null;const a=r(t.quiet_reason)??null,o=r(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:Ne(t.last_reply_at)??r(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:c(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Qc(t,e){return(Array.isArray(t)?t:u(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!u(s))return null;const a=u(s.agent)?s.agent:null,o=u(s.context)?s.context:null,l=u(s.metrics_window)?s.metrics_window:void 0,d=r(s.name);if(!d)return null;const p=c(s.context_ratio)??c(o==null?void 0:o.context_ratio),_=r(s.status)??r(a==null?void 0:a.status)??"offline",m=Io(_),v=r(s.model)??r(s.active_model)??r(s.primary_model),f=O(s.skill_secondary),h=o?{source:r(o.source),context_ratio:c(o.context_ratio),context_tokens:c(o.context_tokens),context_max:c(o.context_max),message_count:c(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,k=a?{name:r(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:r(a.error),agent_type:r(a.agent_type),status:r(a.status),current_task:r(a.current_task)??null,joined_at:r(a.joined_at),last_seen:r(a.last_seen),last_seen_ago_s:c(a.last_seen_ago_s),capabilities:O(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,x=Xc(s.metrics_series),S={name:d,emoji:r(s.emoji),koreanName:r(s.koreanName)??r(s.korean_name),agent_name:r(s.agent_name),trace_id:r(s.trace_id),model:v,primary_model:r(s.primary_model),active_model:r(s.active_model),next_model_hint:r(s.next_model_hint)??null,status:m,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:c(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:c(s.proactive_idle_sec),proactive_cooldown_sec:c(s.proactive_cooldown_sec),last_heartbeat:r(s.last_heartbeat)??r(a==null?void 0:a.last_seen),generation:c(s.generation),turn_count:c(s.turn_count)??c(s.total_turns),keeper_age_s:c(s.keeper_age_s),last_turn_ago_s:c(s.last_turn_ago_s),last_handoff_ago_s:c(s.last_handoff_ago_s),last_compaction_ago_s:c(s.last_compaction_ago_s),last_proactive_ago_s:c(s.last_proactive_ago_s),last_proactive_preview:r(s.last_proactive_preview)??null,context_ratio:p,context_tokens:c(s.context_tokens)??c(o==null?void 0:o.context_tokens),context_max:c(s.context_max)??c(o==null?void 0:o.context_max),context_source:r(s.context_source)??r(o==null?void 0:o.source),context:h,traits:O(s.traits),interests:O(s.interests),primaryValue:r(s.primaryValue)??r(s.primary_value),activityLevel:c(s.activityLevel)??c(s.activity_level),memory_recent_note:r(s.memory_recent_note)??null,recent_input_preview:r(s.recent_input_preview)??null,recent_output_preview:r(s.recent_output_preview)??null,recent_tool_names:O(s.recent_tool_names)??[],conversation_tail_count:c(s.conversation_tail_count),k2k_count:c(s.k2k_count),handoff_count_total:c(s.handoff_count_total)??c(s.trace_history_count),compaction_count:c(s.compaction_count),last_compaction_saved_tokens:c(s.last_compaction_saved_tokens),diagnostic:Ii(s.diagnostic),skill_primary:r(s.skill_primary)??null,skill_secondary:f,skill_reason:r(s.skill_reason)??null,metrics_series:x.length>0?x:void 0,metrics_window:l,agent:k};return S.diagnostic=Ii(s.diagnostic)??Sc(S,(e==null?void 0:e.lodge)??null),S}).filter(s=>s!==null)}function Ro(t){return u(t)?{...t,lodge:bc(t.lodge)??void 0}:null}function Zc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function td(t){if(!u(t))return null;const e=c(t.iteration);if(e==null)return null;const n=c(t.metric_before)??0,s=c(t.metric_after)??n,a=u(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:c(t.delta)??s-n,changes:r(t.changes)??"",failed_attempts:r(t.failed_attempts)??"",next_suggestion:r(t.next_suggestion)??"",elapsed_ms:c(t.elapsed_ms)??0,cost_usd:c(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:c(a.tool_call_count)??0,tool_names:O(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function ed(t){var o,l;if(!u(t))return null;const e=r(t.loop_id);if(!e)return null;const n=c(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(td).filter(d=>d!==null):[],a=c(t.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:r(t.profile)??"unknown",status:Zc(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:r(t.error_message)??r(t.error_reason)??null,stop_reason:r(t.stop_reason)??r(t.reason)??null,current_iteration:c(t.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:c(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(t.target)??"",stagnation_streak:c(t.stagnation_streak)??0,stagnation_limit:c(t.stagnation_limit)??0,elapsed_seconds:c(t.elapsed_seconds)??0,updated_at:Ne(t.updated_at)??null,stopped_at:Ne(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:c(t.latest_tool_call_count)??0,latest_tool_names:O(t.latest_tool_names)??[],session_id:r(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function In(){ja.value=!0;try{await Promise.all([No(),Lt()]),wo.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{ja.value=!1}}async function Po(){ps.value=!0,ms.value=null;try{const t=await bl();ai.value=t,Oc.value=new Date().toISOString()}catch(t){ms.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{ps.value=!1}}function nd(t){var e;return((e=ai.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function sd(t){var n;const e=((n=ai.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(o=>o.id===t);if(a)return a}return null}function ad(t){var s,a;Se.value=(Array.isArray(t.goals)?t.goals:[]).map(o=>{if(!u(o))return null;const l=r(o.id),d=r(o.title),p=r(o.horizon),_=r(o.status),m=r(o.created_at),v=r(o.updated_at);return!l||!d||!p||!_||!m||!v?null:{id:l,horizon:p,title:d,metric:r(o.metric)??null,target_value:r(o.target_value)??null,due_date:r(o.due_date)??null,priority:c(o.priority)??3,status:_,parent_goal_id:r(o.parent_goal_id)??null,last_review_note:r(o.last_review_note)??null,last_review_at:r(o.last_review_at)??null,created_at:m,updated_at:v}}).filter(o=>o!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const o of n){const l=ed(o);l&&e.set(l.loop_id,l)}Co.value=e,Ae.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,si.value=Ae.value?"error":e.size===0?"idle":"ready"}async function No(){try{const t=await gl(),e=Ro(t.status);e&&(mt.value=e)}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Lt(){var t;try{const e=await $l(),n=Ro(e.status),s=(t=mt.value)==null?void 0:t.room;n&&(mt.value=n);const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;_t.value=(Array.isArray(e.agents)?e.agents:[]).map(Gc).filter(l=>l!==null),Ct.value=(Array.isArray(e.tasks)?e.tasks:[]).map(Jc).filter(l=>l!==null);const o=(Array.isArray(e.messages)?e.messages:[]).map(Vc).filter(l=>l!==null);Le.value=a?o:Yc(Le.value,o),jt.value=Qc(e.keepers,n??mt.value),Ec.value=null,wo.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function wt(){cn.value=!0;try{const t=await hl(ln.value,{excludeSystem:he.value});rn.value=t.posts??[],Fa.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{cn.value=!1}}async function Tt(){var t;Oa.value=!0;try{const e=Mt.value||((t=mt.value)==null?void 0:t.room)||"default";Mt.value||(Mt.value=e);const n=await tc(e);Ao.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Oa.value=!1}}async function dn(){Ye.value=!0,Xe.value=!0;try{const t=await Sl();ad(t),zc.value=new Date().toISOString(),jc.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),si.value="error",Ae.value=t instanceof Error?t.message:String(t)}finally{Ye.value=!1,Xe.value=!1}}async function Lo(){return dn()}let ts=null;function id(t){ts=t}let es=null;function od(t){es=t}let ns=null;function rd(t){ns=t}const re={};function ae(t,e,n=500){re[t]&&clearTimeout(re[t]),re[t]=setTimeout(()=>{e(),delete re[t]},n)}function ld(){const t=po.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(za.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),za.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&ae("execution",Lt),Wc(e.type)&&(ta||(ta=setTimeout(()=>{In(),es==null||es(),ns==null||ns(),ta=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&ae("execution",Lt),e.type==="broadcast"&&ae("execution",Lt),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&ae("execution",Lt),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&ae("board",wt),e.type.startsWith("decision_")&&ae("council",()=>ts==null?void 0:ts()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&ae("mdal",Lo,350)}});return()=>{t();for(const e of Object.keys(re))clearTimeout(re[e]),delete re[e]}}let Qe=null;function cd(){Qe||(Qe=setInterval(()=>{Jt.value,In()},1e4))}function dd(){Qe&&(clearInterval(Qe),Qe=null)}function ud({metric:t}){return i`
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
  `}function pd({panel:t}){return i`
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
            ${t.metrics.map(e=>i`<${ud} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function L({panelId:t,compact:e=!1,label:n="Why"}){const s=sd(t);return s?i`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${pd} panel=${s} />
    </details>
  `:ps.value?i`<span class="semantic-inline-state">Loading semantics…</span>`:null}function vt({surfaceId:t,compact:e=!1}){const n=nd(t);return n?i`
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
  `:ps.value?i`<div class="semantic-surface-card ${e?"compact":""}">Loading semantics…</div>`:ms.value?i`<div class="semantic-surface-card ${e?"compact":""}">${ms.value}</div>`:null}function C({title:t,class:e,semanticId:n,children:s}){return i`
    <div class="card ${e??""}">
      ${t?i`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?i`<${L} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${s}
    </div>
  `}function md(t){const e=t.indexOf("-");if(e<0)return{model:t,nickname:t,isKeeper:t==="keeper"};const n=t.slice(0,e),s=t.slice(e+1);return{model:n,nickname:s,isKeeper:n==="keeper"}}function vd(t){return t==="keeper"||t.startsWith("keeper-")}const Hs=g(null),qa=g(!1),vs=g(null),Mo=g(null),ye=g(!1),oe=g(null);let Ce=null;function Ri(){Ce!==null&&(window.clearTimeout(Ce),Ce=null)}function _d(t=1500){Ce===null&&(Ce=window.setTimeout(()=>{Ce=null,un(!1)},t))}function Ws(t){if(!u(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function Bs(t){if(!u(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:E(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function fd(t){if(!u(t))return null;const e=r(t.session_id);return e?{session_id:e,goal:r(t.goal),status:r(t.status),health:r(t.health),scale_profile:r(t.scale_profile),control_profile:r(t.control_profile),planned_worker_count:c(t.planned_worker_count),active_agent_count:c(t.active_agent_count),last_turn_age_sec:c(t.last_turn_age_sec)??null,attention_count:c(t.attention_count),recommended_action_count:c(t.recommended_action_count),top_attention:Ws(t.top_attention),top_recommendation:Bs(t.top_recommendation)}:null}function gd(t){if(!u(t))return null;const e=r(t.session_id);if(!e)return null;const n=u(t.status)?t.status:t,s=u(n.summary)?n.summary:void 0;return{session_id:e,status:r(t.status)??r(s==null?void 0:s.status)??(u(n.session)?r(n.session.status):void 0),progress_pct:c(t.progress_pct)??c(s==null?void 0:s.progress_pct),elapsed_sec:c(t.elapsed_sec)??c(s==null?void 0:s.elapsed_sec),remaining_sec:c(t.remaining_sec)??c(s==null?void 0:s.remaining_sec),done_delta_total:c(t.done_delta_total)??c(s==null?void 0:s.done_delta_total),summary:u(t.summary)?t.summary:s,team_health:u(t.team_health)?t.team_health:u(n.team_health)?n.team_health:void 0,communication_metrics:u(t.communication_metrics)?t.communication_metrics:u(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:u(t.orchestration_state)?t.orchestration_state:u(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:u(t.cascade_metrics)?t.cascade_metrics:u(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:u(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,o])=>{const l=r(o);return l?[a,l]:null}).filter(a=>a!==null)):u(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const l=r(o);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:u(t.session)?t.session:u(n.session)?n.session:void 0,recent_events:Y(t.recent_events,["events"]).filter(u)}}function $d(t){if(!u(t))return null;const e=r(t.name);return e?{name:e,agent_name:r(t.agent_name),status:r(t.status),autonomy_level:r(t.autonomy_level),context_ratio:c(t.context_ratio),generation:c(t.generation),active_goal_ids:Y(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:r(t.last_autonomous_action_at)??null,last_turn_ago_s:c(t.last_turn_ago_s),model:r(t.model)}:null}function hd(t){if(!u(t))return null;const e=r(t.confirm_token)??r(t.token);return e?{confirm_token:e,actor:r(t.actor),action_type:r(t.action_type),target_type:r(t.target_type),target_id:r(t.target_id)??null,delegated_tool:r(t.delegated_tool),created_at:r(t.created_at),preview:t.preview}:null}function yd(t){if(!u(t))return null;const e=r(t.action_type),n=r(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:r(t.description),confirm_required:E(t.confirm_required)}}function bd(t){const e=u(t)?t:{};return{room_health:r(e.room_health),cluster:r(e.cluster),project:r(e.project),current_room:r(e.current_room)??null,paused:E(e.paused),tempo_interval_s:c(e.tempo_interval_s),active_agents:c(e.active_agents),keeper_pressure:c(e.keeper_pressure),active_operations:c(e.active_operations),pending_approvals:c(e.pending_approvals),incident_count:c(e.incident_count),recommended_action_count:c(e.recommended_action_count),top_attention:Ws(e.top_attention),top_action:Bs(e.top_action)}}function kd(t){const e=u(t)?t:{},n=u(e.swarm_overview)?e.swarm_overview:{};return{health:r(e.health),active_operations:c(e.active_operations),pending_approvals:c(e.pending_approvals),swarm_overview:{active_lanes:c(n.active_lanes),moving_lanes:c(n.moving_lanes),stalled_lanes:c(n.stalled_lanes),projected_lanes:c(n.projected_lanes),last_movement_at:r(n.last_movement_at)??null},top_attention:Ws(e.top_attention),top_action:Bs(e.top_action),session_cards:Y(e.session_cards).map(fd).filter(s=>s!==null)}}function xd(t){const e=u(t)?t:{};return{sessions:Y(e.sessions,["items"]).map(gd).filter(n=>n!==null),keepers:Y(e.keepers,["items"]).map($d).filter(n=>n!==null),pending_confirms:Y(e.pending_confirms).map(hd).filter(n=>n!==null),available_actions:Y(e.available_actions).map(yd).filter(n=>n!==null)}}function Sd(t){const e=u(t)?t:{};return{generated_at:r(e.generated_at),summary:bd(e.summary),incidents:Y(e.incidents).map(Ws).filter(n=>n!==null),recommended_actions:Y(e.recommended_actions).map(Bs).filter(n=>n!==null),command_focus:kd(e.command_focus),operator_targets:xd(e.operator_targets)}}function Ad(t){if(!u(t))return null;const e=r(t.id),n=r(t.label),s=r(t.summary);if(!e||!n||!s)return null;const a=r(t.status)??"unclear";return{id:e,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,evidence:Y(t.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function Cd(t){const e=u(t)?t:{},n=u(e.basis)?e.basis:{},s=r(e.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:r(e.generated_at),cached:E(e.cached),stale:E(e.stale),refreshing:E(e.refreshing),status:a,summary:r(e.summary)??null,model:r(e.model)??null,ttl_sec:c(e.ttl_sec),criteria:Y(e.criteria).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),basis:{current_room:r(n.current_room)??null,crew_count:c(n.crew_count),agent_count:c(n.agent_count),keeper_count:c(n.keeper_count)},sections:Y(e.sections).map(Ad).filter(o=>o!==null),error:r(e.error)??null,last_error:r(e.last_error)??null}}async function ss(){qa.value=!0,vs.value=null;try{const t=await kl();Hs.value=Sd(t)}catch(t){vs.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{qa.value=!1}}async function un(t=!1){ye.value=!0,oe.value=null;try{const e=await xl(t),n=Cd(e);Mo.value=n,n.refreshing||n.status==="pending"?_d():Ri()}catch(e){oe.value=e instanceof Error?e.message:"Failed to load mission briefing",Ri()}finally{ye.value=!1}}function Qt({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Do(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const o=Math.floor(a/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function X({timestamp:t}){const e=Do(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return i`<span class="time-ago" title=${n}>${e}</span>`}let wd=0;const le=g([]);function R(t,e="success",n=4e3){const s=++wd;le.value=[...le.value,{id:s,message:t,type:e}],setTimeout(()=>{le.value=le.value.filter(a=>a.id!==s)},n)}function Td(t){le.value=le.value.filter(e=>e.id!==t)}function Id(){const t=le.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Td(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Rd="masc_dashboard_agent_name",je=g(null),_s=g(!1),pn=g(""),fs=g([]),mn=g([]),we=g(""),Ze=g(!1);function Gs(t){je.value=t,ii()}function Pi(){je.value=null,pn.value="",fs.value=[],mn.value=[],we.value=""}function Pd(){const t=je.value;return t?_t.value.find(e=>e.name===t)??null:null}function Eo(t){return t?Ct.value.filter(e=>e.assignee===t):[]}function zo(t){return t?jt.value.find(e=>e.agent_name===t||e.name===t)??null:null}function Nd(t){if(!t)return[];const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Ld(t){const e=zo(t);return e?e.recent_tool_names&&e.recent_tool_names.length>0?e.recent_tool_names:[]:[]}async function ii(){const t=je.value;if(t){_s.value=!0,pn.value="",fs.value=[],mn.value=[];try{const e=await dc(80);fs.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Eo(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await uc(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const l=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));mn.value=s}catch(e){pn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{_s.value=!1}}}async function Ni(){var s;const t=je.value,e=we.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Rd))==null?void 0:s.trim())||"dashboard";Ze.value=!0;try{await cc(n,`@${t} ${e}`),we.value="",R(`Mention sent to ${t}`,"success"),ii()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";R(o,"error")}finally{Ze.value=!1}}function Md({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Qt} status=${t.status} />
    </div>
  `}function Dd({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Ed(){var v,f,h,k,x,S,w;const t=je.value;if(!t)return null;const e=Pd(),n=zo(t),s=Eo(t),a=fs.value,o=Ld(t),l=Nd(n),d=(e==null?void 0:e.capabilities)??[],p=((v=mt.value)==null?void 0:v.room)??"default",_=((f=mt.value)==null?void 0:f.project)??"확인 없음",m=((h=mt.value)==null?void 0:h.cluster)??"확인 없음";return i`
    <div
      class="agent-detail-overlay"
      onClick=${A=>{A.target.classList.contains("agent-detail-overlay")&&Pi()}}
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
                        <${Qt} status=${e.status} />
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
            ${(((k=e==null?void 0:e.traits)==null?void 0:k.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(x=e==null?void 0:e.traits)==null?void 0:x.map(A=>i`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${A}</span>`)}
              </div>
            `:""}
            ${(((S=e==null?void 0:e.interests)==null?void 0:S.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(w=e==null?void 0:e.interests)==null?void 0:w.map(A=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${A}</span>`)}
              </div>
            `:""}
            ${d.length>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${d.map(A=>i`<span style="font-size:0.7rem;background:#183153;color:#7dd3fc;padding:2px 8px;border-radius:10px">${A}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?i`
                    ${e.current_task?i`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?i`<span>Last seen: <${X} timestamp=${e.last_seen} /></span>`:null}
                    <span>Room: ${p}</span>
                    <span>Project: ${_}</span>
                    <span>Cluster: ${m}</span>
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{ii()}} disabled=${_s.value}>
              ${_s.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Pi}>Close</button>
          </div>
        </div>

        ${pn.value?i`<div class="council-error">${pn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${C} title="Assigned Tasks">
            ${s.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${s.map(A=>i`<${Md} key=${A.id} task=${A} />`)}</div>`}
          <//>

          <${C} title="Recent Activity">
            ${a.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${a.map((A,N)=>i`<div key=${N} class="agent-activity-line">${A}</div>`)}</div>`}
          <//>
        </div>

        <${C} title="Capabilities & Tools">
          <div style="display:flex; flex-direction:column; gap:12px;">
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Capabilities</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${d.length>0?d.map(A=>i`<span class="pill">${A}</span>`):i`<span class="empty-state" style="font-size:12px;">No capability metadata</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Recent tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${o.length>0?o.map(A=>i`<span class="pill">${A}</span>`):i`<span class="empty-state" style="font-size:12px;">No tool telemetry</span>`}
              </div>
            </div>
            ${o.length===0&&l.length>0?i`
                  <div>
                    <div style="font-size:12px; color:#888; margin-bottom:6px;">Window top tools</div>
                    <div style="display:flex; flex-wrap:wrap; gap:6px;">
                      ${l.map(A=>i`<span class="pill">${A}</span>`)}
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
          ${mn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${mn.value.map(A=>i`<${Dd} key=${A.taskId} row=${A} />`)}</div>`}
        <//>

        <${C} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${we.value}
              onInput=${A=>{we.value=A.target.value}}
              onKeyDown=${A=>{A.key==="Enter"&&Ni()}}
              disabled=${Ze.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Ni()}}
              disabled=${Ze.value||we.value.trim()===""}
            >
              ${Ze.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const It=g(null),jo=g(null),Rt=g(null),vn=g(!1),Vt=g(null),_n=g(!1),Me=g(null),W=g(!1),gs=g([]);let zd=1;function jd(t){return u(t)?{id:r(t.id),seq:c(t.seq),from:r(t.from)??r(t.from_agent)??"system",content:r(t.content)??"",timestamp:r(t.timestamp)??new Date().toISOString(),type:r(t.type)}:null}function Od(t){return u(t)?{room_id:r(t.room_id),current_room:r(t.current_room)??r(t.room),project:r(t.project),cluster:r(t.cluster),paused:E(t.paused),pause_reason:r(t.pause_reason)??null,paused_by:r(t.paused_by)??null,paused_at:r(t.paused_at)??null}:{}}function Li(t){if(!u(t))return;const e=Object.entries(t).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Oo(t){if(!u(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function Fo(t){if(!u(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:E(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Fd(t){return u(t)?{actor:r(t.actor)??null,spawn_agent:r(t.spawn_agent)??null,spawn_role:r(t.spawn_role)??null,spawn_model:r(t.spawn_model)??null,worker_class:r(t.worker_class)??null,parent_actor:r(t.parent_actor)??null,capsule_mode:r(t.capsule_mode)??null,runtime_pool:r(t.runtime_pool)??null,lane_id:r(t.lane_id)??null,controller_level:r(t.controller_level)??null,control_domain:r(t.control_domain)??null,supervisor_actor:r(t.supervisor_actor)??null,model_tier:r(t.model_tier)??null,task_profile:r(t.task_profile)??null,risk_level:r(t.risk_level)??null,routing_confidence:c(t.routing_confidence)??null,routing_reason:r(t.routing_reason)??null,status:r(t.status)??"unknown",turn_count:c(t.turn_count)??0,empty_note_turn_count:c(t.empty_note_turn_count)??0,has_turn:E(t.has_turn)??!1,last_turn_ts_iso:r(t.last_turn_ts_iso)??null}:null}function qd(t){if(!u(t))return null;const e=r(t.session_id);return e?{session_id:e,goal:r(t.goal),status:r(t.status),health:r(t.health),scale_profile:r(t.scale_profile),control_profile:r(t.control_profile),planned_worker_count:c(t.planned_worker_count),active_agent_count:c(t.active_agent_count),last_turn_age_sec:c(t.last_turn_age_sec)??null,attention_count:c(t.attention_count),recommended_action_count:c(t.recommended_action_count),top_attention:Oo(t.top_attention),top_recommendation:Fo(t.top_recommendation)}:null}function qo(t){const e=u(t)?t:{};return{trace_id:r(e.trace_id),target_type:r(e.target_type)??"room",target_id:r(e.target_id)??null,health:r(e.health),swarm_status:u(e.swarm_status)?e.swarm_status:void 0,attention_items:Y(e.attention_items).map(Oo).filter(n=>n!==null),recommended_actions:Y(e.recommended_actions).map(Fo).filter(n=>n!==null),session_cards:Y(e.session_cards).map(qd).filter(n=>n!==null),worker_cards:Y(e.worker_cards).map(Fd).filter(n=>n!==null)}}function Kd(t){if(!u(t))return null;const e=u(t.status)?t.status:void 0,n=u(t.summary)?t.summary:u(e==null?void 0:e.summary)?e.summary:void 0,s=u(t.session)?t.session:u(e==null?void 0:e.session)?e.session:void 0,a=r(t.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const o=Li(t.report_paths)??Li(e==null?void 0:e.report_paths),l=Y(t.recent_events,["events"]).filter(u);return{session_id:a,status:r(t.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:c(t.progress_pct)??c(n==null?void 0:n.progress_pct),elapsed_sec:c(t.elapsed_sec)??c(n==null?void 0:n.elapsed_sec),remaining_sec:c(t.remaining_sec)??c(n==null?void 0:n.remaining_sec),done_delta_total:c(t.done_delta_total)??c(n==null?void 0:n.done_delta_total),summary:n,team_health:u(t.team_health)?t.team_health:u(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:u(t.communication_metrics)?t.communication_metrics:u(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:u(t.orchestration_state)?t.orchestration_state:u(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:u(t.cascade_metrics)?t.cascade_metrics:u(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:s,recent_events:l}}function Ud(t){if(!u(t))return null;const e=r(t.name);if(!e)return null;const n=u(t.context)?t.context:void 0;return{name:e,agent_name:r(t.agent_name),status:r(t.status),autonomy_level:r(t.autonomy_level),context_ratio:c(t.context_ratio)??c(n==null?void 0:n.context_ratio),generation:c(t.generation),active_goal_ids:O(t.active_goal_ids),last_autonomous_action_at:r(t.last_autonomous_action_at)??null,last_turn_ago_s:c(t.last_turn_ago_s),model:r(t.model)??r(t.active_model)??r(t.primary_model)}}function Hd(t){if(!u(t))return null;const e=r(t.confirm_token)??r(t.token);return e?{confirm_token:e,actor:r(t.actor),action_type:r(t.action_type),target_type:r(t.target_type),target_id:r(t.target_id)??null,delegated_tool:r(t.delegated_tool),created_at:r(t.created_at),preview:t.preview}:null}function Wd(t){const e=u(t)?t:{};return{room:Od(e.room),sessions:Y(e.sessions,["items","sessions"]).map(Kd).filter(n=>n!==null),keepers:Y(e.keepers,["items","keepers"]).map(Ud).filter(n=>n!==null),recent_messages:Y(e.recent_messages,["messages"]).map(jd).filter(n=>n!==null),pending_confirms:Y(e.pending_confirms,["items","confirms"]).map(Hd).filter(n=>n!==null),available_actions:Y(e.available_actions,["actions"]).filter(u).map(n=>({action_type:r(n.action_type)??"unknown",target_type:r(n.target_type)??"unknown",description:r(n.description),confirm_required:E(n.confirm_required)}))}}function qn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Mi(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function $s(t){gs.value=[{...t,id:zd++,at:new Date().toISOString()},...gs.value].slice(0,20)}function Ko(t){return t.confirm_required?qn(t.preview)||"Confirmation required":qn(t.result)||qn(t.executed_action)||qn(t.delegated_tool_result)||t.status}async function tt(){vn.value=!0,Vt.value=null;try{const t=await Al();It.value=Wd(t)}catch(t){Vt.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{vn.value=!1}}async function zt(){_n.value=!0,Me.value=null;try{const t=await ho({targetType:"room"});jo.value=qo(t)}catch(t){Me.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{_n.value=!1}}async function De(t){if(!t){Rt.value=null;return}_n.value=!0,Me.value=null;try{const e=await ho({targetType:"team_session",targetId:t,includeWorkers:!0});Rt.value=qo(e)}catch(e){Me.value=e instanceof Error?e.message:"Failed to load session digest"}finally{_n.value=!1}}async function Bd(t){var e;W.value=!0,Vt.value=null;try{const n=await qs(t);return $s({actor:t.actor,action_type:t.action_type,target_label:Mi(t),outcome:n.confirm_required?"preview":"executed",message:Ko(n),delegated_tool:n.delegated_tool}),await tt(),await zt(),(e=Rt.value)!=null&&e.target_id&&await De(Rt.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw Vt.value=s,$s({actor:t.actor,action_type:t.action_type,target_label:Mi(t),outcome:"error",message:s}),n}finally{W.value=!1}}async function Gd(t,e){var n;W.value=!0,Vt.value=null;try{const s=await Ml(t,e);return $s({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Ko(s),delegated_tool:s.delegated_tool}),await tt(),await zt(),(n=Rt.value)!=null&&n.target_id&&await De(Rt.value.target_id),s}catch(s){const a=s instanceof Error?s.message:"Operator confirmation failed";throw Vt.value=a,$s({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),s}finally{W.value=!1}}rd(()=>{var t;tt(),zt(),(t=Rt.value)!=null&&t.target_id&&De(Rt.value.target_id)});function Jd(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Vd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Yd(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Di(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function Uo(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Xd(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Ho(t){if(!t)return null;const e=Dt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function Qd({keeper:t,showRawStatus:e=!1}){if(Z(()=>{t!=null&&t.name&&So(t.name)},[t==null?void 0:t.name]),!t)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Dt.value[t.name],s=Ho(t),a=La.value[t.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${Jd(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Vd((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?i` · ${Uo(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?i` · next eligible ${Xd(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Zd({keeperName:t,placeholder:e}){const[n,s]=Za("");Z(()=>{t&&So(t)},[t]);const a=it.value[t]??[],o=Ma.value[t]??!1,l=Et.value[t],d=async()=>{const p=n.trim();if(!(!t||!p)){s("");try{await Rc(t,p)}catch(_){const m=_ instanceof Error?_.message:`Failed to message ${t}`;R(m,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(p=>i`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Di(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${Di(p)}`}>${Yd(p)}</span>
                  ${p.timestamp?i`<span class="keeper-conversation-time">${Uo(p.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${p.text}</div>
                ${p.error?i`<div class="keeper-conversation-error">${p.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${e}
          value=${n}
          onInput=${p=>{s(p.target.value)}}
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
  `}function tu({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=Ho(e),a=Da.value[e.name]??!1,o=Ea.value[e.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",d=(s==null?void 0:s.recoverable)??l==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{Pc(e.name,t).catch(p=>{const _=p instanceof Error?p.message:`Failed to probe ${e.name}`;R(_,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{Nc(e.name,t).catch(p=>{const _=p instanceof Error?p.message:`Failed to recover ${e.name}`;R(_,"error")})}}
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
  `}const oi=g(null);function ri(t){oi.value=t,Ic(t.name)}function Ei(){oi.value=null}const ge=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function eu(t){if(!t)return 0;const e=ge.findIndex(n=>n.level===t);return e>=0?e:0}function nu({keeper:t}){const e=eu(t.autonomy_level),n=ge[e]??ge[0];if(!n)return null;const s=(e+1)/ge.length*100;return i`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${ge.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${ge.map((a,o)=>i`
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
            <strong><${X} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?i`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function as(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function su(t){switch(t){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(t==null?void 0:t.trim())||"action"}}function au(t){return t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]}function iu(t){const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function ou({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${as(t.context_tokens)}</div>
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
  `}function ru({keeper:t}){var m,v;const e=t.metrics_series??[];if(e.length<2){const f=(((m=t.context)==null?void 0:m.context_ratio)??0)*100,h=f>85?"#ef4444":f>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${f.toFixed(1)}%;background:${h}"></div>
        </div>
        <span class="chart-pct">${f.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=e.length,l=e.map((f,h)=>{const k=a+h/(o-1)*(n-2*a),x=s-a-(f.context_ratio??0)*(s-2*a);return{x:k,y:x,p:f}}),d=l.map(({x:f,y:h})=>`${f.toFixed(1)},${h.toFixed(1)}`).join(" "),p=(((v=e[e.length-1])==null?void 0:v.context_ratio)??0)*100,_=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:f})=>f.is_handoff).map(({x:f})=>i`
          <line x1="${f.toFixed(1)}" y1="${a}" x2="${f.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${d}" fill="none" stroke="${_}" stroke-width="1.5"/>
        ${l.filter(({p:f})=>f.is_compaction).map(({x:f,y:h})=>i`
          <circle cx="${f.toFixed(1)}" cy="${h.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}const ea=g("");function lu({keeper:t}){var a,o,l,d;const e=ea.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],s=e?n.filter(p=>p.title.toLowerCase().includes(e)||p.key.includes(e)||p.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${ea.value}
        onInput=${p=>{ea.value=p.target.value}}
      />
      ${s.map(p=>i`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${p.title}</span>
          <span class="keeper-field-key">${p.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${p.value}</span>
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
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${as(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${as(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${as(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((d=t.context)==null?void 0:d.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function cu({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
  `}function du({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function uu({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function zi({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function na(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function pu({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:na(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:na(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:na(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(s=>i`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function mu({keeper:t}){var _,m,v,f,h,k,x;const e=((_=It.value)==null?void 0:_.room)??{},n=(((m=It.value)==null?void 0:m.available_actions)??[]).filter(S=>S.target_type==="keeper"||S.target_type==="room").slice(0,8),s=au(t),a=iu(t),o=((v=t.agent)==null?void 0:v.capabilities)??[],l=e.current_room??e.room_id??((f=mt.value)==null?void 0:f.room)??"default",d=e.project??((h=mt.value)==null?void 0:h.project)??"확인 없음",p=e.cluster??((k=mt.value)==null?void 0:k.cluster)??"확인 없음";return i`
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
        <strong>${p}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Current task</span>
        <strong>${((x=t.agent)==null?void 0:x.current_task)??"없음"}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Skill route</span>
        <strong>${t.skill_primary??"미확인"}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Recent tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${s.length>0?s.map(S=>i`<span class="pill">${S}</span>`):i`<span style="font-size:12px; color:#888;">도구 텔레메트리 없음</span>`}
        </div>
      </div>
      ${s.length===0&&a.length>0?i`
            <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
              <span style="font-size:12px; color:#888;">Window top tools</span>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${a.map(S=>i`<span class="pill">${S}</span>`)}
              </div>
            </div>
          `:null}
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Capabilities</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${o.length>0?o.map(S=>i`<span class="pill">${S}</span>`):i`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(S=>i`<span class="pill">${su(S.action_type)}</span>`):i`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function Wo(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function vu(){try{const t=await qs({actor:Wo(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=xo(t.result);await In(),e!=null&&e.skipped_reason?R(e.skipped_reason,"warning"):R(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";R(e,"error")}}function _u({keeper:t}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Qd} keeper=${t} />
          <${tu}
            actor=${Wo()}
            keeper=${t}
            onPokeLodge=${()=>{vu()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Zd}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function fu(){var e,n,s;const t=oi.value;return t?i`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Ei()}}
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
            <${Qt} status=${t.status} />
            ${t.model?i`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Ei()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${ou} keeper=${t} />

        ${""}
        <${ru} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${C} title="Field Dictionary">
            <${lu} keeper=${t} />
          <//>

          ${""}
          <${C} title="Profile">
            <${zi} traits=${t.traits??[]} label="Traits" />
            <${zi} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${X} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?i`
              <${C} title="Autonomy">
                <${nu} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?i`
              <${C} title="TRPG Stats">
                <${cu} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${C} title="Equipment (${t.inventory.length})">
                <${du} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${C} title="Relationships (${Object.keys(t.relationships).length})">
                <${uu} rels=${t.relationships} />
              <//>
            `:null}

          <${C} title="Runtime Signals">
            <${pu} keeper=${t} />
          <//>

          <${C} title="Neighborhood & Tools">
            <${mu} keeper=${t} />
          <//>

          <${C} title="Memory & Context">
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
        <${_u} keeper=${t} />
      </div>
    </div>
  `:null}const hs="masc_dashboard_workflow_context",gu=900*1e3;function gt(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function Ft(t){const e=gt(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function Bo(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function Ka(t){return u(t)?t:null}function $u(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function hu(t){if(!t)return null;try{const e=JSON.parse(t);if(!u(e))return null;const n=gt(e.id),s=gt(e.source_surface),a=gt(e.source_label),o=gt(e.summary),l=gt(e.created_at);return!n||s!=="mission"||!a||!o||!l?null:{id:n,source_surface:"mission",source_label:a,action_type:gt(e.action_type),target_type:gt(e.target_type),target_id:gt(e.target_id),focus_kind:gt(e.focus_kind),summary:o,payload_preview:gt(e.payload_preview),suggested_payload:Ka(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:l}}catch{return null}}function li(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=gu}function yu(){const t=Bo(),e=hu((t==null?void 0:t.getItem(hs))??null);return e?li(e)?e:(t==null||t.removeItem(hs),null):null}const Go=g(yu());function bu(t){const e=t&&li(t)?t:null;Go.value=e;const n=Bo();if(!n)return;if(!e){n.removeItem(hs);return}const s=$u(e);s&&n.setItem(hs,s)}function Jo(t){if(!t)return null;const e=Ka(t.suggested_payload);if(e)return e;if(u(t.preview)){const n=Ka(t.preview.payload);if(n)return n}return null}function Vo(t){if(!t)return null;const e=Ft(t.message);if(e)return e;const n=Ft(t.task_title)??Ft(t.title),s=Ft(t.task_description)??Ft(t.description),a=Ft(t.reason),o=Ft(t.priority)??Ft(t.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function Yo(t,e,n,s,a,o){return["mission",t,e??"action",n??"target",s??"room",a??"focus",o].join(":")}function Oe(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=Jo(t),o=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,l=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,d=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,p=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:Yo(n,(t==null?void 0:t.action_type)??null,o,l,d,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:o,target_id:l,focus_kind:d,summary:p,payload_preview:Vo(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function ku(t,e){return e.source==="mission"&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)}function Rn(t){const{params:e}=t;if(e.source!=="mission")return null;const n=Go.value;if(n&&li(n)&&ku(n,e))return n;const s=new Date().toISOString();return{id:Yo("상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,s),source_surface:"mission",source_label:"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,summary:e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function xu(t){return{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function Xo(t){const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.target_type==="room"?"summary":"swarm"}function Su(t){return{source:"mission",surface:Xo(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function ci(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function di(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";default:return(t==null?void 0:t.trim())||"추천 액션"}}function Au(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}function at(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function fn(t){return typeof t=="number"&&Number.isFinite(t)?t:null}function V(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function ot(t){return t==="bad"||t==="offline"||t==="critical"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"?"warn":"ok"}function Yt(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:n<86400?`${Math.round(n/3600)}h 전`:`${Math.round(n/86400)}d 전`}function Cu(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:t<86400?`${Math.round(t/3600)}h`:`${Math.round(t/86400)}d`}function ji(t){const e=fn(t.ts);if(e!=null)return e;const n=at(t.ts_iso);if(!n)return 0;const s=Date.parse(n);return Number.isNaN(s)?0:s}function wu(t){return[...new Set(t.filter(Boolean))]}function Tu(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function Iu(t){return Vo(Jo(t))}function Ru(t){return ci(t?Oe(t,null,"상황판 추천 액션"):null)}function Js(t,e=Oe()){bu(e),lt(t,t==="intervene"?xu(e):Su(e))}function Pu(t){Js("intervene",Oe(null,t,"상황판 incident"))}function Nu(t){Js("command",Oe(null,t,"상황판 incident"))}function Lu(t,e,n="상황판 추천 액션"){Js("intervene",Oe(t,e,n))}function Mu(t,e,n="상황판 추천 액션"){Js("command",Oe(t,e,n))}function Oi(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),lt(t,n)}function Qo(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>(s.from??"").trim().toLowerCase()===n).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function Du(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>{if((s.from??"").trim().toLowerCase()===n)return!1;const o=(s.content??"").trim().toLowerCase();return o.includes(`@${n}`)||o.includes(n)}).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function Eu(t){const e=u(t.session)?t.session:{},n=u(t.summary)?t.summary:{};return wu([...O(e.agent_names),...O(n.active_agents),...O(n.planned_participants)]).filter(s=>!vd(s))}function zu(t){const e=u(t.session)?t.session:{};return at(e.goal)??at(e.session_id)??t.session_id}function ju(t){const e=u(t.session)?t.session:{};return at(e.room_id)}function Ou(t){const e=u(t.session)?t.session:{};return at(e.created_at_iso)}function Fu(t){const e=u(t.session)?t.session:{};return at(e.updated_at_iso)}function qu(t){const e=u(t.communication_metrics)?t.communication_metrics:{};return at(e.mode)}function Ku(t){const e=u(t.communication_metrics)?t.communication_metrics:{};return fn(e.broadcast_count)??0}function Uu(t){const e=u(t.communication_metrics)?t.communication_metrics:{};return fn(e.portal_count)??0}function Hu(t){const e=u(t.team_health)?t.team_health:{};return{active:fn(e.active_agents_count)??0,required:fn(e.required_agents)??0}}function Wu(t){const n=[...t.recent_events??[]].sort((m,v)=>ji(v)-ji(m))[0];if(!n)return{at:null,summary:"최근 session event가 없습니다."};const s=u(n.detail)?n.detail:{},a=at(n.event_type)??"event",o=at(s.actor),l=at(s.task_title)??at(s.title),d=V(at(s.result),120),p=V(at(s.reason),120),_=l?`${o?`${o} · `:""}${l}`:d??p??a.replace(/_/g," ");return{at:at(n.ts_iso),summary:_}}function Bu(){const t=Hs.value;return t?t.operator_targets.sessions.map(e=>{var o,l;const n=Hu(e),s=Wu(e),a=t.command_focus.session_cards.find(d=>d.session_id===e.session_id);return{session:e,goal:zu(e),room:ju(e),status:e.status??"unknown",memberNames:Eu(e),startedAt:Ou(e),stoppedAt:Fu(e),elapsedSec:e.elapsed_sec??null,lastEventAt:s.at,lastEventSummary:s.summary,communicationMode:qu(e),broadcastCount:Ku(e),portalCount:Uu(e),activeCount:n.active,requiredCount:n.required,attentionSummary:((o=a==null?void 0:a.top_attention)==null?void 0:o.summary)??((l=a==null?void 0:a.top_recommendation)==null?void 0:l.reason)??null}}).sort((e,n)=>{const s=Date.parse(e.lastEventAt??e.startedAt??"")||0;return(Date.parse(n.lastEventAt??n.startedAt??"")||0)-s}):[]}function Zo(t){if(t.recent_tool_names&&t.recent_tool_names.length>0)return t.recent_tool_names;const e=u(t.metrics_window)?t.metrics_window:{};return(Array.isArray(e.top_tools)?e.top_tools:[]).map(s=>u(s)?at(s.tool):null).filter(s=>s!==null)}function Gu(t){return jt.value.find(e=>e.agent_name===t||e.name===t)??null}function tr(t,e){const n=V(t.current_task,100);if(!n)return"명시된 current task 없음";const s=e.find(o=>o.id===n);if(s)return`${s.id} · ${V(s.title,92)}`;const a=e.find(o=>o.title===n);return a?`${a.id} · ${V(a.title,92)}`:n}function Ju(t){const e=new Map;for(const n of t)for(const s of n.memberNames)e.has(s)||e.set(s,n);return[..._t.value].map(n=>{var f,h;const s=e.get(n.name),a=Gu(n.name),o=Qo(n.name,Le.value),l=Du(n.name,Le.value),d=Us.value.get(n.name.trim().toLowerCase()),p=s?s.memberNames.filter(k=>k!==n.name):[],_=s?`${s.goal}${s.room?` · ${s.room}`:""}`:((f=Hs.value)==null?void 0:f.summary.current_room)??"room",m=(a==null?void 0:a.skill_primary)??(n.capabilities&&n.capabilities.length>0?n.capabilities.slice(0,3).join(", "):null)??n.agent_type??null,v=tr(n,Ct.value);return{agent:n,where:_,withWhom:p,activeSince:(s==null?void 0:s.startedAt)??n.joined_at??n.last_seen??null,currentWork:v,how:m,recentInput:V(l==null?void 0:l.content,120)??V(a==null?void 0:a.recent_input_preview,120)??null,recentOutput:V(o==null?void 0:o.content,120)??V(a==null?void 0:a.recent_output_preview,120)??V((h=a==null?void 0:a.diagnostic)==null?void 0:h.last_reply_preview,120)??null,recentEvent:V(d==null?void 0:d.lastActivityText,120)??(s==null?void 0:s.lastEventSummary)??null,recentTools:a?Zo(a):[]}}).sort((n,s)=>{const a=p=>p==="busy"?4:p==="active"?3:p==="listening"?2:p==="idle"?1:0,o=a(s.agent.status)-a(n.agent.status);if(o!==0)return o;const l=Date.parse(n.agent.last_seen??n.activeSince??"")||0;return(Date.parse(s.agent.last_seen??s.activeSince??"")||0)-l})}function Vu(){return[...jt.value].map(t=>{var e,n,s,a;return{keeper:t,activeSince:((e=t.agent)==null?void 0:e.joined_at)??t.created_at??t.last_heartbeat??null,currentWork:V((n=t.agent)==null?void 0:n.current_task,110)??V(t.skill_primary,110)??V(t.last_proactive_reason,110)??"명시된 keeper focus 없음",recentInput:V(t.recent_input_preview,120)??null,recentOutput:V(t.recent_output_preview,120)??V((s=t.diagnostic)==null?void 0:s.last_reply_preview,120)??V(t.last_proactive_preview,120)??null,recentEvent:V(t.last_proactive_reason,120)??V((a=t.diagnostic)==null?void 0:a.summary,120)??null,recentTools:Zo(t)}}).sort((t,e)=>{const n=Date.parse(t.keeper.last_heartbeat??t.activeSince??"")||0;return(Date.parse(e.keeper.last_heartbeat??e.activeSince??"")||0)-n})}function Yu({cluster:t,project:e,room:n,generatedAt:s}){return i`
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
        <strong>${s?Yt(s):"fresh"}</strong>
      </div>
    </div>
  `}function _e({label:t,value:e,detail:n,tone:s}){return i`
    <article class="mission-stat-card ${ot(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function Xu(){const t=Mo.value,e=ot((t==null?void 0:t.status)??(oe.value?"bad":"warn")),n=!t||t.sections.length===0,s=(t==null?void 0:t.status)==="error"||(t==null?void 0:t.status)==="unavailable"&&!(t!=null&&t.cached);return i`
    <${C} title="LLM 판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>heuristic 대신 별도 판단 계층</h3>
        <p>아래 해석은 LLM이 사실 스냅샷만 읽고 만든 요약입니다. raw thinking은 숨기고, 기준과 근거만 남깁니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${e}">
          ${(t==null?void 0:t.status)??(oe.value?"error":"loading")}
        </span>
        ${t!=null&&t.model?i`<span class="command-chip">${t.model}</span>`:null}
        ${t!=null&&t.generated_at?i`<span class="command-chip">${Yt(t.generated_at)}</span>`:null}
        ${t!=null&&t.cached?i`<span class="command-chip">cached</span>`:null}
        ${t!=null&&t.stale?i`<span class="command-chip warn">stale</span>`:null}
        ${t!=null&&t.refreshing?i`<span class="command-chip warn">refreshing</span>`:null}
      </div>

      ${oe.value?i`<div class="empty-state error">${oe.value}</div>`:null}
      ${t!=null&&t.error?i`<div class="empty-state error">${t.error}</div>`:null}
      ${t!=null&&t.summary?i`<div class="mission-inline-note">${t.summary}</div>`:null}
      ${t!=null&&t.last_error&&!t.error?i`<div class="mission-inline-note">최근 refresh 실패: ${t.last_error}</div>`:null}

      ${t&&t.sections.length>0?i`
            <div class="mission-briefing-grid">
              ${t.sections.map(a=>i`
                <article class="mission-briefing-section ${ot(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <span class="command-chip ${ot(a.status)}">${a.status}</span>
                  </div>
                  <p>${a.summary}</p>
                  ${a.evidence.length>0?i`
                        <div class="mission-briefing-evidence">
                          ${a.evidence.map(o=>i`<span>${o}</span>`)}
                        </div>
                      `:null}
                </article>
              `)}
            </div>
          `:!ye.value&&!oe.value&&n?i`
                <div class="empty-state">
                  ${(t==null?void 0:t.status)==="pending"?"최신 스냅샷으로 브리핑을 생성 중입니다. 마지막 성공 결과가 생기면 자동으로 다시 읽습니다.":"아직 판단 레이어를 불러오지 못했습니다."}
                </div>
              `:null}

      ${t!=null&&t.criteria&&t.criteria.length>0?i`
            <details class="mission-briefing-criteria">
              <summary>판단 기준 보기</summary>
              <div class="mission-briefing-evidence">
                ${t.criteria.map(a=>i`<span>${a}</span>`)}
              </div>
            </details>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{un(s)}} disabled=${ye.value}>
          ${ye.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{un(!0)}} disabled=${ye.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function Qu({rows:t}){const[e,n]=Za(!1);return i`
    <div class="mission-stale-section">
      <button class="mission-stale-toggle" onClick=${()=>n(!e)}>
        ${e?"▾":"▸"} 종료/중단된 세션 (${t.length})
      </button>
      ${e?t.map(s=>i`<${er} key=${s.session.session_id} row=${s} />`):null}
    </div>
  `}function er({row:t}){const e=t.memberNames.slice(0,4).map(n=>{const s=_t.value.find(l=>l.name===n),a=Qo(n,Le.value),o=md(n);return{name:n,model:o.model,nickname:o.nickname,currentTask:s?tr(s,Ct.value):"서버 재시작 후 상태 소실",output:V(a==null?void 0:a.content,96)}});return i`
    <article class="mission-crew-card ${ot(t.status)}">
      <div class="mission-card-head">
        <div>
          <strong>${t.goal}</strong>
          <div class="mission-card-target">${t.session.session_id}${t.room?` · ${t.room}`:""}</div>
        </div>
        <span class="command-chip ${ot(t.status)}">${t.status}</span>
        ${t.status==="interrupted"?i`<small class="mission-stale-reason">서버 재시작으로 중단됨</small>`:null}
        ${t.status==="completed"?i`<small class="mission-stale-reason">정상 완료</small>`:null}
      </div>

      <div class="mission-fact-grid">
        <div class="mission-fact-tile">
          <span>멤버</span>
          <strong>${t.memberNames.length}</strong>
          <small>${t.memberNames.slice(0,3).join(", ")||"n/a"}</small>
        </div>
        <div class="mission-fact-tile">
          <span>가동 시간</span>
          <strong>${Cu(t.elapsedSec)}</strong>
          <small>${t.startedAt?`${Yt(t.startedAt)} 시작`:"시작 시각 없음"}</small>
        </div>
        <div class="mission-fact-tile">
          <span>커뮤니케이션</span>
          <strong>${t.broadcastCount+t.portalCount}</strong>
          <small>${t.communicationMode??"mode n/a"} · broadcast ${t.broadcastCount} · portal ${t.portalCount}</small>
        </div>
        <div class="mission-fact-tile">
          <span>커버리지</span>
          <strong>${t.activeCount}/${t.requiredCount||t.activeCount||1}</strong>
          <small>active / required</small>
        </div>
      </div>

      <div class="mission-crew-event">
        <span>최근 사건</span>
        <strong>${t.lastEventSummary}</strong>
        <small>${t.lastEventAt?Yt(t.lastEventAt):"시각 없음"}</small>
      </div>

      ${e.length>0?i`
            <div class="mission-member-stack">
              ${e.map(n=>i`
                <button class="mission-member-row" onClick=${()=>Gs(n.name)}>
                  <strong>${n.model!==n.nickname?i`<span class="model-badge">${n.model}</span> `:""}${n.nickname}</strong>
                  <span>${n.currentTask}</span>
                  <small>${n.output??"최근 출력 없음"}</small>
                </button>
              `)}
            </div>
          `:null}

      ${t.attentionSummary?i`<div class="mission-inline-note">attention: ${t.attentionSummary}</div>`:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Oi("intervene",t.session.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Oi("command",t.session.session_id)}>세션 원인 보기</button>
      </div>
    </article>
  `}function Zu({row:t}){const e=t.recentTools.length>0?t.recentTools.join(", "):"도구 텔레메트리 없음",n=t.withWhom.length>0?t.withWhom.slice(0,3).join(", "):"단독 또는 room-level";return i`
    <button class="mission-activity-card ${ot(t.agent.status)}" onClick=${()=>Gs(t.agent.name)}>
      <div class="mission-activity-head">
        <div class="mission-activity-title">
          <span class="agent-emoji">${t.agent.emoji??""}</span>
          <div>
            <strong>${t.agent.name}</strong>
            ${t.agent.koreanName?i`<span>${t.agent.koreanName}</span>`:null}
          </div>
        </div>
        <span class="command-chip ${ot(t.agent.status)}">${t.agent.status}</span>
      </div>

      <div class="mission-activity-meta">
        <span>어디서 · ${t.where}</span>
        <span>누구와 · ${n}</span>
        <span>언제부터 · ${t.activeSince?Yt(t.activeSince):"n/a"}</span>
      </div>

      <div class="mission-activity-focus">
        <span>무엇을</span>
        <strong>${t.currentWork}</strong>
        ${t.how?i`<small>어떻게 · ${t.how}</small>`:null}
      </div>

      <div class="mission-io-stack">
        <div class="mission-io-item">
          <span>최근 input</span>
          <strong>${t.recentInput??"명시된 recent input 없음"}</strong>
        </div>
        <div class="mission-io-item">
          <span>최근 output</span>
          <strong>${t.recentOutput??"명시된 recent output 없음"}</strong>
        </div>
      </div>

      <div class="mission-activity-foot">
        <span>최근 도구 · ${e}</span>
        ${t.recentEvent?i`<span>최근 일 · ${t.recentEvent}</span>`:null}
      </div>
    </button>
  `}function tp({row:t}){const e=[`gen ${t.keeper.generation??0}`,`handoff ${t.keeper.handoff_count_total??0}`,`compact ${t.keeper.compaction_count??0}`,t.keeper.context_ratio!=null?`ctx ${Math.round(t.keeper.context_ratio*100)}%`:null].filter(n=>n!==null).join(" · ");return i`
    <button class="mission-activity-card ${ot(t.keeper.status)}" onClick=${()=>ri(t.keeper)}>
      <div class="mission-activity-head">
        <div class="mission-activity-title">
          <span class="agent-emoji">${t.keeper.emoji??""}</span>
          <div>
            <strong>${t.keeper.name}</strong>
            ${t.keeper.koreanName?i`<span>${t.keeper.koreanName}</span>`:null}
          </div>
        </div>
        <span class="command-chip ${ot(t.keeper.status)}">${t.keeper.status}</span>
      </div>

      <div class="mission-activity-meta">
        <span>언제부터 · ${t.activeSince?Yt(t.activeSince):"n/a"}</span>
        <span>최근 heartbeat · ${t.keeper.last_heartbeat?Yt(t.keeper.last_heartbeat):"n/a"}</span>
        <span>${e}</span>
      </div>

      <div class="mission-activity-focus">
        <span>무엇을</span>
        <strong>${t.currentWork}</strong>
        ${t.keeper.skill_reason?i`<small>판단 요약 · ${V(t.keeper.skill_reason,120)}</small>`:null}
      </div>

      <div class="mission-io-stack">
        <div class="mission-io-item">
          <span>최근 input</span>
          <strong>${t.recentInput??"명시된 recent input 없음"}</strong>
        </div>
        <div class="mission-io-item">
          <span>최근 output</span>
          <strong>${t.recentOutput??"명시된 recent output 없음"}</strong>
        </div>
      </div>

      <div class="mission-activity-foot">
        <span>최근 도구 · ${t.recentTools.length>0?t.recentTools.join(", "):"도구 사용 없음"}</span>
        ${t.recentEvent?i`<span>최근 일 · ${t.recentEvent}</span>`:null}
      </div>
    </button>
  `}function ep({item:t}){return i`
    <article class="mission-action-card ${ot(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${ot(t.severity)}">${t.kind}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Pu(t)}>이 이슈로 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Nu(t)}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `}function np({action:t,incident:e}){const n=Iu(t);return i`
    <article class="mission-action-card ${ot(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${ot(t.severity)}">${di(t.action_type)}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.reason}</p>
      <div class="mission-action-detail">
        <span>${Tu(t)}</span>
        <span>${Ru(t)}</span>
      </div>
      ${n?i`<div class="mission-action-preview">${n}</div>`:null}
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Lu(t,e,"상황판 추천 액션")}>이 액션으로 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Mu(t,e,"상황판 추천 액션")}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `}function Fi(){const t=Hs.value;if(qa.value&&!t)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(vs.value&&!t)return i`<div class="empty-state error">${vs.value}</div>`;if(!t)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;const e=Bu(),n=Ju(e),s=Vu(),a=n.filter(p=>["active","busy","listening","idle"].includes(p.agent.status)).length,o=n.filter(p=>p.recentOutput).length+s.filter(p=>p.recentOutput).length,l=t.incidents[0]??null,d=t.recommended_actions[0]??null;return i`
    <section class="dashboard-panel mission-view">
      <${vt} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>사람 운영자가 누가 어디서 누구와 무엇을 하고 있는지 바로 보는 관찰면입니다. 내부 메트릭은 아래가 아니라 Command로 내렸습니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${ot(t.summary.room_health)}">${t.summary.room_health??"ok"}</span>
          <span class="command-chip">${t.summary.project??"room"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?Yt(t.generated_at):"fresh"}</span>
        </div>
      </div>

      <${Yu}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <${Xu} />

      <div class="mission-stat-grid">
        <${_e} label="활성 흐름" value=${e.length} detail="지금 보이는 crew / session" tone=${e.length>0?"ok":"warn"} />
        <${_e} label="응답 가능 에이전트" value=${a} detail="지금 응답 가능한 actor 수" tone=${a>0?"ok":"warn"} />
        <${_e} label="Keeper 수" value=${s.length} detail="연속성 runtime / generation 관찰 대상" tone=${s.length>0?"ok":"warn"} />
        <${_e} label="최근 output" value=${o} detail="main 화면에서 바로 볼 수 있는 최근 출력 수" tone=${o>0?"ok":"warn"} />
        <${_e} label="내부 incident" value=${t.incidents.length} detail="시스템 진단 신호는 아래 보조 카드로만 유지" tone=${(l==null?void 0:l.severity)??"ok"} />
        <${_e} label="추천 액션" value=${t.recommended_actions.length} detail="개입이 필요하면 Intervene로 바로 이동" tone=${(d==null?void 0:d.severity)??"ok"} />
      </div>

      <div class="mission-human-grid">
        <${C} title="같이 움직이는 흐름" class="mission-list-card" semanticId="mission.crews">
          <div class="mission-section-head">
            <h3>누가 누구와 같은 목표를 향하는지</h3>
            <p>team session 단위로 목표, 멤버, 최근 사건, 커뮤니케이션 흔적을 바로 보여줍니다.</p>
          </div>
          <div class="mission-list-stack">
            ${(()=>{const p=e.filter(m=>m.status!=="interrupted"&&m.status!=="completed"),_=e.filter(m=>m.status==="interrupted"||m.status==="completed");return p.length===0&&_.length===0?i`<div class="empty-state">지금 열려 있는 crew / session 이 없습니다.</div>`:i`
                ${p.map(m=>i`<${er} key=${m.session.session_id} row=${m} />`)}
                ${_.length>0?i`<${Qu} rows=${_} />`:null}
              `})()}
          </div>
        <//>

        <${C} title="에이전트 활동" class="mission-list-card" semanticId="mission.agent_activity">
          <div class="mission-section-head">
            <h3>각 에이전트가 지금 뭘 하는가</h3>
            <p>where / with whom / current task / recent input-output / recent tools 를 preview-first로 보여줍니다.</p>
          </div>
          <div class="mission-activity-list">
            ${n.length>0?n.slice(0,10).map(p=>i`<${Zu} key=${p.agent.name} row=${p} />`):i`<div class="empty-state">지금 보이는 에이전트 활동이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${C} title="Keeper 연속성" class="mission-list-card" semanticId="mission.keeper_activity">
          <div class="mission-section-head">
            <h3>generation / compaction / handoff 를 거치는 장기 실행체</h3>
            <p>keeper 는 별도 continuity lane 으로 보고, raw thinking 대신 최근 입출력과 판단 요약만 노출합니다.</p>
          </div>
          <div class="mission-activity-list">
            ${s.length>0?s.slice(0,8).map(p=>i`<${tp} key=${p.keeper.name} row=${p} />`):i`<div class="empty-state">지금 보이는 keeper 가 없습니다.</div>`}
          </div>
        <//>

        <${C} title="내부 진단은 여기서만" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>internal signal / recommendation</h3>
            <p>artifact_scope_drift 같은 시스템 진단은 메인 판단 근거가 아니라 보조 신호로만 유지합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${t.incidents.slice(0,2).map(p=>i`<${ep} key=${`${p.kind}:${p.target_id??"room"}`} item=${p} />`)}
            ${t.recommended_actions.slice(0,2).map(p=>i`<${np} key=${`${p.action_type}:${p.target_id??"room"}`} action=${p} />`)}
            ${t.incidents.length===0&&t.recommended_actions.length===0?i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`:null}
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>lt("execution")}>실행 관찰면 보기</button>
            <button class="control-btn ghost" onClick=${()=>lt("command")}>지휘 진단면 보기</button>
          </div>
        <//>
      </div>
    </section>
  `}const ui=g(null),Nt=g(null),ys=g(!1),bs=g(!1),ks=g(null),xs=g(null),Ua=g(null),Ss=g(null),q=g("warroom"),Pn=g(null),Ha=g(!1),As=g(null),ue=g(null),Cs=g(!1),ws=g(null),Nn=g(null),Wa=g(!1),Ts=g(null),gn=g(null),Is=g(!1),$n=g(null),Te=g(null);let Ge=null;function pi(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"}function nr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function sp(){const e=nr().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function ap(){const e=nr().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function ip(t){if(u(t))return{policy_class:r(t.policy_class),approval_class:r(t.approval_class),tool_allowlist:O(t.tool_allowlist),model_allowlist:O(t.model_allowlist),requires_human_for:O(t.requires_human_for),autonomy_level:r(t.autonomy_level),escalation_timeout_sec:c(t.escalation_timeout_sec),kill_switch:E(t.kill_switch),frozen:E(t.frozen)}}function op(t){if(u(t))return{headcount_cap:c(t.headcount_cap),active_operation_cap:c(t.active_operation_cap),max_cost_usd:c(t.max_cost_usd),max_tokens:c(t.max_tokens)}}function mi(t){if(!u(t))return null;const e=r(t.unit_id),n=r(t.label),s=r(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:r(t.parent_unit_id)??null,leader_id:r(t.leader_id)??null,roster:O(t.roster),capability_profile:O(t.capability_profile),source:r(t.source),created_at:r(t.created_at),updated_at:r(t.updated_at),policy:ip(t.policy),budget:op(t.budget)}}function sr(t){if(!u(t))return null;const e=mi(t.unit);return e?{unit:e,leader_status:r(t.leader_status),roster_total:c(t.roster_total),roster_live:c(t.roster_live),active_operation_count:c(t.active_operation_count),health:r(t.health),reasons:O(t.reasons),children:Array.isArray(t.children)?t.children.map(sr).filter(n=>n!==null):[]}:null}function rp(t){if(u(t))return{total_units:c(t.total_units),company_count:c(t.company_count),platoon_count:c(t.platoon_count),squad_count:c(t.squad_count),leaf_agent_unit_count:c(t.leaf_agent_unit_count),live_agent_count:c(t.live_agent_count),managed_unit_count:c(t.managed_unit_count),active_operation_count:c(t.active_operation_count)}}function ar(t){const e=u(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),source:r(e.source),summary:rp(e.summary),units:Array.isArray(e.units)?e.units.map(sr).filter(n=>n!==null):[]}}function lp(t){if(!u(t))return null;const e=r(t.kind),n=r(t.status);return!e||!n?null:{kind:e,chain_id:r(t.chain_id)??null,goal:r(t.goal)??null,run_id:r(t.run_id)??null,status:n,viewer_path:r(t.viewer_path)??null,last_sync_at:r(t.last_sync_at)??null}}function Vs(t){if(!u(t))return null;const e=r(t.operation_id),n=r(t.objective),s=r(t.assigned_unit_id),a=r(t.trace_id),o=r(t.status);return!e||!n||!s||!a||!o?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:r(t.autonomy_level),policy_class:r(t.policy_class),budget_class:r(t.budget_class),detachment_session_id:r(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(t.checkpoint_ref)??null,active_goal_ids:O(t.active_goal_ids),note:r(t.note)??null,created_by:r(t.created_by),source:r(t.source),status:o,chain:lp(t.chain),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function cp(t){if(!u(t))return null;const e=Vs(t.operation);return e?{operation:e,assigned_unit_label:r(t.assigned_unit_label)}:null}function He(t){if(u(t))return{tone:r(t.tone),pending_ops:c(t.pending_ops),blocked_ops:c(t.blocked_ops),in_flight_ops:c(t.in_flight_ops),pipeline_stalls:c(t.pipeline_stalls),bus_traffic:c(t.bus_traffic),l1_hit_rate:c(t.l1_hit_rate),invalidation_count:c(t.invalidation_count),current_pending:c(t.current_pending),current_in_flight:c(t.current_in_flight),cdb_wakeups:c(t.cdb_wakeups),total_stolen:c(t.total_stolen),avg_best_score:c(t.avg_best_score),avg_candidate_count:c(t.avg_candidate_count),best_first_operations:c(t.best_first_operations),active_sessions:c(t.active_sessions),commit_rate:c(t.commit_rate),total_speculations:c(t.total_speculations)}}function dp(t){if(!u(t))return;const e=u(t.pipeline)?t.pipeline:void 0,n=u(t.cache)?t.cache:void 0,s=u(t.ooo)?t.ooo:void 0,a=u(t.speculative)?t.speculative:void 0,o=u(t.search_fabric)?t.search_fabric:void 0,l=u(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:c(e.total_ops),completed_ops:c(e.completed_ops),stalled_cycles:c(e.stalled_cycles),hazards_detected:c(e.hazards_detected),forwarding_used:c(e.forwarding_used),pipeline_flushes:c(e.pipeline_flushes),ipc:c(e.ipc)}:void 0,cache:n?{total_reads:c(n.total_reads),total_writes:c(n.total_writes),l1_hit_rate:c(n.l1_hit_rate),invalidation_count:c(n.invalidation_count),writeback_count:c(n.writeback_count),bus_traffic:c(n.bus_traffic)}:void 0,ooo:s?{agent_count:c(s.agent_count),total_added:c(s.total_added),total_issued:c(s.total_issued),total_completed:c(s.total_completed),total_stolen:c(s.total_stolen),cdb_wakeups:c(s.cdb_wakeups),stall_cycles:c(s.stall_cycles),global_cdb_events:c(s.global_cdb_events),current_pending:c(s.current_pending),current_in_flight:c(s.current_in_flight)}:void 0,speculative:a?{total_speculations:c(a.total_speculations),total_commits:c(a.total_commits),total_aborts:c(a.total_aborts),commit_rate:c(a.commit_rate),total_fast_calls:c(a.total_fast_calls),total_cost_usd:c(a.total_cost_usd),active_sessions:c(a.active_sessions)}:void 0,search_fabric:o?{total_operations:c(o.total_operations),best_first_operations:c(o.best_first_operations),legacy_operations:c(o.legacy_operations),blocked_operations:c(o.blocked_operations),ready_operations:c(o.ready_operations),research_pipeline_operations:c(o.research_pipeline_operations),avg_candidate_count:c(o.avg_candidate_count),avg_best_score:c(o.avg_best_score),top_stage:r(o.top_stage)??null}:void 0,signals:l?{issue_pressure:He(l.issue_pressure),cache_contention:He(l.cache_contention),scheduler_efficiency:He(l.scheduler_efficiency),routing_confidence:He(l.routing_confidence),speculative_posture:He(l.speculative_posture)}:void 0}}function ir(t){const e=u(t)?t:{},n=u(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:c(n.total),active:c(n.active),paused:c(n.paused),managed:c(n.managed),projected:c(n.projected)}:void 0,microarch:dp(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(cp).filter(s=>s!==null):[]}}function or(t){if(!u(t))return null;const e=r(t.detachment_id),n=r(t.operation_id),s=r(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:r(t.leader_id)??null,roster:O(t.roster),session_id:r(t.session_id)??null,checkpoint_ref:r(t.checkpoint_ref)??null,runtime_kind:r(t.runtime_kind)??null,runtime_ref:r(t.runtime_ref)??null,source:r(t.source),status:r(t.status),last_event_at:r(t.last_event_at)??null,last_progress_at:r(t.last_progress_at)??null,heartbeat_deadline:r(t.heartbeat_deadline)??null,created_at:r(t.created_at),updated_at:r(t.updated_at)}}function up(t){if(!u(t))return null;const e=or(t.detachment);return e?{detachment:e,assigned_unit_label:r(t.assigned_unit_label),operation:Vs(t.operation)}:null}function rr(t){const e=u(t)?t:{},n=u(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:c(n.total),active:c(n.active),projected:c(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(up).filter(s=>s!==null):[]}}function pp(t){if(!u(t))return null;const e=r(t.decision_id),n=r(t.trace_id),s=r(t.requested_action),a=r(t.scope_type),o=r(t.scope_id);return!e||!n||!s||!a||!o?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:r(t.operation_id)??null,target_unit_id:r(t.target_unit_id)??null,requested_by:r(t.requested_by),status:r(t.status),reason:r(t.reason)??null,source:r(t.source),detail:t.detail,created_at:r(t.created_at),decided_at:r(t.decided_at)??null,expires_at:r(t.expires_at)??null}}function lr(t){const e=u(t)?t:{},n=u(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:c(n.total),pending:c(n.pending),approved:c(n.approved),denied:c(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(pp).filter(s=>s!==null):[]}}function mp(t){if(!u(t))return null;const e=mi(t.unit);return e?{unit:e,roster_total:c(t.roster_total),roster_live:c(t.roster_live),headcount_cap:c(t.headcount_cap),active_operations:c(t.active_operations),active_operation_cap:c(t.active_operation_cap),utilization:c(t.utilization)}:null}function vp(t){const e=u(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(mp).filter(n=>n!==null):[]}}function _p(t){if(!u(t))return null;const e=r(t.alert_id);return e?{alert_id:e,severity:r(t.severity),kind:r(t.kind),scope_type:r(t.scope_type),scope_id:r(t.scope_id),title:r(t.title),detail:r(t.detail),timestamp:r(t.timestamp)}:null}function cr(t){const e=u(t)?t:{},n=u(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:c(n.total),bad:c(n.bad),warn:c(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(_p).filter(s=>s!==null):[]}}function dr(t){if(!u(t))return null;const e=r(t.event_id),n=r(t.trace_id),s=r(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:r(t.operation_id)??null,unit_id:r(t.unit_id)??null,actor:r(t.actor)??null,source:r(t.source),timestamp:r(t.timestamp),detail:t.detail}}function fp(t){const e=u(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),events:Array.isArray(e.events)?e.events.map(dr).filter(n=>n!==null):[]}}function gp(t){if(!u(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function $p(t){if(!u(t))return null;const e=r(t.lane_id),n=r(t.label),s=r(t.kind),a=r(t.phase),o=r(t.motion_state),l=r(t.source_of_truth),d=r(t.movement_reason),p=r(t.current_step);if(!e||!n||!s||!a||!o||!l||!d||!p)return null;const _=u(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:E(t.present)??!1,phase:a,motion_state:o,source_of_truth:l,last_movement_at:r(t.last_movement_at)??null,movement_reason:d,current_step:p,blockers:O(t.blockers),counts:{operations:c(_.operations),detachments:c(_.detachments),workers:c(_.workers),approvals:c(_.approvals),alerts:c(_.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(gp).filter(m=>m!==null):[]}}function hp(t){if(!u(t))return null;const e=r(t.event_id),n=r(t.lane_id),s=r(t.kind),a=r(t.timestamp),o=r(t.title),l=r(t.detail),d=r(t.tone),p=r(t.source);return!e||!n||!s||!a||!o||!l||!d||!p?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:o,detail:l,tone:d,source:p}}function yp(t){if(!u(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,lane_ids:O(t.lane_ids),count:c(t.count)??0}}function ur(t){if(!u(t))return;const e=u(t.overview)?t.overview:{},n=u(t.gaps)?t.gaps:{},s=u(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:r(t.generated_at),overview:{active_lanes:c(e.active_lanes),moving_lanes:c(e.moving_lanes),stalled_lanes:c(e.stalled_lanes),projected_lanes:c(e.projected_lanes),last_movement_at:r(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map($p).filter(a=>a!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(hp).filter(a=>a!==null):[],gaps:{count:c(n.count),items:Array.isArray(n.items)?n.items.map(yp).filter(a=>a!==null):[]},recommended_next_action:s?{tool:r(s.tool)??"masc_operator_snapshot",label:r(s.label)??"Observe operator state",reason:r(s.reason)??"",lane_id:r(s.lane_id)??null}:void 0}}function bp(t){if(!u(t))return;const e=u(t.workers)?t.workers:{},n=E(t.pass);return{status:r(t.status)??"missing",source:r(t.source)??"none",run_id:r(t.run_id)??null,captured_at:r(t.captured_at)??null,...n!==void 0?{pass:n}:{},...c(t.peak_hot_slots)!=null?{peak_hot_slots:c(t.peak_hot_slots)}:{},...c(t.ctx_per_slot)!=null?{ctx_per_slot:c(t.ctx_per_slot)}:{},workers:{expected:c(e.expected),joined:c(e.joined),current_task_bound:c(e.current_task_bound),fresh_heartbeats:c(e.fresh_heartbeats),done:c(e.done),final:c(e.final)},artifact_ref:r(t.artifact_ref)??null,missing_reason:r(t.missing_reason)??null}}function kp(t){const e=u(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),topology:ar(e.topology),operations:ir(e.operations),detachments:rr(e.detachments),alerts:cr(e.alerts),decisions:lr(e.decisions),capacity:vp(e.capacity),traces:fp(e.traces),swarm_status:ur(e.swarm_status)}}function xp(t){const e=u(t)?t:{},n=ar(e.topology),s=ir(e.operations),a=rr(e.detachments),o=cr(e.alerts),l=lr(e.decisions);return{version:r(e.version),generated_at:r(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:ur(e.swarm_status),swarm_proof:bp(e.swarm_proof)}}function Sp(t){return u(t)?{chain_id:r(t.chain_id)??null,started_at:c(t.started_at)??null,progress:c(t.progress)??null,elapsed_sec:c(t.elapsed_sec)??null}:null}function pr(t){if(!u(t))return null;const e=r(t.event);return e?{event:e,chain_id:r(t.chain_id)??null,timestamp:r(t.timestamp)??null,duration_ms:c(t.duration_ms)??null,message:r(t.message)??null,tokens:c(t.tokens)??null}:null}function Ap(t){if(!u(t))return null;const e=Vs(t.operation);return e?{operation:e,runtime:Sp(t.runtime),history:pr(t.history),mermaid:r(t.mermaid)??null,preview_run:mr(t.preview_run)}:null}function Cp(t){const e=u(t)?t:{};return{status:r(e.status)??"disconnected",base_url:r(e.base_url)??null,message:r(e.message)??null}}function wp(t){const e=u(t)?t:{},n=u(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),connection:Cp(e.connection),summary:n?{linked_operations:c(n.linked_operations),active_chains:c(n.active_chains),running_operations:c(n.running_operations),recent_failures:c(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(Ap).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(pr).filter(s=>s!==null):[]}}function Tp(t){if(!u(t))return null;const e=r(t.id);return e?{id:e,type:r(t.type),status:r(t.status),duration_ms:c(t.duration_ms)??null,error:r(t.error)??null}:null}function mr(t){if(!u(t))return null;const e=r(t.run_id),n=r(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:c(t.duration_ms),success:E(t.success),mermaid:r(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(Tp).filter(s=>s!==null):[]}:null}function Ip(t){const e=u(t)?t:{};return{run:mr(e.run)}}function Rp(t){if(!u(t))return null;const e=r(t.title),n=r(t.path);return!e||!n?null:{title:e,path:n}}function Pp(t){if(!u(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function Np(t){if(!u(t))return null;const e=r(t.id),n=r(t.title),s=r(t.tool),a=r(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:O(t.success_signals),pitfalls:O(t.pitfalls)}}function Lp(t){if(!u(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary),a=r(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(Np).filter(o=>o!==null):[]}}function Mp(t){if(!u(t))return null;const e=r(t.id),n=r(t.title),s=r(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:O(t.tools)}}function Dp(t){if(!u(t))return null;const e=r(t.id),n=r(t.title),s=r(t.symptom),a=r(t.why),o=r(t.fix_tool),l=r(t.fix_summary);return!e||!n||!s||!a||!o||!l?null:{id:e,title:n,symptom:s,why:a,fix_tool:o,fix_summary:l}}function Ep(t){if(!u(t))return null;const e=r(t.id),n=r(t.title),s=r(t.path_id),a=r(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:O(t.notes)}}function zp(t){const e=u(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(Rp).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(Pp).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(Lp).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Mp).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Dp).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Ep).filter(n=>n!==null):[]}}function jp(t){if(!u(t))return null;const e=r(t.id),n=r(t.title),s=r(t.status),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{id:e,title:n,status:s,detail:a,next_tool:o}}function Op(t){if(!u(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.title),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{code:e,severity:n,title:s,detail:a,next_tool:o}}function Fp(t){if(!u(t))return null;const e=r(t.from),n=r(t.content),s=r(t.timestamp),a=c(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function qp(t){if(!u(t))return null;const e=r(t.name),n=r(t.role),s=r(t.lane),a=r(t.status),o=r(t.claim_marker),l=r(t.done_marker),d=r(t.final_marker);if(!e||!n||!s||!a||!o||!l||!d)return null;const p=(()=>{if(!u(t.last_message))return null;const _=c(t.last_message.seq),m=r(t.last_message.content),v=r(t.last_message.timestamp);return _==null||!m||!v?null:{seq:_,content:m,timestamp:v}})();return{name:e,role:n,lane:s,joined:E(t.joined)??!1,live_presence:E(t.live_presence)??!1,completed:E(t.completed)??!1,status:a,current_task:r(t.current_task)??null,bound_task_id:r(t.bound_task_id)??null,bound_task_title:r(t.bound_task_title)??null,bound_task_status:r(t.bound_task_status)??null,current_task_matches_run:E(t.current_task_matches_run)??!1,squad_member:E(t.squad_member)??!1,detachment_member:E(t.detachment_member)??!1,last_seen:r(t.last_seen)??null,heartbeat_age_sec:c(t.heartbeat_age_sec)??null,heartbeat_fresh:E(t.heartbeat_fresh)??!1,claim_marker_seen:E(t.claim_marker_seen)??!1,done_marker_seen:E(t.done_marker_seen)??!1,final_marker_seen:E(t.final_marker_seen)??!1,claim_marker:o,done_marker:l,final_marker:d,last_message:p}}function Kp(t){if(!u(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!u(n))return null;const s=r(n.timestamp),a=c(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:r(t.slot_url)??null,provider_base_url:r(t.provider_base_url)??null,provider_reachable:E(t.provider_reachable)??null,provider_status_code:c(t.provider_status_code)??null,provider_model_id:r(t.provider_model_id)??null,actual_model_id:r(t.actual_model_id)??null,expected_slots:c(t.expected_slots),actual_slots:c(t.actual_slots),expected_ctx:c(t.expected_ctx),actual_ctx:c(t.actual_ctx),slot_reachable:E(t.slot_reachable)??null,slot_status_code:c(t.slot_status_code)??null,runtime_blocker:r(t.runtime_blocker)??null,detail:r(t.detail)??null,checked_at:r(t.checked_at)??null,total_slots:c(t.total_slots),ctx_per_slot:c(t.ctx_per_slot),active_slots_now:c(t.active_slots_now),peak_active_slots:c(t.peak_active_slots),sample_count:c(t.sample_count),last_sample_at:r(t.last_sample_at)??null,timeline:e}}function Up(t){const e=u(t)?t:{},n=u(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),run_id:r(e.run_id),room_id:r(e.room_id),operation_id:r(e.operation_id)??null,recommended_next_tool:r(e.recommended_next_tool),summary:n?{expected_workers:c(n.expected_workers),joined_workers:c(n.joined_workers),live_workers:c(n.live_workers),squad_roster_size:c(n.squad_roster_size),detachment_roster_size:c(n.detachment_roster_size),current_task_bound:c(n.current_task_bound),fresh_heartbeats:c(n.fresh_heartbeats),claim_markers_seen:c(n.claim_markers_seen),done_markers_seen:c(n.done_markers_seen),final_markers_seen:c(n.final_markers_seen),completed_workers:c(n.completed_workers),peak_hot_slots:c(n.peak_hot_slots),hot_window_ok:E(n.hot_window_ok),pass_hot_concurrency:E(n.pass_hot_concurrency),pass_end_to_end:E(n.pass_end_to_end),pending_decisions:c(n.pending_decisions),pass:E(n.pass)}:void 0,provider:Kp(e.provider),operation:Vs(e.operation),squad:mi(e.squad),detachment:or(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(qp).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(jp).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Op).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Fp).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(dr).filter(s=>s!==null):[],truth_notes:O(e.truth_notes)}}function de(t){q.value=t,pi(t)&&Hp()}async function vr(){ys.value=!0,ks.value=null;try{const t=await wl();ui.value=xp(t)}catch(t){ks.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{ys.value=!1}}function vi(t){Te.value=t}async function _i(){bs.value=!0,xs.value=null;try{const t=await Cl();Nt.value=kp(t)}catch(t){xs.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{bs.value=!1}}async function Hp(){Nt.value||bs.value||await _i()}async function Ht(){await vr(),pi(q.value)&&await _i()}async function Wt(){var t;Wa.value=!0,Ts.value=null;try{const e=await Tl(),n=wp(e);Nn.value=n;const s=Te.value;n.operations.length===0?Te.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Te.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Ts.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{Wa.value=!1}}function Wp(){Ge=null,gn.value=null,Is.value=!1,$n.value=null}async function Bp(t){Ge=t,Is.value=!0,$n.value=null;try{const e=await Il(t);if(Ge!==t)return;gn.value=Ip(e)}catch(e){if(Ge!==t)return;gn.value=null,$n.value=e instanceof Error?e.message:"Failed to load chain run"}finally{Ge===t&&(Is.value=!1)}}async function Gp(){Ha.value=!0,As.value=null;try{const t=await Rl();Pn.value=zp(t)}catch(t){As.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Ha.value=!1}}async function St(t=sp(),e=ap()){Cs.value=!0,ws.value=null;try{const n=await Pl(t,e);ue.value=Up(n)}catch(n){ws.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{Cs.value=!1}}async function Zt(t,e,n){Ua.value=t,Ss.value=null;try{await Nl(e,n),await vr(),(Nt.value||pi(q.value))&&await _i(),await St(),await Wt()}catch(s){throw Ss.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{Ua.value=null}}function Jp(t){return Zt(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Vp(t){return Zt(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function Yp(t){return Zt(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Xp(t={}){return Zt("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function Qp(t){return Zt(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Zp(t){return Zt(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function tm(t,e){return Zt(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function em(t,e){return Zt(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}od(()=>{Ht(),Wt(),(q.value==="swarm"||q.value==="warroom"||ue.value!==null)&&St(),q.value==="warroom"&&tt()});const nm="modulepreload",sm=function(t){return"/dashboard/"+t},qi={},am=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(_){return Promise.all(_.map(m=>Promise.resolve(m).then(v=>({status:"fulfilled",value:v}),v=>({status:"rejected",reason:v}))))};document.getElementsByTagName("link");const d=document.querySelector("meta[property=csp-nonce]"),p=(d==null?void 0:d.nonce)||(d==null?void 0:d.getAttribute("nonce"));a=l(n.map(_=>{if(_=sm(_),_ in qi)return;qi[_]=!0;const m=_.endsWith(".css"),v=m?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${_}"]${v}`))return;const f=document.createElement("link");if(f.rel=m?"stylesheet":nm,m||(f.as="script"),f.crossOrigin="",f.href=_,p&&f.setAttribute("nonce",p),document.head.appendChild(f),m)return new Promise((h,k)=>{f.addEventListener("load",h),f.addEventListener("error",()=>k(new Error(`Unable to preload CSS for ${_}`)))})}))}function o(l){const d=new Event("vite:preloadError",{cancelable:!0});if(d.payload=l,window.dispatchEvent(d),!d.defaultPrevented)throw l}return a.then(l=>{for(const d of l||[])d.status==="rejected"&&o(d.reason);return e().catch(o)})};function _r(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function B(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function im(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function fr(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function P(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let Ki=!1,om=0;function rm(){return++om}let sa=null;async function lm(){sa||(sa=am(()=>import("./mermaid.core-BqcZ7r6j.js").then(e=>e.bE),[]).then(e=>e.default));const t=await sa;return Ki||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),Ki=!0),t}function Bt(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Ln(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function Je(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function Mn(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function ie(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:Mn(t/e*100)}function cm(t,e){const n=Mn(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function gr(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const dm=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],$r=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],um=$r.map(t=>t.id),pm=["chain_start","node_start","node_complete","chain_complete","chain_error"],mm={warroom:{title:"라이브 워룸",description:"실제 run, worker, message, trace를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function Ui(t){return!!t&&um.includes(t)}function vm(){const t=D.value.params;return t.source!=="mission"?{}:{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function hr(t){const e=vm();if(t==="operations")return e;if(t==="chains"){const n=Te.value;return n?{...e,surface:t,operation:n}:{...e,surface:t}}return{...e,surface:t}}function _m(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function fm(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function et(t){return Ua.value===t}function Dn(){return ui.value}function gm(t){var a,o,l,d,p,_,m;const e=ui.value,n=ue.value,s=Nn.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"live run, worker, message, trace를 한 화면에서 보고 필요한 detail 표면으로 바로 점프합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(o=e==null?void 0:e.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((p=(d=e==null?void 0:e.swarm_status)==null?void 0:d.recommended_next_action)==null?void 0:p.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(m=(_=s==null?void 0:s.operations[0])==null?void 0:_.preview_run)!=null&&m.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function $m(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function hm(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function ym(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function yr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function bm(){const e=yr().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function br(){const e=yr().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function km(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function xm(t){return t.status==="claimed"||t.status==="in_progress"}function Sm(t){const e=Pn.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function aa(t){var e;return((e=Pn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function Am(t){const e=Pn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function Gt(t){try{await t()}catch{}}function fi(t){return(t==null?void 0:t.trim().toLowerCase())??""}function be(t){const e=fi(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function ia(t){const e=fi(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function Cm(){var e,n,s;const t=ue.value;return t?!!(t.run_id||(e=t.operation)!=null&&e.operation_id||(n=t.detachment)!=null&&n.detachment_id||(((s=t.summary)==null?void 0:s.expected_workers)??0)>0||t.workers.length>0||t.recent_messages.length>0||t.recent_trace_events.length>0):!1}function wm(t){const e=fi(t.status);return e==="active"||e==="running"}function Tm(){var o,l,d,p;const t=((o=It.value)==null?void 0:o.sessions)??[],e=ue.value,n=((l=e==null?void 0:e.detachment)==null?void 0:l.session_id)??null;if(n){const _=t.find(m=>m.session_id===n);if(_)return _}const s=((d=e==null?void 0:e.operation)==null?void 0:d.operation_id)??br();if(s){const _=t.find(m=>m.command_plane_operation_id===s);if(_)return _}const a=((p=e==null?void 0:e.detachment)==null?void 0:p.detachment_id)??null;if(a){const _=t.find(m=>m.command_plane_detachment_id===a);if(_)return _}return t.find(wm)??t[0]??null}function Im(){const t=Rn(D.value);return t?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${di(t.action_type)}</span>
        <span class="command-chip">${ci(t)}</span>
        <span class="command-chip">${Au(D.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?i`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function Rm(){const t=q.value,e=mm[t],n=gm(t);return i`
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
  `}function Kn({label:t,value:e,subtext:n,percent:s,color:a}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${cm(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(Mn(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function Un({label:t,value:e,detail:n,percent:s,tone:a}){return i`
    <article class="command-signal-rail ${P(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${P(a)}" style=${`width: ${Math.max(8,Math.round(Mn(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function Pm(){var z,G,F,J;const t=Dn(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,o=t==null?void 0:t.alerts.summary,l=(z=t==null?void 0:t.swarm_status)==null?void 0:z.overview,d=t==null?void 0:t.swarm_proof,p=t==null?void 0:t.operations.microarch,_=(e==null?void 0:e.managed_unit_count)??0,m=(e==null?void 0:e.total_units)??0,v=(n==null?void 0:n.active)??0,f=(s==null?void 0:s.active)??0,h=(l==null?void 0:l.moving_lanes)??0,k=(l==null?void 0:l.active_lanes)??0,x=(d==null?void 0:d.workers.done)??0,S=(d==null?void 0:d.workers.expected)??0,w=(o==null?void 0:o.bad)??0,A=(o==null?void 0:o.warn)??0,N=(a==null?void 0:a.pending)??0,T=(a==null?void 0:a.total)??0,I=v+f,H=((G=p==null?void 0:p.cache)==null?void 0:G.l1_hit_rate)??((J=(F=p==null?void 0:p.signals)==null?void 0:F.cache_contention)==null?void 0:J.l1_hit_rate)??0,K=v>0||f>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",$=v>0||h>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${K}</h3>
        <p>${$}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${P(v>0?"ok":"warn")}">활성 작전 ${v}</span>
          <span class="command-chip ${P(h>0?"ok":(k>0,"warn"))}">이동 레인 ${h}/${Math.max(k,h)}</span>
          <span class="command-chip ${P(w>0?"bad":A>0?"warn":"ok")}">치명 알림 ${w}</span>
          <span class="command-chip ${P(N>0?"warn":"ok")}">승인 대기 ${N}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${Kn}
          label="관리 단위 범위"
          value=${`${_}/${Math.max(m,_)}`}
          subtext=${m>0?`${m-_}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${ie(_,Math.max(m,_))}
          color="#67e8f9"
        />
        <${Kn}
          label="실행 열도"
          value=${String(I)}
          subtext=${`${v}개 작전 + ${f}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${ie(I,Math.max(_,I||1))}
          color="#4ade80"
        />
        <${Kn}
          label="스웜 이동감"
          value=${`${h}/${Math.max(k,h)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${B(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${ie(h,Math.max(k,h||1))}
          color="#fbbf24"
        />
        <${Kn}
          label="증거 수집률"
          value=${`${x}/${Math.max(S,x)}`}
          subtext=${d!=null&&d.status?`증거 소스 ${d.source} · ${d.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${ie(x,Math.max(S,x||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${Un}
        label="승인 대기열"
        value=${`${N}건 대기`}
        detail=${`현재 정책 창에서 ${T}개 결정을 추적 중입니다`}
        percent=${ie(N,Math.max(T,N||1))}
        tone=${N>0?"warn":"ok"}
      />
      <${Un}
        label="알림 압력"
        value=${`${w} bad / ${A} warn`}
        detail=${w>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${ie(w*2+A,Math.max((w+A)*2,1))}
        tone=${w>0?"bad":A>0?"warn":"ok"}
      />
      <${Un}
        label="디스패치 점유"
          value=${`${f}개 가동`}
        detail=${_>0?`${_}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${ie(f,Math.max(_,f||1))}
        tone=${f>0?"ok":"warn"}
      />
      <${Un}
        label="캐시 신뢰도"
        value=${H?Ln(H):"n/a"}
        detail=${H?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Mn((H??0)*100)}
        tone=${H>=.75?"ok":H>=.4?"warn":"bad"}
      />
    </div>
  `}function Nm(){var f,h,k,x,S;const t=Dn(),e=Nn.value,n=Rn(D.value),s=$m(n),a=t==null?void 0:t.topology.summary,o=t==null?void 0:t.operations.summary,l=(f=t==null?void 0:t.swarm_status)==null?void 0:f.overview,d=t==null?void 0:t.operations.microarch,p=t==null?void 0:t.decisions.summary,_=t==null?void 0:t.alerts.summary,m=(h=d==null?void 0:d.signals)==null?void 0:h.issue_pressure,v=d==null?void 0:d.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((k=t==null?void 0:t.detachments.summary)==null?void 0:k.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(p==null?void 0:p.pending)??0}</strong><small>${(p==null?void 0:p.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(_==null?void 0:_.bad)??0}</strong><small>${(_==null?void 0:_.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((x=e==null?void 0:e.summary)==null?void 0:x.active_chains)??0}</strong><small>${((S=e==null?void 0:e.summary)==null?void 0:S.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${B(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(m==null?void 0:m.pending_ops)??0}</strong><small>${(v==null?void 0:v.l1_hit_rate)!=null?`${Ln(v.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(m==null?void 0:m.tone)??"n/a"}</small></div>
    </div>
  `}function Lm(){var z,G,F,J,b,ht,Ot,te,ee;const t=Dn(),e=Nt.value,n=mt.value,s=ym(),a=s?_t.value.find(M=>M.name===s)??null:null,o=s?Ct.value.filter(M=>M.assignee===s&&xm(M)):[],l=((z=t==null?void 0:t.operations.summary)==null?void 0:z.active)??0,d=((G=t==null?void 0:t.detachments.summary)==null?void 0:G.total)??0,p=((F=t==null?void 0:t.decisions.summary)==null?void 0:F.pending)??0,_=e==null?void 0:e.detachments.detachments.find(M=>{const yt=M.detachment.heartbeat_deadline,ne=yt?Date.parse(yt):Number.NaN;return M.detachment.status==="stalled"||!Number.isNaN(ne)&&ne<=Date.now()}),m=e==null?void 0:e.alerts.alerts.find(M=>M.severity==="bad"),v=!!(n!=null&&n.room||n!=null&&n.project),f=(a==null?void 0:a.current_task)??null,h=km(a==null?void 0:a.last_seen),k=h!=null?h<=120:null,x=[v?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:Ct.value.length>0?"masc_claim":"masc_add_task"}:f?k===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${f} 이지만 heartbeat가 stale 합니다 (${h}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${f}${h!=null?` · 마지막 활동 ${h}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((J=t.topology.summary)==null?void 0:J.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((b=t.topology.summary)==null?void 0:b.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((ht=t.topology.summary)==null?void 0:ht.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},p>0?{title:"디스패치 준비도",tone:"warn",detail:`${p}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&d===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:_||m?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${_?` · detachment ${_.detachment.detachment_id} 가 stalled 상태입니다`:""}${m?` · alert ${m.title??m.alert_id}`:""}${!e&&!_&&!m?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${d}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],S=v?!s||!a?"masc_join":o.length===0?Ct.value.length>0?"masc_claim":"masc_add_task":f?k===!1?"masc_heartbeat":!t||(((Ot=t.topology.summary)==null?void 0:Ot.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":p>0?"masc_policy_approve":l>0&&d===0||_||m?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",w=Sm(S),N=Am(S==="masc_set_room"?["repo-root-room"]:S==="masc_plan_set_task"?["claimed-not-current"]:S==="masc_heartbeat"?["heartbeat-stale"]:S==="masc_dispatch_tick"?["no-detachments"]:S==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),T=aa("room_task_hygiene"),I=aa("cpv2_benchmark"),H=aa("supervisor_session"),K=((te=Pn.value)==null?void 0:te.docs)??[],$=[T,I,H].filter(M=>M!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${L} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(w==null?void 0:w.title)??S}</strong>
            <span class="command-chip ok">${S}</span>
          </div>
          <p>${(w==null?void 0:w.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(ee=w==null?void 0:w.success_signals)!=null&&ee.length?i`<div class="command-tag-row">
                ${w.success_signals.map(M=>i`<span class="command-tag ok">${M}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${x.map(M=>i`
            <article class="command-readiness-row ${P(M.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${M.title}</strong>
                  <span class="command-chip ${P(M.tone)}">${M.tone}</span>
                </div>
                <p>${M.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${M.tool}</div>
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
                  ${N.map(M=>i`
                    <article class="command-guide-inline">
                      <strong>${M.title}</strong>
                      <div>${M.symptom}</div>
                      <div class="command-card-sub">${M.fix_tool} 로 해결: ${M.fix_summary}</div>
                    </article>
                  `)}
                </div>
              </div>
            `:null}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">운영 경로</div>
          <${L} panelId="command.summary" compact=${!0} />
        </div>
        ${Ha.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:As.value?i`<div class="empty-state error">${As.value}</div>`:i`
                <div class="command-path-grid">
                  ${$.map(M=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${M.title}</strong>
                        <span class="command-chip">${M.id}</span>
                      </div>
                      <p>${M.summary}</p>
                      <div class="command-card-sub">${M.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${M.steps.slice(0,4).map(yt=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${yt.tool}</span>
                            <span>${yt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${K.length>0?i`<div class="command-doc-links">
                      ${K.map(M=>i`<span class="command-tag">${M.title}: ${M.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Mm(){return i`
    <${Pm} />
    <${Nm} />
    <${Lm} />
  `}function Dm(){return bs.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:xs.value?i`<div class="empty-state error">${xs.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function kr({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,o=t.unit.policy;return i`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${fm(t.unit.kind)}</span>
            <span class="command-chip ${P(t.health)}">${t.health??"ok"}</span>
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
            ${t.children.map(l=>i`<${kr} node=${l} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function Em({alert:t}){return i`
    <article class="command-alert ${P(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${P(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${B(t.timestamp)}</span>
      </div>
      ${t.detail?i`<p>${t.detail}</p>`:null}
    </article>
  `}function gi({event:t}){return i`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${B(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${_r(t.detail)}</pre>
    </article>
  `}function zm(){const t=Nt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${L} panelId="command.topology" compact=${!0} />
      </div>
      ${t&&t.topology.units.length>0?i`${t.topology.units.map(e=>i`<${kr} node=${e} />`)}`:i`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function jm(){const t=Nt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${L} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>i`<${Em} alert=${e} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function Om(){const t=Nt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${L} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?i`<div class="command-trace-stack">
            ${t.traces.events.map(e=>i`<${gi} event=${e} />`)}
          </div>`:i`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function xr(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function Sr({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const o=a.motion_state;o in e?e[o]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return i`
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
  `}function Fm({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${a.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?i`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function qm({lane:t}){const e=t.counts??{},n=xr(t),s=e.workers??0,a=e.operations??0,o=e.detachments??0,l=a+o,d=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return i`
    <article class="swarm-lane-strip ${P(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${P(n)}">${t.phase}</span>
          <span class="command-chip ${P(n)}">${t.motion_state}</span>
          <span class="command-chip">${B(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${P(n)}" style=${`width:${d}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${s>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${Fm} total=${s} />
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
              ${t.hard_flags.map(p=>i`<span class="command-chip ${P(p.severity)}">${p.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Ar({lanes:t}){const e=t.slice(0,4);return e.length===0?null:i`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=xr(n),a=n.counts.workers??0,o=n.counts.operations??0,l=n.counts.detachments??0;return i`
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
  `}function Km({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${P(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?i`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function Um({gap:t}){return i`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${P(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function Hm({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${P(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${P(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?i`
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${B(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.artifact_ref?i`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?i`<p>${t.missing_reason}</p>`:null}
          `:i`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function Wm(){const t=Dn(),e=Rn(D.value),n=hm(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,o=(s==null?void 0:s.lanes.filter(v=>v.present))??[],l=(s==null?void 0:s.gaps.items)??[],d=(s==null?void 0:s.timeline.slice(0,8))??[],p=s==null?void 0:s.overview,_=s==null?void 0:s.recommended_next_action,m=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${L} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${Ar} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(p==null?void 0:p.active_lanes)??0}</strong><small>${(p==null?void 0:p.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(p==null?void 0:p.stalled_lanes)??0}</strong><small>${(p==null?void 0:p.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${B(p==null?void 0:p.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${B(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(_==null?void 0:_.label)??"운영자 상태 확인"}</strong><small>${(_==null?void 0:_.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${Sr} lanes=${o} />`:null}

            <div class="command-swarm-layout ${m?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(v=>i`<${qm} lane=${v} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight ${n==="recommendation"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>${(_==null?void 0:_.label)??"운영자 상태 확인"}</strong>
                    <span class="command-chip">${(_==null?void 0:_.lane_id)??"전체"}</span>
                  </div>
                  <p>${(_==null?void 0:_.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="command-card-foot">${(_==null?void 0:_.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${Hm} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${P(l.some(v=>v.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?i`<div class="swarm-event-rail">${l.slice(0,4).map(v=>i`<${Um} gap=${v} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${d.length}</span>
                  </div>
                  ${d.length>0?i`<div class="swarm-event-rail">${d.map(v=>i`<${Km} event=${v} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function Bm({item:t}){return i`
    <article class="command-guide-card ${P(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${P(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Cr({blocker:t}){return i`
    <article class="command-alert ${P(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${P(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function Gm({worker:t}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${P(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${t.last_message?i`<div class="command-card-foot">${B(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function Jm(){var p,_,m,v,f,h,k,x,S,w,A,N,T,I,H,K,$,z,G,F,J;const t=ue.value,e=bm(),n=br(),s=(p=t==null?void 0:t.provider)!=null&&p.runtime_blocker?"blocked":(_=t==null?void 0:t.provider)!=null&&_.provider_reachable?"ready":"check",a=((m=t==null?void 0:t.provider)==null?void 0:m.actual_slots)??((v=t==null?void 0:t.provider)==null?void 0:v.total_slots)??0,o=((f=t==null?void 0:t.provider)==null?void 0:f.expected_slots)??"n/a",l=((h=t==null?void 0:t.provider)==null?void 0:h.actual_ctx)??((k=t==null?void 0:t.provider)==null?void 0:k.ctx_per_slot)??0,d=((x=t==null?void 0:t.provider)==null?void 0:x.expected_ctx)??"n/a";return i`
    <div class="command-section-stack">
      <${Wm} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${L} panelId="command.swarm" compact=${!0} />
          </div>
          ${Cs.value?i`<div class="empty-state">Loading swarm live state…</div>`:ws.value?i`<div class="empty-state error">${ws.value}</div>`:t?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((S=t.summary)==null?void 0:S.joined_workers)??0}/${((w=t.summary)==null?void 0:w.expected_workers)??0}</strong><small>${((A=t.summary)==null?void 0:A.live_workers)??0}개 가동 · ${((N=t.summary)==null?void 0:N.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${o} · ctx ${l}/${d}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(T=t.summary)!=null&&T.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((I=t.provider)==null?void 0:I.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(H=t.summary)!=null&&H.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((K=t.operation)==null?void 0:K.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${(($=t.squad)==null?void 0:$.label)??"없음"}</span>
                      <span>실행체</span><span>${((z=t.detachment)==null?void 0:z.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((G=t.summary)==null?void 0:G.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((F=t.summary)==null?void 0:F.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((J=t.provider)==null?void 0:J.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?i`<div class="command-tag-row">
                          ${t.truth_notes.map(b=>i`<span class="command-tag">${b}</span>`)}
                        </div>`:null}
                  `:i`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${L} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?i`<div class="command-card-stack">
                ${t.checklist.map(b=>i`<${Bm} item=${b} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${L} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?i`<div class="command-card-stack">
                ${t.workers.map(b=>i`<${Gm} worker=${b} />`)}
              </div>`:i`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${L} panelId="command.swarm" compact=${!0} />
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
                  <span>Last Sample</span><span>${t.provider.last_sample_at?B(t.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${t.provider.checked_at?B(t.provider.checked_at):"n/a"}</span>
                </div>
                ${t.provider.detail?i`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?i`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(b=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${b.active_slots} active</strong>
                              <span class="command-chip">${B(b.timestamp)}</span>
                            </div>
                            <div class="command-card-sub">slots ${b.active_slot_ids.join(", ")||"none"}</div>
                          </div>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:i`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${L} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?i`<div class="command-card-stack">
                ${t.blockers.map(b=>i`<${Cr} blocker=${b} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${L} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?i`<div class="command-trace-stack">
                ${t.recent_messages.map(b=>i`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${b.from}</strong>
                        <span class="command-chip">${B(b.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${b.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${b.content}</pre>
                  </article>
                `)}
              </div>`:i`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${L} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${t.recent_trace_events.map(b=>i`<${gi} event=${b} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function Vm(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"none",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}s`:t.heartbeat_fresh?"clean":"n/a",detail:[t.bound_task_status??null,t.detachment_member?"detachment":null,t.squad_member?"squad":null].filter(Boolean).join(" · ")||"live swarm worker",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function Ym(t,e){const n=t.actor??t.spawn_role??`worker-${e+1}`,s=t.spawn_role??t.worker_class??t.spawn_agent??"worker",a=t.lane_id??t.capsule_mode??t.control_domain??"session",o=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:s,lane:a,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"session lane",heartbeat:t.last_turn_ts_iso?B(t.last_turn_ts_iso):"n/a",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?Ln(t.routing_confidence):null].filter(Boolean).join(" · ")||"session worker",markers:o,note:t.routing_reason??null}}function Hi(t){return P(t.severity)}function Xm({worker:t}){return i`
    <article class="command-card compact warroom-worker-card ${P(be(t.status))}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${P(be(t.status))}">${t.status}</span>
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
  `}function qt({label:t,surface:e,params:n={}}){return i`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(e){de(e),lt("command",{...hr(e),...n});return}lt("intervene")}}
    >
      ${t}
    </button>
  `}function Qm(){var K,$,z,G,F,J,b,ht,Ot,te,ee,M,yt,ne,Fe,qe,En,zn,jn,On;const t=Dn(),e=ue.value,n=It.value,s=Rt.value,a=Tm(),o=e!=null&&e.operation?((K=Nn.value)==null?void 0:K.operations.find(j=>{var me;return j.operation.operation_id===((me=e.operation)==null?void 0:me.operation_id)}))??null:null,l=(e==null?void 0:e.workers)??[],d=(s==null?void 0:s.worker_cards)??[],p=l.length>0?l.map(Vm):d.map(Ym),_=Cm(),m=(($=t==null?void 0:t.decisions.summary)==null?void 0:$.pending)??0,v=(n==null?void 0:n.pending_confirms)??[],f=(e==null?void 0:e.blockers)??[],h=(s==null?void 0:s.recommended_actions)??[],k=(s==null?void 0:s.attention_items)??[],x=((z=e==null?void 0:e.recent_messages[0])==null?void 0:z.timestamp)??null,S=((G=e==null?void 0:e.recent_trace_events[0])==null?void 0:G.timestamp)??null,w=x??S??null,A=a==null?void 0:a.summary,N=((F=e==null?void 0:e.summary)==null?void 0:F.expected_workers)??(typeof(A==null?void 0:A.planned_worker_count)=="number"?A.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,T=((J=e==null?void 0:e.summary)==null?void 0:J.joined_workers)??(typeof(A==null?void 0:A.active_agent_count)=="number"?A.active_agent_count:void 0)??p.length,I=f.length>0||m>0||v.length>0?"warn":_||a?"ok":"warn",H=((b=t==null?void 0:t.swarm_status)==null?void 0:b.lanes.filter(j=>j.present))??[];return Z(()=>{tt()},[]),Z(()=>{a!=null&&a.session_id&&De(a.session_id)},[a==null?void 0:a.session_id,n,(ht=e==null?void 0:e.detachment)==null?void 0:ht.session_id]),!_&&!a?Cs.value||vn.value?i`<div class="empty-state">live war room 불러오는 중…</div>`:i`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">라이브 워룸</div>
          <${L} panelId="command.warroom" compact=${!0} />
        </div>
        <div class="command-warroom-empty-copy">
          <strong>현재 live run 없음</strong>
          <p>활성 operation 또는 team session이 시작되면 이 화면이 자동으로 붙잡습니다.</p>
        </div>
        <div class="command-action-row">
          <${qt} label="작전 보기" surface="operations" />
          <${qt} label="스웜 보기" surface="swarm" />
          <${qt} label="개입 열기" />
          <${qt} label="제어 보기" surface="control" />
        </div>
      </section>
    `:i`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${P(I)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">Live War Room</span>
            <strong>${((Ot=e==null?void 0:e.operation)==null?void 0:Ot.objective)??(a==null?void 0:a.session_id)??"active run"}</strong>
            <div class="command-card-sub">
              ${((te=e==null?void 0:e.operation)==null?void 0:te.operation_id)??"operation 없음"}
              ${a!=null&&a.session_id?` · session ${a.session_id}`:""}
              ${(ee=e==null?void 0:e.detachment)!=null&&ee.detachment_id?` · detachment ${e.detachment.detachment_id}`:""}
            </div>
          </div>
          <div class="command-action-row">
            <${qt}
              label="스웜 상세"
              surface="swarm"
              params=${{...(M=e==null?void 0:e.operation)!=null&&M.operation_id?{operation_id:e.operation.operation_id}:{},...e!=null&&e.run_id?{run_id:e.run_id}:{}}}
            />
            <${qt} label="트레이스" surface="trace" />
            ${o?i`<${qt}
                  label="체인"
                  surface="chains"
                  params=${{operation:o.operation.operation_id}}
                />`:null}
            <${qt} label="Intervene" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>Workers</span>
            <strong>${T??0}/${N??0}</strong>
            <small>${((yt=e==null?void 0:e.summary)==null?void 0:yt.completed_workers)??0} 완료 · ${p.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>Runtime</span>
            <strong>${(ne=e==null?void 0:e.provider)!=null&&ne.runtime_blocker?"blocked":(Fe=e==null?void 0:e.provider)!=null&&Fe.provider_reachable?"ready":a?ia(a.status):"check"}</strong>
            <small>slots ${((qe=e==null?void 0:e.provider)==null?void 0:qe.active_slots_now)??0}/${((En=e==null?void 0:e.provider)==null?void 0:En.actual_slots)??((zn=e==null?void 0:e.provider)==null?void 0:zn.total_slots)??0} · ctx ${((jn=e==null?void 0:e.provider)==null?void 0:jn.actual_ctx)??((On=e==null?void 0:e.provider)==null?void 0:On.ctx_per_slot)??0}</small>
          </div>
          <div class="monitor-stat-card ${P(f.length>0||m>0?"warn":"ok")}">
            <span>Pressure</span>
            <strong>${f.length+m+v.length}</strong>
            <small>blockers ${f.length} · approvals ${m} · confirms ${v.length}</small>
          </div>
          <div class="monitor-stat-card">
            <span>Last signal</span>
            <strong>${B(w)}</strong>
            <small>${x?"message":S?"trace":"waiting"}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${L} panelId="command.warroom" compact=${!0} />
            </div>
            ${H.length>0?i`
                  <${Ar} lanes=${H} />
                  <${Sr} lanes=${H} />
                `:a?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${P(be(a.status))}">${ia(a.status)}</span>
                      </div>
                      <p>command-plane live run은 아직 옅지만, session 쪽 worker와 digest를 기준으로 워룸을 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${Je(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${Je(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:i`<div class="empty-state">보이는 lane이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Worker Roster</div>
              <${L} panelId="command.warroom" compact=${!0} />
            </div>
            ${p.length>0?i`<div class="command-card-stack">
                  ${p.map(j=>i`<${Xm} worker=${j} />`)}
                </div>`:i`<div class="empty-state">활성 worker 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Live Feed</div>
              <${L} panelId="command.warroom" compact=${!0} />
            </div>
            ${e&&e.recent_messages.length>0?i`<div class="command-trace-stack">
                  ${e.recent_messages.map(j=>i`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${j.from}</strong>
                          <span class="command-chip">${B(j.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${j.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${j.content}</pre>
                    </article>
                  `)}
                </div>`:h.length>0||k.length>0?i`<div class="command-card-stack">
                    ${h.slice(0,4).map(j=>i`
                      <article class="command-guide-card ${Hi(j)}">
                        <div class="command-guide-head">
                          <strong>${j.action_type}</strong>
                          <span class="command-chip ${Hi(j)}">${j.target_type}</span>
                        </div>
                        <p>${j.reason}</p>
                      </article>
                    `)}
                    ${k.slice(0,3).map(j=>i`
                      <article class="command-alert ${P(j.severity)}">
                        <div class="command-card-head">
                          <strong>${j.kind}</strong>
                          <span class="command-chip ${P(j.severity)}">${j.severity}</span>
                        </div>
                        <p>${j.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?i`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((j,me)=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>session-event-${me+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${_r(j)}</pre>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">메시지나 attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Trace Feed</div>
              <${L} panelId="command.trace" compact=${!0} />
            </div>
            ${e&&e.recent_trace_events.length>0?i`<div class="command-trace-stack">
                  ${e.recent_trace_events.map(j=>i`<${gi} event=${j} />`)}
                </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Pressure</div>
              <${L} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${f.length>0?f.map(j=>i`<${Cr} blocker=${j} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${m>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending approvals</strong>
                        <span class="command-chip warn">${m}</span>
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
                        ${v.slice(0,3).map(j=>i`<span class="command-tag">${j.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
            </div>
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Focus Detail</div>
              <${L} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${e!=null&&e.operation?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${e.operation.objective}</strong>
                          <div class="command-card-sub">${e.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${P(be(e.operation.status))}">${e.operation.status}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Unit</span><span>${e.operation.assigned_unit_id}</span>
                        <span>Trace</span><span>${e.operation.trace_id}</span>
                        <span>Autonomy</span><span>${e.operation.autonomy_level??"n/a"}</span>
                        <span>Updated</span><span>${B(e.operation.updated_at)}</span>
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
                        <span class="command-chip ${P(be(e.detachment.status))}">${e.detachment.status??"active"}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Leader</span><span>${e.detachment.leader_id??"unassigned"}</span>
                        <span>Roster</span><span>${e.detachment.roster.length}</span>
                        <span>Session</span><span>${e.detachment.session_id??"none"}</span>
                        <span>Heartbeat</span><span>${fr(e.detachment.heartbeat_deadline)}</span>
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
                        <span class="command-chip ${P(be(a.status))}">${ia(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${Je(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${Je(a.remaining_sec)}</span>
                        <span>Done delta</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function Zm({source:t}){const e=Gr(null),[n,s]=Za(null);return Z(()=>{let a=!1;const o=e.current;return o?(o.innerHTML="",s(null),(async()=>{try{const d=await lm(),{svg:p}=await d.render(`command-chain-${rm()}`,t);if(a||!e.current)return;e.current.innerHTML=p}catch(d){if(a)return;s(d instanceof Error?d.message:"Mermaid render failed")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function tv({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return i`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${Bt(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?i`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?i`<span class="command-tag ${Bt(s==null?void 0:s.status)}">${Ln(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${gr(t.history)}</div>
    </button>
  `}function ev({item:t}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${Bt(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${B(t.timestamp)}</div>
      <div class="command-card-sub">${gr(t)}</div>
    </article>
  `}function nv({node:t}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${Bt(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?i`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function sv({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,o=e.chain,l=(o==null?void 0:o.run_id)??null;return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${P(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Autonomy</span><span>${e.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${e.budget_class??"standard"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Updated</span><span>${B(e.updated_at)}</span>
      </div>
      ${o?i`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${Bt(o.status)}">${o.status}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">run ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?i`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{de("swarm"),lt("command",{surface:"swarm",operation_id:e.operation_id,...l?{run_id:l}:{}})}}
        >
          Swarm Live
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{vi(e.operation_id),de("chains"),lt("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?i`
              <button class="control-btn ghost" disabled=${et(n)} onClick=${()=>Gt(()=>Jp(e.operation_id))}>
                ${et(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${et(a)} onClick=${()=>Gt(()=>Yp(e.operation_id))}>
                ${et(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?i`
              <button class="control-btn ghost" disabled=${et(s)} onClick=${()=>Gt(()=>Vp(e.operation_id))}>
                ${et(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function av({card:t}){var n;const e=t.detachment;return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${P(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${B(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${fr(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${B(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?i`<span class="command-tag ${im(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function iv(){const t=Nt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${L} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?i`<div class="command-card-stack">
              ${t.operations.operations.map(e=>i`<${sv} card=${e} />`)}
            </div>`:i`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${L} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>i`<${av} card=${e} />`)}
            </div>`:i`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function ov(){var d,p,_,m,v,f,h,k,x,S,w,A,N,T,I,H;const t=Nn.value,e=(t==null?void 0:t.operations)??[],n=Te.value,s=e.find(K=>K.operation.operation_id===n)??e[0]??null,a=((d=s==null?void 0:s.operation.chain)==null?void 0:d.run_id)??null,o=((p=gn.value)==null?void 0:p.run)??(s==null?void 0:s.preview_run)??null,l=!((_=gn.value)!=null&&_.run)&&!!(s!=null&&s.preview_run);return Z(()=>{a?Bp(a):Wp()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${L} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${Bt(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${Bt(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(t==null?void 0:t.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((m=t==null?void 0:t.summary)==null?void 0:m.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((v=t==null?void 0:t.summary)==null?void 0:v.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((f=t==null?void 0:t.summary)==null?void 0:f.recent_failures)??0}</span>
            <span>Last Event</span><span>${B((h=t==null?void 0:t.summary)==null?void 0:h.last_history_event_at)}</span>
          </div>
        </article>

        ${Ts.value?i`<div class="empty-state error">${Ts.value}</div>`:null}

        ${Wa.value&&!t?i`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?i`
                <div class="command-chain-list">
                  ${e.map(K=>i`
                    <${tv}
                      overlay=${K}
                      selected=${(s==null?void 0:s.operation.operation_id)===K.operation.operation_id}
                      onSelect=${()=>vi(K.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(K=>i`<${ev} item=${K} />`)}
                </div>
              `:i`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chain Detail</div>
          <${L} panelId="command.chains" compact=${!0} />
        </div>
        ${s?i`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${Bt((k=s.operation.chain)==null?void 0:k.status)}">
                    ${((x=s.operation.chain)==null?void 0:x.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((S=s.operation.chain)==null?void 0:S.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((w=s.operation.chain)==null?void 0:w.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${Ln((A=s.runtime)==null?void 0:A.progress)}</span>
                  <span>Elapsed</span><span>${Je((N=s.runtime)==null?void 0:N.elapsed_sec)}</span>
                  <span>Updated</span><span>${B(((T=s.operation.chain)==null?void 0:T.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(I=s.operation.chain)!=null&&I.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((H=s.operation.chain)==null?void 0:H.chain_id)??"graph"}</span>
                      </div>
                      <${Zm} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"failed":l?"preview":"captured":"pending"}
                  </span>
                </div>
                ${Is.value?i`<div class="empty-state">Loading run detail…</div>`:$n.value?i`<div class="empty-state error">${$n.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${o.chain_id}</span>
                            <span>Run</span><span>${o.run_id??"preview only"}</span>
                            <span>Duration</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${o.nodes.length}</span>
                          </div>
                          ${l?i`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(K=>i`<${nv} node=${K} />`)}
                          </div>
                        `:i`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:i`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function rv({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return i`
    <article class="command-card ${P(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${P(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${B(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!s?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${et(e)} onClick=${()=>Gt(()=>Qp(t.decision_id))}>
                ${et(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${et(n)} onClick=${()=>Gt(()=>Zp(t.decision_id))}>
                ${et(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function lv({row:t}){var d,p,_;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((d=e.policy)!=null&&d.frozen),o=!!((p=e.policy)!=null&&p.kill_switch),l=Math.round((t.utilization??0)*100);return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${P(l>100?"bad":l>70?"warn":"ok")}">${l}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>Headcount Cap</span><span>${t.headcount_cap??0}</span>
        <span>Ops</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${((_=e.policy)==null?void 0:_.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${a?"yes":"no"}</span>
        <span>Kill Switch</span><span>${o?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${et(n)} onClick=${()=>Gt(()=>tm(e.unit_id,!a))}>
          ${et(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${et(s)} onClick=${()=>Gt(()=>em(e.unit_id,!o))}>
          ${et(s)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function cv(){const t=Nt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${L} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>i`<${rv} decision=${e} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${L} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>i`<${lv} row=${e} />`)}
            </div>`:i`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function dv(){return i`
    <div class="command-surface-tabs grouped">
      ${dm.map(t=>i`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${$r.filter(e=>e.group===t.id).map(e=>i`
                <button
                  class="command-surface-tab ${q.value===e.id?"active":""}"
                  onClick=${()=>{de(e.id),lt("command",hr(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function uv(){if(q.value==="warroom")return i`<${Qm} />`;if(q.value==="summary")return i`<${Mm} />`;if(q.value==="swarm")return i`<${Jm} />`;if(!Nt.value)return i`<${Dm} />`;switch(q.value){case"chains":return i`<${ov} />`;case"topology":return i`<${zm} />`;case"alerts":return i`<${jm} />`;case"trace":return i`<${Om} />`;case"control":return i`<${cv} />`;case"operations":default:return i`<${iv} />`}}function pv(){return Z(()=>{Ht(),Wt(),Gp(),St()},[]),Z(()=>{if(D.value.tab!=="command")return;const t=D.value.params.surface,e=D.value.params.operation,n=Rn(D.value);if(Ui(t))de(t);else if(n){const s=Xo(n);Ui(s)&&de(s)}else t||de("warroom");e&&vi(e),(t==="swarm"||t==="warroom"||q.value==="warroom")&&St(),(t==="warroom"||q.value==="warroom")&&tt()},[D.value.tab,D.value.params.surface,D.value.params.operation,D.value.params.operation_id,D.value.params.run_id,D.value.params.source,D.value.params.action_type,D.value.params.target_type,D.value.params.target_id,D.value.params.focus_kind]),Z(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,Ht(),Wt(),(q.value==="swarm"||q.value==="warroom")&&St(),q.value==="warroom"&&tt()},250))},n=new EventSource(_m()),s=pm.map(a=>{const o=()=>e();return n.addEventListener(a,o),{type:a,handler:o}});return n.onerror=()=>{e()},()=>{s.forEach(({type:a,handler:o})=>{n.removeEventListener(a,o)}),n.close(),t&&window.clearTimeout(t)}},[]),Z(()=>{const t=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const e=q.value;e!=="swarm"&&e!=="warroom"||(Ht(),St(),e==="warroom"&&tt())},5e3);return()=>{window.clearInterval(t)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Gt(()=>Xp())}}
            disabled=${et("dispatch:tick")}
          >
            ${et("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Ht(),Wt(),St(),q.value==="warroom"&&tt()}}
            disabled=${ys.value}
          >
            ${ys.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${ks.value?i`<div class="empty-state error">${ks.value}</div>`:null}
      ${Ss.value?i`<div class="empty-state error">${Ss.value}</div>`:null}
      <${vt} surfaceId="command" />
      <${Im} />
      ${q.value==="warroom"?null:i`<${Rm} />`}
      <${dv} />
      <${uv} />
    </section>
  `}const wr="masc_dashboard_agent_name";function mv(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(wr))==null?void 0:s.trim())||"dashboard"}const Ys=g(mv()),Ie=g(""),Ba=g("운영 점검"),Re=g(""),hn=g(""),yn=g("2"),bn=g(""),At=g("note"),kn=g(""),xn=g(""),Sn=g(""),An=g("2"),Rs=g("운영자 중지 요청"),Ps=g(""),Pe=g(""),Hn=g(null);function vv(t){const e=t.trim()||"dashboard";Ys.value=e,localStorage.setItem(wr,e)}function Wi(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function _v(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function Ee(t){return typeof t=="string"?t.trim().toLowerCase():""}function fv(t){var s;const e=Ee(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=Ee((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function oa(t){const e=Ee(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function Bi(t){return t.some(e=>Ee(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function gv(t){return t.target_type==="team_session"}function $v(t){return t.target_type==="keeper"}function Wn(t){switch(t){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";case"keeper_msg":return"keeper 메시지";default:return(t==null?void 0:t.trim())||"액션"}}function Bn(t){switch(t){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";default:return(t==null?void 0:t.trim())||"target"}}function We(t){switch(Ee(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Gi(t){return t?"확인 후 실행":"즉시 실행"}function hv(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";default:return t}}function rt(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function yv(t){if(t.action_type==="team_task_inject")return"task";if(t.action_type==="team_broadcast")return"broadcast";if(t.action_type==="team_note")return"note";if(t.action_type==="team_turn"){const e=rt(t.suggested_payload,"turn_kind");if(e==="broadcast"||e==="task")return e}return"note"}function bv(t){const e=t.suggested_payload;if(t.target_type==="room"){if(t.action_type==="broadcast"){Ie.value=rt(e,"message")??t.summary;return}t.action_type==="task_inject"&&(Re.value=rt(e,"title")??"운영자 주입 작업",hn.value=rt(e,"description")??t.summary,yn.value=rt(e,"priority")??yn.value);return}if(t.target_type==="team_session"){if(t.target_id&&(bn.value=t.target_id),t.action_type==="team_stop"){Rs.value=rt(e,"reason")??t.summary;return}At.value=yv(t);const n=rt(e,"message");n&&(kn.value=n),At.value==="task"&&(xn.value=rt(e,"task_title")??rt(e,"title")??"운영자 주입 작업",Sn.value=rt(e,"task_description")??rt(e,"description")??t.summary,An.value=rt(e,"task_priority")??rt(e,"priority")??An.value);return}t.target_type==="keeper"&&(t.target_id&&(Ps.value=t.target_id),Pe.value=rt(e,"message")??t.summary)}function kv(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function pe(t){const e=Ys.value.trim()||"dashboard";try{const n=await Bd({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?R("확인 대기열에 올렸습니다","warning"):R(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return R(s,"error"),null}}async function Ji(){const t=Ie.value.trim();if(!t)return;await pe({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(Ie.value="")}async function xv(){await pe({action_type:"room_pause",target_type:"room",payload:{reason:Ba.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function Vi(){await pe({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function Sv(){const t=Re.value.trim();if(!t)return;await pe({action_type:"task_inject",target_type:"room",payload:{title:t,description:hn.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(yn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(Re.value="",hn.value="")}async function Av(){var l;const t=It.value,e=bn.value||((l=t==null?void 0:t.sessions[0])==null?void 0:l.session_id)||"";if(!e){R("먼저 세션을 고르세요","warning");return}const n={},s=kn.value.trim();s&&(n.message=s);let a="team_note";At.value==="broadcast"?a="team_broadcast":At.value==="task"&&(a="team_task_inject"),At.value==="task"&&(n.task_title=xn.value.trim()||"운영자 주입 작업",n.task_description=Sn.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(An.value,10)||2),await pe({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(kn.value="",At.value==="task"&&(xn.value="",Sn.value=""))}async function Cv(){var n;const t=It.value,e=bn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){R("먼저 세션을 고르세요","warning");return}await pe({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Rs.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function wv(){var a;const t=It.value,e=Ps.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=Pe.value.trim();if(!e){R("먼저 keeper를 고르세요","warning");return}if(!n)return;await pe({action_type:"keeper_message",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`${e}에게 메시지를 보냈습니다`})&&(Pe.value="")}async function Tv(t){const e=Ys.value.trim()||"dashboard";try{await Gd(e,t),R("확인 실행을 완료했습니다","success")}catch(n){const s=n instanceof Error?n.message:"확인 실행에 실패했습니다";R(s,"error")}}function Iv(){var I,H,K;const t=It.value,e=D.value.tab==="intervene"?Rn(D.value):null,n=jo.value,s=Rt.value,a=(t==null?void 0:t.room)??{},o=(t==null?void 0:t.sessions)??[],l=(t==null?void 0:t.keepers)??[],d=(t==null?void 0:t.pending_confirms)??[],p=(t==null?void 0:t.recent_messages)??[],_=(n==null?void 0:n.recommended_actions)??[],m=(t==null?void 0:t.available_actions)??[],v=o.find($=>$.session_id===bn.value)??o[0]??null,f=l.find($=>$.name===Ps.value)??l[0]??null,h=(n==null?void 0:n.attention_items)??[],k=h.filter(gv),x=h.filter($v),S=o.filter($=>fv($)!=="ok"),w=l.filter($=>oa($)!=="ok"),A=p.slice(0,5),N=kv(e,o,l);Z(()=>{zt()},[]),Z(()=>{if(D.value.tab!=="intervene"){Hn.value=null;return}if(!e){Hn.value=null;return}Hn.value!==e.id&&(Hn.value=e.id,bv(e))},[D.value.tab,D.value.params.source,D.value.params.action_type,D.value.params.target_type,D.value.params.target_id,D.value.params.focus_kind,e==null?void 0:e.id]),Z(()=>{const $=(v==null?void 0:v.session_id)??null;De($)},[v==null?void 0:v.session_id]);const T=[{key:"room",label:"Room 게이트",value:a.paused?"일시정지":"열림",detail:a.paused?`재개 전환 대기 중${a.pause_reason?` · ${a.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:a.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:d.length,detail:d.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:d.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:k.length>0?k.length:o.length,detail:k.length>0?((I=k[0])==null?void 0:I.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":o.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:k.length>0?Bi(k):o.length===0?"warn":S.some($=>Ee($.status)==="paused")?"bad":S.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:x.length>0?x.length:w.length,detail:x.length>0?((H=x[0])==null?void 0:H.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":w.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:x.length>0?Bi(x):w.some($=>oa($)==="bad")?"bad":w.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${vt} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">Intervene</div>
            <${L} panelId="intervene.action_studio" compact=${!0} />
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
            value=${Ys.value}
            onInput=${$=>vv($.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{tt(),zt(),De((v==null?void 0:v.session_id)??null)}}
            disabled=${vn.value||W.value}
          >
            ${vn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Vt.value?i`<section class="ops-banner error">${Vt.value}</section>`:null}
      ${Me.value?i`<section class="ops-banner error">${Me.value}</section>`:null}
      ${e?i`
        <section class="ops-banner ${N?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${di(e.action_type)}</span>
            <span>${ci(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?i`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${N?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const $=[];if(d.length>0&&$.push({label:`확인 대기 ${d.length}건 처리`,desc:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:"bad",onClick:()=>{const z=document.querySelector(".ops-pending-section");z==null||z.scrollIntoView({behavior:"smooth"})}}),a.paused&&$.push({label:"Room 재개",desc:`현재 일시정지 상태${a.pause_reason?` (${a.pause_reason})`:""}`,tone:"warn",onClick:()=>void Vi()}),w.length>0){const z=w.filter(G=>oa(G)==="bad");$.push({label:z.length>0?`Keeper ${z.length}개 오프라인`:`Keeper ${w.length}개 점검 필요`,desc:z.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:z.length>0?"bad":"warn",onClick:()=>{const G=document.querySelector(".ops-keeper-section");G==null||G.scrollIntoView({behavior:"smooth"})}})}return $.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${$.slice(0,3).map(z=>i`
                <button class="ops-action-guide-item ${z.tone}" onClick=${z.onClick}>
                  <strong>${z.label}</strong>
                  <span>${z.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `})()}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${L} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 room인지, session인지, keeper인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${T.map($=>i`
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
              <${L} panelId="intervene.action_studio" compact=${!0} />
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
                value=${Ie.value}
                onInput=${$=>{Ie.value=$.target.value}}
                onKeyDown=${$=>{$.key==="Enter"&&Ji()}}
                disabled=${W.value}
              />
              <button class="control-btn" onClick=${()=>{Ji()}} disabled=${W.value||Ie.value.trim()===""}>
                보내기
              </button>
            </div>

            <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
            <div class="control-row ops-split-row">
              <input
                id="ops-pause-reason"
                class="control-input"
                type="text"
                value=${Ba.value}
                onInput=${$=>{Ba.value=$.target.value}}
                disabled=${W.value}
              />
              <button class="control-btn ghost" onClick=${()=>{xv()}} disabled=${W.value}>
                일시정지
              </button>
              <button class="control-btn ghost" onClick=${()=>{Vi()}} disabled=${W.value}>
                재개
              </button>
            </div>

            <div class="ops-section-head">작업 주입</div>
            <input
              class="control-input"
              type="text"
              placeholder="작업 제목"
              value=${Re.value}
              onInput=${$=>{Re.value=$.target.value}}
              disabled=${W.value}
            />
            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="작업 설명"
              value=${hn.value}
              onInput=${$=>{hn.value=$.target.value}}
              disabled=${W.value}
            ></textarea>
            <div class="control-row ops-split-row">
              <select
                class="control-input ops-select"
                value=${yn.value}
                onChange=${$=>{yn.value=$.target.value}}
                disabled=${W.value}
              >
                <option value="1">P1</option>
                <option value="2">P2</option>
                <option value="3">P3</option>
                <option value="4">P4</option>
                <option value="5">P5</option>
              </select>
              <button class="control-btn" onClick=${()=>{Sv()}} disabled=${W.value||Re.value.trim()===""}>
                주입
              </button>
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">추천 개입</div>
              <${L} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
            ${_n.value&&!n?i`
              <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
            `:_.length>0?i`
              <div class="ops-log-list">
                ${_.map($=>i`
                  <article key=${`${$.action_type}:${$.target_type}:${$.target_id??"room"}`} class="ops-log-entry ${$.severity}">
                    <div class="ops-log-head">
                      <strong>${Wn($.action_type)}</strong>
                      <span>${Bn($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                      <span>${Gi($.confirm_required)}</span>
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
              <${L} panelId="intervene.pending_confirmations" compact=${!0} />
            </div>
            <p class="ops-context-note">미리보기만 끝났고 아직 사람이 눌러줘야 하는 액션만 남깁니다.</p>
            ${d.length>0?i`
              <div class="ops-confirmation-list">
                ${d.map($=>i`
                  <article key=${$.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${Wn($.action_type)}</strong>
                      <span>${Bn($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                      <span>${$.delegated_tool??"위임 도구 확인 필요"}</span>
                    </div>
                    ${$.preview?i`<pre class="ops-code-block compact">${Wi($.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{Tv($.confirm_token)}} disabled=${W.value}>
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
              <${L} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
            ${A.length>0?i`
              <div class="ops-feed-list">
                ${A.map($=>i`
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
              <${L} panelId="intervene.session_queue" compact=${!0} />
            </div>
            <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

            <div class="ops-entity-list">
              ${o.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:o.map($=>{var z;return i`
                <button
                  key=${$.session_id}
                  class="ops-entity-card ${(v==null?void 0:v.session_id)===$.session_id?"active":""}"
                  onClick=${()=>{bn.value=$.session_id}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${$.session_id}</strong>
                    <span class="status-badge ${$.status??"idle"}">${We($.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round($.progress_pct??0)}%</span>
                    <span>${$.done_delta_total??0}건 완료</span>
                    <span>${(z=$.team_health)!=null&&z.status?We(String($.team_health.status)):"상태 확인 필요"}</span>
                  </div>
                </button>
              `})}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">선택한 Session 요약</div>
              <${L} panelId="intervene.session_digest" compact=${!0} />
            </div>
            <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
            ${v&&s?i`
              <div class="ops-log-list">
                ${s.attention_items.length>0?s.attention_items.map($=>i`
                  <article key=${`${$.kind}:${$.target_id??"session"}`} class="ops-log-entry ${$.severity}">
                    <div class="ops-log-head">
                      <strong>${$.kind}</strong>
                      <span>${Bn($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                    </div>
                    <div class="ops-log-body">${$.summary}</div>
                  </article>
                `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
                ${s.worker_cards.length>0?s.worker_cards.map($=>i`
                  <article key=${`${$.actor??$.spawn_role??"worker"}:${$.spawn_agent??$.runtime_pool??"runtime"}`} class="ops-log-entry">
                    <div class="ops-log-head">
                      <strong>${$.actor??$.spawn_role??"worker"}</strong>
                      <span>${We($.status)}</span>
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
              <${L} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>

            ${v?i`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${v.session_id}</div>
                <div class="ops-detail-meta">
                  <span>상태: ${We(v.status)}</span>
                  <span>경과: ${v.elapsed_sec??0}초</span>
                  <span>남은 시간: ${v.remaining_sec??0}초</span>
                </div>
                ${v.recent_events&&v.recent_events.length>0?i`
                  <pre class="ops-code-block compact">${Wi(v.recent_events.slice(-3))}</pre>
                `:null}
              </div>
            `:i`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

            <label class="control-label" for="ops-turn-kind">세션 액션</label>
            <div class="control-row ops-split-row">
              <select
                id="ops-turn-kind"
                class="control-input ops-select"
                value=${At.value}
                onChange=${$=>{At.value=$.target.value}}
                disabled=${W.value||!v}
              >
                <option value="note">노트</option>
                <option value="broadcast">방송</option>
                <option value="task">작업</option>
              </select>
              <button class="control-btn" onClick=${()=>{Av()}} disabled=${W.value||!v}>
                적용
              </button>
            </div>
            <div class="ops-context-note">현재 선택: ${hv(At.value)}</div>

            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="세션에 남길 메시지"
              value=${kn.value}
              onInput=${$=>{kn.value=$.target.value}}
              disabled=${W.value||!v}
            ></textarea>

            ${At.value==="task"?i`
              <input
                class="control-input"
                type="text"
                placeholder="주입할 작업 제목"
                value=${xn.value}
                onInput=${$=>{xn.value=$.target.value}}
                disabled=${W.value||!v}
              />
              <textarea
                class="control-textarea"
                rows=${2}
                placeholder="주입할 작업 설명"
                value=${Sn.value}
                onInput=${$=>{Sn.value=$.target.value}}
                disabled=${W.value||!v}
              ></textarea>
              <select
                class="control-input ops-select"
                value=${An.value}
                onChange=${$=>{An.value=$.target.value}}
                disabled=${W.value||!v}
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
                value=${Rs.value}
                onInput=${$=>{Rs.value=$.target.value}}
                disabled=${W.value||!v}
              />
              <button class="control-btn ghost" onClick=${()=>{Cv()}} disabled=${W.value||!v}>
                세션 중지
              </button>
            </div>
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel ops-keeper-section">
            <div class="card-title-row">
              <div class="card-title">Keeper 개입</div>
              <${L} panelId="intervene.keeper_queue" compact=${!0} />
            </div>
            <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

            <div class="ops-entity-list">
              ${l.length===0?i`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:l.map($=>i`
                <button
                  key=${$.name}
                  class="ops-entity-card ${(f==null?void 0:f.name)===$.name?"active":""}"
                  onClick=${()=>{Ps.value=$.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${$.name}</strong>
                    <span class="status-badge ${$.status??"idle"}">${We($.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${$.model??"model 확인 필요"}</span>
                    <span>${typeof $.context_ratio=="number"?`${Math.round($.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                    <span>${_v($.last_turn_ago_s)}</span>
                  </div>
                </button>
              `)}
            </div>
          </section>

          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">선택한 Keeper 액션</div>
              <${L} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">선택한 keeper에만 직접 메시지를 보내서 probe, 수정, 재지시를 합니다.</p>

            ${f?i`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${f.name}</div>
                <div class="ops-detail-meta">
                  <span>자율성: ${f.autonomy_level??"확인 없음"}</span>
                  <span>세대: ${f.generation??0}</span>
                  <span>활성 목표: ${((K=f.active_goal_ids)==null?void 0:K.length)??0}</span>
                </div>
              </div>
            `:i`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

            <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
            <textarea
              id="ops-keeper-message"
              class="control-textarea"
              rows=${6}
              placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
              value=${Pe.value}
              onInput=${$=>{Pe.value=$.target.value}}
              disabled=${W.value||!f}
            ></textarea>
            <div class="control-row">
              <button class="control-btn" onClick=${()=>{wv()}} disabled=${W.value||!f||Pe.value.trim()===""}>
                keeper에 보내기
              </button>
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">가능한 액션 목록</div>
              <${L} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
            <div class="ops-log-list">
              ${m.length?m.map($=>i`
                    <article key=${`${$.action_type}:${$.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${Wn($.action_type)}</strong>
                        <span>${Bn($.target_type)}</span>
                        <span>${Gi($.confirm_required)}</span>
                      </div>
                      <div class="ops-log-body">${$.description??"설명이 아직 없습니다."}</div>
                    </article>
                  `):i`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 개입 로그</div>
              <${L} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <div class="ops-log-list">
              ${gs.value.length===0?i`
                <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
              `:gs.value.map($=>i`
                <article key=${$.id} class="ops-log-entry ${$.outcome}">
                  <div class="ops-log-head">
                    <strong>${Wn($.action_type)}</strong>
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
  `}function Rv({text:t}){if(!t)return null;const e=Pv(t);return i`<div class="markdown-content">${e}</div>`}function Pv(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],d=a.slice(l.length).trim(),p=[];for(s++;s<e.length&&!e[s].startsWith(l);)p.push(e[s]),s++;s++,n.push(i`<pre><code class=${d?`language-${d}`:""}>${p.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],d=a.trim().replace(/^<think>/,"").trim();for(d&&d!=="</think>"&&l.push(d),s++;s<e.length&&!e[s].includes("</think>");)l.push(e[s]),s++;if(s<e.length){const _=e[s].replace("</think>","").trim();_&&l.push(_),s++}const p=l.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${ra(p)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<e.length&&e[s].startsWith("> ");)l.push(e[s].slice(2)),s++;n.push(i`<blockquote>${ra(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<e.length;){const l=e[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;o.push(l),s++}o.length>0&&n.push(i`<p>${ra(o.join(`
`))}</p>`)}return n}function ra(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&e.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Tr=[{id:"recent",label:"Latest"},{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],is=g(null),os=g([]),ze=g(!1),ce=g(null),tn=g(""),en=g(!1),ke=g(!0);function Nv(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Lv=g(Nv());function Mv(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function Yi(t){return t.updated_at!==t.created_at}function Dv(t){const e=`${t.title} ${t.tags.join(" ")} ${t.flair??""}`.toLowerCase();return/\b(test|smoke|harness|sandbox|dummy|sample|tmp|qa|e2e)\b/.test(e)||e.includes("테스트")||e.includes("실험")}function Ev(t){const e=(t.hearth??"").toLowerCase();return t.visibility!=="internal"||!t.expires_at||!e?!1:!!(e.startsWith("mdal")||e.includes("harness"))}function Ir(t){return ke.value?t.filter(e=>Ev(e)?!1:e.hearth||e.visibility||e.expires_at?!0:!Dv(e)):t}async function $i(t){ce.value=t,is.value=null,os.value=[],ze.value=!0;try{const e=await jl(t);if(ce.value!==t)return;is.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth:e.hearth,visibility:e.visibility,expires_at:e.expires_at,hearth_count:e.hearth_count},os.value=e.comments??[]}catch{ce.value===t&&(is.value=null,os.value=[])}finally{ce.value===t&&(ze.value=!1)}}async function Xi(t){const e=tn.value.trim();if(e){en.value=!0;try{await Ol(t,Lv.value,e),tn.value="",R("Comment posted","success"),await $i(t),wt()}catch{R("Failed to post comment","error")}finally{en.value=!1}}}function zv(){const t=ln.value,e=ke.value?"Hiding automation posts":"Show automation posts";return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Tr.map(n=>i`
          <button
            class="board-sort-btn ${t===n.id?"active":""}"
            onClick=${()=>{ln.value=n.id,wt()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${ke.value?"is-active":""}"
          onClick=${()=>{ke.value=!ke.value}}
        >
          ${e}
        </button>
        <button
          class="control-btn ghost ${he.value?"is-active":""}"
          onClick=${()=>{he.value=!he.value,wt()}}
        >
          ${he.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${wt} disabled=${cn.value}>
          ${cn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function la(){var s;const t=((s=Tr.find(a=>a.id===ln.value))==null?void 0:s.label)??ln.value,e=Ir(rn.value),n=rn.value.length-e.length;return i`
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
        <strong>${ke.value?`automation ${n} hidden`:"full feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${he.value?"Auto reports hidden":"Full memory feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Fa.value?i`<${X} timestamp=${Fa.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function jv({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await yo(t.id,n),wt()}catch{R("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>Qr(t.id)}>
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
                ${Yi(t)?i`<span class="board-meta-chip">Updated</span>`:null}
                ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${X} timestamp=${t.created_at} /></span>
            ${Yi(t)?i`<span>Updated <${X} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${Mv(t.content)}</div>
      </div>
    </div>
  `}function Ov({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${X} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Fv({postId:t}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${tn.value}
        onInput=${e=>{tn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Xi(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${en.value}
      />
      <button
        onClick=${()=>Xi(t)}
        disabled=${en.value||tn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${en.value?"...":"Post"}
      </button>
    </div>
  `}function qv({post:t}){ce.value!==t.id&&!ze.value&&$i(t.id);const e=async n=>{try{await yo(t.id,n),wt()}catch{R("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>lt("memory")}>← Back to Memory</button>
      <${C} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${Rv} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${t.author}</span>
            <${X} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
          </div>
          ${t.hearth||t.visibility||t.expires_at?i`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                  ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
                  ${t.expires_at?i`<span class="board-meta-chip">expires <${X} timestamp=${t.expires_at} /></span>`:null}
                </div>
              `:null}
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${C} title="Comments" semanticId="memory.feed">
        ${ze.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${Ov} comments=${os.value} />`}
        <${Fv} postId=${t.id} />
      <//>
    </div>
  `}function Kv(){const t=Ir(rn.value),e=D.value.params.post??null,n=e?t.find(s=>s.id===e)??(ce.value===e?is.value:null):null;return e&&!n&&ce.value!==e&&!ze.value&&$i(e),e?n?i`
          <${vt} surfaceId="memory" />
          <${la} />
          <${qv} post=${n} />
        `:i`
          <div>
            <${vt} surfaceId="memory" />
            <${la} />
            <button class="back-btn" onClick=${()=>lt("memory")}>← Back to Memory</button>
            ${ze.value?i`<div class="loading-indicator">Loading post...</div>`:i`<div class="empty-state">Post not found</div>`}
          </div>
        `:i`
    <div>
      <${vt} surfaceId="memory" />
      <${la} />
      <${zv} />
      ${cn.value?i`<div class="loading-indicator">Loading memory feed...</div>`:t.length===0?i`<div class="empty-state">No posts in durable memory right now</div>`:i`
              <${C} title="Posts / Comments" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.map(s=>i`<${jv} key=${s.id} post=${s} />`)}
                </div>
              <//>
            `}
    </div>
  `}function Rr({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,o=2*Math.PI*s,l=o*((100-t*100)/100);let d="mitosis-safe";return t>=.8?d="mitosis-critical":t>=.5&&(d="mitosis-warn"),i`
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
  `}const ca=600*1e3,Uv=1200*1e3,Qi=.8;function Kt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function fe(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Hv(t){switch(t){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function Wv(t){switch(t){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function Bv(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Gv(t){var e,n,s,a;return((n=(e=t.agent)==null?void 0:e.current_task)==null?void 0:n.trim())||((s=t.skill_primary)==null?void 0:s.trim())||((a=t.last_proactive_reason)==null?void 0:a.trim())||"현재 포커스 없음"}function Jv(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function Vv(t){var p,_;const e=Us.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,s=n?Math.max(0,Date.now()-Kt(n)):Number.POSITIVE_INFINITY,a=!!((p=t.current_task)!=null&&p.trim())||e.activeAssignedCount>0;let o="watching",l="ok",d="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",l="bad",d=n?"Offline or inactive":"No recent presence"):s>Uv?(o="quiet",l="bad",d=a?"Working without a fresh signal":"No fresh agent signal"):a?(o="working",l=s>ca?"warn":"ok",d=s>ca?"Execution looks quiet for too long":"Task and live signal aligned"):s>ca?(o="quiet",l="warn",d="Quiet but still reachable"):t.status==="idle"&&(o="watching",l="ok",d="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:l,focus:((_=t.current_task)==null?void 0:_.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:d}}function Yv(t){const e=qc.value.get(t.name)??"idle",n=Hc.value.has(t.name),s=t.context_ratio??0;let a="healthy",o="ok",l="하트비트와 컨텍스트 상태가 안정적입니다";return t.status==="offline"||n||e==="handoff-imminent"?(a="critical",o="bad",l=n?"하트비트 지연":e==="handoff-imminent"?"핸드오프 임박":"keeper 오프라인"):(e==="preparing"||e==="compacting"||s>=Qi)&&(a="warning",o="warn",l=s>=Qi?"컨텍스트 압력이 높습니다":e==="compacting"?"컴팩팅 진행 중":"핸드오프 준비 중"),{keeper:t,lifecycle:e,state:a,tone:o,focus:Gv(t),note:l}}function Be({label:t,value:e,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function Xv({item:t}){const e=t.kind==="agent"?()=>Gs(t.agent.name):()=>ri(t.keeper);return i`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"에이전트":"keeper"}
        </span>
        ${t.timestamp?i`<span><${X} timestamp=${t.timestamp} /></span>`:i`<span>신호 없음</span>`}
      </div>
    </button>
  `}function Zi({row:t}){const{agent:e,motion:n}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Gs(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Rr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Qt} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${Hv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?i`<span>신호 <${X} timestamp=${t.lastSignalAt} /></span>`:i`<span>최근 신호 없음</span>`}
        <span>${t.activeTaskCount>0?`활성 작업 ${t.activeTaskCount}개`:"활성 작업 없음"}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
        ${e.last_seen?i`<span>마지막 감지 <${X} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?i`<div class="monitor-footnote">최근 상세: ${n.lastActivityText}</div>`:null}
    </button>
  `}function Qv({row:t}){const{keeper:e}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>ri(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Rr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Qt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Wv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?i`<span>하트비트 <${X} timestamp=${e.last_heartbeat} /></span>`:i`<span>하트비트 없음</span>`}
        <span>${Jv(e)}</span>
        <span>라이프사이클 ${t.lifecycle}</span>
        <span>컨텍스트 ${Bv(e.context_ratio)}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?i`<div class="monitor-footnote">스킬 라우팅: ${e.skill_reason}</div>`:null}
    </button>
  `}function Zv(){const t=[..._t.value].map(Vv).sort((m,v)=>{const f=fe(v.tone)-fe(m.tone);if(f!==0)return f;const h=v.activeTaskCount-m.activeTaskCount;return h!==0?h:Kt(v.lastSignalAt)-Kt(m.lastSignalAt)}),e=[...jt.value].map(Yv).sort((m,v)=>{const f=fe(v.tone)-fe(m.tone);if(f!==0)return f;const h=(v.keeper.context_ratio??0)-(m.keeper.context_ratio??0);return h!==0?h:Kt(v.keeper.last_heartbeat)-Kt(m.keeper.last_heartbeat)}),n=t.filter(m=>m.state!=="offline"),s=t.filter(m=>m.state==="offline"),a=n.length,o=t.filter(m=>m.state==="working").length,l=t.filter(m=>m.lastSignalAt&&Date.now()-Kt(m.lastSignalAt)<=12e4).length,d=t.filter(m=>m.tone!=="ok"),p=e.filter(m=>m.tone!=="ok"),_=[...p.map(m=>({kind:"keeper",key:`keeper-${m.keeper.name}`,tone:m.tone,title:m.keeper.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.keeper.last_heartbeat??null,keeper:m.keeper})),...d.map(m=>({kind:"agent",key:`agent-${m.agent.name}`,tone:m.tone,title:m.agent.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.lastSignalAt,agent:m.agent}))].sort((m,v)=>{const f=fe(v.tone)-fe(m.tone);return f!==0?f:Kt(v.timestamp)-Kt(m.timestamp)}).slice(0,8);return i`
    <div class="agents-monitor">
      <${vt} surfaceId="execution" />
      <div class="stats-grid">
        <${Be} label="온라인 worker" value=${a} color="#4ade80" caption="활성 + 대기 실행 주체" />
        <${Be} label="지금 작업 중" value=${o} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${Be} label="신선한 신호" value=${l} color="#22d3ee" caption="최근 2분 이내 신호" />
        <${Be} label="worker 경고" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="실행 주체 경고" />
        <${Be} label="연속성 경고" value=${p.length} color=${p.length>0?"#fb7185":"#4ade80"} caption="keeper 연속성 경고" />
      </div>

      <${C} title="Execution Priorities" class="section" semanticId="execution.priority_queue">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">지금 실행 관점에서 먼저 봐야 할 대상</h2>
          <p class="monitor-subheadline">worker 드리프트와 keeper 연속성 위험은 여기서 함께 우선순위를 매기고, 아래 섹션에서 각각 따로 진단합니다.</p>
        </div>
        <div class="monitor-alert-list">
          ${_.length===0?i`<div class="empty-state">지금은 실행 경고가 없습니다</div>`:_.map(m=>i`<${Xv} key=${m.key} item=${m} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${C} title="Workers" class="section" semanticId="execution.workers">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">단기 실행 모니터</h2>
            <p class="monitor-subheadline">현재 살아 있는 worker를 먼저 묶어서, 누가 일을 잃었는지 오프라인 이력보다 먼저 보이게 합니다.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?i`<div class="empty-state">보이는 활성 worker가 없습니다</div>`:n.map(m=>i`<${Zi} key=${m.agent.name} row=${m} />`)}
          </div>
        <//>

        <${C} title="Continuity" class="section" semanticId="execution.continuity">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">장기 keeper 연속성</h2>
            <p class="monitor-subheadline">하트비트, 컨텍스트 압력, 핸드오프 상태를 worker 실행 드리프트와 분리해서 봅니다.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?i`<div class="empty-state">활성 keeper가 없습니다</div>`:e.map(m=>i`<${Qv} key=${m.keeper.name} row=${m} />`)}
          </div>
        <//>

        <${C} title="Offline Workers" class="section" semanticId="execution.offline">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">라이브 루프에서 빠진 worker</h2>
            <p class="monitor-subheadline">오프라인 row를 분리해서, 활성 실행 모니터가 묻히지 않게 합니다.</p>
          </div>
          <div class="monitor-list">
            ${s.length===0?i`<div class="empty-state">지금은 오프라인 worker가 없습니다</div>`:s.map(m=>i`<${Zi} key=${m.agent.name} row=${m} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Ns=g("all"),Ls=g("all"),Ga=g(new Set);function t_(t){const e=new Set(Ga.value);e.has(t)?e.delete(t):e.add(t),Ga.value=e}const Pr=$t(()=>{let t=Se.value;return Ns.value!=="all"&&(t=t.filter(e=>e.horizon===Ns.value)),Ls.value!=="all"&&(t=t.filter(e=>e.status===Ls.value)),t}),e_=$t(()=>{const t={short:[],mid:[],long:[]};for(const e of Pr.value){const n=t[e.horizon];n&&n.push(e)}return t}),n_=$t(()=>{const t=Array.from(Co.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function s_(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function hi(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function rs(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function a_(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function to(t){return t.toFixed(4)}function eo(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function i_(t){switch(t){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function no(t,e){return(t.priority??4)-(e.priority??4)}function o_(t,e){const n=t.updated_at??t.created_at??"";return(e.updated_at??e.created_at??"").localeCompare(n)}function r_(t,e){return t.length<=e?t:t.slice(0,e)+"..."}function l_({goal:t}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${rs(t.horizon)}">
            ${hi(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${s_(t.priority)}</span>
          ${t.metric?i`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?i`<span class="goal-due">Due: <${X} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?i`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${Qt} status=${t.status} />
        <div class="goal-updated">
          <${X} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function da({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return i`
    <${C} title="${hi(t)} Goals (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${l_} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function c_(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>i`
          <button
            class="goal-filter-btn ${Ns.value===t?"active":""}"
            onClick=${()=>{Ns.value=t}}
          >
            ${t==="all"?"All":hi(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>i`
          <button
            class="goal-filter-btn ${Ls.value===t?"active":""}"
            onClick=${()=>{Ls.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function d_(){const t=Se.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return i`
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
        <div class="goal-summary-value" style="color:${rs("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${rs("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${rs("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function u_({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return i`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${Qt} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${to(t.baseline_metric)}</span>
          <span>Current ${to(t.current_metric)}</span>
          <span class=${eo(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${eo(t)}
          </span>
          <span>Elapsed ${a_(t.elapsed_seconds)}</span>
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
  `}function ua({task:t}){const e=t.priority??4,n=e<=1?"p1":e===2?"p2":e===3?"p3":"p4",s=Ga.value.has(t.id),a=!!t.description;return i`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${i_(e)}</span>
        <div class="kanban-card-title">${t.title}</div>
      </div>
      ${a?i`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>t_(t.id)}
        >
          ${s?t.description:r_(t.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${t.created_at?i`<${X} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function p_(){const{todo:t,inProgress:e,done:n}=To.value,s=[...t].sort(no),a=[...e].sort(no),o=[...n].sort(o_);return i`
    <${C} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${s.length===0?i`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:s.map(l=>i`<${ua} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${a.length===0?i`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:a.map(l=>i`<${ua} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${o.length===0?i`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:o.slice(0,20).map(l=>i`<${ua} key=${l.id} task=${l} />`)}
          ${o.length>20?i`<div class="empty-state" style="opacity: 0.5;">...and ${o.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function m_(){const{todo:t,inProgress:e,done:n}=To.value,s=t.length+e.length+n.length,a=[...t,...e].filter(m=>(m.priority??4)<=2).length,o=e_.value,l=n_.value,d=Se.value.length>0,p=l.length>0,_=si.value;return i`
    <div>
      <${vt} surfaceId="planning" />

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
          onClick=${()=>{dn(),Lo()}}
          disabled=${Ye.value||Xe.value}
        >
          ${Ye.value||Xe.value?"Refreshing...":"Refresh planning data"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${p_} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${d}>
        <summary>
          Goal Pipeline
          <span class="monitor-pill">${Se.value.length}</span>
        </summary>
        <div>
          ${d?i`
            <${d_} />
            <${c_} />
            ${Ye.value&&Se.value.length===0?i`<div class="loading-indicator">Loading goals...</div>`:Pr.value.length===0?i`<div class="empty-state">No goals match the current filters</div>`:i`
                    <${da} horizon="short" items=${o.short??[]} />
                    <${da} horizon="mid" items=${o.mid??[]} />
                    <${da} horizon="long" items=${o.long??[]} />
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
          ${Xe.value&&l.length===0?i`<div class="loading-indicator">Loading MDAL loops...</div>`:l.length===0&&(_==="error"||Ae.value)?i`<div class="empty-state">MDAL snapshot could not be loaded${Ae.value?`: ${Ae.value}`:""}. Check backend health.</div>`:l.length===0?i`<div class="empty-state">No active loops. Use <code>masc_mdal_start</code> to start a loop.</div>`:i`
                  <div class="planning-loop-list">
                    ${l.map(m=>i`<${u_} key=${m.loop_id} loop=${m} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const nn=g("debates"),Ms=g([]),Ds=g([]),Es=g(!1),sn=g(!1),Cn=g(""),an=g(""),zs=g(null),bt=g(null),Ja=g(!1);async function Xs(){Es.value=!0,Cn.value="";try{const t=await yl();Ms.value=Array.isArray(t.debates)?t.debates:[],Ds.value=Array.isArray(t.sessions)?t.sessions:[]}catch(t){Cn.value=t instanceof Error?t.message:"Failed to load governance state"}finally{Es.value=!1}}id(Xs);async function so(){const t=an.value.trim();if(t){sn.value=!0;try{const e=await pc(t);an.value="",R(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Xs()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";R(n,"error")}finally{sn.value=!1}}}async function v_(t){zs.value=t,bt.value=null,Ja.value=!0;try{bt.value=await mc(t)}catch(e){Cn.value=e instanceof Error?e.message:"Failed to load debate detail"}finally{Ja.value=!1}}function __(){return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${Ms.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Voting sessions</span>
        <strong>${Ds.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Active view</span>
        <strong>${nn.value==="debates"?"Debates":"Voting"}</strong>
      </div>
    </div>
  `}function f_({debate:t}){const e=zs.value===t.id;return i`
    <button class="council-row ${e?"selected":""}" onClick=${()=>v_(t.id)}>
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Arguments: ${t.argument_count}</span>
          ${t.created_at?i`<span><${X} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </button>
  `}function g_({session:t}){return i`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.created_at?i`<span><${X} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function $_(){const t=nn.value;return i`
    <div class="overview-sub-tabs" style="margin-bottom:12px;">
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{nn.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{nn.value="voting"}}>Voting</button>
    </div>
  `}function h_(){return i`
    <div>
      <${C} title="Start Debate" class="section" semanticId="governance.debates">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${an.value}
            onInput=${t=>{an.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&so()}}
            disabled=${sn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${so}
            disabled=${sn.value||an.value.trim()===""}
          >
            ${sn.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Xs} disabled=${Es.value}>
            ${Es.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Cn.value?i`<div class="council-error">${Cn.value}</div>`:null}
      <//>

      <${C} title="Debates" class="section" semanticId="governance.debates">
        <div class="council-list">
          ${Ms.value.length===0?i`<div class="empty-state">No debates yet</div>`:Ms.value.map(t=>i`<${f_} key=${t.id} debate=${t} />`)}
        </div>
      <//>

      <${C} title=${zs.value?`Debate Detail (${zs.value})`:"Debate Detail"} class="section" semanticId="governance.debates">
        ${Ja.value?i`<div class="loading-indicator">Loading debate detail...</div>`:bt.value?i`
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Status: ${bt.value.status}</span>
                  <span>Total arguments: ${bt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Support: ${bt.value.support_count}</span>
                  <span>Oppose: ${bt.value.oppose_count}</span>
                  <span>Neutral: ${bt.value.neutral_count}</span>
                </div>
                ${bt.value.summary_text?i`<pre class="council-detail">${bt.value.summary_text}</pre>`:null}
              `:i`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function y_(){return i`
    <${C} title="Voting Sessions" class="section" semanticId="governance.voting">
      <div class="council-list">
        ${Ds.value.length===0?i`<div class="empty-state">No active sessions</div>`:Ds.value.map(t=>i`<${g_} key=${t.id} session=${t} />`)}
      </div>
    <//>
  `}function b_(){return Z(()=>{Xs()},[]),i`
    <div>
      <${vt} surfaceId="governance" />
      <${__} />
      <${$_} />
      ${nn.value==="debates"?i`<${h_} />`:i`<${y_} />`}
    </div>
  `}const $e=g(""),pa=g("ability_check"),ma=g("10"),va=g("12"),Gn=g(""),Jn=g("idle"),Ut=g(""),Vn=g("keeper-late"),_a=g("player"),fa=g(""),pt=g("idle"),ga=g(null),Yn=g(""),$a=g(""),ha=g("player"),ya=g(""),ba=g(""),ka=g(""),on=g("20"),xa=g("20"),Sa=g(""),Xn=g("idle"),Va=g(null),Nr=g("overview"),Aa=g("all"),Ca=g("all"),wa=g("all"),k_=12e4,Qs=g(null),ao=g(Date.now());function x_(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function S_(t,e){return e>0?Math.round(t/e*100):0}const A_={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},C_={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Qn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function w_(t){const e=t.trim().toLowerCase();return A_[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function T_(t){const e=t.trim().toLowerCase();return C_[e]??"상황에 따라 선택되는 전술 액션입니다."}function dt(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function kt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function wn(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const I_=new Set(["str","dex","con","int","wis","cha"]);function R_(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!u(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const l=a.trim();if(l){if(typeof o=="number"&&Number.isFinite(o)){s[l]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const d=Number.parseFloat(o.trim());if(Number.isFinite(d)){s[l]=Math.max(0,Math.trunc(d));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function P_(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(on.value.trim(),10);Number.isFinite(s)&&s>n&&(on.value=String(n))}function Ya(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function N_(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function L_(t){Nr.value=t}function Lr(t){const e=Qs.value;return e==null||e<=t}function M_(t){const e=Qs.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function js(){Qs.value=null}function Mr(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function D_(t,e){Mr(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Qs.value=Date.now()+k_,R("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function ls(t){return Lr(t)?(R("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Xa(t,e,n){return Mr([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function E_({hp:t,max:e}){const n=S_(t,e),s=x_(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function z_({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function j_({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Dr({actor:t}){var p,_,m,v;const e=(p=t.archetype)==null?void 0:p.trim(),n=(_=t.persona)==null?void 0:_.trim(),s=(m=t.portrait)==null?void 0:m.trim(),a=(v=t.background)==null?void 0:v.trim(),o=t.traits??[],l=t.skills??[],d=Object.entries(t.stats_raw??{}).filter(([f,h])=>Number.isFinite(h)).filter(([f])=>!I_.has(f.toLowerCase()));return i`
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
        <${Qt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${j_} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${E_} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${z_} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${Qn(e)}</div>`:null}
      ${a?i`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${d.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${d.map(([f,h])=>i`
                <span class="trpg-custom-stat-chip">${Qn(f)} ${h}</span>
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
                  <span class="trpg-annot-name">${Qn(f)}</span>
                  <span class="trpg-annot-desc">${w_(f)}</span>
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
                  <span class="trpg-annot-name">${Qn(f)}</span>
                  <span class="trpg-annot-desc">${T_(f)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function O_({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function Er({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?i`<div class="empty-state" style="font-size:13px">${e}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${N_(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Ya(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${X} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function F_({events:t}){const e="__none__",n=Aa.value,s=Ca.value,a=wa.value,o=Array.from(new Set(t.map(Ya).map(v=>v.trim()).filter(v=>v!==""))).sort((v,f)=>v.localeCompare(f)),l=Array.from(new Set(t.map(v=>(v.type??"").trim()).filter(v=>v!==""))).sort((v,f)=>v.localeCompare(f)),d=t.some(v=>(v.type??"").trim()===""),p=Array.from(new Set(t.map(v=>(v.phase??"").trim()).filter(v=>v!==""))).sort((v,f)=>v.localeCompare(f)),_=t.some(v=>(v.phase??"").trim()===""),m=t.filter(v=>{if(n!=="all"&&Ya(v)!==n)return!1;const f=(v.type??"").trim(),h=(v.phase??"").trim();if(s===e){if(f!=="")return!1}else if(s!=="all"&&f!==s)return!1;if(a===e){if(h!=="")return!1}else if(a!=="all"&&h!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${v=>{Aa.value=v.target.value}}>
          <option value="all">all</option>
          ${o.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${v=>{Ca.value=v.target.value}}>
          <option value="all">all</option>
          ${d?i`<option value=${e}>(none)</option>`:null}
          ${l.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${v=>{wa.value=v.target.value}}>
          <option value="all">all</option>
          ${_?i`<option value=${e}>(none)</option>`:null}
          ${p.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Aa.value="all",Ca.value="all",wa.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${m.length} / 전체 ${t.length}
      </span>
    </div>
    <${Er} events=${m.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function q_({outcome:t}){if(!t)return null;const e=o=>{const l=o.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function zr({state:t}){const e=t.history??[];return e.length===0?null:i`
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
  `}function K_({state:t,nowMs:e}){var _;const n=Mt.value||((_=t.session)==null?void 0:_.room)||"",s=Jn.value,a=t.party??[];if(!a.find(m=>m.id===$e.value)&&a.length>0){const m=a[0];m&&($e.value=m.id)}const l=async()=>{var v,f;if(!n){R("Room ID가 비어 있습니다.","error");return}if(!ls(e))return;const m=((v=t.current_round)==null?void 0:v.phase)??((f=t.session)==null?void 0:f.status)??"unknown";if(Xa("라운드 실행",n,m)){Jn.value="running";try{const h=await ec(n);Va.value=h,Jn.value="ok";const k=u(h.summary)?h.summary:null,x=k?wn(k,"advanced",!1):!1,S=k?dt(k,"progress_reason",""):"";R(x?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${S?`: ${S}`:""}`,x?"success":"warning"),Tt()}catch(h){Va.value=null,Jn.value="error";const k=h instanceof Error?h.message:"라운드 실행에 실패했습니다.";R(k,"error")}finally{js()}}},d=async()=>{var v,f;if(!n||!ls(e))return;const m=((v=t.current_round)==null?void 0:v.phase)??((f=t.session)==null?void 0:f.status)??"unknown";if(Xa("턴 강제 진행",n,m))try{await ac(n),R("턴을 다음 단계로 이동했습니다.","success"),Tt()}catch{R("턴 이동에 실패했습니다.","error")}finally{js()}},p=async()=>{if(!n||!ls(e))return;const m=$e.value.trim();if(!m){R("먼저 Actor를 선택하세요.","warning");return}const v=Number.parseInt(ma.value,10),f=Number.parseInt(va.value,10);if(Number.isNaN(v)||Number.isNaN(f)){R("stat/dc는 숫자여야 합니다.","warning");return}const h=Number.parseInt(Gn.value,10),k=Gn.value.trim()===""||Number.isNaN(h)?void 0:h;try{await sc({roomId:n,actorId:m,action:pa.value.trim()||"ability_check",statValue:v,dc:f,rawD20:k}),R("주사위 판정을 기록했습니다.","success"),Tt()}catch{R("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${m=>{Mt.value=m.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${$e.value}
            onChange=${m=>{$e.value=m.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(m=>i`<option value=${m.id}>${m.name} (${m.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${pa.value}
              onInput=${m=>{pa.value=m.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${ma.value}
              onInput=${m=>{ma.value=m.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${va.value}
              onInput=${m=>{va.value=m.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Gn.value}
              onInput=${m=>{Gn.value=m.target.value}}
              onKeyDown=${m=>{m.key==="Enter"&&p()}}
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
            <button class="trpg-run-btn secondary" onClick=${d}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${s!=="idle"?i`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function U_({state:t}){var a;const e=Mt.value||((a=t.session)==null?void 0:a.room)||"",n=Xn.value,s=async()=>{if(!e){R("Room ID가 비어 있습니다.","warning");return}const o=Yn.value.trim(),l=$a.value.trim();if(!l&&!o){R("이름 또는 Actor ID를 입력하세요.","warning");return}const d=Number.parseInt(on.value.trim(),10),p=Number.parseInt(xa.value.trim(),10),_=Number.isFinite(p)?Math.max(1,p):20,m=Number.isFinite(d)?Math.max(0,Math.min(_,d)):_;let v={};try{v=R_(Sa.value)}catch(f){R(f instanceof Error?f.message:"능력치 JSON 오류","error");return}Xn.value="spawning";try{const f=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,h=await ic(e,{actor_id:o||void 0,name:l||void 0,role:ha.value,idempotencyKey:f,portrait:ba.value.trim()||void 0,background:ka.value.trim()||void 0,hp:m,max_hp:_,alive:m>0,stats:Object.keys(v).length>0?v:void 0}),k=typeof h.actor_id=="string"?h.actor_id.trim():"";if(!k)throw new Error("생성 응답에 actor_id가 없습니다.");const x=ya.value.trim();x&&await oc(e,k,x),$e.value=k,Ut.value=k,o||(Yn.value=""),Xn.value="ok",R(`Actor 생성 완료: ${k}`,"success"),await Tt()}catch(f){Xn.value="error",R(f instanceof Error?f.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${$a.value}
            onInput=${o=>{$a.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${ha.value}
            onChange=${o=>{ha.value=o.target.value}}
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
            value=${ya.value}
            onInput=${o=>{ya.value=o.target.value}}
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
              value=${Yn.value}
              onInput=${o=>{Yn.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${ba.value}
              onInput=${o=>{ba.value=o.target.value}}
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
              value=${on.value}
              onInput=${o=>{on.value=o.target.value}}
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
              value=${xa.value}
              onInput=${o=>{const l=o.target.value;xa.value=l,P_(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${ka.value}
              onInput=${o=>{ka.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Sa.value}
              onInput=${o=>{Sa.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function H_({state:t,nowMs:e}){var f;const n=Mt.value||((f=t.session)==null?void 0:f.room)||"",s=t.join_gate,a=ga.value,o=u(a)?a:null,l=(t.party??[]).filter(h=>h.role!=="dm"),d=Ut.value.trim(),p=l.some(h=>h.id===d),_=p?d:d?"__manual__":"",m=async()=>{const h=Ut.value.trim(),k=Vn.value.trim();if(!n||!h){R("Room/Actor가 필요합니다.","warning");return}pt.value="checking";try{const x=await rc(n,h,k||void 0);ga.value=x,pt.value="ok",R("참가 가능 여부를 갱신했습니다.","success")}catch(x){pt.value="error";const S=x instanceof Error?x.message:"참가 가능 여부 확인에 실패했습니다.";R(S,"error")}},v=async()=>{var w,A;const h=Ut.value.trim(),k=Vn.value.trim(),x=fa.value.trim();if(!n||!h||!k){R("Room/Actor/Keeper가 필요합니다.","warning");return}if(!ls(e))return;const S=((w=t.current_round)==null?void 0:w.phase)??((A=t.session)==null?void 0:A.status)??"unknown";if(Xa("Mid-Join 승인 요청",n,S)){pt.value="requesting";try{const N=await lc({room_id:n,actor_id:h,keeper_name:k,role:_a.value,...x?{name:x}:{}});ga.value=N;const T=u(N)?wn(N,"granted",!1):!1,I=u(N)?dt(N,"reason_code",""):"";T?R("Mid-Join이 승인되었습니다.","success"):R(`Mid-Join이 거절되었습니다${I?`: ${I}`:""}`,"warning"),pt.value=T?"ok":"error",Tt()}catch(N){pt.value="error";const T=N instanceof Error?N.message:"Mid-Join 요청에 실패했습니다.";R(T,"error")}finally{js()}}};return i`
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
            onChange=${h=>{const k=h.target.value;if(k==="__manual__"){(p||!d)&&(Ut.value="");return}Ut.value=k}}
          >
            <option value="">Actor 선택</option>
            ${l.map(h=>i`
              <option value=${h.id}>${h.name} (${h.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${_==="__manual__"?i`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${Ut.value}
                onInput=${h=>{Ut.value=h.target.value}}
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
            value=${Vn.value}
            onInput=${h=>{Vn.value=h.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${_a.value}
            onChange=${h=>{_a.value=h.target.value}}
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
            value=${fa.value}
            onInput=${h=>{fa.value=h.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${m} disabled=${pt.value==="checking"||pt.value==="requesting"}>
              ${pt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${v} disabled=${pt.value==="checking"||pt.value==="requesting"}>
              ${pt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${wn(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${kt(o,"effective_score",0)}/${kt(o,"required_points",0)}</span>
            ${dt(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${dt(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function jr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Or({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Fr(){const t=Va.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=u(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(u).slice(-8),o=t.canon_check,l=u(o)?o:null,d=l&&Array.isArray(l.warnings)?l.warnings.filter(I=>typeof I=="string").slice(0,3):[],p=l&&Array.isArray(l.violations)?l.violations.filter(I=>typeof I=="string").slice(0,3):[],_=n?wn(n,"advanced",!1):!1,m=n?dt(n,"progress_reason",""):"",v=n?dt(n,"progress_detail",""):"",f=n?kt(n,"player_successes",0):0,h=n?kt(n,"player_required_successes",0):0,k=n?wn(n,"dm_success",!1):!1,x=n?kt(n,"timeouts",0):0,S=n?kt(n,"unavailable",0):0,w=n?kt(n,"reprompts",0):0,A=n?kt(n,"npc_attacks",0):0,N=n?kt(n,"keeper_timeout_sec",0):0,T=n?kt(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${_?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${_?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${k?"DM ok":"DM stalled"} / players ${f}/${h}
          </span>
        </div>
        ${m?i`<div style="margin-top:4px; font-size:12px;">${m}</div>`:null}
        ${v?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${v}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${w}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${N||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${T}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(I=>{const H=dt(I,"status","unknown"),K=dt(I,"actor_id","-"),$=dt(I,"role","-"),z=dt(I,"reason",""),G=dt(I,"action_type",""),F=dt(I,"reply","");return i`
                <div class="trpg-round-item ${H.includes("fallback")||H.includes("timeout")?"failed":"active"}">
                  <span>${K} (${$})</span>
                  <span style="margin-left:auto; font-size:11px;">${H}</span>
                  ${G?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${G}</div>`:null}
                  ${z?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${z}</div>`:null}
                  ${F?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${F.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${dt(l,"status","unknown")}</strong>
            </div>
            ${p.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${p.map(I=>i`<div>violation: ${I}</div>`)}
                </div>`:null}
            ${d.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${d.map(I=>i`<div>warning: ${I}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function W_({state:t,nowMs:e}){var l,d,p;const n=Mt.value||((l=t.session)==null?void 0:l.room)||"",s=((d=t.current_round)==null?void 0:d.phase)??((p=t.session)==null?void 0:p.status)??"unknown",a=Lr(e),o=M_(e);return i`
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
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>D_(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{js(),R("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function B_({active:t}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>L_(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function G_({state:t}){const e=t.party??[],n=t.story_log??[];return i`
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
          <${Er} events=${n.slice(-20)} />
        <//>

        ${t.map?i`
            <${C} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${O_} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${C} title="현재 라운드" semanticId="lab.trpg">
          <${Or} state=${t} />
        <//>

        <${C} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${jr} state=${t} />
        <//>

        <${C} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>i`<${Dr} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?i`
            <${C} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${zr} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function J_({state:t}){const e=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${C} title=${`이벤트 타임라인 (${e.length})`}>
          <${F_} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${C} title="최근 라운드 결과" semanticId="lab.trpg">
          <${Fr} />
        <//>

        <${C} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${Or} state=${t} />
        <//>
      </div>
    </div>
  `}function V_({state:t,nowMs:e}){const n=t.party??[];return i`
    <div>
      <${W_} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${C} title="조작 패널" semanticId="lab.trpg">
            <${K_} state=${t} nowMs=${e} />
          <//>

          <${C} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${U_} state=${t} />
          <//>

          <${C} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${H_} state=${t} nowMs=${e} />
          <//>

          <${C} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${Fr} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${C} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${jr} state=${t} />
          <//>

          <${C} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${Dr} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?i`
              <${C} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${zr} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Y_(){var d,p,_,m,v;const t=Ao.value,e=Oa.value;if(Z(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const f=window.setInterval(()=>{ao.value=Date.now()},1e3);return()=>{window.clearInterval(f)}},[]),e&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Tt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,o=Nr.value,l=ao.value;return i`
    <div>
      <${vt} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Mt.value||((d=t.session)==null?void 0:d.room)||"-"} · phase: ${((p=t.current_round)==null?void 0:p.phase)??((_=t.session)==null?void 0:_.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Tt()}>새로고침</button>
      </div>

      <${q_} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((m=t.session)==null?void 0:m.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((v=t.current_round)==null?void 0:v.round_number)??0}</div>
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

      <${B_} active=${o} />

      ${o==="overview"?i`<${G_} state=${t} />`:o==="timeline"?i`<${J_} state=${t} />`:i`<${V_} state=${t} nowMs=${l} />`}
    </div>
  `}function X_(){return i`
    <div>
      <${vt} surfaceId="lab" />
      <${C} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${C} title="TRPG" class="section" semanticId="lab.trpg">
        <${Y_} />
      <//>
    </div>
  `}const Os=g(new Set(["broadcast","tasks","keepers","system"]));function Q_(t){const e=new Set(Os.value);e.has(t)?e.delete(t):e.add(t),Os.value=e}const yi=g(null);function qr(t){yi.value=t}function Z_(t){return t.kind==="board"?"broadcast":t.kind==="tasks"?"tasks":t.kind==="keepers"?"keepers":"system"}const tf=$t(()=>{const t=Os.value;return ds.value.filter(e=>t.has(Z_(e)))}),ef=12e4,nf=$t(()=>{const t=Us.value,e=Date.now();return _t.value.map(n=>{const s=n.name.trim().toLowerCase(),a=t.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?o=e-new Date(l).getTime()>ef?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),sf=$t(()=>{const t=Us.value;return _t.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle").map(e=>{const n=e.name.trim().toLowerCase(),s=t.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:e.name,emoji:e.emoji??"",koreanName:e.koreanName??null,currentTask:e.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((e,n)=>{const s={hot:0,normal:1,calm:2};return s[e.pressure]-s[n.pressure]})});function io(t){return t.kind==="board"?"live-event-broadcast":t.kind==="tasks"?"live-event-task":t.kind==="keepers"?"live-event-keeper":"live-event-system"}function af(t){const e=t.eventType;return e==="broadcast"?"broadcast":e==="agent_joined"?"joined":e==="agent_left"?"left":e==="task_update"?"task":e==="board_post"?"post":e==="board_comment"?"comment":e==="keeper_heartbeat"?"heartbeat":e==="keeper_handoff"?"handoff":e==="keeper_compaction"?"compact":e==="keeper_guardrail"?"guardrail":t.kind==="board"?"board":t.kind==="tasks"?"task":t.kind==="keepers"?"keeper":"system"}function of(t){switch(t){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function rf(){const t=nf.value,e=yi.value;return t.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${t.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${of(n.state)} ${e===n.name?"pulse-selected":""}"
          onClick=${()=>qr(e===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const lf=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function cf(){const t=Os.value;return i`
    <div class="activity-filter-bar">
      ${lf.map(e=>i`
        <button
          key=${e.kind}
          class="activity-filter-btn ${e.cssClass} ${t.has(e.kind)?"active":""}"
          onClick=${()=>Q_(e.kind)}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function df(){const t=tf.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${t.length} events</span>
      </div>
      <${cf} />
      <div class="activity-stream-list">
        ${t.length===0?i`<div class="activity-empty">No events matching filters</div>`:t.map((e,n)=>i`
            <div
              key=${`${e.timestamp}-${n}`}
              class="activity-item ${io(e)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${io(e)}">${af(e)}</span>
                <span class="activity-agent">${e.agent}</span>
                <span class="activity-time">${Do(e.timestamp)}</span>
              </div>
              <div class="activity-item-text">${e.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function uf(t){switch(t){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function pf(t){switch(t){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function mf(){const t=sf.value,e=yi.value;return i`
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
              onClick=${()=>qr(e===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?i`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${uf(n.pressure)}">
                  ${pf(n.pressure)}
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
  `}function vf(){const t=Jt.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>Live Monitor</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${t?"connected":"disconnected"}"></span>
            ${t?"Connected":"Offline"}
          </span>
          <span class="live-stat">${_t.value.length} agents</span>
          <span class="live-stat">${Fs.value} events</span>
        </div>
      </div>

      <${rf} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${df} />
        </div>
        <div class="live-panel-side">
          <${mf} />
        </div>
      </div>
    </div>
  `}const oo=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],Qa=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"live",label:"Live",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}];function _f(){const t=Jt.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Fs.value} events</span>
    </div>
  `}function ff({currentTab:t,currentSectionLabel:e}){const n=Jt.value;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>Snapshot</h3>
        <${L} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${n?"ok":"bad"}">${n?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agents</span>
          <strong>${_t.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keepers</span>
          <strong>${jt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Tasks</span>
          <strong>${Ct.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Events</span>
          <strong>${Fs.value}</strong>
        </div>
      </div>
      <div class="rail-snapshot-copy">
        <span>Connection ${n?"healthy":"recovering"}</span>
        <span>${e} workspace active</span>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{In(),Po(),t==="command"&&(Ht(),Wt(),(q.value==="swarm"||q.value==="warroom")&&St(),q.value==="warroom"&&tt()),t==="mission"&&(ss(),un()),t==="execution"&&Lt(),t==="intervene"&&(tt(),zt()),t==="memory"&&wt(),t==="planning"&&dn(),t==="lab"&&Tt()}}
        >
          Refresh Now
        </button>
        <button class="rail-secondary-btn" onClick=${()=>lt("intervene")}>
          Open Intervene
        </button>
      </div>
    </section>
  `}function gf(){const t=It.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${L} panelId="side_rail.quick_actions" compact=${!0} />
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
          onClick=${()=>{tt(),zt()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>lt("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function $f(){const t=D.value.tab,e=Qa.find(s=>s.id===t),n=oo.find(s=>s.id===(e==null?void 0:e.group));return i`
    <aside class="dashboard-rail">
      <${vt} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          <${L} panelId="side_rail.navigate" compact=${!0} />
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${oo.map(s=>i`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${Qa.filter(a=>a.group===s.id).map(a=>i`
                  <button
                    class="rail-tab-btn ${t===a.id?"active":""}"
                    onClick=${()=>lt(a.id)}
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

      <${ff} currentTab=${t} currentSectionLabel=${(n==null?void 0:n.label)??"Observe"} />
      <${gf} />
    </aside>
  `}function hf(){switch(D.value.tab){case"mission":return i`<${Fi} />`;case"execution":return i`<${Zv} />`;case"live":return i`<${vf} />`;case"memory":return i`<${Kv} />`;case"governance":return i`<${b_} />`;case"planning":return i`<${m_} />`;case"intervene":return i`<${Iv} />`;case"command":return i`<${pv} />`;case"lab":return i`<${X_} />`;default:return i`<${Fi} />`}}function yf(){Z(()=>{Zr(),vo(),No(),Lt(),Po(),ss();const n=ld();return cd(),()=>{rl(),n(),dd()}},[]),Z(()=>{const n=setInterval(()=>{const s=D.value.tab;s==="command"?(Ht(),Wt(),(q.value==="swarm"||q.value==="warroom")&&St(),q.value==="warroom"&&tt()):s==="mission"?ss():s==="execution"?Lt():s==="intervene"?(tt(),zt()):s==="memory"?wt():s==="planning"?dn():s==="lab"&&Tt()},15e3);return()=>{clearInterval(n)}},[]),Z(()=>{const n=D.value.tab;n==="command"&&(Ht(),Wt(),(q.value==="swarm"||q.value==="warroom")&&St(),q.value==="warroom"&&tt()),n==="mission"&&(ss(),un()),n==="execution"&&Lt(),n==="intervene"&&(tt(),zt()),n==="memory"&&wt(),n==="planning"&&dn(),n==="lab"&&Tt()},[D.value.tab]);const t=D.value.tab,e=Qa.find(n=>n.id===t);return i`
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
          <${_f} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${$f} />
        <main class="dashboard-main">
          ${ja.value&&!Jt.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${hf} />`}
        </main>
      </div>

      <${fu} />
      <${Ed} />
      <${Id} />
    </div>
  `}const ro=document.getElementById("app");ro&&Jr(i`<${yf} />`,ro);export{am as _};
