var Wr=Object.defineProperty;var Br=(t,e,n)=>e in t?Wr(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var fe=(t,e,n)=>Br(t,typeof e!="symbol"?e+"":e,n);import{e as Gr,_ as Jr,c as g,b as ft,y as Z,d as lo,A as Vr,G as Yr}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const l of o.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=Gr.bind(Jr);const Qr=["mission","execution","live","memory","governance","planning","intervene","command","lab"],co={tab:"mission",params:{},postId:null};function ki(t){return!!t&&Qr.includes(t)}function wa(t){try{return decodeURIComponent(t)}catch{return t}}function Ta(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Xr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function uo(t,e){if(t[0]==="chains"){const o={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(o.operation=wa(t[2])),{tab:"command",params:o,postId:null}}if(t[0]==="lab"){const o={...e};return t[1]&&(o.surface=wa(t[1])),{tab:"lab",params:o,postId:null}}const n=t[0],s=e.tab;return{tab:ki(n)?n:ki(s)?s:"mission",params:e,postId:null}}function ps(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return co;const n=wa(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const d=n.indexOf("?");d>=0&&(s=n.slice(0,d),a=n.slice(d+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=Ta(a),l=Xr(s);return uo(l,o)}function Zr(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...co,params:Ta(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Ta(e.replace(/^\?/,""));return uo(s,a)}function po(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const D=g(ps(window.location.hash));window.addEventListener("hashchange",()=>{D.value=ps(window.location.hash)});function rt(t,e){const n={tab:t,params:e??{}};window.location.hash=po(n)}function tl(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function el(){if(window.location.hash&&window.location.hash!=="#"){D.value=ps(window.location.hash);return}const t=Zr(window.location.pathname,window.location.search);if(t){D.value=t;const e=po(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",D.value=ps(window.location.hash)}const xi="masc_dashboard_sse_session_id",nl=1e3,sl=15e3,Vt=g(!1),Us=g(0),mo=g(null),ms=g([]);function al(){let t=sessionStorage.getItem(xi);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(xi,t)),t}const il=200;function ol(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};ms.value=[a,...ms.value].slice(0,il)}function Ia(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Si(t,e){const n=Ia(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function vt(t,e,n,s,a={}){ol(t,e,n,{eventType:s,...a})}let kt=null,Ce=null,Ra=0;function vo(){Ce&&(clearTimeout(Ce),Ce=null)}function rl(){if(Ce)return;Ra++;const t=Math.min(Ra,5),e=Math.min(sl,nl*Math.pow(2,t));Ce=setTimeout(()=>{Ce=null,_o()},e)}function _o(){vo(),kt&&(kt.close(),kt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",al());const a=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(a);kt=o,o.onopen=()=>{kt===o&&(Ra=0,Vt.value=!0)},o.onerror=()=>{kt===o&&(Vt.value=!1,o.close(),kt=null,rl())},o.onmessage=l=>{try{const d=JSON.parse(l.data);Us.value++,mo.value=d,ll(d)}catch{}}}function ll(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":vt(n,"Joined","system","agent_joined");break;case"agent_left":vt(n,"Left","system","agent_left");break;case"broadcast":vt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":vt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":vt(n,Si("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Ia(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":vt(n,Si("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Ia(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":vt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":vt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":vt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":vt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:vt(n,e,"system","unknown")}}function cl(){vo(),kt&&(kt.close(),kt=null),Vt.value=!1}function u(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function r(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function c(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function z(t){return typeof t=="boolean"?t:void 0}function K(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function j(t,e=[]){if(Array.isArray(t))return t;if(!u(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Me(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function fo(){return new URLSearchParams(window.location.search)}function go(){const t=fo(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function $o(){return{...go(),"Content-Type":"application/json"}}const dl=15e3,Xa=3e4,ul=6e4,Ci=new Set([408,425,429,500,502,503,504]);class Pn extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);fe(this,"method");fe(this,"path");fe(this,"status");fe(this,"statusText");fe(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function Za(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const l=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Pn({method:l,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function pl(){var e,n;const t=fo();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function X(t){const e=await Za(t,{headers:go()},dl);if(!e.ok)throw new Pn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function ml(t){return new Promise(e=>setTimeout(e,t))}function vl(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function _l(t){if(t instanceof Pn)return t.timeout||typeof t.status=="number"&&Ci.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=vl(t.message);return e!==null&&Ci.has(e)}async function ho(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!_l(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${o}ms`,a),await ml(o),s+=1}}async function Rt(t,e,n,s=Xa){const a=await Za(t,{method:"POST",headers:{...$o(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Pn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function fl(t,e,n,s=Xa){const a=await Za(t,{method:"POST",headers:{...$o(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Pn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function gl(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function $l(t){var e,n,s,a,o,l,d;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const v=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(v)}return((d=(l=(o=t.result)==null?void 0:o.content)==null?void 0:l[0])==null?void 0:d.text)??""}async function Qt(t,e){const n=await fl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},ul),s=gl(n);return $l(s)}function hl(){return X("/api/v1/dashboard/shell")}function yl(){return X("/api/v1/dashboard/execution")}function bl(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),X(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function kl(){return X("/api/v1/dashboard/governance")}function xl(){return X("/api/v1/dashboard/semantics")}function Sl(){return X("/api/v1/dashboard/mission")}function Cl(t=!1){return X(`/api/v1/dashboard/mission/briefing${t?"?force=1":""}`)}function Al(){return X("/api/v1/dashboard/planning")}function wl(){return X("/api/v1/operator")}function yo(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return X(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Tl(){return X("/api/v1/command-plane")}function Il(){return X("/api/v1/command-plane/summary")}function Rl(){return X("/api/v1/chains/summary")}function Pl(t){return X(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Nl(){return X("/api/v1/command-plane/help")}function Ll(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return X(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function Ml(t,e){return Rt(t,e)}function Dl(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return Xa}}function Hs(t){return Rt("/api/v1/operator/action",t,void 0,Dl(t))}function zl(t,e){return Rt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function Ze(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function El(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function jl(t){if(!u(t))return null;const e=y(t.id,"").trim(),n=y(t.author,"").trim(),s=y(t.content,"").trim();if(!e||!n)return null;const a=H(t.score,0),o=H(t.votes_up,0),l=H(t.votes_down,0),d=H(t.votes,a||o-l),v=H(t.comment_count,H(t.reply_count,0)),_=(()=>{const x=t.flair;if(typeof x=="string"&&x.trim())return x.trim();if(u(x)){const w=y(x.name,"").trim();if(w)return w}return y(t.flair_name,"").trim()||void 0})(),p=y(t.created_at_iso,"").trim()||Ze(t.created_at),m=y(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Ze(t.updated_at):p),h=y(t.title,"").trim()||El(s),k=Array.isArray(t.tags)?t.tags.filter(x=>typeof x=="string"&&x.trim()!==""):[];return{id:e,author:n,title:h,content:s,tags:k,votes:d,vote_balance:a,comment_count:v,created_at:p,updated_at:m,flair:_,hearth:y(t.hearth,"").trim()||null,visibility:y(t.visibility,"").trim()||void 0,expires_at:y(t.expires_at_iso,"").trim()||(t.expires_at!==void 0&&t.expires_at!==0?Ze(t.expires_at):"")||null,hearth_count:H(t.hearth_count,0)}}function Ol(t){if(!u(t))return null;const e=y(t.id,"").trim(),n=y(t.post_id,"").trim(),s=y(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:y(t.content,""),created_at:Ze(t.created_at)}}async function Fl(t){return ho("fetchBoardPost",async()=>{const e=await X(`/api/v1/board/${t}?format=flat`),n=u(e.post)?e.post:e,s=jl(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},o=(Array.isArray(e.comments)?e.comments:[]).map(Ol).filter(l=>l!==null);return{...s,comments:o}})}function bo(t,e){return Rt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:pl()})}function ql(t,e,n){return Rt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Kl(t){const e=y(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function st(...t){for(const e of t){const n=y(e,"");if(n.trim())return n.trim()}return""}function Ai(t){const e=Kl(st(t.outcome,t.result,t.result_code));if(!e)return;const n=st(t.reason,t.reason_code,t.description,t.detail),s=st(t.summary,t.summary_ko,t.summary_en,t.note),a=st(t.details,t.details_text,t.text,t.note),o=st(t.winner,t.winner_name,t.actor_winner,t.winner_actor),l=st(t.winner_actor_id,t.winner_actor,t.actor_winner_id),d=st(t.raw_reason,t.raw_reason_code,t.error_message),v=(()=>{const m=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof m=="string"?[m]:Array.isArray(m)?m.map(f=>{if(typeof f=="string")return f.trim();if(u(f)){const h=y(f.summary,"").trim();if(h)return h;const k=y(f.text,"").trim();if(k)return k;const x=y(f.type,"").trim();return x||y(f.event_id,"").trim()}return""}).filter(f=>f.length>0):[]})(),_=(()=>{const m=H(t.turn,Number.NaN);if(Number.isFinite(m))return m;const f=H(t.turn_number,Number.NaN);if(Number.isFinite(f))return f;const h=H(t.current_turn,Number.NaN);if(Number.isFinite(h))return h;const k=H(t.round,Number.NaN);return Number.isFinite(k)?k:void 0})(),p=st(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:l||void 0,evidence:v.length>0?v:void 0,raw_reason:d||void 0,turn:_,phase:p||void 0}}function Ul(t,e){const n=u(t.state)?t.state:{};if(y(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(l=>u(l)?y(l.type,"")==="session.outcome":!1),o=u(n.session_outcome)?n.session_outcome:{};if(u(o)&&Object.keys(o).length>0){const l=Ai(o);if(l)return l}if(u(a))return Ai(u(a.payload)?a.payload:{})}function y(t,e=""){return typeof t=="string"?t:e}function H(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Hl(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Pa(t,e=!1){return typeof t=="boolean"?t:e}function Be(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(u(e)){const n=y(e.name,"").trim(),s=y(e.id,"").trim(),a=y(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Wl(t){const e={};if(!u(t)&&!Array.isArray(t))return e;if(u(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),o=y(s,"").trim();!a||!o||(e[a]=o)}),e;for(const n of t){if(!u(n))continue;const s=st(n.to,n.target,n.actor_id,n.name,n.id),a=st(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function Bl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function dt(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const Gl=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Jl(t){const e=u(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const o=s.trim();o&&(Gl.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function Vl(t,e){if(t!=="dice.rolled")return;const n=H(e.raw_d20,0),s=H(e.total,0),a=H(e.bonus,0),o=y(e.action,"roll"),l=H(e.dc,0);return{notation:l>0?`${o} (DC ${l})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function Yl(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Ql(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Xl(t,e,n,s){const a=n||e||y(s.actor_id,"")||y(s.actor_name,"");switch(t){case"turn.action.proposed":{const o=y(s.proposed_action,y(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=y(s.reply,y(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return y(s.reply,y(s.content,y(s.text,"Narration")));case"dice.rolled":{const o=y(s.action,"roll"),l=H(s.total,0),d=H(s.dc,0),v=y(s.label,""),_=a||"actor",p=d>0?` vs DC ${d}`:"",m=v?` (${v})`:"";return`${_} ${o}: ${l}${p}${m}`}case"turn.started":return`Turn ${H(s.turn,1)} started`;case"phase.changed":return`Phase: ${y(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${y(s.name,u(s.actor)?y(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${y(s.keeper_name,y(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${y(s.keeper_name,y(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${H(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${H(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||y(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||y(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${y(s.reason_code,"unknown")}`;case"memory.signal":{const o=u(s.entity_refs)?s.entity_refs:{},l=y(o.requested_tier,""),d=y(o.effective_tier,""),v=Pa(o.guardrail_applied,!1),_=y(s.summary_en,y(s.summary_ko,"Memory signal"));if(!l&&!d)return _;const p=l&&d?`${l}->${d}`:d||l;return`${_} [${p}${v?" (guardrail)":""}]`}case"world.event":{if(y(s.event_type,"")==="canon.check"){const l=y(s.status,"unknown"),d=y(s.contract_id,"n/a");return`Canon ${l}: ${d}`}return y(s.description,y(s.summary,"World event"))}case"combat.attack":return y(s.summary,y(s.result,"Attack resolved"));case"combat.defense":return y(s.summary,y(s.result,"Defense resolved"));case"session.outcome":return y(s.summary,y(s.outcome,"Session ended"));default:{const o=Yl(s);return o?`${t}: ${o}`:t}}}function Zl(t,e){const n=u(t)?t:{},s=y(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=y(n.actor_name,"").trim()||e[a]||y(u(n.payload)?n.payload.actor_name:"",""),l=u(n.payload)?n.payload:{},d=y(n.ts,y(n.timestamp,new Date().toISOString())),v=y(n.phase,y(l.phase,"")),_=y(n.category,"");return{type:s,actor:o||a||y(l.actor_name,""),actor_id:a||y(l.actor_id,""),actor_name:o,seq:n.seq,room_id:y(n.room_id,""),phase:v||void 0,category:_||Ql(s),visibility:y(n.visibility,y(l.visibility,"public")),event_id:y(n.event_id,""),content:Xl(s,a,o,l),dice_roll:Vl(s,l),timestamp:d}}function tc(t,e,n){var E,J;const s=y(t.room_id,"")||n||"default",a=u(t.state)?t.state:{},o=u(a.party)?a.party:{},l=u(a.actor_control)?a.actor_control:{},d=u(a.join_gate)?a.join_gate:{},v=u(a.contribution_ledger)?a.contribution_ledger:{},_=Object.entries(o).map(([F,Y])=>{const b=u(Y)?Y:{},$t=dt(b,"max_hp",void 0,10),Ot=dt(b,"hp",void 0,$t),te=dt(b,"max_mp",void 0,0),ee=dt(b,"mp",void 0,0),M=dt(b,"level",void 0,1),ht=dt(b,"xp",void 0,0),ne=Pa(b.alive,Ot>0),He=l[F],We=typeof He=="string"?He:void 0,On=Bl(b.role,F,We),Fn=Hl(b.generation),qn=st(b.joined_at,b.joinedAt,b.started_at,b.startedAt),Kn=st(b.claimed_at,b.claimedAt,b.assigned_at,b.assignedAt,b.assigned_time),O=st(b.last_seen,b.lastSeen,b.last_seen_at,b.lastSeenAt,b.last_active,b.lastActive),_e=st(b.scene,b.current_scene,b.currentScene,b.world_scene,b.scene_name,b.sceneName),Hr=st(b.location,b.current_location,b.currentLocation,b.position,b.zone,b.area);return{id:F,name:y(b.name,F),role:On,keeper:We,archetype:y(b.archetype,""),persona:y(b.persona,""),portrait:y(b.portrait,"")||void 0,background:y(b.background,"")||void 0,traits:Be(b.traits),skills:Be(b.skills),stats_raw:Jl(b),status:ne?"active":"dead",generation:Fn,joined_at:qn||void 0,claimed_at:Kn||void 0,last_seen:O||void 0,scene:_e||void 0,location:Hr||void 0,inventory:Be(b.inventory),notes:Be(b.notes),relationships:Wl(b.relationships),stats:{hp:Ot,max_hp:$t,mp:ee,max_mp:te,level:M,xp:ht,strength:dt(b,"strength","str",10),dexterity:dt(b,"dexterity","dex",10),constitution:dt(b,"constitution","con",10),intelligence:dt(b,"intelligence","int",10),wisdom:dt(b,"wisdom","wis",10),charisma:dt(b,"charisma","cha",10)}}}),p=_.filter(F=>F.status!=="dead"),m=Ul(t,e),f={phase_open:Pa(d.phase_open,!0),min_points:H(d.min_points,3),window:y(d.window,"round_boundary_only"),last_opened_turn:typeof d.last_opened_turn=="number"?d.last_opened_turn:null,last_closed_turn:typeof d.last_closed_turn=="number"?d.last_closed_turn:null},h=Object.entries(v).map(([F,Y])=>{const b=u(Y)?Y:{};return{actor_id:F,score:H(b.score,0),last_reason:y(b.last_reason,"")||null,reasons:Be(b.reasons)}}),k=_.reduce((F,Y)=>(F[Y.id]=Y.name,F),{}),x=e.map(F=>Zl(F,k)),C=H(a.turn,1),w=y(a.phase,"round"),A=y(a.map,""),S=u(a.world)?a.world:{},I=A||y(S.ascii_map,y(S.map,"")),R=x.filter((F,Y)=>{const b=e[Y];if(!u(b))return!1;const $t=u(b.payload)?b.payload:{};return H($t.turn,-1)===C}),W=(R.length>0?R:x).slice(-12),U=y(a.status,"active");return{session:{id:s,room:s,status:U==="ended"?"ended":U==="paused"?"paused":"active",round:C,actors:p,created_at:((E=x[0])==null?void 0:E.timestamp)??new Date().toISOString()},current_round:{round_number:C,phase:w,events:W,timestamp:((J=x[x.length-1])==null?void 0:J.timestamp)??new Date().toISOString()},map:I||void 0,join_gate:f,contribution_ledger:h,outcome:m,party:p,story_log:x,history:[]}}async function ec(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await X(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function nc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([X(`/api/v1/trpg/state${e}`),ec(t)]);return tc(n,s,t)}function sc(t){return Rt("/api/v1/trpg/rounds/run",{room_id:t})}function ac(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function ic(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Rt("/api/v1/trpg/dice/roll",e)}function oc(t,e){const n=ac();return Rt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function rc(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Rt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function lc(t,e,n){return Rt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function cc(t,e,n){const s=await Qt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function dc(t){const e=await Qt("trpg.mid_join.request",t);return JSON.parse(e)}async function uc(t,e){await Qt("masc_broadcast",{agent_name:t,message:e})}async function pc(t=40){return(await Qt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function mc(t,e=20){return Qt("masc_task_history",{task_id:t,limit:e})}async function vc(t){const e=await Qt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function _c(t){return ho("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await X(`/api/v1/council/debates/${e}/summary`);if(!u(n))return null;const s=y(n.id,"").trim();return s?{id:s,topic:y(n.topic,""),status:y(n.status,"open"),support_count:H(n.support_count,0),oppose_count:H(n.oppose_count,0),neutral_count:H(n.neutral_count,0),total_arguments:H(n.total_arguments,0),created_at:Ze(n.created_at_iso??n.created_at),summary_text:y(n.summary_text,"")}:null})}function fc(t,e,n){return Qt("masc_keeper_msg",{name:t,message:e})}const gc=g(""),Dt=g({}),at=g({}),Na=g({}),La=g({}),Ma=g({}),Da=g({}),zt=g({});function nt(t,e,n){t.value={...t.value,[e]:n}}function $c(t){var n;const e=(n=r(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function hc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Xs(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!u(s))continue;const a=r(s.name);if(!a)continue;const o=r(s[e]);e==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function yc(t){if(!u(t))return null;const e=r(t.name);return e?{name:e,trigger:r(t.trigger),outcome:r(t.outcome),summary:r(t.summary),reason:r(t.reason)}:null}function bc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function kc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function ko(t,e,n){return r(t)??kc(e,n)}function xo(t,e){return typeof t=="boolean"?t:e==="recover"}function vs(t){if(!u(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:r(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:Me(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:c(t.next_eligible_at_s)??null,recoverable:xo(t.recoverable,n),summary:ko(t.summary,e,r(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function So(t){return u(t)?{hour:c(t.hour),checked:c(t.checked)??0,acted:c(t.acted)??0,acted_names:K(t.acted_names),activity_report:r(t.activity_report),quiet_hours_overridden:z(t.quiet_hours_overridden),skipped_reason:r(t.skipped_reason),acted_rows:Xs(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:Xs(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:Xs(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(yc).filter(e=>e!==null):[]}:null}function xc(t){return u(t)?{enabled:z(t.enabled)??!1,interval_s:c(t.interval_s)??0,quiet_start:c(t.quiet_start),quiet_end:c(t.quiet_end),quiet_active:z(t.quiet_active),use_planner:z(t.use_planner),delegate_llm:z(t.delegate_llm),agent_count:c(t.agent_count),agents:K(t.agents),last_tick_ago_s:c(t.last_tick_ago_s)??null,last_tick_ago:r(t.last_tick_ago),total_ticks:c(t.total_ticks),total_checkins:c(t.total_checkins),last_skip_reason:r(t.last_skip_reason)??null,last_tick_result:So(t.last_tick_result),active_self_heartbeats:K(t.active_self_heartbeats)}:null}function Sc(t){return u(t)?{status:t.status,diagnostic:vs(t.diagnostic)}:null}function Cc(t){return u(t)?{recovered:z(t.recovered)??!1,skipped_reason:r(t.skipped_reason)??null,before:vs(t.before),after:vs(t.after),down:t.down,up:t.up}:null}function Ac(t,e){var A,S;if(!(t!=null&&t.name))return null;const n=r((A=t.agent)==null?void 0:A.status)??r(t.status)??"unknown",s=r((S=t.agent)==null?void 0:S.error)??null,a=t.presence_keepalive??!0,o=t.keepalive_running??!1,l=t.turn_count??0,d=t.last_turn_ago_s??null,v=t.proactive_enabled??!1,_=t.proactive_cooldown_sec??0,p=t.last_proactive_ago_s??null,m=v&&p!=null?Math.max(0,_-p):null,f=l<=0||d==null?"never":d>900?"stale":"fresh",h=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,k=s??(a&&!o?"keeper keepalive is not running":null),x=n==="offline"||n==="inactive"?"offline":k?"degraded":f==="stale"?"stale":f==="never"?"idle":"healthy",C=k?bc(k):e!=null&&e.quiet_active&&f!=="fresh"?"quiet_hours":a&&!o?"disabled":l<=0?"never_started":m!=null&&m>0?"min_gap":f==="fresh"||f==="stale"?"no_recent_activity":"unknown",w=x==="offline"||x==="degraded"||x==="stale"?"recover":C==="quiet_hours"?"manual_lodge_poke":C==="unknown"?"probe":"direct_message";return{health_state:x,quiet_reason:C,next_action_path:w,last_reply_status:f,last_reply_at:h,last_reply_preview:null,last_error:k,next_eligible_at_s:m!=null&&m>0?m:null,recoverable:xo(void 0,w),summary:ko(void 0,x,C),keepalive_running:o}}function wc(t,e){if(!u(t))return null;const n=$c(t.role),s=r(t.content)??r(t.preview);if(!s)return null;const a=Me(t.ts_unix)??Me(t.timestamp);return{id:`${n}-${a??"entry"}-${e}`,role:n,label:hc(n),text:s,timestamp:a,delivery:"history"}}function Tc(t,e,n){const s=u(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,l)=>wc(o,l)).filter(o=>o!==null):[];return{name:t,diagnostic:vs(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function wi(t,e){const n=at.value[t]??[];at.value={...at.value,[t]:[...n,e].slice(-50)}}function Ic(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Rc(t,e){const s=(at.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(o=>Ic(a,o)));at.value={...at.value,[t]:[...e,...s].slice(-50)}}function Ws(t,e){Dt.value={...Dt.value,[t]:e},Rc(t,e.history)}function Ti(t,e){const n=Dt.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Ws(t,{...n,diagnostic:{...s,...e}})}async function ti(){try{await Nn()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Pc(t){gc.value=t.trim()}async function Co(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Dt.value[n])return Dt.value[n];nt(Na,n,!0),nt(zt,n,null);try{const s=await Qt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=Tc(n,s,a);return Ws(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return nt(zt,n,a),null}finally{nt(Na,n,!1)}}async function Nc(t,e){const n=t.trim(),s=e.trim();if(!n||!s)return;const a=`local-${Date.now()}`;wi(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),nt(La,n,!0),nt(zt,n,null);try{const o=await fc(n,s);at.value={...at.value,[n]:(at.value[n]??[]).map(l=>l.id===a?{...l,delivery:"delivered"}:l)},wi(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Ti(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await ti()}catch(o){const l=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw at.value={...at.value,[n]:(at.value[n]??[]).map(d=>d.id===a?{...d,delivery:"error",error:l}:d)},Ti(n,{last_reply_status:"error",last_error:l}),nt(zt,n,l),o}finally{nt(La,n,!1)}}async function Lc(t,e){const n=t.trim();if(!n)return null;nt(Ma,n,!0),nt(zt,n,null);try{const s=await Hs({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=Sc(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const l=Dt.value[n];Ws(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??at.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ti(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw nt(zt,n,a),s}finally{nt(Ma,n,!1)}}async function Mc(t,e){const n=t.trim();if(!n)return null;nt(Da,n,!0),nt(zt,n,null);try{const s=await Hs({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Cc(s.result),o=(a==null?void 0:a.after)??null;if(o){const l=Dt.value[n];Ws(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??at.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ti(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw nt(zt,n,a),s}finally{nt(Da,n,!1)}}function se(t){return(t??"").trim().toLowerCase()}function lt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ns(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Un(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ge(t){return t.last_heartbeat??Un(t.last_turn_ago_s)??Un(t.last_proactive_ago_s)??Un(t.last_handoff_ago_s)??Un(t.last_compaction_ago_s)}function Dc(t){const e=t.title.trim();return e||ns(t.content)}function zc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Ec(t,e,n,s,a={}){var S;const o=se(t),l=e.filter(I=>se(I.assignee)===o&&(I.status==="claimed"||I.status==="in_progress")).length,d=n.filter(I=>se(I.from)===o).sort((I,R)=>lt(R.timestamp)-lt(I.timestamp))[0],v=s.filter(I=>se(I.agent)===o||se(I.author)===o).sort((I,R)=>lt(R.timestamp)-lt(I.timestamp))[0],_=(a.boardPosts??[]).filter(I=>se(I.author)===o).sort((I,R)=>lt(R.updated_at||R.created_at)-lt(I.updated_at||I.created_at))[0],p=(a.keepers??[]).filter(I=>se(I.name)===o&&Ge(I)!==null).sort((I,R)=>lt(Ge(R)??0)-lt(Ge(I)??0))[0],m=d?lt(d.timestamp):0,f=v?lt(v.timestamp):0,h=_?lt(_.updated_at||_.created_at):0,k=p?lt(Ge(p)??0):0,x=a.lastSeen?lt(a.lastSeen):0,C=((S=a.currentTask)==null?void 0:S.trim())||(l>0?`${l} claimed tasks`:null);if(m===0&&f===0&&h===0&&k===0&&x===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:C};const A=[d?{timestamp:d.timestamp,ts:m,text:ns(d.content)}:null,_?{timestamp:_.updated_at||_.created_at,ts:h,text:`Post: ${ns(Dc(_))}`}:null,p?{timestamp:Ge(p),ts:k,text:zc(p)}:null,v?{timestamp:new Date(v.timestamp).toISOString(),ts:f,text:ns(v.text)}:null].filter(I=>I!==null).sort((I,R)=>R.ts-I.ts)[0];return A&&A.ts>=x?{activeAssignedCount:l,lastActivityAt:A.timestamp,lastActivityText:A.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:C??"Presence heartbeat"}}const gt=g([]),Ct=g([]),De=g([]),jt=g([]),pt=g(null),jc=g(null),za=g(new Map),un=g([]),pn=g("recent"),be=g(!0),Ao=g(null),Mt=g(""),Ae=g([]),tn=g(!1),wo=g(new Map),ei=g("unknown"),we=g(null),Ea=g(!1),mn=g(!1),ja=g(!1),en=g(!1),ni=g(null),_s=g(!1),fs=g(null),To=g(null),Oa=g(null),Oc=g(null),Fc=g(null),qc=g(null);ft(()=>gt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const Io=ft(()=>{const t=Ct.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),si=ft(()=>{const t=new Map,e=Ct.value,n=De.value,s=ms.value,a=un.value,o=jt.value;for(const l of gt.value)t.set(l.name.trim().toLowerCase(),Ec(l.name,e,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:o}));return t});function Kc(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const Uc=ft(()=>{const t=new Map;for(const e of jt.value)t.set(e.name,Kc(e));return t}),Hc=12e4;function Wc(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}const Bc=ft(()=>{const t=Date.now(),e=new Set,n=za.value;for(const s of jt.value){const a=Wc(s,n);a!=null&&t-a>Hc&&e.add(s.name)}return e});let Zs=null;function Gc(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function Ro(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Jc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Vc(t){if(!u(t))return null;const e=r(t.name);return e?{name:e,agent_type:r(t.agent_type),status:Ro(t.status),current_task:r(t.current_task)??null,joined_at:r(t.joined_at),last_seen:r(t.last_seen),capabilities:K(t.capabilities),emoji:r(t.emoji),koreanName:r(t.koreanName)??r(t.korean_name),model:r(t.model),traits:K(t.traits),interests:K(t.interests),activityLevel:c(t.activityLevel)??c(t.activity_level),primaryValue:r(t.primaryValue)??r(t.primary_value)}:null}function Yc(t){if(!u(t))return null;const e=r(t.id),n=r(t.title);return!e||!n?null:{id:e,title:n,status:Jc(t.status),priority:c(t.priority),assignee:r(t.assignee),description:r(t.description),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function Qc(t){if(!u(t))return null;const e=r(t.from)??r(t.from_agent)??"system",n=r(t.content)??"",s=r(t.timestamp)??new Date().toISOString();return{id:r(t.id),seq:c(t.seq),from:e,content:n,timestamp:s,type:r(t.type)}}function Ii(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function Xc(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>Ii(s)-Ii(a)).slice(-500)}function Zc(t){return Array.isArray(t)?t.map(e=>{if(!u(e))return null;const n=c(e.ts_unix);if(n==null)return null;const s=u(e.handoff)?e.handoff:null;return{ts:n,context_ratio:c(e.context_ratio)??0,context_tokens:c(e.context_tokens)??0,context_max:c(e.context_max)??0,latency_ms:c(e.latency_ms)??0,generation:c(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:c(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:c(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?c(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Ri(t){if(!u(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);if(!e||!n||!s)return null;const a=r(t.quiet_reason)??null,o=r(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:Me(t.last_reply_at)??r(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:c(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function td(t,e){return(Array.isArray(t)?t:u(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!u(s))return null;const a=u(s.agent)?s.agent:null,o=u(s.context)?s.context:null,l=u(s.metrics_window)?s.metrics_window:void 0,d=r(s.name);if(!d)return null;const v=c(s.context_ratio)??c(o==null?void 0:o.context_ratio),_=r(s.status)??r(a==null?void 0:a.status)??"offline",p=Ro(_),m=r(s.model)??r(s.active_model)??r(s.primary_model),f=K(s.skill_secondary),h=o?{source:r(o.source),context_ratio:c(o.context_ratio),context_tokens:c(o.context_tokens),context_max:c(o.context_max),message_count:c(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,k=a?{name:r(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:r(a.error),agent_type:r(a.agent_type),status:r(a.status),current_task:r(a.current_task)??null,joined_at:r(a.joined_at),last_seen:r(a.last_seen),last_seen_ago_s:c(a.last_seen_ago_s),capabilities:K(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,x=Zc(s.metrics_series),C={name:d,emoji:r(s.emoji),koreanName:r(s.koreanName)??r(s.korean_name),agent_name:r(s.agent_name),trace_id:r(s.trace_id),model:m,primary_model:r(s.primary_model),active_model:r(s.active_model),next_model_hint:r(s.next_model_hint)??null,status:p,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:c(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:c(s.proactive_idle_sec),proactive_cooldown_sec:c(s.proactive_cooldown_sec),last_heartbeat:r(s.last_heartbeat)??r(a==null?void 0:a.last_seen),generation:c(s.generation),turn_count:c(s.turn_count)??c(s.total_turns),keeper_age_s:c(s.keeper_age_s),last_turn_ago_s:c(s.last_turn_ago_s),last_handoff_ago_s:c(s.last_handoff_ago_s),last_compaction_ago_s:c(s.last_compaction_ago_s),last_proactive_ago_s:c(s.last_proactive_ago_s),last_proactive_preview:r(s.last_proactive_preview)??null,context_ratio:v,context_tokens:c(s.context_tokens)??c(o==null?void 0:o.context_tokens),context_max:c(s.context_max)??c(o==null?void 0:o.context_max),context_source:r(s.context_source)??r(o==null?void 0:o.source),context:h,traits:K(s.traits),interests:K(s.interests),primaryValue:r(s.primaryValue)??r(s.primary_value),activityLevel:c(s.activityLevel)??c(s.activity_level),memory_recent_note:r(s.memory_recent_note)??null,recent_input_preview:r(s.recent_input_preview)??null,recent_output_preview:r(s.recent_output_preview)??null,recent_tool_names:K(s.recent_tool_names)??[],conversation_tail_count:c(s.conversation_tail_count),k2k_count:c(s.k2k_count),handoff_count_total:c(s.handoff_count_total)??c(s.trace_history_count),compaction_count:c(s.compaction_count),last_compaction_saved_tokens:c(s.last_compaction_saved_tokens),diagnostic:Ri(s.diagnostic),skill_primary:r(s.skill_primary)??null,skill_secondary:f,skill_reason:r(s.skill_reason)??null,metrics_series:x.length>0?x:void 0,metrics_window:l,agent:k};return C.diagnostic=Ri(s.diagnostic)??Ac(C,(e==null?void 0:e.lodge)??null),C}).filter(s=>s!==null)}function Po(t){return u(t)?{...t,lodge:xc(t.lodge)??void 0}:null}function ed(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function nd(t){if(!u(t))return null;const e=c(t.iteration);if(e==null)return null;const n=c(t.metric_before)??0,s=c(t.metric_after)??n,a=u(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:c(t.delta)??s-n,changes:r(t.changes)??"",failed_attempts:r(t.failed_attempts)??"",next_suggestion:r(t.next_suggestion)??"",elapsed_ms:c(t.elapsed_ms)??0,cost_usd:c(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:c(a.tool_call_count)??0,tool_names:K(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function sd(t){var o,l;if(!u(t))return null;const e=r(t.loop_id);if(!e)return null;const n=c(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(nd).filter(d=>d!==null):[],a=c(t.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:r(t.profile)??"unknown",status:ed(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:r(t.error_message)??r(t.error_reason)??null,stop_reason:r(t.stop_reason)??r(t.reason)??null,current_iteration:c(t.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:c(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(t.target)??"",stagnation_streak:c(t.stagnation_streak)??0,stagnation_limit:c(t.stagnation_limit)??0,elapsed_seconds:c(t.elapsed_seconds)??0,updated_at:Me(t.updated_at)??null,stopped_at:Me(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:c(t.latest_tool_call_count)??0,latest_tool_names:K(t.latest_tool_names)??[],session_id:r(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function Nn(){Ea.value=!0;try{await Promise.all([Lo(),Lt()]),To.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{Ea.value=!1}}async function No(){_s.value=!0,fs.value=null;try{const t=await xl();ni.value=t,qc.value=new Date().toISOString()}catch(t){fs.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{_s.value=!1}}function ad(t){var e;return((e=ni.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function id(t){var n;const e=((n=ni.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(o=>o.id===t);if(a)return a}return null}function od(t){var s,a;Ae.value=(Array.isArray(t.goals)?t.goals:[]).map(o=>{if(!u(o))return null;const l=r(o.id),d=r(o.title),v=r(o.horizon),_=r(o.status),p=r(o.created_at),m=r(o.updated_at);return!l||!d||!v||!_||!p||!m?null:{id:l,horizon:v,title:d,metric:r(o.metric)??null,target_value:r(o.target_value)??null,due_date:r(o.due_date)??null,priority:c(o.priority)??3,status:_,parent_goal_id:r(o.parent_goal_id)??null,last_review_note:r(o.last_review_note)??null,last_review_at:r(o.last_review_at)??null,created_at:p,updated_at:m}}).filter(o=>o!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const o of n){const l=sd(o);l&&e.set(l.loop_id,l)}wo.value=e,we.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,ei.value=we.value?"error":e.size===0?"idle":"ready"}async function Lo(){try{const t=await hl(),e=Po(t.status);e&&(pt.value=e)}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Lt(){var t;try{const e=await yl(),n=Po(e.status),s=(t=pt.value)==null?void 0:t.room;n&&(pt.value=n);const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;gt.value=(Array.isArray(e.agents)?e.agents:[]).map(Vc).filter(l=>l!==null),Ct.value=(Array.isArray(e.tasks)?e.tasks:[]).map(Yc).filter(l=>l!==null);const o=(Array.isArray(e.messages)?e.messages:[]).map(Qc).filter(l=>l!==null);De.value=a?o:Xc(De.value,o),jt.value=td(e.keepers,n??pt.value),jc.value=null,To.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function At(){mn.value=!0;try{const t=await bl(pn.value,{excludeSystem:be.value});un.value=t.posts??[],Oa.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{mn.value=!1}}async function wt(){var t;ja.value=!0;try{const e=Mt.value||((t=pt.value)==null?void 0:t.room)||"default";Mt.value||(Mt.value=e);const n=await nc(e);Ao.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{ja.value=!1}}async function vn(){tn.value=!0,en.value=!0;try{const t=await Al();od(t),Oc.value=new Date().toISOString(),Fc.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),ei.value="error",we.value=t instanceof Error?t.message:String(t)}finally{tn.value=!1,en.value=!1}}async function Mo(){return vn()}let ss=null;function rd(t){ss=t}let as=null;function ld(t){as=t}let is=null;function cd(t){is=t}const re={};function ae(t,e,n=500){re[t]&&clearTimeout(re[t]),re[t]=setTimeout(()=>{e(),delete re[t]},n)}function dd(){const t=mo.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(za.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),za.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&ae("execution",Lt),Gc(e.type)&&(Zs||(Zs=setTimeout(()=>{Nn(),as==null||as(),is==null||is(),Zs=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&ae("execution",Lt),e.type==="broadcast"&&ae("execution",Lt),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&ae("execution",Lt),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&ae("board",At),e.type.startsWith("decision_")&&ae("council",()=>ss==null?void 0:ss()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&ae("mdal",Mo,350)}});return()=>{t();for(const e of Object.keys(re))clearTimeout(re[e]),delete re[e]}}let nn=null;function ud(){nn||(nn=setInterval(()=>{Vt.value,Nn()},1e4))}function pd(){nn&&(clearInterval(nn),nn=null)}function md({metric:t}){return i`
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
  `}function vd({panel:t}){return i`
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
            ${t.metrics.map(e=>i`<${md} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function L({panelId:t,compact:e=!1,label:n="Why"}){const s=id(t);return s?i`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${vd} panel=${s} />
    </details>
  `:_s.value?i`<span class="semantic-inline-state">Loading semantics…</span>`:null}function mt({surfaceId:t,compact:e=!1}){const n=ad(t);return n?i`
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
  `:_s.value?i`<div class="semantic-surface-card ${e?"compact":""}">Loading semantics…</div>`:fs.value?i`<div class="semantic-surface-card ${e?"compact":""}">${fs.value}</div>`:null}function T({title:t,class:e,semanticId:n,children:s}){return i`
    <div class="card ${e??""}">
      ${t?i`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?i`<${L} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${s}
    </div>
  `}function ai(t){const e=t.indexOf("-");if(e<0)return{model:t,nickname:t,isKeeper:t==="keeper"};const n=t.slice(0,e),s=t.slice(e+1);return{model:n,nickname:s,isKeeper:n==="keeper"}}function _d(t){return t==="keeper"||t.startsWith("keeper-")}const ii=g(null),Fa=g(!1),gs=g(null),Do=g(null),ke=g(!1),oe=g(null);let Te=null;function Pi(){Te!==null&&(window.clearTimeout(Te),Te=null)}function fd(t=1500){Te===null&&(Te=window.setTimeout(()=>{Te=null,_n(!1)},t))}function qe(t){if(!u(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function pe(t){if(!u(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:z(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function gd(t){if(!u(t))return null;const e=r(t.session_id);return e?{session_id:e,goal:r(t.goal),status:r(t.status),health:r(t.health),scale_profile:r(t.scale_profile),control_profile:r(t.control_profile),planned_worker_count:c(t.planned_worker_count),active_agent_count:c(t.active_agent_count),last_turn_age_sec:c(t.last_turn_age_sec)??null,attention_count:c(t.attention_count),recommended_action_count:c(t.recommended_action_count),top_attention:qe(t.top_attention),top_recommendation:pe(t.top_recommendation)}:null}function $d(t){if(!u(t))return null;const e=r(t.session_id);if(!e)return null;const n=u(t.status)?t.status:t,s=u(n.summary)?n.summary:void 0;return{session_id:e,status:r(t.status)??r(s==null?void 0:s.status)??(u(n.session)?r(n.session.status):void 0),progress_pct:c(t.progress_pct)??c(s==null?void 0:s.progress_pct),elapsed_sec:c(t.elapsed_sec)??c(s==null?void 0:s.elapsed_sec),remaining_sec:c(t.remaining_sec)??c(s==null?void 0:s.remaining_sec),done_delta_total:c(t.done_delta_total)??c(s==null?void 0:s.done_delta_total),summary:u(t.summary)?t.summary:s,team_health:u(t.team_health)?t.team_health:u(n.team_health)?n.team_health:void 0,communication_metrics:u(t.communication_metrics)?t.communication_metrics:u(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:u(t.orchestration_state)?t.orchestration_state:u(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:u(t.cascade_metrics)?t.cascade_metrics:u(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:u(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,o])=>{const l=r(o);return l?[a,l]:null}).filter(a=>a!==null)):u(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const l=r(o);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:u(t.session)?t.session:u(n.session)?n.session:void 0,recent_events:j(t.recent_events,["events"]).filter(u)}}function hd(t){if(!u(t))return null;const e=r(t.name);return e?{name:e,agent_name:r(t.agent_name),status:r(t.status),autonomy_level:r(t.autonomy_level),context_ratio:c(t.context_ratio),generation:c(t.generation),active_goal_ids:j(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:r(t.last_autonomous_action_at)??null,last_turn_ago_s:c(t.last_turn_ago_s),model:r(t.model)}:null}function yd(t){if(!u(t))return null;const e=r(t.confirm_token)??r(t.token);return e?{confirm_token:e,actor:r(t.actor),action_type:r(t.action_type),target_type:r(t.target_type),target_id:r(t.target_id)??null,delegated_tool:r(t.delegated_tool),created_at:r(t.created_at),preview:t.preview}:null}function bd(t){if(!u(t))return null;const e=r(t.action_type),n=r(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:r(t.description),confirm_required:z(t.confirm_required)}}function kd(t){const e=u(t)?t:{};return{room_health:r(e.room_health),cluster:r(e.cluster),project:r(e.project),current_room:r(e.current_room)??null,paused:z(e.paused),tempo_interval_s:c(e.tempo_interval_s),active_agents:c(e.active_agents),keeper_pressure:c(e.keeper_pressure),active_operations:c(e.active_operations),pending_approvals:c(e.pending_approvals),incident_count:c(e.incident_count),recommended_action_count:c(e.recommended_action_count),top_attention:qe(e.top_attention),top_action:pe(e.top_action)}}function xd(t){const e=u(t)?t:{},n=u(e.swarm_overview)?e.swarm_overview:{};return{health:r(e.health),active_operations:c(e.active_operations),pending_approvals:c(e.pending_approvals),swarm_overview:{active_lanes:c(n.active_lanes),moving_lanes:c(n.moving_lanes),stalled_lanes:c(n.stalled_lanes),projected_lanes:c(n.projected_lanes),last_movement_at:r(n.last_movement_at)??null},top_attention:qe(e.top_attention),top_action:pe(e.top_action),session_cards:j(e.session_cards).map(gd).filter(s=>s!==null)}}function Sd(t){const e=u(t)?t:{};return{sessions:j(e.sessions,["items"]).map($d).filter(n=>n!==null),keepers:j(e.keepers,["items"]).map(hd).filter(n=>n!==null),pending_confirms:j(e.pending_confirms).map(yd).filter(n=>n!==null),available_actions:j(e.available_actions).map(bd).filter(n=>n!==null)}}function Cd(t){if(!u(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.summary),a=r(t.target_type);return!e||!n||!s||!a?null:{id:e,kind:n,severity:r(t.severity)??"warn",summary:s,target_type:a,target_id:r(t.target_id)??null,top_action:pe(t.top_action),related_session_ids:j(t.related_session_ids).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),related_agent_names:j(t.related_agent_names).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),evidence_preview:j(t.evidence_preview).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),last_seen_at:r(t.last_seen_at)??null}}function Ad(t){if(!u(t))return null;const e=r(t.session_id),n=r(t.goal);return!e||!n?null:{session_id:e,goal:n,room:r(t.room)??null,status:r(t.status),health:r(t.health),member_names:j(t.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:r(t.started_at)??null,elapsed_sec:c(t.elapsed_sec)??null,last_event_at:r(t.last_event_at)??null,last_event_summary:r(t.last_event_summary)??null,communication_summary:r(t.communication_summary)??null,active_count:c(t.active_count),required_count:c(t.required_count),related_attention_count:c(t.related_attention_count)??0,top_attention:qe(t.top_attention),top_recommendation:pe(t.top_recommendation)}}function wd(t){if(!u(t))return null;const e=r(t.agent_name);return e?{agent_name:e,status:r(t.status),where:r(t.where)??null,with_whom:j(t.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:r(t.current_work)??null,related_session_id:r(t.related_session_id)??null,related_attention_count:c(t.related_attention_count)??0,recent_output_preview:r(t.recent_output_preview)??null,recent_input_preview:r(t.recent_input_preview)??null,recent_event:r(t.recent_event)??null,recent_tool_names:j(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean)}:null}function Td(t){if(!u(t))return null;const e=r(t.name);return e?{name:e,agent_name:r(t.agent_name)??null,status:r(t.status),generation:c(t.generation),context_ratio:c(t.context_ratio)??null,last_turn_ago_s:c(t.last_turn_ago_s)??null,current_work:r(t.current_work)??null,last_autonomous_action_at:r(t.last_autonomous_action_at)??null}:null}function Id(t){if(!u(t))return null;const e=r(t.id),n=r(t.signal_type),s=r(t.summary),a=r(t.target_type);return!e||!n||!s||!a?null:{id:e,signal_type:n==="action"?"action":"attention",severity:r(t.severity)??"warn",summary:s,target_type:a,target_id:r(t.target_id)??null,attention:qe(t.attention),action:pe(t.action)}}function Rd(t){const e=u(t)?t:{};return{generated_at:r(e.generated_at),summary:kd(e.summary),incidents:j(e.incidents).map(qe).filter(n=>n!==null),recommended_actions:j(e.recommended_actions).map(pe).filter(n=>n!==null),command_focus:xd(e.command_focus),operator_targets:Sd(e.operator_targets),attention_queue:j(e.attention_queue).map(Cd).filter(n=>n!==null),session_briefs:j(e.session_briefs).map(Ad).filter(n=>n!==null),agent_briefs:j(e.agent_briefs).map(wd).filter(n=>n!==null),keeper_briefs:j(e.keeper_briefs).map(Td).filter(n=>n!==null),internal_signals:j(e.internal_signals).map(Id).filter(n=>n!==null)}}function Pd(t){if(!u(t))return null;const e=r(t.id),n=r(t.label),s=r(t.summary);if(!e||!n||!s)return null;const a=r(t.status)??"unclear";return{id:e,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,evidence:j(t.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function Nd(t){const e=u(t)?t:{},n=u(e.basis)?e.basis:{},s=r(e.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:r(e.generated_at),cached:z(e.cached),stale:z(e.stale),refreshing:z(e.refreshing),status:a,summary:r(e.summary)??null,model:r(e.model)??null,ttl_sec:c(e.ttl_sec),criteria:j(e.criteria).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),basis:{current_room:r(n.current_room)??null,crew_count:c(n.crew_count),agent_count:c(n.agent_count),keeper_count:c(n.keeper_count)},sections:j(e.sections).map(Pd).filter(o=>o!==null),error:r(e.error)??null,last_error:r(e.last_error)??null}}async function os(){Fa.value=!0,gs.value=null;try{const t=await Sl();ii.value=Rd(t)}catch(t){gs.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{Fa.value=!1}}async function _n(t=!1){ke.value=!0,oe.value=null;try{const e=await Cl(t),n=Nd(e);Do.value=n,n.refreshing||n.status==="pending"?fd():Pi()}catch(e){oe.value=e instanceof Error?e.message:"Failed to load mission briefing",Pi()}finally{ke.value=!1}}function Xt({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function zo(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const o=Math.floor(a/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function Q({timestamp:t}){const e=zo(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return i`<span class="time-ago" title=${n}>${e}</span>`}let Ld=0;const le=g([]);function P(t,e="success",n=4e3){const s=++Ld;le.value=[...le.value,{id:s,message:t,type:e}],setTimeout(()=>{le.value=le.value.filter(a=>a.id!==s)},n)}function Md(t){le.value=le.value.filter(e=>e.id!==t)}function Dd(){const t=le.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Md(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const zd="masc_dashboard_agent_name",Ke=g(null),$s=g(!1),fn=g(""),hs=g([]),gn=g([]),Ie=g(""),sn=g(!1);function ze(t){Ke.value=t,oi()}function Ni(){Ke.value=null,fn.value="",hs.value=[],gn.value=[],Ie.value=""}function Ed(){const t=Ke.value;return t?gt.value.find(e=>e.name===t)??null:null}function Eo(t){return t?Ct.value.filter(e=>e.assignee===t):[]}function jo(t){return t?jt.value.find(e=>e.agent_name===t||e.name===t)??null:null}function jd(t){if(!t)return[];const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Od(t){const e=jo(t);return e?e.recent_tool_names&&e.recent_tool_names.length>0?e.recent_tool_names:[]:[]}async function oi(){const t=Ke.value;if(t){$s.value=!0,fn.value="",hs.value=[],gn.value=[];try{const e=await pc(80);hs.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Eo(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await mc(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const l=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));gn.value=s}catch(e){fn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{$s.value=!1}}}async function Li(){var s;const t=Ke.value,e=Ie.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(zd))==null?void 0:s.trim())||"dashboard";sn.value=!0;try{await uc(n,`@${t} ${e}`),Ie.value="",P(`Mention sent to ${t}`,"success"),oi()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";P(o,"error")}finally{sn.value=!1}}function Fd({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Xt} status=${t.status} />
    </div>
  `}function qd({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Kd(){var m,f,h,k,x,C,w;const t=Ke.value;if(!t)return null;const e=Ed(),n=jo(t),s=Eo(t),a=hs.value,o=Od(t),l=jd(n),d=(e==null?void 0:e.capabilities)??[],v=((m=pt.value)==null?void 0:m.room)??"default",_=((f=pt.value)==null?void 0:f.project)??"확인 없음",p=((h=pt.value)==null?void 0:h.cluster)??"확인 없음";return i`
    <div
      class="agent-detail-overlay"
      onClick=${A=>{A.target.classList.contains("agent-detail-overlay")&&Ni()}}
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
                        <${Xt} status=${e.status} />
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
            ${(((C=e==null?void 0:e.interests)==null?void 0:C.length)??0)>0?i`
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
                    ${e.last_seen?i`<span>Last seen: <${Q} timestamp=${e.last_seen} /></span>`:null}
                    <span>Room: ${v}</span>
                    <span>Project: ${_}</span>
                    <span>Cluster: ${p}</span>
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{oi()}} disabled=${$s.value}>
              ${$s.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Ni}>Close</button>
          </div>
        </div>

        ${fn.value?i`<div class="council-error">${fn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${T} title="Assigned Tasks">
            ${s.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${s.map(A=>i`<${Fd} key=${A.id} task=${A} />`)}</div>`}
          <//>

          <${T} title="Recent Activity">
            ${a.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${a.map((A,S)=>i`<div key=${S} class="agent-activity-line">${A}</div>`)}</div>`}
          <//>
        </div>

        <${T} title="Capabilities & Tools">
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

        <${T} title="Task History">
          ${gn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${gn.value.map(A=>i`<${qd} key=${A.taskId} row=${A} />`)}</div>`}
        <//>

        <${T} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Ie.value}
              onInput=${A=>{Ie.value=A.target.value}}
              onKeyDown=${A=>{A.key==="Enter"&&Li()}}
              disabled=${sn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Li()}}
              disabled=${sn.value||Ie.value.trim()===""}
            >
              ${sn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const Tt=g(null),Oo=g(null),It=g(null),$n=g(!1),Yt=g(null),hn=g(!1),Ee=g(null),B=g(!1),ys=g([]);let Ud=1;function Hd(t){return u(t)?{id:r(t.id),seq:c(t.seq),from:r(t.from)??r(t.from_agent)??"system",content:r(t.content)??"",timestamp:r(t.timestamp)??new Date().toISOString(),type:r(t.type)}:null}function Wd(t){return u(t)?{room_id:r(t.room_id),current_room:r(t.current_room)??r(t.room),project:r(t.project),cluster:r(t.cluster),paused:z(t.paused),pause_reason:r(t.pause_reason)??null,paused_by:r(t.paused_by)??null,paused_at:r(t.paused_at)??null}:{}}function Mi(t){if(!u(t))return;const e=Object.entries(t).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Fo(t){if(!u(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function qo(t){if(!u(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:z(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Bd(t){return u(t)?{actor:r(t.actor)??null,spawn_agent:r(t.spawn_agent)??null,spawn_role:r(t.spawn_role)??null,spawn_model:r(t.spawn_model)??null,worker_class:r(t.worker_class)??null,parent_actor:r(t.parent_actor)??null,capsule_mode:r(t.capsule_mode)??null,runtime_pool:r(t.runtime_pool)??null,lane_id:r(t.lane_id)??null,controller_level:r(t.controller_level)??null,control_domain:r(t.control_domain)??null,supervisor_actor:r(t.supervisor_actor)??null,model_tier:r(t.model_tier)??null,task_profile:r(t.task_profile)??null,risk_level:r(t.risk_level)??null,routing_confidence:c(t.routing_confidence)??null,routing_reason:r(t.routing_reason)??null,status:r(t.status)??"unknown",turn_count:c(t.turn_count)??0,empty_note_turn_count:c(t.empty_note_turn_count)??0,has_turn:z(t.has_turn)??!1,last_turn_ts_iso:r(t.last_turn_ts_iso)??null}:null}function Gd(t){if(!u(t))return null;const e=r(t.session_id);return e?{session_id:e,goal:r(t.goal),status:r(t.status),health:r(t.health),scale_profile:r(t.scale_profile),control_profile:r(t.control_profile),planned_worker_count:c(t.planned_worker_count),active_agent_count:c(t.active_agent_count),last_turn_age_sec:c(t.last_turn_age_sec)??null,attention_count:c(t.attention_count),recommended_action_count:c(t.recommended_action_count),top_attention:Fo(t.top_attention),top_recommendation:qo(t.top_recommendation)}:null}function Ko(t){const e=u(t)?t:{};return{trace_id:r(e.trace_id),target_type:r(e.target_type)??"room",target_id:r(e.target_id)??null,health:r(e.health),swarm_status:u(e.swarm_status)?e.swarm_status:void 0,attention_items:j(e.attention_items).map(Fo).filter(n=>n!==null),recommended_actions:j(e.recommended_actions).map(qo).filter(n=>n!==null),session_cards:j(e.session_cards).map(Gd).filter(n=>n!==null),worker_cards:j(e.worker_cards).map(Bd).filter(n=>n!==null)}}function Jd(t){if(!u(t))return null;const e=u(t.status)?t.status:void 0,n=u(t.summary)?t.summary:u(e==null?void 0:e.summary)?e.summary:void 0,s=u(t.session)?t.session:u(e==null?void 0:e.session)?e.session:void 0,a=r(t.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const o=Mi(t.report_paths)??Mi(e==null?void 0:e.report_paths),l=j(t.recent_events,["events"]).filter(u);return{session_id:a,status:r(t.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:c(t.progress_pct)??c(n==null?void 0:n.progress_pct),elapsed_sec:c(t.elapsed_sec)??c(n==null?void 0:n.elapsed_sec),remaining_sec:c(t.remaining_sec)??c(n==null?void 0:n.remaining_sec),done_delta_total:c(t.done_delta_total)??c(n==null?void 0:n.done_delta_total),summary:n,team_health:u(t.team_health)?t.team_health:u(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:u(t.communication_metrics)?t.communication_metrics:u(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:u(t.orchestration_state)?t.orchestration_state:u(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:u(t.cascade_metrics)?t.cascade_metrics:u(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:s,recent_events:l}}function Vd(t){if(!u(t))return null;const e=r(t.name);if(!e)return null;const n=u(t.context)?t.context:void 0;return{name:e,agent_name:r(t.agent_name),status:r(t.status),autonomy_level:r(t.autonomy_level),context_ratio:c(t.context_ratio)??c(n==null?void 0:n.context_ratio),generation:c(t.generation),active_goal_ids:K(t.active_goal_ids),last_autonomous_action_at:r(t.last_autonomous_action_at)??null,last_turn_ago_s:c(t.last_turn_ago_s),model:r(t.model)??r(t.active_model)??r(t.primary_model)}}function Yd(t){if(!u(t))return null;const e=r(t.confirm_token)??r(t.token);return e?{confirm_token:e,actor:r(t.actor),action_type:r(t.action_type),target_type:r(t.target_type),target_id:r(t.target_id)??null,delegated_tool:r(t.delegated_tool),created_at:r(t.created_at),preview:t.preview}:null}function Qd(t){const e=u(t)?t:{};return{room:Wd(e.room),sessions:j(e.sessions,["items","sessions"]).map(Jd).filter(n=>n!==null),keepers:j(e.keepers,["items","keepers"]).map(Vd).filter(n=>n!==null),recent_messages:j(e.recent_messages,["messages"]).map(Hd).filter(n=>n!==null),pending_confirms:j(e.pending_confirms,["items","confirms"]).map(Yd).filter(n=>n!==null),available_actions:j(e.available_actions,["actions"]).filter(u).map(n=>({action_type:r(n.action_type)??"unknown",target_type:r(n.target_type)??"unknown",description:r(n.description),confirm_required:z(n.confirm_required)}))}}function Hn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Di(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function bs(t){ys.value=[{...t,id:Ud++,at:new Date().toISOString()},...ys.value].slice(0,20)}function Uo(t){return t.confirm_required?Hn(t.preview)||"Confirmation required":Hn(t.result)||Hn(t.executed_action)||Hn(t.delegated_tool_result)||t.status}async function tt(){$n.value=!0,Yt.value=null;try{const t=await wl();Tt.value=Qd(t)}catch(t){Yt.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{$n.value=!1}}async function Et(){hn.value=!0,Ee.value=null;try{const t=await yo({targetType:"room"});Oo.value=Ko(t)}catch(t){Ee.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{hn.value=!1}}async function je(t){if(!t){It.value=null;return}hn.value=!0,Ee.value=null;try{const e=await yo({targetType:"team_session",targetId:t,includeWorkers:!0});It.value=Ko(e)}catch(e){Ee.value=e instanceof Error?e.message:"Failed to load session digest"}finally{hn.value=!1}}async function Xd(t){var e;B.value=!0,Yt.value=null;try{const n=await Hs(t);return bs({actor:t.actor,action_type:t.action_type,target_label:Di(t),outcome:n.confirm_required?"preview":"executed",message:Uo(n),delegated_tool:n.delegated_tool}),await tt(),await Et(),(e=It.value)!=null&&e.target_id&&await je(It.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw Yt.value=s,bs({actor:t.actor,action_type:t.action_type,target_label:Di(t),outcome:"error",message:s}),n}finally{B.value=!1}}async function Zd(t,e){var n;B.value=!0,Yt.value=null;try{const s=await zl(t,e);return bs({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Uo(s),delegated_tool:s.delegated_tool}),await tt(),await Et(),(n=It.value)!=null&&n.target_id&&await je(It.value.target_id),s}catch(s){const a=s instanceof Error?s.message:"Operator confirmation failed";throw Yt.value=a,bs({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),s}finally{B.value=!1}}cd(()=>{var t;tt(),Et(),(t=It.value)!=null&&t.target_id&&je(It.value.target_id)});function tu(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function eu(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function nu(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function zi(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function Ho(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function su(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Wo(t){if(!t)return null;const e=Dt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function au({keeper:t,showRawStatus:e=!1}){if(Z(()=>{t!=null&&t.name&&Co(t.name)},[t==null?void 0:t.name]),!t)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Dt.value[t.name],s=Wo(t),a=Na.value[t.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${tu(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${eu((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?i` · ${Ho(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?i` · next eligible ${su(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function iu({keeperName:t,placeholder:e}){const[n,s]=lo("");Z(()=>{t&&Co(t)},[t]);const a=at.value[t]??[],o=La.value[t]??!1,l=zt.value[t],d=async()=>{const v=n.trim();if(!(!t||!v)){s("");try{await Nc(t,v)}catch(_){const p=_ instanceof Error?_.message:`Failed to message ${t}`;P(p,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(v=>i`
              <div class="keeper-conversation-item" key=${v.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${zi(v)}`}>${v.label}</span>
                  <span class=${`keeper-role-chip ${zi(v)}`}>${nu(v)}</span>
                  ${v.timestamp?i`<span class="keeper-conversation-time">${Ho(v.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${v.text}</div>
                ${v.error?i`<div class="keeper-conversation-error">${v.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${e}
          value=${n}
          onInput=${v=>{s(v.target.value)}}
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
  `}function ou({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=Wo(e),a=Ma.value[e.name]??!1,o=Da.value[e.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",d=(s==null?void 0:s.recoverable)??l==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{Lc(e.name,t).catch(v=>{const _=v instanceof Error?v.message:`Failed to probe ${e.name}`;P(_,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{Mc(e.name,t).catch(v=>{const _=v instanceof Error?v.message:`Failed to recover ${e.name}`;P(_,"error")})}}
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
  `}const ri=g(null);function li(t){ri.value=t,Pc(t.name)}function Ei(){ri.value=null}const he=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function ru(t){if(!t)return 0;const e=he.findIndex(n=>n.level===t);return e>=0?e:0}function lu({keeper:t}){const e=ru(t.autonomy_level),n=he[e]??he[0];if(!n)return null;const s=(e+1)/he.length*100;return i`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${he.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${he.map((a,o)=>i`
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
            <strong><${Q} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?i`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function rs(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function cu(t){switch(t){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(t==null?void 0:t.trim())||"action"}}function du(t){return t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]}function uu(t){const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function pu({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${rs(t.context_tokens)}</div>
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
  `}function mu({keeper:t}){var p,m;const e=t.metrics_series??[];if(e.length<2){const f=(((p=t.context)==null?void 0:p.context_ratio)??0)*100,h=f>85?"#ef4444":f>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${f.toFixed(1)}%;background:${h}"></div>
        </div>
        <span class="chart-pct">${f.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=e.length,l=e.map((f,h)=>{const k=a+h/(o-1)*(n-2*a),x=s-a-(f.context_ratio??0)*(s-2*a);return{x:k,y:x,p:f}}),d=l.map(({x:f,y:h})=>`${f.toFixed(1)},${h.toFixed(1)}`).join(" "),v=(((m=e[e.length-1])==null?void 0:m.context_ratio)??0)*100,_=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return i`
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
      <span class="chart-pct">${v.toFixed(1)}%</span>
    </div>`}const ta=g("");function vu({keeper:t}){var a,o,l,d;const e=ta.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],s=e?n.filter(v=>v.title.toLowerCase().includes(e)||v.key.includes(e)||v.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${ta.value}
        onInput=${v=>{ta.value=v.target.value}}
      />
      ${s.map(v=>i`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${v.title}</span>
          <span class="keeper-field-key">${v.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${v.value}</span>
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
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${rs(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${rs(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${rs(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((d=t.context)==null?void 0:d.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function _u({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
  `}function fu({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function gu({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function ji({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function ea(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function $u({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:ea(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:ea(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:ea(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(s=>i`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function hu({keeper:t}){var _,p,m,f,h,k,x;const e=((_=Tt.value)==null?void 0:_.room)??{},n=(((p=Tt.value)==null?void 0:p.available_actions)??[]).filter(C=>C.target_type==="keeper"||C.target_type==="room").slice(0,8),s=du(t),a=uu(t),o=((m=t.agent)==null?void 0:m.capabilities)??[],l=e.current_room??e.room_id??((f=pt.value)==null?void 0:f.room)??"default",d=e.project??((h=pt.value)==null?void 0:h.project)??"확인 없음",v=e.cluster??((k=pt.value)==null?void 0:k.cluster)??"확인 없음";return i`
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
        <strong>${v}</strong>
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
          ${n.length>0?n.map(C=>i`<span class="pill">${cu(C.action_type)}</span>`):i`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function Bo(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function yu(){try{const t=await Hs({actor:Bo(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=So(t.result);await Nn(),e!=null&&e.skipped_reason?P(e.skipped_reason,"warning"):P(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";P(e,"error")}}function bu({keeper:t}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${au} keeper=${t} />
          <${ou}
            actor=${Bo()}
            keeper=${t}
            onPokeLodge=${()=>{yu()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${iu}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function ku(){var e,n,s;const t=ri.value;return t?i`
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
            <${Xt} status=${t.status} />
            ${t.model?i`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Ei()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${pu} keeper=${t} />

        ${""}
        <${mu} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${T} title="Field Dictionary">
            <${vu} keeper=${t} />
          <//>

          ${""}
          <${T} title="Profile">
            <${ji} traits=${t.traits??[]} label="Traits" />
            <${ji} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${Q} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?i`
              <${T} title="Autonomy">
                <${lu} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?i`
              <${T} title="TRPG Stats">
                <${_u} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${T} title="Equipment (${t.inventory.length})">
                <${fu} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${T} title="Relationships (${Object.keys(t.relationships).length})">
                <${gu} rels=${t.relationships} />
              <//>
            `:null}

          <${T} title="Runtime Signals">
            <${$u} keeper=${t} />
          <//>

          <${T} title="Neighborhood & Tools">
            <${hu} keeper=${t} />
          <//>

          <${T} title="Memory & Context">
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
        <${bu} keeper=${t} />
      </div>
    </div>
  `:null}const ks="masc_dashboard_workflow_context",xu=900*1e3;function _t(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function Ft(t){const e=_t(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function Go(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function qa(t){return u(t)?t:null}function Su(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function Cu(t){if(!t)return null;try{const e=JSON.parse(t);if(!u(e))return null;const n=_t(e.id),s=_t(e.source_surface),a=_t(e.source_label),o=_t(e.summary),l=_t(e.created_at);return!n||s!=="mission"||!a||!o||!l?null:{id:n,source_surface:"mission",source_label:a,action_type:_t(e.action_type),target_type:_t(e.target_type),target_id:_t(e.target_id),focus_kind:_t(e.focus_kind),summary:o,payload_preview:_t(e.payload_preview),suggested_payload:qa(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:l}}catch{return null}}function ci(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=xu}function Au(){const t=Go(),e=Cu((t==null?void 0:t.getItem(ks))??null);return e?ci(e)?e:(t==null||t.removeItem(ks),null):null}const Jo=g(Au());function wu(t){const e=t&&ci(t)?t:null;Jo.value=e;const n=Go();if(!n)return;if(!e){n.removeItem(ks);return}const s=Su(e);s&&n.setItem(ks,s)}function Tu(t){if(!t)return null;const e=qa(t.suggested_payload);if(e)return e;if(u(t.preview)){const n=qa(t.preview.payload);if(n)return n}return null}function Iu(t){if(!t)return null;const e=Ft(t.message);if(e)return e;const n=Ft(t.task_title)??Ft(t.title),s=Ft(t.task_description)??Ft(t.description),a=Ft(t.reason),o=Ft(t.priority)??Ft(t.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function Vo(t,e,n,s,a,o){return["mission",t,e??"action",n??"target",s??"room",a??"focus",o].join(":")}function Ue(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=Tu(t),o=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,l=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,d=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,v=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:Vo(n,(t==null?void 0:t.action_type)??null,o,l,d,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:o,target_id:l,focus_kind:d,summary:v,payload_preview:Iu(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function Ru(t,e){return e.source==="mission"&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)}function Ln(t){const{params:e}=t;if(e.source!=="mission")return null;const n=Jo.value;if(n&&ci(n)&&Ru(n,e))return n;const s=new Date().toISOString();return{id:Vo("상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,s),source_surface:"mission",source_label:"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,summary:e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function Pu(t){return{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function Yo(t){const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.target_type==="room"?"summary":"swarm"}function Nu(t){return{source:"mission",surface:Yo(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function di(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function Bs(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";default:return(t==null?void 0:t.trim())||"추천 액션"}}function Lu(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}const Ht=g(null),Nt=g(null);function V(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function it(t){return t==="bad"||t==="offline"||t==="critical"||t==="risk"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"||t==="watch"?"warn":"ok"}function ue(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:n<86400?`${Math.round(n/3600)}h 전`:`${Math.round(n/86400)}d 전`}function Mu(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:t<86400?`${Math.round(t/3600)}h`:`${Math.round(t/86400)}d`}function Du(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function zu(t){return di(t?Ue(t,null,"상황판 추천 액션"):null)}function Gs(t,e=Ue()){wu(e),rt(t,t==="intervene"?Pu(e):Nu(e))}function Qo(t){Gs("intervene",Ue(null,t,"상황판 incident"))}function Xo(t){Gs("command",Ue(null,t,"상황판 incident"))}function ui(t,e,n="상황판 추천 액션"){Gs("intervene",Ue(t,e,n))}function Zo(t,e,n="상황판 추천 액션"){Gs("command",Ue(t,e,n))}function Oi(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),rt(t,n)}function Eu(t){return{kind:t.kind,severity:t.severity,summary:t.summary,target_type:t.target_type,target_id:t.target_id??null,actor:null,evidence:t.evidence_preview}}function tr(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>(s.from??"").trim().toLowerCase()===n).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function ju(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>{if((s.from??"").trim().toLowerCase()===n)return!1;const o=(s.content??"").trim().toLowerCase();return o.includes(`@${n}`)||o.includes(n)}).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function Ou(t){return jt.value.find(e=>e.agent_name===t||e.name===t)??null}function er(t){return gt.value.find(e=>e.name===t)??null}function nr(t,e){const n=V(t,100);if(!n)return null;const s=e.find(o=>o.id===n);if(s)return`${s.id} · ${V(s.title,92)}`;const a=e.find(o=>o.title===n);return a?`${a.id} · ${V(a.title,92)}`:n}function Fu(t){var d,v;const e=er(t.agent_name),n=Ou(t.agent_name),s=tr(t.agent_name,De.value),a=ju(t.agent_name,De.value),o=ai(t.agent_name),l=(n==null?void 0:n.skill_primary)??(e!=null&&e.capabilities&&e.capabilities.length>0?e.capabilities.slice(0,3).join(", "):null)??o.model??(e==null?void 0:e.agent_type)??null;return{brief:t,agent:e,keeper:n,where:t.where??"room",withWhom:t.with_whom,currentWork:t.current_work??nr((e==null?void 0:e.current_task)??null,Ct.value)??"명시된 current task 없음",how:l,recentInput:V(t.recent_input_preview,120)??V(a==null?void 0:a.content,120)??V(n==null?void 0:n.recent_input_preview,120)??null,recentOutput:V(t.recent_output_preview,120)??V(s==null?void 0:s.content,120)??V(n==null?void 0:n.recent_output_preview,120)??V((d=n==null?void 0:n.diagnostic)==null?void 0:d.last_reply_preview,120)??null,recentEvent:V(t.recent_event,120)??V((v=n==null?void 0:n.diagnostic)==null?void 0:v.summary,120)??null,recentTools:t.recent_tool_names.length>0?t.recent_tool_names:(n==null?void 0:n.recent_tool_names)??[]}}function qu(t){var n,s;const e=jt.value.find(a=>a.name===t.name||a.agent_name===t.agent_name)??null;return{brief:t,keeper:e,currentWork:V(t.current_work,110)??V(e==null?void 0:e.skill_primary,110)??V(e==null?void 0:e.last_proactive_reason,110)??"명시된 keeper focus 없음",recentInput:V(e==null?void 0:e.recent_input_preview,120)??null,recentOutput:V(e==null?void 0:e.recent_output_preview,120)??V((n=e==null?void 0:e.diagnostic)==null?void 0:n.last_reply_preview,120)??V(e==null?void 0:e.last_proactive_preview,120)??null,recentEvent:V(e==null?void 0:e.last_proactive_reason,120)??V((s=e==null?void 0:e.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(e==null?void 0:e.recent_tool_names)??[]}}function Ku(){const t=ii.value;return t?new Map(t.session_briefs.map(e=>[e.session_id,e])):new Map}function Uu(t){const e=er(t),n=tr(t,De.value),s=ai(t);return{name:t,model:s.model,nickname:s.nickname,currentTask:nr((e==null?void 0:e.current_task)??null,Ct.value)??"agent snapshot 없음",output:V(n==null?void 0:n.content,96)}}function Hu(t){Ht.value=Ht.value===t?null:t,Nt.value=null}function sr(t){Nt.value=Nt.value===t?null:t}function Wu(){Ht.value=null,Nt.value=null}function Bu({cluster:t,project:e,room:n,generatedAt:s}){return i`
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
        <strong>${s?ue(s):"fresh"}</strong>
      </div>
    </div>
  `}function ge({label:t,value:e,detail:n,tone:s}){return i`
    <article class="mission-stat-card ${it(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function Gu(){const t=Do.value,e=it((t==null?void 0:t.status)??(oe.value?"bad":"warn")),n=(t==null?void 0:t.status)==="error"||(t==null?void 0:t.status)==="unavailable"&&!(t!=null&&t.cached);return i`
    <${T} title="LLM 판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>heuristic 대신 별도 판단 계층</h3>
        <p>핵심 해석 3줄만 먼저 보여주고, 근거는 접어서 둡니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${e}">
          ${(t==null?void 0:t.status)??(oe.value?"error":"loading")}
        </span>
        ${t!=null&&t.model?i`<span class="command-chip">${t.model}</span>`:null}
        ${t!=null&&t.generated_at?i`<span class="command-chip">${ue(t.generated_at)}</span>`:null}
        ${t!=null&&t.cached?i`<span class="command-chip">cached</span>`:null}
        ${t!=null&&t.stale?i`<span class="command-chip warn">stale</span>`:null}
      </div>

      ${oe.value?i`<div class="empty-state error">${oe.value}</div>`:null}
      ${t!=null&&t.error?i`<div class="empty-state error">${t.error}</div>`:null}
      ${t!=null&&t.summary?i`<div class="mission-inline-note">${t.summary}</div>`:null}

      ${t&&t.sections.length>0?i`
            <div class="mission-briefing-grid">
              ${t.sections.slice(0,3).map(s=>i`
                <article class="mission-briefing-section ${it(s.status)}">
                  <div class="mission-card-head">
                    <strong>${s.label}</strong>
                    <span class="command-chip ${it(s.status)}">${s.status}</span>
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
          `:!ke.value&&!oe.value?i`<div class="empty-state">판단 레이어 결과가 아직 없습니다.</div>`:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{_n(n)}} disabled=${ke.value}>
          ${ke.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{_n(!0)}} disabled=${ke.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function Ju({item:t,selected:e,sessionLookup:n}){const s=Eu(t),a=t.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),o=t.top_action??null;return i`
    <article class="mission-attention-card ${it((o==null?void 0:o.severity)??t.severity)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Hu(t.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.summary}</strong>
            <div class="mission-card-target">${t.kind}${t.target_id?` · ${t.target_id}`:""}</div>
          </div>
          <span class="command-chip ${it((o==null?void 0:o.severity)??t.severity)}">${o?Du(o):t.severity}</span>
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
            <strong>${t.last_seen_at?ue(t.last_seen_at):"n/a"}</strong>
            <small>${t.target_type}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${o?Bs(o.action_type):"판단 필요"}</strong>
            <small>${o?zu(o):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${o?i`<div class="mission-inline-note">${o.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?i`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>i`
                  <button class="mission-link-row" onClick=${()=>sr(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${l.status??"unknown"} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:i`<div class="empty-state">직접 연결된 session이 아직 없습니다.</div>`}

        ${t.related_agent_names.length>0?i`
              <div class="mission-pill-row">
                ${t.related_agent_names.slice(0,8).map(l=>i`
                  <button class="mission-pill action" onClick=${()=>ze(l)}>${l}</button>
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
              <button class="control-btn ghost" onClick=${()=>ui(o,s,"Mission attention")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>Zo(o,s,"Mission attention")}>
                원인 보기
              </button>
            `:i`
              <button class="control-btn ghost" onClick=${()=>Qo(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Xo(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function Vu({brief:t,selected:e}){var o,l;const n=t.member_names.slice(0,6).map(Uu),s=t.top_recommendation??null,a=t.top_attention??null;return i`
    <article class="mission-crew-card ${it(((o=t.top_attention)==null?void 0:o.severity)??t.health??t.status)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>sr(t.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.goal}</strong>
            <div class="mission-card-target">${t.session_id}${t.room?` · ${t.room}`:""}</div>
          </div>
          <span class="command-chip ${it(((l=t.top_attention)==null?void 0:l.severity)??t.health??t.status)}">${t.status??"unknown"}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${t.member_names.length}</strong>
            <small>${t.member_names.slice(0,3).join(", ")||"n/a"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${Mu(t.elapsed_sec)}</strong>
            <small>${t.started_at?`${ue(t.started_at)} 시작`:"시작 시각 없음"}</small>
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
        <small>${t.last_event_at?ue(t.last_event_at):"시각 없음"}</small>
      </div>

      ${t.top_attention?i`<div class="mission-inline-note">attention: ${t.top_attention.summary}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>session detail</summary>
        ${n.length>0?i`
              <div class="mission-pill-row">
                ${n.map(d=>i`
                  <button class="mission-pill action" onClick=${()=>ze(d.name)}>
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
                    <button class="mission-link-row" onClick=${()=>ze(d.name)}>
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
        <button class="control-btn ghost" onClick=${()=>Oi("intervene",t.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Oi("command",t.session_id)}>세션 원인 보기</button>
        ${s?i`<button class="control-btn ghost" onClick=${()=>ui(s,a,"Mission session brief")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function Yu({row:t}){var s,a,o,l,d;const e=ai(t.brief.agent_name),n=t.withWhom.length>0?t.withWhom.slice(0,3).join(", "):"단독 또는 room-level";return i`
    <article class="mission-activity-card ${it(t.brief.status??((s=t.agent)==null?void 0:s.status))}">
      <button class="mission-card-select" onClick=${()=>ze(t.brief.agent_name)}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((a=t.agent)==null?void 0:a.emoji)??((o=t.keeper)==null?void 0:o.emoji)??""}</span>
            <div>
              <strong>${t.brief.agent_name}</strong>
              <span>${e.model!==e.nickname?`${e.model} · `:""}${e.nickname}</span>
            </div>
          </div>
          <span class="command-chip ${it(t.brief.status??((l=t.agent)==null?void 0:l.status))}">${t.brief.status??((d=t.agent)==null?void 0:d.status)??"unknown"}</span>
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
  `}function Qu({row:t}){var n,s,a,o,l,d,v,_,p,m;const e=[`gen ${t.brief.generation??((n=t.keeper)==null?void 0:n.generation)??0}`,t.brief.context_ratio!=null?`ctx ${Math.round(t.brief.context_ratio*100)}%`:((s=t.keeper)==null?void 0:s.context_ratio)!=null?`ctx ${Math.round(t.keeper.context_ratio*100)}%`:null,t.brief.last_turn_ago_s!=null?`last turn ${Math.round(t.brief.last_turn_ago_s)}s`:null].filter(f=>f!==null).join(" · ");return i`
    <article class="mission-activity-card ${it(t.brief.status??((a=t.keeper)==null?void 0:a.status))}">
      <button class="mission-card-select" onClick=${()=>{t.keeper&&li(t.keeper)}}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((o=t.keeper)==null?void 0:o.emoji)??""}</span>
            <div>
              <strong>${t.brief.name}</strong>
              ${(l=t.keeper)!=null&&l.koreanName?i`<span>${t.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <span class="command-chip ${it(t.brief.status??((d=t.keeper)==null?void 0:d.status))}">${t.brief.status??((v=t.keeper)==null?void 0:v.status)??"unknown"}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 heartbeat · ${(_=t.keeper)!=null&&_.last_heartbeat?ue(t.keeper.last_heartbeat):"n/a"}</span>
          <span>${e||"continuity 정보 없음"}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${t.currentWork}</strong>
          ${(p=t.keeper)!=null&&p.skill_reason?i`<small>판단 요약 · ${V(t.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>continuity detail</summary>
        <div class="mission-activity-foot">
          <span>agent · ${t.brief.agent_name??((m=t.keeper)==null?void 0:m.agent_name)??"n/a"}</span>
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
  `}function Xu({item:t}){const e=t.action??null,n=t.attention??null;return i`
    <article class="mission-action-card ${it(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${it(t.severity)}">
          ${t.signal_type==="action"&&e?Bs(e.action_type):(n==null?void 0:n.kind)??"signal"}
        </span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      ${e?i`<div class="mission-action-preview">${e.reason}</div>`:null}
      <div class="mission-card-actions">
        ${e?i`
              <button class="control-btn ghost" onClick=${()=>ui(e,n,"Mission internal signal")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Zo(e,n,"Mission internal signal")}>이 이슈의 원인 보기</button>
            `:n?i`
                <button class="control-btn ghost" onClick=${()=>Qo(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>Xo(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function Fi(){var f,h,k,x,C,w,A;const t=ii.value;if(Fa.value&&!t)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(gs.value&&!t)return i`<div class="empty-state error">${gs.value}</div>`;if(!t)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;Ht.value&&!t.attention_queue.some(S=>S.id===Ht.value)&&(Ht.value=null),Nt.value&&!t.session_briefs.some(S=>S.session_id===Nt.value)&&(Nt.value=null);const e=t.attention_queue.find(S=>S.id===Ht.value)??null,n=Nt.value,s=Ku(),a=e?new Set(e.related_session_ids):null,o=e?new Set(e.related_agent_names):null,l=(a?t.session_briefs.filter(S=>a.has(S.session_id)):t.session_briefs).slice(0,e?8:6),d=t.agent_briefs.filter(S=>!_d(S.agent_name)).filter(S=>n?S.related_session_id===n:o&&a?o.has(S.agent_name)||(S.related_session_id?a.has(S.related_session_id):!1):!0).slice(0,n||e?10:8).map(Fu),v=t.keeper_briefs.slice(0,6).map(qu),_=t.attention_queue.slice(0,6),p=t.internal_signals.slice(0,3),m=d.filter(S=>S.recentOutput).length+v.filter(S=>S.recentOutput).length;return i`
    <section class="dashboard-panel mission-view">
      <${mt} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>원인 분석과 개입 판단을 먼저 보는 landing 입니다. 문제 → 영향 session → 관련 actor 순서로 좁혀서 읽습니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${it(t.summary.room_health)}">${t.summary.room_health??"ok"}</span>
          <span class="command-chip">${t.summary.project??"room"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?ue(t.generated_at):"fresh"}</span>
        </div>
      </div>

      <${Bu}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <${Gu} />

      <div class="mission-stat-grid">
        <${ge} label="주의 큐" value=${_.length} detail="개입 판단이 필요한 issue" tone=${((f=_[0])==null?void 0:f.severity)??"ok"} />
        <${ge} label="영향 session" value=${l.length} detail="현재 선택 기준으로 좁힌 흐름" tone=${((k=(h=l[0])==null?void 0:h.top_attention)==null?void 0:k.severity)??((x=l[0])==null?void 0:x.health)??"ok"} />
        <${ge} label="영향 agent" value=${d.length} detail="선택된 흐름에 연결된 actor" tone=${((C=d[0])==null?void 0:C.brief.status)??"ok"} />
        <${ge} label="Keeper watch" value=${v.length} detail="continuity lane 관찰 대상" tone=${((w=v[0])==null?void 0:w.brief.status)??"ok"} />
        <${ge} label="최근 output" value=${m} detail="선택된 영역에서 바로 읽을 수 있는 출력 수" tone=${m>0?"ok":"warn"} />
        <${ge} label="내부 신호" value=${p.length} detail="room/system 진단은 하단 보조 lane" tone=${((A=p[0])==null?void 0:A.severity)??"ok"} />
      </div>

      ${e||n?i`
            <div class="mission-selection-bar">
              <span>현재 drill-down · ${e?e.summary:"session 선택"}${n?` · ${n}`:""}</span>
              <button class="control-btn ghost" onClick=${Wu}>선택 해제</button>
            </div>
          `:null}

      <${T} title="Attention Queue" class="mission-list-card" semanticId="mission.attention_queue">
        <div class="mission-section-head">
          <h3>이슈에서 시작</h3>
          <p>문제와 경고를 먼저 보고, 여기서 session과 agent로 좁혀갑니다.</p>
        </div>
        <div class="mission-lane-stack">
          ${_.length>0?_.map(S=>i`<${Ju} key=${S.id} item=${S} selected=${Ht.value===S.id} sessionLookup=${s} />`):i`<div class="empty-state">지금 Mission attention queue가 비어 있습니다.</div>`}
        </div>
      <//>

      <div class="mission-human-grid">
        <${T} title="Affected Sessions" class="mission-list-card" semanticId="mission.session_briefs">
          <div class="mission-section-head">
            <h3>영향받는 session</h3>
            <p>attention과 직접 연결된 흐름만 먼저 보여주고, member preview는 한 단계 더 열었을 때만 보여줍니다.</p>
          </div>
          <div class="mission-list-stack">
            ${l.length>0?l.map(S=>i`<${Vu} key=${S.session_id} brief=${S} selected=${Nt.value===S.session_id} />`):i`<div class="empty-state">현재 선택과 연결된 session이 없습니다.</div>`}
          </div>
        <//>

        <${T} title="Impacted Agents" class="mission-list-card" semanticId="mission.agent_activity">
          <div class="mission-section-head">
            <h3>관련 agent</h3>
            <p>선택된 incident 또는 session과 연결된 actor만 보여주고, input-output은 접어서 둡니다.</p>
          </div>
          <div class="mission-activity-list">
            ${d.length>0?d.map(S=>i`<${Yu} key=${S.brief.agent_name} row=${S} />`):i`<div class="empty-state">현재 선택과 연결된 agent가 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${T} title="Keeper Continuity" class="mission-list-card" semanticId="mission.keeper_activity">
          <div class="mission-section-head">
            <h3>continuity lane</h3>
            <p>keeper는 별도 lane으로 보고, continuity 판단에 필요한 정보만 먼저 보여줍니다.</p>
          </div>
          <div class="mission-activity-list">
            ${v.length>0?v.map(S=>i`<${Qu} key=${S.brief.name} row=${S} />`):i`<div class="empty-state">지금 보이는 keeper가 없습니다.</div>`}
          </div>
        <//>

        <${T} title="Internal Signals" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>room / system 보조 신호</h3>
            <p>artifact scope drift 같은 시스템 진단은 메인 판단 근거가 아니라 보조 lane으로만 유지합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${p.length>0?p.map(S=>i`<${Xu} key=${S.id} item=${S} />`):i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>rt("execution")}>실행 관찰면 보기</button>
            <button class="control-btn ghost" onClick=${()=>rt("command")}>지휘 진단면 보기</button>
          </div>
        <//>
      </div>
    </section>
  `}const pi=g(null),Pt=g(null),xs=g(!1),Ss=g(!1),Cs=g(null),As=g(null),Ka=g(null),ws=g(null),q=g("warroom"),Mn=g(null),Ua=g(!1),Ts=g(null),me=g(null),Is=g(!1),Rs=g(null),Dn=g(null),Ha=g(!1),Ps=g(null),yn=g(null),Ns=g(!1),bn=g(null),Re=g(null);let Qe=null;function mi(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"}function ar(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function Zu(){const e=ar().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function tp(){const e=ar().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function ep(t){if(u(t))return{policy_class:r(t.policy_class),approval_class:r(t.approval_class),tool_allowlist:K(t.tool_allowlist),model_allowlist:K(t.model_allowlist),requires_human_for:K(t.requires_human_for),autonomy_level:r(t.autonomy_level),escalation_timeout_sec:c(t.escalation_timeout_sec),kill_switch:z(t.kill_switch),frozen:z(t.frozen)}}function np(t){if(u(t))return{headcount_cap:c(t.headcount_cap),active_operation_cap:c(t.active_operation_cap),max_cost_usd:c(t.max_cost_usd),max_tokens:c(t.max_tokens)}}function vi(t){if(!u(t))return null;const e=r(t.unit_id),n=r(t.label),s=r(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:r(t.parent_unit_id)??null,leader_id:r(t.leader_id)??null,roster:K(t.roster),capability_profile:K(t.capability_profile),source:r(t.source),created_at:r(t.created_at),updated_at:r(t.updated_at),policy:ep(t.policy),budget:np(t.budget)}}function ir(t){if(!u(t))return null;const e=vi(t.unit);return e?{unit:e,leader_status:r(t.leader_status),roster_total:c(t.roster_total),roster_live:c(t.roster_live),active_operation_count:c(t.active_operation_count),health:r(t.health),reasons:K(t.reasons),children:Array.isArray(t.children)?t.children.map(ir).filter(n=>n!==null):[]}:null}function sp(t){if(u(t))return{total_units:c(t.total_units),company_count:c(t.company_count),platoon_count:c(t.platoon_count),squad_count:c(t.squad_count),leaf_agent_unit_count:c(t.leaf_agent_unit_count),live_agent_count:c(t.live_agent_count),managed_unit_count:c(t.managed_unit_count),active_operation_count:c(t.active_operation_count)}}function or(t){const e=u(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),source:r(e.source),summary:sp(e.summary),units:Array.isArray(e.units)?e.units.map(ir).filter(n=>n!==null):[]}}function ap(t){if(!u(t))return null;const e=r(t.kind),n=r(t.status);return!e||!n?null:{kind:e,chain_id:r(t.chain_id)??null,goal:r(t.goal)??null,run_id:r(t.run_id)??null,status:n,viewer_path:r(t.viewer_path)??null,last_sync_at:r(t.last_sync_at)??null}}function Js(t){if(!u(t))return null;const e=r(t.operation_id),n=r(t.objective),s=r(t.assigned_unit_id),a=r(t.trace_id),o=r(t.status);return!e||!n||!s||!a||!o?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:r(t.autonomy_level),policy_class:r(t.policy_class),budget_class:r(t.budget_class),detachment_session_id:r(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(t.checkpoint_ref)??null,active_goal_ids:K(t.active_goal_ids),note:r(t.note)??null,created_by:r(t.created_by),source:r(t.source),status:o,chain:ap(t.chain),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function ip(t){if(!u(t))return null;const e=Js(t.operation);return e?{operation:e,assigned_unit_label:r(t.assigned_unit_label)}:null}function Je(t){if(u(t))return{tone:r(t.tone),pending_ops:c(t.pending_ops),blocked_ops:c(t.blocked_ops),in_flight_ops:c(t.in_flight_ops),pipeline_stalls:c(t.pipeline_stalls),bus_traffic:c(t.bus_traffic),l1_hit_rate:c(t.l1_hit_rate),invalidation_count:c(t.invalidation_count),current_pending:c(t.current_pending),current_in_flight:c(t.current_in_flight),cdb_wakeups:c(t.cdb_wakeups),total_stolen:c(t.total_stolen),avg_best_score:c(t.avg_best_score),avg_candidate_count:c(t.avg_candidate_count),best_first_operations:c(t.best_first_operations),active_sessions:c(t.active_sessions),commit_rate:c(t.commit_rate),total_speculations:c(t.total_speculations)}}function op(t){if(!u(t))return;const e=u(t.pipeline)?t.pipeline:void 0,n=u(t.cache)?t.cache:void 0,s=u(t.ooo)?t.ooo:void 0,a=u(t.speculative)?t.speculative:void 0,o=u(t.search_fabric)?t.search_fabric:void 0,l=u(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:c(e.total_ops),completed_ops:c(e.completed_ops),stalled_cycles:c(e.stalled_cycles),hazards_detected:c(e.hazards_detected),forwarding_used:c(e.forwarding_used),pipeline_flushes:c(e.pipeline_flushes),ipc:c(e.ipc)}:void 0,cache:n?{total_reads:c(n.total_reads),total_writes:c(n.total_writes),l1_hit_rate:c(n.l1_hit_rate),invalidation_count:c(n.invalidation_count),writeback_count:c(n.writeback_count),bus_traffic:c(n.bus_traffic)}:void 0,ooo:s?{agent_count:c(s.agent_count),total_added:c(s.total_added),total_issued:c(s.total_issued),total_completed:c(s.total_completed),total_stolen:c(s.total_stolen),cdb_wakeups:c(s.cdb_wakeups),stall_cycles:c(s.stall_cycles),global_cdb_events:c(s.global_cdb_events),current_pending:c(s.current_pending),current_in_flight:c(s.current_in_flight)}:void 0,speculative:a?{total_speculations:c(a.total_speculations),total_commits:c(a.total_commits),total_aborts:c(a.total_aborts),commit_rate:c(a.commit_rate),total_fast_calls:c(a.total_fast_calls),total_cost_usd:c(a.total_cost_usd),active_sessions:c(a.active_sessions)}:void 0,search_fabric:o?{total_operations:c(o.total_operations),best_first_operations:c(o.best_first_operations),legacy_operations:c(o.legacy_operations),blocked_operations:c(o.blocked_operations),ready_operations:c(o.ready_operations),research_pipeline_operations:c(o.research_pipeline_operations),avg_candidate_count:c(o.avg_candidate_count),avg_best_score:c(o.avg_best_score),top_stage:r(o.top_stage)??null}:void 0,signals:l?{issue_pressure:Je(l.issue_pressure),cache_contention:Je(l.cache_contention),scheduler_efficiency:Je(l.scheduler_efficiency),routing_confidence:Je(l.routing_confidence),speculative_posture:Je(l.speculative_posture)}:void 0}}function rr(t){const e=u(t)?t:{},n=u(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:c(n.total),active:c(n.active),paused:c(n.paused),managed:c(n.managed),projected:c(n.projected)}:void 0,microarch:op(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(ip).filter(s=>s!==null):[]}}function lr(t){if(!u(t))return null;const e=r(t.detachment_id),n=r(t.operation_id),s=r(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:r(t.leader_id)??null,roster:K(t.roster),session_id:r(t.session_id)??null,checkpoint_ref:r(t.checkpoint_ref)??null,runtime_kind:r(t.runtime_kind)??null,runtime_ref:r(t.runtime_ref)??null,source:r(t.source),status:r(t.status),last_event_at:r(t.last_event_at)??null,last_progress_at:r(t.last_progress_at)??null,heartbeat_deadline:r(t.heartbeat_deadline)??null,created_at:r(t.created_at),updated_at:r(t.updated_at)}}function rp(t){if(!u(t))return null;const e=lr(t.detachment);return e?{detachment:e,assigned_unit_label:r(t.assigned_unit_label),operation:Js(t.operation)}:null}function cr(t){const e=u(t)?t:{},n=u(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:c(n.total),active:c(n.active),projected:c(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(rp).filter(s=>s!==null):[]}}function lp(t){if(!u(t))return null;const e=r(t.decision_id),n=r(t.trace_id),s=r(t.requested_action),a=r(t.scope_type),o=r(t.scope_id);return!e||!n||!s||!a||!o?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:r(t.operation_id)??null,target_unit_id:r(t.target_unit_id)??null,requested_by:r(t.requested_by),status:r(t.status),reason:r(t.reason)??null,source:r(t.source),detail:t.detail,created_at:r(t.created_at),decided_at:r(t.decided_at)??null,expires_at:r(t.expires_at)??null}}function dr(t){const e=u(t)?t:{},n=u(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:c(n.total),pending:c(n.pending),approved:c(n.approved),denied:c(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(lp).filter(s=>s!==null):[]}}function cp(t){if(!u(t))return null;const e=vi(t.unit);return e?{unit:e,roster_total:c(t.roster_total),roster_live:c(t.roster_live),headcount_cap:c(t.headcount_cap),active_operations:c(t.active_operations),active_operation_cap:c(t.active_operation_cap),utilization:c(t.utilization)}:null}function dp(t){const e=u(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(cp).filter(n=>n!==null):[]}}function up(t){if(!u(t))return null;const e=r(t.alert_id);return e?{alert_id:e,severity:r(t.severity),kind:r(t.kind),scope_type:r(t.scope_type),scope_id:r(t.scope_id),title:r(t.title),detail:r(t.detail),timestamp:r(t.timestamp)}:null}function ur(t){const e=u(t)?t:{},n=u(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:c(n.total),bad:c(n.bad),warn:c(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(up).filter(s=>s!==null):[]}}function pr(t){if(!u(t))return null;const e=r(t.event_id),n=r(t.trace_id),s=r(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:r(t.operation_id)??null,unit_id:r(t.unit_id)??null,actor:r(t.actor)??null,source:r(t.source),timestamp:r(t.timestamp),detail:t.detail}}function pp(t){const e=u(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),events:Array.isArray(e.events)?e.events.map(pr).filter(n=>n!==null):[]}}function mp(t){if(!u(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function vp(t){if(!u(t))return null;const e=r(t.lane_id),n=r(t.label),s=r(t.kind),a=r(t.phase),o=r(t.motion_state),l=r(t.source_of_truth),d=r(t.movement_reason),v=r(t.current_step);if(!e||!n||!s||!a||!o||!l||!d||!v)return null;const _=u(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:z(t.present)??!1,phase:a,motion_state:o,source_of_truth:l,last_movement_at:r(t.last_movement_at)??null,movement_reason:d,current_step:v,blockers:K(t.blockers),counts:{operations:c(_.operations),detachments:c(_.detachments),workers:c(_.workers),approvals:c(_.approvals),alerts:c(_.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(mp).filter(p=>p!==null):[]}}function _p(t){if(!u(t))return null;const e=r(t.event_id),n=r(t.lane_id),s=r(t.kind),a=r(t.timestamp),o=r(t.title),l=r(t.detail),d=r(t.tone),v=r(t.source);return!e||!n||!s||!a||!o||!l||!d||!v?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:o,detail:l,tone:d,source:v}}function fp(t){if(!u(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,lane_ids:K(t.lane_ids),count:c(t.count)??0}}function mr(t){if(!u(t))return;const e=u(t.overview)?t.overview:{},n=u(t.gaps)?t.gaps:{},s=u(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:r(t.generated_at),overview:{active_lanes:c(e.active_lanes),moving_lanes:c(e.moving_lanes),stalled_lanes:c(e.stalled_lanes),projected_lanes:c(e.projected_lanes),last_movement_at:r(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(vp).filter(a=>a!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(_p).filter(a=>a!==null):[],gaps:{count:c(n.count),items:Array.isArray(n.items)?n.items.map(fp).filter(a=>a!==null):[]},recommended_next_action:s?{tool:r(s.tool)??"masc_operator_snapshot",label:r(s.label)??"Observe operator state",reason:r(s.reason)??"",lane_id:r(s.lane_id)??null}:void 0}}function gp(t){if(!u(t))return;const e=u(t.workers)?t.workers:{},n=z(t.pass);return{status:r(t.status)??"missing",source:r(t.source)??"none",run_id:r(t.run_id)??null,captured_at:r(t.captured_at)??null,...n!==void 0?{pass:n}:{},...c(t.peak_hot_slots)!=null?{peak_hot_slots:c(t.peak_hot_slots)}:{},...c(t.ctx_per_slot)!=null?{ctx_per_slot:c(t.ctx_per_slot)}:{},workers:{expected:c(e.expected),joined:c(e.joined),current_task_bound:c(e.current_task_bound),fresh_heartbeats:c(e.fresh_heartbeats),done:c(e.done),final:c(e.final)},artifact_ref:r(t.artifact_ref)??null,missing_reason:r(t.missing_reason)??null}}function $p(t){const e=u(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),topology:or(e.topology),operations:rr(e.operations),detachments:cr(e.detachments),alerts:ur(e.alerts),decisions:dr(e.decisions),capacity:dp(e.capacity),traces:pp(e.traces),swarm_status:mr(e.swarm_status)}}function hp(t){const e=u(t)?t:{},n=or(e.topology),s=rr(e.operations),a=cr(e.detachments),o=ur(e.alerts),l=dr(e.decisions);return{version:r(e.version),generated_at:r(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:mr(e.swarm_status),swarm_proof:gp(e.swarm_proof)}}function yp(t){return u(t)?{chain_id:r(t.chain_id)??null,started_at:c(t.started_at)??null,progress:c(t.progress)??null,elapsed_sec:c(t.elapsed_sec)??null}:null}function vr(t){if(!u(t))return null;const e=r(t.event);return e?{event:e,chain_id:r(t.chain_id)??null,timestamp:r(t.timestamp)??null,duration_ms:c(t.duration_ms)??null,message:r(t.message)??null,tokens:c(t.tokens)??null}:null}function bp(t){if(!u(t))return null;const e=Js(t.operation);return e?{operation:e,runtime:yp(t.runtime),history:vr(t.history),mermaid:r(t.mermaid)??null,preview_run:_r(t.preview_run)}:null}function kp(t){const e=u(t)?t:{};return{status:r(e.status)??"disconnected",base_url:r(e.base_url)??null,message:r(e.message)??null}}function xp(t){const e=u(t)?t:{},n=u(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),connection:kp(e.connection),summary:n?{linked_operations:c(n.linked_operations),active_chains:c(n.active_chains),running_operations:c(n.running_operations),recent_failures:c(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(bp).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(vr).filter(s=>s!==null):[]}}function Sp(t){if(!u(t))return null;const e=r(t.id);return e?{id:e,type:r(t.type),status:r(t.status),duration_ms:c(t.duration_ms)??null,error:r(t.error)??null}:null}function _r(t){if(!u(t))return null;const e=r(t.run_id),n=r(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:c(t.duration_ms),success:z(t.success),mermaid:r(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(Sp).filter(s=>s!==null):[]}:null}function Cp(t){const e=u(t)?t:{};return{run:_r(e.run)}}function Ap(t){if(!u(t))return null;const e=r(t.title),n=r(t.path);return!e||!n?null:{title:e,path:n}}function wp(t){if(!u(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function Tp(t){if(!u(t))return null;const e=r(t.id),n=r(t.title),s=r(t.tool),a=r(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:K(t.success_signals),pitfalls:K(t.pitfalls)}}function Ip(t){if(!u(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary),a=r(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(Tp).filter(o=>o!==null):[]}}function Rp(t){if(!u(t))return null;const e=r(t.id),n=r(t.title),s=r(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:K(t.tools)}}function Pp(t){if(!u(t))return null;const e=r(t.id),n=r(t.title),s=r(t.symptom),a=r(t.why),o=r(t.fix_tool),l=r(t.fix_summary);return!e||!n||!s||!a||!o||!l?null:{id:e,title:n,symptom:s,why:a,fix_tool:o,fix_summary:l}}function Np(t){if(!u(t))return null;const e=r(t.id),n=r(t.title),s=r(t.path_id),a=r(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:K(t.notes)}}function Lp(t){const e=u(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(Ap).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(wp).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(Ip).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Rp).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Pp).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Np).filter(n=>n!==null):[]}}function Mp(t){if(!u(t))return null;const e=r(t.id),n=r(t.title),s=r(t.status),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{id:e,title:n,status:s,detail:a,next_tool:o}}function Dp(t){if(!u(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.title),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{code:e,severity:n,title:s,detail:a,next_tool:o}}function zp(t){if(!u(t))return null;const e=r(t.from),n=r(t.content),s=r(t.timestamp),a=c(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function Ep(t){if(!u(t))return null;const e=r(t.name),n=r(t.role),s=r(t.lane),a=r(t.status),o=r(t.claim_marker),l=r(t.done_marker),d=r(t.final_marker);if(!e||!n||!s||!a||!o||!l||!d)return null;const v=(()=>{if(!u(t.last_message))return null;const _=c(t.last_message.seq),p=r(t.last_message.content),m=r(t.last_message.timestamp);return _==null||!p||!m?null:{seq:_,content:p,timestamp:m}})();return{name:e,role:n,lane:s,joined:z(t.joined)??!1,live_presence:z(t.live_presence)??!1,completed:z(t.completed)??!1,status:a,current_task:r(t.current_task)??null,bound_task_id:r(t.bound_task_id)??null,bound_task_title:r(t.bound_task_title)??null,bound_task_status:r(t.bound_task_status)??null,current_task_matches_run:z(t.current_task_matches_run)??!1,squad_member:z(t.squad_member)??!1,detachment_member:z(t.detachment_member)??!1,last_seen:r(t.last_seen)??null,heartbeat_age_sec:c(t.heartbeat_age_sec)??null,heartbeat_fresh:z(t.heartbeat_fresh)??!1,claim_marker_seen:z(t.claim_marker_seen)??!1,done_marker_seen:z(t.done_marker_seen)??!1,final_marker_seen:z(t.final_marker_seen)??!1,claim_marker:o,done_marker:l,final_marker:d,last_message:v}}function jp(t){if(!u(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!u(n))return null;const s=r(n.timestamp),a=c(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:r(t.slot_url)??null,provider_base_url:r(t.provider_base_url)??null,provider_reachable:z(t.provider_reachable)??null,provider_status_code:c(t.provider_status_code)??null,provider_model_id:r(t.provider_model_id)??null,actual_model_id:r(t.actual_model_id)??null,expected_slots:c(t.expected_slots),actual_slots:c(t.actual_slots),expected_ctx:c(t.expected_ctx),actual_ctx:c(t.actual_ctx),slot_reachable:z(t.slot_reachable)??null,slot_status_code:c(t.slot_status_code)??null,runtime_blocker:r(t.runtime_blocker)??null,detail:r(t.detail)??null,checked_at:r(t.checked_at)??null,total_slots:c(t.total_slots),ctx_per_slot:c(t.ctx_per_slot),active_slots_now:c(t.active_slots_now),peak_active_slots:c(t.peak_active_slots),sample_count:c(t.sample_count),last_sample_at:r(t.last_sample_at)??null,timeline:e}}function Op(t){const e=u(t)?t:{},n=u(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),run_id:r(e.run_id),room_id:r(e.room_id),operation_id:r(e.operation_id)??null,recommended_next_tool:r(e.recommended_next_tool),summary:n?{expected_workers:c(n.expected_workers),joined_workers:c(n.joined_workers),live_workers:c(n.live_workers),squad_roster_size:c(n.squad_roster_size),detachment_roster_size:c(n.detachment_roster_size),current_task_bound:c(n.current_task_bound),fresh_heartbeats:c(n.fresh_heartbeats),claim_markers_seen:c(n.claim_markers_seen),done_markers_seen:c(n.done_markers_seen),final_markers_seen:c(n.final_markers_seen),completed_workers:c(n.completed_workers),peak_hot_slots:c(n.peak_hot_slots),hot_window_ok:z(n.hot_window_ok),pass_hot_concurrency:z(n.pass_hot_concurrency),pass_end_to_end:z(n.pass_end_to_end),pending_decisions:c(n.pending_decisions),pass:z(n.pass)}:void 0,provider:jp(e.provider),operation:Js(e.operation),squad:vi(e.squad),detachment:lr(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Ep).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Mp).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Dp).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(zp).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(pr).filter(s=>s!==null):[],truth_notes:K(e.truth_notes)}}function de(t){q.value=t,mi(t)&&Fp()}async function fr(){xs.value=!0,Cs.value=null;try{const t=await Il();pi.value=hp(t)}catch(t){Cs.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{xs.value=!1}}function _i(t){Re.value=t}async function fi(){Ss.value=!0,As.value=null;try{const t=await Tl();Pt.value=$p(t)}catch(t){As.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{Ss.value=!1}}async function Fp(){Pt.value||Ss.value||await fi()}async function Wt(){await fr(),mi(q.value)&&await fi()}async function Bt(){var t;Ha.value=!0,Ps.value=null;try{const e=await Rl(),n=xp(e);Dn.value=n;const s=Re.value;n.operations.length===0?Re.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Re.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Ps.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{Ha.value=!1}}function qp(){Qe=null,yn.value=null,Ns.value=!1,bn.value=null}async function Kp(t){Qe=t,Ns.value=!0,bn.value=null;try{const e=await Pl(t);if(Qe!==t)return;yn.value=Cp(e)}catch(e){if(Qe!==t)return;yn.value=null,bn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{Qe===t&&(Ns.value=!1)}}async function Up(){Ua.value=!0,Ts.value=null;try{const t=await Nl();Mn.value=Lp(t)}catch(t){Ts.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Ua.value=!1}}async function xt(t=Zu(),e=tp()){Is.value=!0,Rs.value=null;try{const n=await Ll(t,e);me.value=Op(n)}catch(n){Rs.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{Is.value=!1}}async function Zt(t,e,n){Ka.value=t,ws.value=null;try{await Ml(e,n),await fr(),(Pt.value||mi(q.value))&&await fi(),await xt(),await Bt()}catch(s){throw ws.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{Ka.value=null}}function Hp(t){return Zt(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Wp(t){return Zt(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function Bp(t){return Zt(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Gp(t={}){return Zt("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function Jp(t){return Zt(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Vp(t){return Zt(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Yp(t,e){return Zt(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Qp(t,e){return Zt(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}ld(()=>{Wt(),Bt(),(q.value==="swarm"||q.value==="warroom"||me.value!==null)&&xt(),q.value==="warroom"&&tt()});const Xp="modulepreload",Zp=function(t){return"/dashboard/"+t},qi={},tm=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(_){return Promise.all(_.map(p=>Promise.resolve(p).then(m=>({status:"fulfilled",value:m}),m=>({status:"rejected",reason:m}))))};document.getElementsByTagName("link");const d=document.querySelector("meta[property=csp-nonce]"),v=(d==null?void 0:d.nonce)||(d==null?void 0:d.getAttribute("nonce"));a=l(n.map(_=>{if(_=Zp(_),_ in qi)return;qi[_]=!0;const p=_.endsWith(".css"),m=p?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${_}"]${m}`))return;const f=document.createElement("link");if(f.rel=p?"stylesheet":Xp,p||(f.as="script"),f.crossOrigin="",f.href=_,v&&f.setAttribute("nonce",v),document.head.appendChild(f),p)return new Promise((h,k)=>{f.addEventListener("load",h),f.addEventListener("error",()=>k(new Error(`Unable to preload CSS for ${_}`)))})}))}function o(l){const d=new Event("vite:preloadError",{cancelable:!0});if(d.payload=l,window.dispatchEvent(d),!d.defaultPrevented)throw l}return a.then(l=>{for(const d of l||[])d.status==="rejected"&&o(d.reason);return e().catch(o)})};function gr(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function G(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function em(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function $r(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function N(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let Ki=!1,nm=0;function sm(){return++nm}let na=null;async function am(){na||(na=tm(()=>import("./mermaid.core-DAsj0LvH.js").then(e=>e.bE),[]).then(e=>e.default));const t=await na;return Ki||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),Ki=!0),t}function Gt(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function zn(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function Xe(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function En(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function ie(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:En(t/e*100)}function im(t,e){const n=En(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function hr(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const om=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],yr=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],rm=yr.map(t=>t.id),lm=["chain_start","node_start","node_complete","chain_complete","chain_error"],cm={warroom:{title:"라이브 워룸",description:"실제 run, worker, message, trace를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function Ui(t){return!!t&&rm.includes(t)}function dm(){const t=D.value.params;return t.source!=="mission"?{}:{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function br(t){const e=dm();if(t==="operations")return e;if(t==="chains"){const n=Re.value;return n?{...e,surface:t,operation:n}:{...e,surface:t}}return{...e,surface:t}}function um(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function pm(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function et(t){return Ka.value===t}function jn(){return pi.value}function mm(t){var a,o,l,d,v,_,p;const e=pi.value,n=me.value,s=Dn.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"live run, worker, message, trace를 한 화면에서 보고 필요한 detail 표면으로 바로 점프합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(o=e==null?void 0:e.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((v=(d=e==null?void 0:e.swarm_status)==null?void 0:d.recommended_next_action)==null?void 0:v.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(p=(_=s==null?void 0:s.operations[0])==null?void 0:_.preview_run)!=null&&p.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function vm(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function _m(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function fm(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function kr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function gm(){const e=kr().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function xr(){const e=kr().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function $m(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function hm(t){return t.status==="claimed"||t.status==="in_progress"}function ym(t){const e=Mn.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function sa(t){var e;return((e=Mn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function bm(t){const e=Mn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function Jt(t){try{await t()}catch{}}function gi(t){return(t==null?void 0:t.trim().toLowerCase())??""}function xe(t){const e=gi(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function aa(t){const e=gi(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function km(){var e,n,s;const t=me.value;return t?!!(t.run_id||(e=t.operation)!=null&&e.operation_id||(n=t.detachment)!=null&&n.detachment_id||(((s=t.summary)==null?void 0:s.expected_workers)??0)>0||t.workers.length>0||t.recent_messages.length>0||t.recent_trace_events.length>0):!1}function xm(t){const e=gi(t.status);return e==="active"||e==="running"}function Sm(){var o,l,d,v;const t=((o=Tt.value)==null?void 0:o.sessions)??[],e=me.value,n=((l=e==null?void 0:e.detachment)==null?void 0:l.session_id)??null;if(n){const _=t.find(p=>p.session_id===n);if(_)return _}const s=((d=e==null?void 0:e.operation)==null?void 0:d.operation_id)??xr();if(s){const _=t.find(p=>p.command_plane_operation_id===s);if(_)return _}const a=((v=e==null?void 0:e.detachment)==null?void 0:v.detachment_id)??null;if(a){const _=t.find(p=>p.command_plane_detachment_id===a);if(_)return _}return t.find(xm)??t[0]??null}function Cm(){const t=Ln(D.value);return t?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${Bs(t.action_type)}</span>
        <span class="command-chip">${di(t)}</span>
        <span class="command-chip">${Lu(D.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?i`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function Am(){const t=q.value,e=cm[t],n=mm(t);return i`
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
  `}function Wn({label:t,value:e,subtext:n,percent:s,color:a}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${im(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(En(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function Bn({label:t,value:e,detail:n,percent:s,tone:a}){return i`
    <article class="command-signal-rail ${N(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${N(a)}" style=${`width: ${Math.max(8,Math.round(En(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function wm(){var E,J,F,Y;const t=jn(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,o=t==null?void 0:t.alerts.summary,l=(E=t==null?void 0:t.swarm_status)==null?void 0:E.overview,d=t==null?void 0:t.swarm_proof,v=t==null?void 0:t.operations.microarch,_=(e==null?void 0:e.managed_unit_count)??0,p=(e==null?void 0:e.total_units)??0,m=(n==null?void 0:n.active)??0,f=(s==null?void 0:s.active)??0,h=(l==null?void 0:l.moving_lanes)??0,k=(l==null?void 0:l.active_lanes)??0,x=(d==null?void 0:d.workers.done)??0,C=(d==null?void 0:d.workers.expected)??0,w=(o==null?void 0:o.bad)??0,A=(o==null?void 0:o.warn)??0,S=(a==null?void 0:a.pending)??0,I=(a==null?void 0:a.total)??0,R=m+f,W=((J=v==null?void 0:v.cache)==null?void 0:J.l1_hit_rate)??((Y=(F=v==null?void 0:v.signals)==null?void 0:F.cache_contention)==null?void 0:Y.l1_hit_rate)??0,U=m>0||f>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",$=m>0||h>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${U}</h3>
        <p>${$}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${N(m>0?"ok":"warn")}">활성 작전 ${m}</span>
          <span class="command-chip ${N(h>0?"ok":(k>0,"warn"))}">이동 레인 ${h}/${Math.max(k,h)}</span>
          <span class="command-chip ${N(w>0?"bad":A>0?"warn":"ok")}">치명 알림 ${w}</span>
          <span class="command-chip ${N(S>0?"warn":"ok")}">승인 대기 ${S}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${Wn}
          label="관리 단위 범위"
          value=${`${_}/${Math.max(p,_)}`}
          subtext=${p>0?`${p-_}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${ie(_,Math.max(p,_))}
          color="#67e8f9"
        />
        <${Wn}
          label="실행 열도"
          value=${String(R)}
          subtext=${`${m}개 작전 + ${f}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${ie(R,Math.max(_,R||1))}
          color="#4ade80"
        />
        <${Wn}
          label="스웜 이동감"
          value=${`${h}/${Math.max(k,h)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${G(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${ie(h,Math.max(k,h||1))}
          color="#fbbf24"
        />
        <${Wn}
          label="증거 수집률"
          value=${`${x}/${Math.max(C,x)}`}
          subtext=${d!=null&&d.status?`증거 소스 ${d.source} · ${d.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${ie(x,Math.max(C,x||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${Bn}
        label="승인 대기열"
        value=${`${S}건 대기`}
        detail=${`현재 정책 창에서 ${I}개 결정을 추적 중입니다`}
        percent=${ie(S,Math.max(I,S||1))}
        tone=${S>0?"warn":"ok"}
      />
      <${Bn}
        label="알림 압력"
        value=${`${w} bad / ${A} warn`}
        detail=${w>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${ie(w*2+A,Math.max((w+A)*2,1))}
        tone=${w>0?"bad":A>0?"warn":"ok"}
      />
      <${Bn}
        label="디스패치 점유"
          value=${`${f}개 가동`}
        detail=${_>0?`${_}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${ie(f,Math.max(_,f||1))}
        tone=${f>0?"ok":"warn"}
      />
      <${Bn}
        label="캐시 신뢰도"
        value=${W?zn(W):"n/a"}
        detail=${W?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${En((W??0)*100)}
        tone=${W>=.75?"ok":W>=.4?"warn":"bad"}
      />
    </div>
  `}function Tm(){var f,h,k,x,C;const t=jn(),e=Dn.value,n=Ln(D.value),s=vm(n),a=t==null?void 0:t.topology.summary,o=t==null?void 0:t.operations.summary,l=(f=t==null?void 0:t.swarm_status)==null?void 0:f.overview,d=t==null?void 0:t.operations.microarch,v=t==null?void 0:t.decisions.summary,_=t==null?void 0:t.alerts.summary,p=(h=d==null?void 0:d.signals)==null?void 0:h.issue_pressure,m=d==null?void 0:d.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((k=t==null?void 0:t.detachments.summary)==null?void 0:k.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(v==null?void 0:v.pending)??0}</strong><small>${(v==null?void 0:v.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(_==null?void 0:_.bad)??0}</strong><small>${(_==null?void 0:_.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((x=e==null?void 0:e.summary)==null?void 0:x.active_chains)??0}</strong><small>${((C=e==null?void 0:e.summary)==null?void 0:C.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${G(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(p==null?void 0:p.pending_ops)??0}</strong><small>${(m==null?void 0:m.l1_hit_rate)!=null?`${zn(m.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(p==null?void 0:p.tone)??"n/a"}</small></div>
    </div>
  `}function Im(){var E,J,F,Y,b,$t,Ot,te,ee;const t=jn(),e=Pt.value,n=pt.value,s=fm(),a=s?gt.value.find(M=>M.name===s)??null:null,o=s?Ct.value.filter(M=>M.assignee===s&&hm(M)):[],l=((E=t==null?void 0:t.operations.summary)==null?void 0:E.active)??0,d=((J=t==null?void 0:t.detachments.summary)==null?void 0:J.total)??0,v=((F=t==null?void 0:t.decisions.summary)==null?void 0:F.pending)??0,_=e==null?void 0:e.detachments.detachments.find(M=>{const ht=M.detachment.heartbeat_deadline,ne=ht?Date.parse(ht):Number.NaN;return M.detachment.status==="stalled"||!Number.isNaN(ne)&&ne<=Date.now()}),p=e==null?void 0:e.alerts.alerts.find(M=>M.severity==="bad"),m=!!(n!=null&&n.room||n!=null&&n.project),f=(a==null?void 0:a.current_task)??null,h=$m(a==null?void 0:a.last_seen),k=h!=null?h<=120:null,x=[m?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:Ct.value.length>0?"masc_claim":"masc_add_task"}:f?k===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${f} 이지만 heartbeat가 stale 합니다 (${h}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${f}${h!=null?` · 마지막 활동 ${h}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((Y=t.topology.summary)==null?void 0:Y.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((b=t.topology.summary)==null?void 0:b.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${(($t=t.topology.summary)==null?void 0:$t.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},v>0?{title:"디스패치 준비도",tone:"warn",detail:`${v}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&d===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:_||p?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${_?` · detachment ${_.detachment.detachment_id} 가 stalled 상태입니다`:""}${p?` · alert ${p.title??p.alert_id}`:""}${!e&&!_&&!p?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:v>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${d}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],C=m?!s||!a?"masc_join":o.length===0?Ct.value.length>0?"masc_claim":"masc_add_task":f?k===!1?"masc_heartbeat":!t||(((Ot=t.topology.summary)==null?void 0:Ot.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":v>0?"masc_policy_approve":l>0&&d===0||_||p?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",w=ym(C),S=bm(C==="masc_set_room"?["repo-root-room"]:C==="masc_plan_set_task"?["claimed-not-current"]:C==="masc_heartbeat"?["heartbeat-stale"]:C==="masc_dispatch_tick"?["no-detachments"]:C==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),I=sa("room_task_hygiene"),R=sa("cpv2_benchmark"),W=sa("supervisor_session"),U=((te=Mn.value)==null?void 0:te.docs)??[],$=[I,R,W].filter(M=>M!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${L} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(w==null?void 0:w.title)??C}</strong>
            <span class="command-chip ok">${C}</span>
          </div>
          <p>${(w==null?void 0:w.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(ee=w==null?void 0:w.success_signals)!=null&&ee.length?i`<div class="command-tag-row">
                ${w.success_signals.map(M=>i`<span class="command-tag ok">${M}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${x.map(M=>i`
            <article class="command-readiness-row ${N(M.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${M.title}</strong>
                  <span class="command-chip ${N(M.tone)}">${M.tone}</span>
                </div>
                <p>${M.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${M.tool}</div>
            </article>
          `)}
        </div>

        ${S.length>0?i`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${S.length}</span>
                </div>
                <div class="command-guide-list">
                  ${S.map(M=>i`
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
        ${Ua.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:Ts.value?i`<div class="empty-state error">${Ts.value}</div>`:i`
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
                        ${M.steps.slice(0,4).map(ht=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${ht.tool}</span>
                            <span>${ht.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${U.length>0?i`<div class="command-doc-links">
                      ${U.map(M=>i`<span class="command-tag">${M.title}: ${M.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Rm(){return i`
    <${wm} />
    <${Tm} />
    <${Im} />
  `}function Pm(){return Ss.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:As.value?i`<div class="empty-state error">${As.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function Sr({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,o=t.unit.policy;return i`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${pm(t.unit.kind)}</span>
            <span class="command-chip ${N(t.health)}">${t.health??"ok"}</span>
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
            ${t.children.map(l=>i`<${Sr} node=${l} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function Nm({alert:t}){return i`
    <article class="command-alert ${N(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${N(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${G(t.timestamp)}</span>
      </div>
      ${t.detail?i`<p>${t.detail}</p>`:null}
    </article>
  `}function $i({event:t}){return i`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${G(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${gr(t.detail)}</pre>
    </article>
  `}function Lm(){const t=Pt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${L} panelId="command.topology" compact=${!0} />
      </div>
      ${t&&t.topology.units.length>0?i`${t.topology.units.map(e=>i`<${Sr} node=${e} />`)}`:i`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function Mm(){const t=Pt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${L} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>i`<${Nm} alert=${e} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function Dm(){const t=Pt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${L} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?i`<div class="command-trace-stack">
            ${t.traces.events.map(e=>i`<${$i} event=${e} />`)}
          </div>`:i`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function Cr(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function Ar({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const o=a.motion_state;o in e?e[o]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return i`
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
  `}function zm({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${a.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?i`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function Em({lane:t}){const e=t.counts??{},n=Cr(t),s=e.workers??0,a=e.operations??0,o=e.detachments??0,l=a+o,d=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return i`
    <article class="swarm-lane-strip ${N(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${N(n)}">${t.phase}</span>
          <span class="command-chip ${N(n)}">${t.motion_state}</span>
          <span class="command-chip">${G(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${N(n)}" style=${`width:${d}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${s>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${zm} total=${s} />
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
              ${t.hard_flags.map(v=>i`<span class="command-chip ${N(v.severity)}">${v.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function wr({lanes:t}){const e=t.slice(0,4);return e.length===0?null:i`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=Cr(n),a=n.counts.workers??0,o=n.counts.operations??0,l=n.counts.detachments??0;return i`
          <article class="swarm-story-card ${N(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${N(s)}">${n.motion_state}</span>
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
  `}function jm({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${N(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?i`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function Om({gap:t}){return i`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${N(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function Fm({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${N(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${N(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?i`
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${G(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.artifact_ref?i`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?i`<p>${t.missing_reason}</p>`:null}
          `:i`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function qm(){const t=jn(),e=Ln(D.value),n=_m(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,o=(s==null?void 0:s.lanes.filter(m=>m.present))??[],l=(s==null?void 0:s.gaps.items)??[],d=(s==null?void 0:s.timeline.slice(0,8))??[],v=s==null?void 0:s.overview,_=s==null?void 0:s.recommended_next_action,p=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${L} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${wr} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(v==null?void 0:v.active_lanes)??0}</strong><small>${(v==null?void 0:v.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(v==null?void 0:v.stalled_lanes)??0}</strong><small>${(v==null?void 0:v.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${G(v==null?void 0:v.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${G(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(_==null?void 0:_.label)??"운영자 상태 확인"}</strong><small>${(_==null?void 0:_.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${Ar} lanes=${o} />`:null}

            <div class="command-swarm-layout ${p?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(m=>i`<${Em} lane=${m} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${Fm} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${N(l.some(m=>m.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?i`<div class="swarm-event-rail">${l.slice(0,4).map(m=>i`<${Om} gap=${m} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${d.length}</span>
                  </div>
                  ${d.length>0?i`<div class="swarm-event-rail">${d.map(m=>i`<${jm} event=${m} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function Km({item:t}){return i`
    <article class="command-guide-card ${N(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${N(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Tr({blocker:t}){return i`
    <article class="command-alert ${N(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${N(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function Um({worker:t}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${N(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${t.last_message?i`<div class="command-card-foot">${G(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function Hm(){var v,_,p,m,f,h,k,x,C,w,A,S,I,R,W,U,$,E,J,F,Y;const t=me.value,e=gm(),n=xr(),s=(v=t==null?void 0:t.provider)!=null&&v.runtime_blocker?"blocked":(_=t==null?void 0:t.provider)!=null&&_.provider_reachable?"ready":"check",a=((p=t==null?void 0:t.provider)==null?void 0:p.actual_slots)??((m=t==null?void 0:t.provider)==null?void 0:m.total_slots)??0,o=((f=t==null?void 0:t.provider)==null?void 0:f.expected_slots)??"n/a",l=((h=t==null?void 0:t.provider)==null?void 0:h.actual_ctx)??((k=t==null?void 0:t.provider)==null?void 0:k.ctx_per_slot)??0,d=((x=t==null?void 0:t.provider)==null?void 0:x.expected_ctx)??"n/a";return i`
    <div class="command-section-stack">
      <${qm} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${L} panelId="command.swarm" compact=${!0} />
          </div>
          ${Is.value?i`<div class="empty-state">Loading swarm live state…</div>`:Rs.value?i`<div class="empty-state error">${Rs.value}</div>`:t?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((C=t.summary)==null?void 0:C.joined_workers)??0}/${((w=t.summary)==null?void 0:w.expected_workers)??0}</strong><small>${((A=t.summary)==null?void 0:A.live_workers)??0}개 가동 · ${((S=t.summary)==null?void 0:S.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${o} · ctx ${l}/${d}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(I=t.summary)!=null&&I.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((R=t.provider)==null?void 0:R.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(W=t.summary)!=null&&W.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((U=t.operation)==null?void 0:U.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${(($=t.squad)==null?void 0:$.label)??"없음"}</span>
                      <span>실행체</span><span>${((E=t.detachment)==null?void 0:E.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((J=t.summary)==null?void 0:J.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((F=t.summary)==null?void 0:F.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((Y=t.provider)==null?void 0:Y.runtime_blocker)??"없음"}</span>
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
                ${t.checklist.map(b=>i`<${Km} item=${b} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${L} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?i`<div class="command-card-stack">
                ${t.workers.map(b=>i`<${Um} worker=${b} />`)}
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
                  <span>Last Sample</span><span>${t.provider.last_sample_at?G(t.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${t.provider.checked_at?G(t.provider.checked_at):"n/a"}</span>
                </div>
                ${t.provider.detail?i`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?i`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(b=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${b.active_slots} active</strong>
                              <span class="command-chip">${G(b.timestamp)}</span>
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
                ${t.blockers.map(b=>i`<${Tr} blocker=${b} />`)}
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
                        <span class="command-chip">${G(b.timestamp)}</span>
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
                ${t.recent_trace_events.map(b=>i`<${$i} event=${b} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function Wm(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"none",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}s`:t.heartbeat_fresh?"clean":"n/a",detail:[t.bound_task_status??null,t.detachment_member?"detachment":null,t.squad_member?"squad":null].filter(Boolean).join(" · ")||"live swarm worker",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function Bm(t,e){const n=t.actor??t.spawn_role??`worker-${e+1}`,s=t.spawn_role??t.worker_class??t.spawn_agent??"worker",a=t.lane_id??t.capsule_mode??t.control_domain??"session",o=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:s,lane:a,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"session lane",heartbeat:t.last_turn_ts_iso?G(t.last_turn_ts_iso):"n/a",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?zn(t.routing_confidence):null].filter(Boolean).join(" · ")||"session worker",markers:o,note:t.routing_reason??null}}function Hi(t){return N(t.severity)}function Gm({worker:t}){return i`
    <article class="command-card compact warroom-worker-card ${N(xe(t.status))}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${N(xe(t.status))}">${t.status}</span>
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
      onClick=${()=>{if(e){de(e),rt("command",{...br(e),...n});return}rt("intervene")}}
    >
      ${t}
    </button>
  `}function Jm(){var U,$,E,J,F,Y,b,$t,Ot,te,ee,M,ht,ne,He,We,On,Fn,qn,Kn;const t=jn(),e=me.value,n=Tt.value,s=It.value,a=Sm(),o=e!=null&&e.operation?((U=Dn.value)==null?void 0:U.operations.find(O=>{var _e;return O.operation.operation_id===((_e=e.operation)==null?void 0:_e.operation_id)}))??null:null,l=(e==null?void 0:e.workers)??[],d=(s==null?void 0:s.worker_cards)??[],v=l.length>0?l.map(Wm):d.map(Bm),_=km(),p=(($=t==null?void 0:t.decisions.summary)==null?void 0:$.pending)??0,m=(n==null?void 0:n.pending_confirms)??[],f=(e==null?void 0:e.blockers)??[],h=(s==null?void 0:s.recommended_actions)??[],k=(s==null?void 0:s.attention_items)??[],x=((E=e==null?void 0:e.recent_messages[0])==null?void 0:E.timestamp)??null,C=((J=e==null?void 0:e.recent_trace_events[0])==null?void 0:J.timestamp)??null,w=x??C??null,A=a==null?void 0:a.summary,S=((F=e==null?void 0:e.summary)==null?void 0:F.expected_workers)??(typeof(A==null?void 0:A.planned_worker_count)=="number"?A.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,I=((Y=e==null?void 0:e.summary)==null?void 0:Y.joined_workers)??(typeof(A==null?void 0:A.active_agent_count)=="number"?A.active_agent_count:void 0)??v.length,R=f.length>0||p>0||m.length>0?"warn":_||a?"ok":"warn",W=((b=t==null?void 0:t.swarm_status)==null?void 0:b.lanes.filter(O=>O.present))??[];return Z(()=>{tt()},[]),Z(()=>{a!=null&&a.session_id&&je(a.session_id)},[a==null?void 0:a.session_id,n,($t=e==null?void 0:e.detachment)==null?void 0:$t.session_id]),!_&&!a?Is.value||$n.value?i`<div class="empty-state">live war room 불러오는 중…</div>`:i`
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
      <section class="command-warroom-strip ${N(R)}">
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
            <strong>${I??0}/${S??0}</strong>
            <small>${((ht=e==null?void 0:e.summary)==null?void 0:ht.completed_workers)??0} 완료 · ${v.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>Runtime</span>
            <strong>${(ne=e==null?void 0:e.provider)!=null&&ne.runtime_blocker?"blocked":(He=e==null?void 0:e.provider)!=null&&He.provider_reachable?"ready":a?aa(a.status):"check"}</strong>
            <small>slots ${((We=e==null?void 0:e.provider)==null?void 0:We.active_slots_now)??0}/${((On=e==null?void 0:e.provider)==null?void 0:On.actual_slots)??((Fn=e==null?void 0:e.provider)==null?void 0:Fn.total_slots)??0} · ctx ${((qn=e==null?void 0:e.provider)==null?void 0:qn.actual_ctx)??((Kn=e==null?void 0:e.provider)==null?void 0:Kn.ctx_per_slot)??0}</small>
          </div>
          <div class="monitor-stat-card ${N(f.length>0||p>0?"warn":"ok")}">
            <span>Pressure</span>
            <strong>${f.length+p+m.length}</strong>
            <small>blockers ${f.length} · approvals ${p} · confirms ${m.length}</small>
          </div>
          <div class="monitor-stat-card">
            <span>Last signal</span>
            <strong>${G(w)}</strong>
            <small>${x?"message":C?"trace":"waiting"}</small>
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
            ${W.length>0?i`
                  <${wr} lanes=${W} />
                  <${Ar} lanes=${W} />
                `:a?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${N(xe(a.status))}">${aa(a.status)}</span>
                      </div>
                      <p>command-plane live run은 아직 옅지만, session 쪽 worker와 digest를 기준으로 워룸을 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${Xe(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${Xe(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:i`<div class="empty-state">보이는 lane이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Worker Roster</div>
              <${L} panelId="command.warroom" compact=${!0} />
            </div>
            ${v.length>0?i`<div class="command-card-stack">
                  ${v.map(O=>i`<${Gm} worker=${O} />`)}
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
                  ${e.recent_messages.map(O=>i`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${O.from}</strong>
                          <span class="command-chip">${G(O.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${O.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${O.content}</pre>
                    </article>
                  `)}
                </div>`:h.length>0||k.length>0?i`<div class="command-card-stack">
                    ${h.slice(0,4).map(O=>i`
                      <article class="command-guide-card ${Hi(O)}">
                        <div class="command-guide-head">
                          <strong>${O.action_type}</strong>
                          <span class="command-chip ${Hi(O)}">${O.target_type}</span>
                        </div>
                        <p>${O.reason}</p>
                      </article>
                    `)}
                    ${k.slice(0,3).map(O=>i`
                      <article class="command-alert ${N(O.severity)}">
                        <div class="command-card-head">
                          <strong>${O.kind}</strong>
                          <span class="command-chip ${N(O.severity)}">${O.severity}</span>
                        </div>
                        <p>${O.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?i`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((O,_e)=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>session-event-${_e+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${gr(O)}</pre>
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
                  ${e.recent_trace_events.map(O=>i`<${$i} event=${O} />`)}
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
              ${f.length>0?f.map(O=>i`<${Tr} blocker=${O} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${p>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending approvals</strong>
                        <span class="command-chip warn">${p}</span>
                      </div>
                      <p>strict action이 묶여 있습니다. 실제 승인 처리는 control 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${m.length>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending confirms</strong>
                        <span class="command-chip warn">${m.length}</span>
                      </div>
                      <p>operator preview가 사람 확인을 기다리고 있습니다.</p>
                      <div class="command-tag-row">
                        ${m.slice(0,3).map(O=>i`<span class="command-tag">${O.confirm_token}</span>`)}
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
                        <span class="command-chip ${N(xe(e.operation.status))}">${e.operation.status}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Unit</span><span>${e.operation.assigned_unit_id}</span>
                        <span>Trace</span><span>${e.operation.trace_id}</span>
                        <span>Autonomy</span><span>${e.operation.autonomy_level??"n/a"}</span>
                        <span>Updated</span><span>${G(e.operation.updated_at)}</span>
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
                        <span class="command-chip ${N(xe(e.detachment.status))}">${e.detachment.status??"active"}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Leader</span><span>${e.detachment.leader_id??"unassigned"}</span>
                        <span>Roster</span><span>${e.detachment.roster.length}</span>
                        <span>Session</span><span>${e.detachment.session_id??"none"}</span>
                        <span>Heartbeat</span><span>${$r(e.detachment.heartbeat_deadline)}</span>
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
                        <span class="command-chip ${N(xe(a.status))}">${aa(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${Xe(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${Xe(a.remaining_sec)}</span>
                        <span>Done delta</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function Vm({source:t}){const e=Vr(null),[n,s]=lo(null);return Z(()=>{let a=!1;const o=e.current;return o?(o.innerHTML="",s(null),(async()=>{try{const d=await am(),{svg:v}=await d.render(`command-chain-${sm()}`,t);if(a||!e.current)return;e.current.innerHTML=v}catch(d){if(a)return;s(d instanceof Error?d.message:"Mermaid render failed")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function Ym({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return i`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${Gt(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?i`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?i`<span class="command-tag ${Gt(s==null?void 0:s.status)}">${zn(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${hr(t.history)}</div>
    </button>
  `}function Qm({item:t}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${Gt(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${G(t.timestamp)}</div>
      <div class="command-card-sub">${hr(t)}</div>
    </article>
  `}function Xm({node:t}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${Gt(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?i`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function Zm({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,o=e.chain,l=(o==null?void 0:o.run_id)??null;return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${N(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Autonomy</span><span>${e.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${e.budget_class??"standard"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Updated</span><span>${G(e.updated_at)}</span>
      </div>
      ${o?i`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${Gt(o.status)}">${o.status}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">run ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?i`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{de("swarm"),rt("command",{surface:"swarm",operation_id:e.operation_id,...l?{run_id:l}:{}})}}
        >
          Swarm Live
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{_i(e.operation_id),de("chains"),rt("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?i`
              <button class="control-btn ghost" disabled=${et(n)} onClick=${()=>Jt(()=>Hp(e.operation_id))}>
                ${et(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${et(a)} onClick=${()=>Jt(()=>Bp(e.operation_id))}>
                ${et(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?i`
              <button class="control-btn ghost" disabled=${et(s)} onClick=${()=>Jt(()=>Wp(e.operation_id))}>
                ${et(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function tv({card:t}){var n;const e=t.detachment;return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${N(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${G(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${$r(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${G(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?i`<span class="command-tag ${em(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function ev(){const t=Pt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${L} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?i`<div class="command-card-stack">
              ${t.operations.operations.map(e=>i`<${Zm} card=${e} />`)}
            </div>`:i`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${L} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>i`<${tv} card=${e} />`)}
            </div>`:i`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function nv(){var d,v,_,p,m,f,h,k,x,C,w,A,S,I,R,W;const t=Dn.value,e=(t==null?void 0:t.operations)??[],n=Re.value,s=e.find(U=>U.operation.operation_id===n)??e[0]??null,a=((d=s==null?void 0:s.operation.chain)==null?void 0:d.run_id)??null,o=((v=yn.value)==null?void 0:v.run)??(s==null?void 0:s.preview_run)??null,l=!((_=yn.value)!=null&&_.run)&&!!(s!=null&&s.preview_run);return Z(()=>{a?Kp(a):qp()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${L} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${Gt(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${Gt(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(t==null?void 0:t.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((p=t==null?void 0:t.summary)==null?void 0:p.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((m=t==null?void 0:t.summary)==null?void 0:m.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((f=t==null?void 0:t.summary)==null?void 0:f.recent_failures)??0}</span>
            <span>Last Event</span><span>${G((h=t==null?void 0:t.summary)==null?void 0:h.last_history_event_at)}</span>
          </div>
        </article>

        ${Ps.value?i`<div class="empty-state error">${Ps.value}</div>`:null}

        ${Ha.value&&!t?i`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?i`
                <div class="command-chain-list">
                  ${e.map(U=>i`
                    <${Ym}
                      overlay=${U}
                      selected=${(s==null?void 0:s.operation.operation_id)===U.operation.operation_id}
                      onSelect=${()=>_i(U.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(U=>i`<${Qm} item=${U} />`)}
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
                  <span class="command-chip ${Gt((k=s.operation.chain)==null?void 0:k.status)}">
                    ${((x=s.operation.chain)==null?void 0:x.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((C=s.operation.chain)==null?void 0:C.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((w=s.operation.chain)==null?void 0:w.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${zn((A=s.runtime)==null?void 0:A.progress)}</span>
                  <span>Elapsed</span><span>${Xe((S=s.runtime)==null?void 0:S.elapsed_sec)}</span>
                  <span>Updated</span><span>${G(((I=s.operation.chain)==null?void 0:I.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(R=s.operation.chain)!=null&&R.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((W=s.operation.chain)==null?void 0:W.chain_id)??"graph"}</span>
                      </div>
                      <${Vm} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"failed":l?"preview":"captured":"pending"}
                  </span>
                </div>
                ${Ns.value?i`<div class="empty-state">Loading run detail…</div>`:bn.value?i`<div class="empty-state error">${bn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${o.chain_id}</span>
                            <span>Run</span><span>${o.run_id??"preview only"}</span>
                            <span>Duration</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${o.nodes.length}</span>
                          </div>
                          ${l?i`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(U=>i`<${Xm} node=${U} />`)}
                          </div>
                        `:i`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:i`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function sv({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return i`
    <article class="command-card ${N(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${N(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${G(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!s?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${et(e)} onClick=${()=>Jt(()=>Jp(t.decision_id))}>
                ${et(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${et(n)} onClick=${()=>Jt(()=>Vp(t.decision_id))}>
                ${et(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function av({row:t}){var d,v,_;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((d=e.policy)!=null&&d.frozen),o=!!((v=e.policy)!=null&&v.kill_switch),l=Math.round((t.utilization??0)*100);return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${N(l>100?"bad":l>70?"warn":"ok")}">${l}%</span>
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
        <button class="control-btn ghost" disabled=${et(n)} onClick=${()=>Jt(()=>Yp(e.unit_id,!a))}>
          ${et(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${et(s)} onClick=${()=>Jt(()=>Qp(e.unit_id,!o))}>
          ${et(s)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function iv(){const t=Pt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${L} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>i`<${sv} decision=${e} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${L} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>i`<${av} row=${e} />`)}
            </div>`:i`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function ov(){return i`
    <div class="command-surface-tabs grouped">
      ${om.map(t=>i`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${yr.filter(e=>e.group===t.id).map(e=>i`
                <button
                  class="command-surface-tab ${q.value===e.id?"active":""}"
                  onClick=${()=>{de(e.id),rt("command",br(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function rv(){if(q.value==="warroom")return i`<${Jm} />`;if(q.value==="summary")return i`<${Rm} />`;if(q.value==="swarm")return i`<${Hm} />`;if(!Pt.value)return i`<${Pm} />`;switch(q.value){case"chains":return i`<${nv} />`;case"topology":return i`<${Lm} />`;case"alerts":return i`<${Mm} />`;case"trace":return i`<${Dm} />`;case"control":return i`<${iv} />`;case"operations":default:return i`<${ev} />`}}function lv(){return Z(()=>{Wt(),Bt(),Up(),xt()},[]),Z(()=>{if(D.value.tab!=="command")return;const t=D.value.params.surface,e=D.value.params.operation,n=Ln(D.value);if(Ui(t))de(t);else if(n){const s=Yo(n);Ui(s)&&de(s)}else t||de("warroom");e&&_i(e),(t==="swarm"||t==="warroom"||q.value==="warroom")&&xt(),(t==="warroom"||q.value==="warroom")&&tt()},[D.value.tab,D.value.params.surface,D.value.params.operation,D.value.params.operation_id,D.value.params.run_id,D.value.params.source,D.value.params.action_type,D.value.params.target_type,D.value.params.target_id,D.value.params.focus_kind]),Z(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,Wt(),Bt(),(q.value==="swarm"||q.value==="warroom")&&xt(),q.value==="warroom"&&tt()},250))},n=new EventSource(um()),s=lm.map(a=>{const o=()=>e();return n.addEventListener(a,o),{type:a,handler:o}});return n.onerror=()=>{e()},()=>{s.forEach(({type:a,handler:o})=>{n.removeEventListener(a,o)}),n.close(),t&&window.clearTimeout(t)}},[]),Z(()=>{const t=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const e=q.value;e!=="swarm"&&e!=="warroom"||(Wt(),xt(),e==="warroom"&&tt())},5e3);return()=>{window.clearInterval(t)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Jt(()=>Gp())}}
            disabled=${et("dispatch:tick")}
          >
            ${et("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Wt(),Bt(),xt(),q.value==="warroom"&&tt()}}
            disabled=${xs.value}
          >
            ${xs.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Cs.value?i`<div class="empty-state error">${Cs.value}</div>`:null}
      ${ws.value?i`<div class="empty-state error">${ws.value}</div>`:null}
      <${mt} surfaceId="command" />
      <${Cm} />
      ${q.value==="warroom"?null:i`<${Am} />`}
      <${ov} />
      <${rv} />
    </section>
  `}const Ir="masc_dashboard_agent_name";function cv(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Ir))==null?void 0:s.trim())||"dashboard"}const Vs=g(cv()),Pe=g(""),Wa=g("운영 점검"),Ne=g(""),kn=g(""),xn=g("2"),Sn=g(""),St=g("note"),Cn=g(""),An=g(""),wn=g(""),Tn=g("2"),Ls=g("운영자 중지 요청"),Ms=g(""),Le=g(""),Gn=g(null);function dv(t){const e=t.trim()||"dashboard";Vs.value=e,localStorage.setItem(Ir,e)}function Wi(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function uv(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function Oe(t){return typeof t=="string"?t.trim().toLowerCase():""}function pv(t){var s;const e=Oe(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=Oe((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function ia(t){const e=Oe(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function Bi(t){return t.some(e=>Oe(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function mv(t){return t.target_type==="team_session"}function vv(t){return t.target_type==="keeper"}function Jn(t){switch(t){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";case"keeper_msg":return"keeper 메시지";default:return(t==null?void 0:t.trim())||"액션"}}function Vn(t){switch(t){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";default:return(t==null?void 0:t.trim())||"target"}}function Ve(t){switch(Oe(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Gi(t){return t?"확인 후 실행":"즉시 실행"}function _v(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";default:return t}}function ot(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function fv(t){if(t.action_type==="team_task_inject")return"task";if(t.action_type==="team_broadcast")return"broadcast";if(t.action_type==="team_note")return"note";if(t.action_type==="team_turn"){const e=ot(t.suggested_payload,"turn_kind");if(e==="broadcast"||e==="task")return e}return"note"}function gv(t){const e=t.suggested_payload;if(t.target_type==="room"){if(t.action_type==="broadcast"){Pe.value=ot(e,"message")??t.summary;return}t.action_type==="task_inject"&&(Ne.value=ot(e,"title")??"운영자 주입 작업",kn.value=ot(e,"description")??t.summary,xn.value=ot(e,"priority")??xn.value);return}if(t.target_type==="team_session"){if(t.target_id&&(Sn.value=t.target_id),t.action_type==="team_stop"){Ls.value=ot(e,"reason")??t.summary;return}St.value=fv(t);const n=ot(e,"message");n&&(Cn.value=n),St.value==="task"&&(An.value=ot(e,"task_title")??ot(e,"title")??"운영자 주입 작업",wn.value=ot(e,"task_description")??ot(e,"description")??t.summary,Tn.value=ot(e,"task_priority")??ot(e,"priority")??Tn.value);return}t.target_type==="keeper"&&(t.target_id&&(Ms.value=t.target_id),Le.value=ot(e,"message")??t.summary)}function $v(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function ve(t){const e=Vs.value.trim()||"dashboard";try{const n=await Xd({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?P("확인 대기열에 올렸습니다","warning"):P(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return P(s,"error"),null}}async function Ji(){const t=Pe.value.trim();if(!t)return;await ve({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(Pe.value="")}async function hv(){await ve({action_type:"room_pause",target_type:"room",payload:{reason:Wa.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function Vi(){await ve({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function yv(){const t=Ne.value.trim();if(!t)return;await ve({action_type:"task_inject",target_type:"room",payload:{title:t,description:kn.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(xn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(Ne.value="",kn.value="")}async function bv(){var l;const t=Tt.value,e=Sn.value||((l=t==null?void 0:t.sessions[0])==null?void 0:l.session_id)||"";if(!e){P("먼저 세션을 고르세요","warning");return}const n={},s=Cn.value.trim();s&&(n.message=s);let a="team_note";St.value==="broadcast"?a="team_broadcast":St.value==="task"&&(a="team_task_inject"),St.value==="task"&&(n.task_title=An.value.trim()||"운영자 주입 작업",n.task_description=wn.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(Tn.value,10)||2),await ve({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Cn.value="",St.value==="task"&&(An.value="",wn.value=""))}async function kv(){var n;const t=Tt.value,e=Sn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){P("먼저 세션을 고르세요","warning");return}await ve({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Ls.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function xv(){var a;const t=Tt.value,e=Ms.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=Le.value.trim();if(!e){P("먼저 keeper를 고르세요","warning");return}if(!n)return;await ve({action_type:"keeper_message",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`${e}에게 메시지를 보냈습니다`})&&(Le.value="")}async function Sv(t){const e=Vs.value.trim()||"dashboard";try{await Zd(e,t),P("확인 실행을 완료했습니다","success")}catch(n){const s=n instanceof Error?n.message:"확인 실행에 실패했습니다";P(s,"error")}}function Cv(){var R,W,U;const t=Tt.value,e=D.value.tab==="intervene"?Ln(D.value):null,n=Oo.value,s=It.value,a=(t==null?void 0:t.room)??{},o=(t==null?void 0:t.sessions)??[],l=(t==null?void 0:t.keepers)??[],d=(t==null?void 0:t.pending_confirms)??[],v=(t==null?void 0:t.recent_messages)??[],_=(n==null?void 0:n.recommended_actions)??[],p=(t==null?void 0:t.available_actions)??[],m=o.find($=>$.session_id===Sn.value)??o[0]??null,f=l.find($=>$.name===Ms.value)??l[0]??null,h=(n==null?void 0:n.attention_items)??[],k=h.filter(mv),x=h.filter(vv),C=o.filter($=>pv($)!=="ok"),w=l.filter($=>ia($)!=="ok"),A=v.slice(0,5),S=$v(e,o,l);Z(()=>{Et()},[]),Z(()=>{if(D.value.tab!=="intervene"){Gn.value=null;return}if(!e){Gn.value=null;return}Gn.value!==e.id&&(Gn.value=e.id,gv(e))},[D.value.tab,D.value.params.source,D.value.params.action_type,D.value.params.target_type,D.value.params.target_id,D.value.params.focus_kind,e==null?void 0:e.id]),Z(()=>{const $=(m==null?void 0:m.session_id)??null;je($)},[m==null?void 0:m.session_id]);const I=[{key:"room",label:"Room 게이트",value:a.paused?"일시정지":"열림",detail:a.paused?`재개 전환 대기 중${a.pause_reason?` · ${a.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:a.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:d.length,detail:d.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:d.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:k.length>0?k.length:o.length,detail:k.length>0?((R=k[0])==null?void 0:R.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":o.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:k.length>0?Bi(k):o.length===0?"warn":C.some($=>Oe($.status)==="paused")?"bad":C.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:x.length>0?x.length:w.length,detail:x.length>0?((W=x[0])==null?void 0:W.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":w.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:x.length>0?Bi(x):w.some($=>ia($)==="bad")?"bad":w.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${mt} surfaceId="intervene" />
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
            value=${Vs.value}
            onInput=${$=>dv($.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{tt(),Et(),je((m==null?void 0:m.session_id)??null)}}
            disabled=${$n.value||B.value}
          >
            ${$n.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Yt.value?i`<section class="ops-banner error">${Yt.value}</section>`:null}
      ${Ee.value?i`<section class="ops-banner error">${Ee.value}</section>`:null}
      ${e?i`
        <section class="ops-banner ${S?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${Bs(e.action_type)}</span>
            <span>${di(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?i`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${S?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const $=[];if(d.length>0&&$.push({label:`확인 대기 ${d.length}건 처리`,desc:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:"bad",onClick:()=>{const E=document.querySelector(".ops-pending-section");E==null||E.scrollIntoView({behavior:"smooth"})}}),a.paused&&$.push({label:"Room 재개",desc:`현재 일시정지 상태${a.pause_reason?` (${a.pause_reason})`:""}`,tone:"warn",onClick:()=>void Vi()}),w.length>0){const E=w.filter(J=>ia(J)==="bad");$.push({label:E.length>0?`Keeper ${E.length}개 오프라인`:`Keeper ${w.length}개 점검 필요`,desc:E.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:E.length>0?"bad":"warn",onClick:()=>{const J=document.querySelector(".ops-keeper-section");J==null||J.scrollIntoView({behavior:"smooth"})}})}return $.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${$.slice(0,3).map(E=>i`
                <button class="ops-action-guide-item ${E.tone}" onClick=${E.onClick}>
                  <strong>${E.label}</strong>
                  <span>${E.desc}</span>
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
          ${I.map($=>i`
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
                value=${Pe.value}
                onInput=${$=>{Pe.value=$.target.value}}
                onKeyDown=${$=>{$.key==="Enter"&&Ji()}}
                disabled=${B.value}
              />
              <button class="control-btn" onClick=${()=>{Ji()}} disabled=${B.value||Pe.value.trim()===""}>
                보내기
              </button>
            </div>

            <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
            <div class="control-row ops-split-row">
              <input
                id="ops-pause-reason"
                class="control-input"
                type="text"
                value=${Wa.value}
                onInput=${$=>{Wa.value=$.target.value}}
                disabled=${B.value}
              />
              <button class="control-btn ghost" onClick=${()=>{hv()}} disabled=${B.value}>
                일시정지
              </button>
              <button class="control-btn ghost" onClick=${()=>{Vi()}} disabled=${B.value}>
                재개
              </button>
            </div>

            <div class="ops-section-head">작업 주입</div>
            <input
              class="control-input"
              type="text"
              placeholder="작업 제목"
              value=${Ne.value}
              onInput=${$=>{Ne.value=$.target.value}}
              disabled=${B.value}
            />
            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="작업 설명"
              value=${kn.value}
              onInput=${$=>{kn.value=$.target.value}}
              disabled=${B.value}
            ></textarea>
            <div class="control-row ops-split-row">
              <select
                class="control-input ops-select"
                value=${xn.value}
                onChange=${$=>{xn.value=$.target.value}}
                disabled=${B.value}
              >
                <option value="1">P1</option>
                <option value="2">P2</option>
                <option value="3">P3</option>
                <option value="4">P4</option>
                <option value="5">P5</option>
              </select>
              <button class="control-btn" onClick=${()=>{yv()}} disabled=${B.value||Ne.value.trim()===""}>
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
            ${hn.value&&!n?i`
              <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
            `:_.length>0?i`
              <div class="ops-log-list">
                ${_.map($=>i`
                  <article key=${`${$.action_type}:${$.target_type}:${$.target_id??"room"}`} class="ops-log-entry ${$.severity}">
                    <div class="ops-log-head">
                      <strong>${Jn($.action_type)}</strong>
                      <span>${Vn($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
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
                      <strong>${Jn($.action_type)}</strong>
                      <span>${Vn($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                      <span>${$.delegated_tool??"위임 도구 확인 필요"}</span>
                    </div>
                    ${$.preview?i`<pre class="ops-code-block compact">${Wi($.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{Sv($.confirm_token)}} disabled=${B.value}>
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
              ${o.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:o.map($=>{var E;return i`
                <button
                  key=${$.session_id}
                  class="ops-entity-card ${(m==null?void 0:m.session_id)===$.session_id?"active":""}"
                  onClick=${()=>{Sn.value=$.session_id}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${$.session_id}</strong>
                    <span class="status-badge ${$.status??"idle"}">${Ve($.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round($.progress_pct??0)}%</span>
                    <span>${$.done_delta_total??0}건 완료</span>
                    <span>${(E=$.team_health)!=null&&E.status?Ve(String($.team_health.status)):"상태 확인 필요"}</span>
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
            ${m&&s?i`
              <div class="ops-log-list">
                ${s.attention_items.length>0?s.attention_items.map($=>i`
                  <article key=${`${$.kind}:${$.target_id??"session"}`} class="ops-log-entry ${$.severity}">
                    <div class="ops-log-head">
                      <strong>${$.kind}</strong>
                      <span>${Vn($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                    </div>
                    <div class="ops-log-body">${$.summary}</div>
                  </article>
                `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
                ${s.worker_cards.length>0?s.worker_cards.map($=>i`
                  <article key=${`${$.actor??$.spawn_role??"worker"}:${$.spawn_agent??$.runtime_pool??"runtime"}`} class="ops-log-entry">
                    <div class="ops-log-head">
                      <strong>${$.actor??$.spawn_role??"worker"}</strong>
                      <span>${Ve($.status)}</span>
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

            ${m?i`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${m.session_id}</div>
                <div class="ops-detail-meta">
                  <span>상태: ${Ve(m.status)}</span>
                  <span>경과: ${m.elapsed_sec??0}초</span>
                  <span>남은 시간: ${m.remaining_sec??0}초</span>
                </div>
                ${m.recent_events&&m.recent_events.length>0?i`
                  <pre class="ops-code-block compact">${Wi(m.recent_events.slice(-3))}</pre>
                `:null}
              </div>
            `:i`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

            <label class="control-label" for="ops-turn-kind">세션 액션</label>
            <div class="control-row ops-split-row">
              <select
                id="ops-turn-kind"
                class="control-input ops-select"
                value=${St.value}
                onChange=${$=>{St.value=$.target.value}}
                disabled=${B.value||!m}
              >
                <option value="note">노트</option>
                <option value="broadcast">방송</option>
                <option value="task">작업</option>
              </select>
              <button class="control-btn" onClick=${()=>{bv()}} disabled=${B.value||!m}>
                적용
              </button>
            </div>
            <div class="ops-context-note">현재 선택: ${_v(St.value)}</div>

            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="세션에 남길 메시지"
              value=${Cn.value}
              onInput=${$=>{Cn.value=$.target.value}}
              disabled=${B.value||!m}
            ></textarea>

            ${St.value==="task"?i`
              <input
                class="control-input"
                type="text"
                placeholder="주입할 작업 제목"
                value=${An.value}
                onInput=${$=>{An.value=$.target.value}}
                disabled=${B.value||!m}
              />
              <textarea
                class="control-textarea"
                rows=${2}
                placeholder="주입할 작업 설명"
                value=${wn.value}
                onInput=${$=>{wn.value=$.target.value}}
                disabled=${B.value||!m}
              ></textarea>
              <select
                class="control-input ops-select"
                value=${Tn.value}
                onChange=${$=>{Tn.value=$.target.value}}
                disabled=${B.value||!m}
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
                value=${Ls.value}
                onInput=${$=>{Ls.value=$.target.value}}
                disabled=${B.value||!m}
              />
              <button class="control-btn ghost" onClick=${()=>{kv()}} disabled=${B.value||!m}>
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
                  onClick=${()=>{Ms.value=$.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${$.name}</strong>
                    <span class="status-badge ${$.status??"idle"}">${Ve($.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${$.model??"model 확인 필요"}</span>
                    <span>${typeof $.context_ratio=="number"?`${Math.round($.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                    <span>${uv($.last_turn_ago_s)}</span>
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
                  <span>활성 목표: ${((U=f.active_goal_ids)==null?void 0:U.length)??0}</span>
                </div>
              </div>
            `:i`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

            <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
            <textarea
              id="ops-keeper-message"
              class="control-textarea"
              rows=${6}
              placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
              value=${Le.value}
              onInput=${$=>{Le.value=$.target.value}}
              disabled=${B.value||!f}
            ></textarea>
            <div class="control-row">
              <button class="control-btn" onClick=${()=>{xv()}} disabled=${B.value||!f||Le.value.trim()===""}>
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
              ${p.length?p.map($=>i`
                    <article key=${`${$.action_type}:${$.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${Jn($.action_type)}</strong>
                        <span>${Vn($.target_type)}</span>
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
              ${ys.value.length===0?i`
                <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
              `:ys.value.map($=>i`
                <article key=${$.id} class="ops-log-entry ${$.outcome}">
                  <div class="ops-log-head">
                    <strong>${Jn($.action_type)}</strong>
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
  `}function Av({text:t}){if(!t)return null;const e=wv(t);return i`<div class="markdown-content">${e}</div>`}function wv(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],d=a.slice(l.length).trim(),v=[];for(s++;s<e.length&&!e[s].startsWith(l);)v.push(e[s]),s++;s++,n.push(i`<pre><code class=${d?`language-${d}`:""}>${v.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],d=a.trim().replace(/^<think>/,"").trim();for(d&&d!=="</think>"&&l.push(d),s++;s<e.length&&!e[s].includes("</think>");)l.push(e[s]),s++;if(s<e.length){const _=e[s].replace("</think>","").trim();_&&l.push(_),s++}const v=l.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${oa(v)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<e.length&&e[s].startsWith("> ");)l.push(e[s].slice(2)),s++;n.push(i`<blockquote>${oa(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<e.length;){const l=e[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;o.push(l),s++}o.length>0&&n.push(i`<p>${oa(o.join(`
`))}</p>`)}return n}function oa(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&e.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Rr=[{id:"recent",label:"Latest"},{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],ls=g(null),cs=g([]),Fe=g(!1),ce=g(null),an=g(""),on=g(!1),Se=g(!0);function Tv(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Iv=g(Tv());function Rv(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function Yi(t){return t.updated_at!==t.created_at}function Pv(t){const e=`${t.title} ${t.tags.join(" ")} ${t.flair??""}`.toLowerCase();return/\b(test|smoke|harness|sandbox|dummy|sample|tmp|qa|e2e)\b/.test(e)||e.includes("테스트")||e.includes("실험")}function Nv(t){const e=(t.hearth??"").toLowerCase();return t.visibility!=="internal"||!t.expires_at||!e?!1:!!(e.startsWith("mdal")||e.includes("harness"))}function Pr(t){return Se.value?t.filter(e=>Nv(e)?!1:e.hearth||e.visibility||e.expires_at?!0:!Pv(e)):t}async function hi(t){ce.value=t,ls.value=null,cs.value=[],Fe.value=!0;try{const e=await Fl(t);if(ce.value!==t)return;ls.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth:e.hearth,visibility:e.visibility,expires_at:e.expires_at,hearth_count:e.hearth_count},cs.value=e.comments??[]}catch{ce.value===t&&(ls.value=null,cs.value=[])}finally{ce.value===t&&(Fe.value=!1)}}async function Qi(t){const e=an.value.trim();if(e){on.value=!0;try{await ql(t,Iv.value,e),an.value="",P("Comment posted","success"),await hi(t),At()}catch{P("Failed to post comment","error")}finally{on.value=!1}}}function Lv(){const t=pn.value,e=Se.value?"Hiding automation posts":"Show automation posts";return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Rr.map(n=>i`
          <button
            class="board-sort-btn ${t===n.id?"active":""}"
            onClick=${()=>{pn.value=n.id,At()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Se.value?"is-active":""}"
          onClick=${()=>{Se.value=!Se.value}}
        >
          ${e}
        </button>
        <button
          class="control-btn ghost ${be.value?"is-active":""}"
          onClick=${()=>{be.value=!be.value,At()}}
        >
          ${be.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${At} disabled=${mn.value}>
          ${mn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function ra(){var s;const t=((s=Rr.find(a=>a.id===pn.value))==null?void 0:s.label)??pn.value,e=Pr(un.value),n=un.value.length-e.length;return i`
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
        <strong>${Se.value?`automation ${n} hidden`:"full feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${be.value?"Auto reports hidden":"Full memory feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Oa.value?i`<${Q} timestamp=${Oa.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Mv({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await bo(t.id,n),At()}catch{P("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>tl(t.id)}>
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
            <span><${Q} timestamp=${t.created_at} /></span>
            ${Yi(t)?i`<span>Updated <${Q} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${Rv(t.content)}</div>
      </div>
    </div>
  `}function Dv({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${Q} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function zv({postId:t}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${an.value}
        onInput=${e=>{an.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Qi(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${on.value}
      />
      <button
        onClick=${()=>Qi(t)}
        disabled=${on.value||an.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${on.value?"...":"Post"}
      </button>
    </div>
  `}function Ev({post:t}){ce.value!==t.id&&!Fe.value&&hi(t.id);const e=async n=>{try{await bo(t.id,n),At()}catch{P("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>rt("memory")}>← Back to Memory</button>
      <${T} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${Av} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${t.author}</span>
            <${Q} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
          </div>
          ${t.hearth||t.visibility||t.expires_at?i`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                  ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
                  ${t.expires_at?i`<span class="board-meta-chip">expires <${Q} timestamp=${t.expires_at} /></span>`:null}
                </div>
              `:null}
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${T} title="Comments" semanticId="memory.feed">
        ${Fe.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${Dv} comments=${cs.value} />`}
        <${zv} postId=${t.id} />
      <//>
    </div>
  `}function jv(){const t=Pr(un.value),e=D.value.params.post??null,n=e?t.find(s=>s.id===e)??(ce.value===e?ls.value:null):null;return e&&!n&&ce.value!==e&&!Fe.value&&hi(e),e?n?i`
          <${mt} surfaceId="memory" />
          <${ra} />
          <${Ev} post=${n} />
        `:i`
          <div>
            <${mt} surfaceId="memory" />
            <${ra} />
            <button class="back-btn" onClick=${()=>rt("memory")}>← Back to Memory</button>
            ${Fe.value?i`<div class="loading-indicator">Loading post...</div>`:i`<div class="empty-state">Post not found</div>`}
          </div>
        `:i`
    <div>
      <${mt} surfaceId="memory" />
      <${ra} />
      <${Lv} />
      ${mn.value?i`<div class="loading-indicator">Loading memory feed...</div>`:t.length===0?i`<div class="empty-state">No posts in durable memory right now</div>`:i`
              <${T} title="Posts / Comments" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.map(s=>i`<${Mv} key=${s.id} post=${s} />`)}
                </div>
              <//>
            `}
    </div>
  `}function Nr({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,o=2*Math.PI*s,l=o*((100-t*100)/100);let d="mitosis-safe";return t>=.8?d="mitosis-critical":t>=.5&&(d="mitosis-warn"),i`
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
  `}const la=600*1e3,Ov=1200*1e3,Xi=.8;function Kt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function $e(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Fv(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function qv(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Kv(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Uv(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function Hv(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function Wv(t){var v,_;const e=si.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,s=n?Math.max(0,Date.now()-Kt(n)):Number.POSITIVE_INFINITY,a=!!((v=t.current_task)!=null&&v.trim())||e.activeAssignedCount>0;let o="watching",l="ok",d="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",l="bad",d=n?"Offline or inactive":"No recent presence"):s>Ov?(o="quiet",l="bad",d=a?"Working without a fresh signal":"No fresh agent signal"):a?(o="working",l=s>la?"warn":"ok",d=s>la?"Execution looks quiet for too long":"Task and live signal aligned"):s>la?(o="quiet",l="warn",d="Quiet but still reachable"):t.status==="idle"&&(o="watching",l="ok",d="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:l,focus:((_=t.current_task)==null?void 0:_.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:d}}function Bv(t){const e=Uc.value.get(t.name)??"idle",n=Bc.value.has(t.name),s=t.context_ratio??0;let a="healthy",o="ok",l="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(a="critical",o="bad",l=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||s>=Xi)&&(a="warning",o="warn",l=s>=Xi?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:a,tone:o,focus:Uv(t),note:l}}function Ye({label:t,value:e,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function Gv({item:t}){const e=t.kind==="agent"?()=>ze(t.agent.name):()=>li(t.keeper);return i`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?i`<span><${Q} timestamp=${t.timestamp} /></span>`:i`<span>No signal</span>`}
      </div>
    </button>
  `}function Zi({row:t}){const{agent:e,motion:n}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>ze(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Nr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Xt} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${Fv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?i`<span>Signal <${Q} timestamp=${t.lastSignalAt} /></span>`:i`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
        ${e.last_seen?i`<span>Seen <${Q} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?i`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function Jv({row:t}){const{keeper:e}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>li(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Nr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Xt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${qv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?i`<span>Heartbeat <${Q} timestamp=${e.last_heartbeat} /></span>`:i`<span>No heartbeat</span>`}
        <span>${Hv(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${Kv(e.context_ratio)}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?i`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function Vv(){const t=[...gt.value].map(Wv).sort((p,m)=>{const f=$e(m.tone)-$e(p.tone);if(f!==0)return f;const h=m.activeTaskCount-p.activeTaskCount;return h!==0?h:Kt(m.lastSignalAt)-Kt(p.lastSignalAt)}),e=[...jt.value].map(Bv).sort((p,m)=>{const f=$e(m.tone)-$e(p.tone);if(f!==0)return f;const h=(m.keeper.context_ratio??0)-(p.keeper.context_ratio??0);return h!==0?h:Kt(m.keeper.last_heartbeat)-Kt(p.keeper.last_heartbeat)}),n=t.filter(p=>p.state!=="offline"),s=t.filter(p=>p.state==="offline"),a=n.length,o=t.filter(p=>p.state==="working").length,l=t.filter(p=>p.lastSignalAt&&Date.now()-Kt(p.lastSignalAt)<=12e4).length,d=t.filter(p=>p.tone!=="ok"),v=e.filter(p=>p.tone!=="ok"),_=[...v.map(p=>({kind:"keeper",key:`keeper-${p.keeper.name}`,tone:p.tone,title:p.keeper.name,subtitle:`${p.note} · ${p.focus}`,timestamp:p.keeper.last_heartbeat??null,keeper:p.keeper})),...d.map(p=>({kind:"agent",key:`agent-${p.agent.name}`,tone:p.tone,title:p.agent.name,subtitle:`${p.note} · ${p.focus}`,timestamp:p.lastSignalAt,agent:p.agent}))].sort((p,m)=>{const f=$e(m.tone)-$e(p.tone);return f!==0?f:Kt(m.timestamp)-Kt(p.timestamp)}).slice(0,8);return i`
    <div class="agents-monitor">
      <${mt} surfaceId="execution" />
      <div class="stats-grid">
        <${Ye} label="Workers online" value=${a} color="#4ade80" caption="활성 + 대기 실행 actor" />
        <${Ye} label="Working now" value=${o} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${Ye} label="Fresh signals" value=${l} color="#22d3ee" caption="최근 2분 이내 신호" />
        <${Ye} label="Worker alerts" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="실행 actor 경고" />
        <${Ye} label="Continuity alerts" value=${v.length} color=${v.length>0?"#fb7185":"#4ade80"} caption="keeper 연속성 경고" />
      </div>

      <${T} title="Execution Priorities" class="section" semanticId="execution.priority_queue">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs execution attention right now</h2>
          <p class="monitor-subheadline">Worker drift and keeper continuity risk are ranked together here, but diagnosed in separate sections below.</p>
        </div>
        <div class="monitor-alert-list">
          ${_.length===0?i`<div class="empty-state">No execution alerts right now</div>`:_.map(p=>i`<${Gv} key=${p.key} item=${p} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${T} title="Workers" class="section" semanticId="execution.workers">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Live workers stay grouped here so owner drift is visible before you scan offline history.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?i`<div class="empty-state">No active workers visible</div>`:n.map(p=>i`<${Zi} key=${p.agent.name} row=${p} />`)}
          </div>
        <//>

        <${T} title="Continuity" class="section" semanticId="execution.continuity">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper continuity</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and handoff state are isolated from worker execution drift.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?i`<div class="empty-state">No keepers active</div>`:e.map(p=>i`<${Jv} key=${p.keeper.name} row=${p} />`)}
          </div>
        <//>

        <${T} title="Offline Workers" class="section" semanticId="execution.offline">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who dropped out of the live loop</h2>
            <p class="monitor-subheadline">Offline rows stay separate so they do not drown the active execution monitor.</p>
          </div>
          <div class="monitor-list">
            ${s.length===0?i`<div class="empty-state">No offline workers right now</div>`:s.map(p=>i`<${Zi} key=${p.agent.name} row=${p} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Ds=g("all"),zs=g("all"),Ba=g(new Set);function Yv(t){const e=new Set(Ba.value);e.has(t)?e.delete(t):e.add(t),Ba.value=e}const Lr=ft(()=>{let t=Ae.value;return Ds.value!=="all"&&(t=t.filter(e=>e.horizon===Ds.value)),zs.value!=="all"&&(t=t.filter(e=>e.status===zs.value)),t}),Qv=ft(()=>{const t={short:[],mid:[],long:[]};for(const e of Lr.value){const n=t[e.horizon];n&&n.push(e)}return t}),Xv=ft(()=>{const t=Array.from(wo.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function Zv(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function yi(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function ds(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function t_(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function to(t){return t.toFixed(4)}function eo(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function e_(t){switch(t){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function no(t,e){return(t.priority??4)-(e.priority??4)}function n_(t,e){const n=t.updated_at??t.created_at??"";return(e.updated_at??e.created_at??"").localeCompare(n)}function s_(t,e){return t.length<=e?t:t.slice(0,e)+"..."}function a_({goal:t}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ds(t.horizon)}">
            ${yi(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${Zv(t.priority)}</span>
          ${t.metric?i`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?i`<span class="goal-due">Due: <${Q} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?i`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${Xt} status=${t.status} />
        <div class="goal-updated">
          <${Q} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function ca({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return i`
    <${T} title="${yi(t)} Goals (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${a_} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function i_(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>i`
          <button
            class="goal-filter-btn ${Ds.value===t?"active":""}"
            onClick=${()=>{Ds.value=t}}
          >
            ${t==="all"?"All":yi(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>i`
          <button
            class="goal-filter-btn ${zs.value===t?"active":""}"
            onClick=${()=>{zs.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function o_(){const t=Ae.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return i`
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
        <div class="goal-summary-value" style="color:${ds("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ds("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ds("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function r_({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return i`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${Xt} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${to(t.baseline_metric)}</span>
          <span>Current ${to(t.current_metric)}</span>
          <span class=${eo(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${eo(t)}
          </span>
          <span>Elapsed ${t_(t.elapsed_seconds)}</span>
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
  `}function da({task:t}){const e=t.priority??4,n=e<=1?"p1":e===2?"p2":e===3?"p3":"p4",s=Ba.value.has(t.id),a=!!t.description;return i`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${e_(e)}</span>
        <div class="kanban-card-title">${t.title}</div>
      </div>
      ${a?i`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>Yv(t.id)}
        >
          ${s?t.description:s_(t.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${t.created_at?i`<${Q} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function l_(){const{todo:t,inProgress:e,done:n}=Io.value,s=[...t].sort(no),a=[...e].sort(no),o=[...n].sort(n_);return i`
    <${T} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${s.length===0?i`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:s.map(l=>i`<${da} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${a.length===0?i`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:a.map(l=>i`<${da} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${o.length===0?i`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:o.slice(0,20).map(l=>i`<${da} key=${l.id} task=${l} />`)}
          ${o.length>20?i`<div class="empty-state" style="opacity: 0.5;">...and ${o.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function c_(){const{todo:t,inProgress:e,done:n}=Io.value,s=t.length+e.length+n.length,a=[...t,...e].filter(p=>(p.priority??4)<=2).length,o=Qv.value,l=Xv.value,d=Ae.value.length>0,v=l.length>0,_=ei.value;return i`
    <div>
      <${mt} surfaceId="planning" />

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
          onClick=${()=>{vn(),Mo()}}
          disabled=${tn.value||en.value}
        >
          ${tn.value||en.value?"Refreshing...":"Refresh planning data"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${l_} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${d}>
        <summary>
          Goal Pipeline
          <span class="monitor-pill">${Ae.value.length}</span>
        </summary>
        <div>
          ${d?i`
            <${o_} />
            <${i_} />
            ${tn.value&&Ae.value.length===0?i`<div class="loading-indicator">Loading goals...</div>`:Lr.value.length===0?i`<div class="empty-state">No goals match the current filters</div>`:i`
                    <${ca} horizon="short" items=${o.short??[]} />
                    <${ca} horizon="mid" items=${o.mid??[]} />
                    <${ca} horizon="long" items=${o.long??[]} />
                  `}
          `:i`
            <div class="empty-state">
              No goals defined. Use <code>masc_goal_upsert</code> to create goals.
            </div>
          `}
        </div>
      </details>

      <!-- MDAL Loops in collapsible details -->
      <details class="overview-section-collapsible" open=${v}>
        <summary>
          MDAL Loops
          <span class="monitor-pill">${l.length}</span>
        </summary>
        <div>
          ${en.value&&l.length===0?i`<div class="loading-indicator">Loading MDAL loops...</div>`:l.length===0&&(_==="error"||we.value)?i`<div class="empty-state">MDAL snapshot could not be loaded${we.value?`: ${we.value}`:""}. Check backend health.</div>`:l.length===0?i`<div class="empty-state">No active loops. Use <code>masc_mdal_start</code> to start a loop.</div>`:i`
                  <div class="planning-loop-list">
                    ${l.map(p=>i`<${r_} key=${p.loop_id} loop=${p} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const rn=g("debates"),Es=g([]),js=g([]),Os=g(!1),ln=g(!1),In=g(""),cn=g(""),Fs=g(null),yt=g(null),Ga=g(!1);async function Ys(){Os.value=!0,In.value="";try{const t=await kl();Es.value=Array.isArray(t.debates)?t.debates:[],js.value=Array.isArray(t.sessions)?t.sessions:[]}catch(t){In.value=t instanceof Error?t.message:"Failed to load governance state"}finally{Os.value=!1}}rd(Ys);async function so(){const t=cn.value.trim();if(t){ln.value=!0;try{const e=await vc(t);cn.value="",P(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Ys()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";P(n,"error")}finally{ln.value=!1}}}async function d_(t){Fs.value=t,yt.value=null,Ga.value=!0;try{yt.value=await _c(t)}catch(e){In.value=e instanceof Error?e.message:"Failed to load debate detail"}finally{Ga.value=!1}}function u_(){return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${Es.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Voting sessions</span>
        <strong>${js.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Active view</span>
        <strong>${rn.value==="debates"?"Debates":"Voting"}</strong>
      </div>
    </div>
  `}function p_({debate:t}){const e=Fs.value===t.id;return i`
    <button class="council-row ${e?"selected":""}" onClick=${()=>d_(t.id)}>
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Arguments: ${t.argument_count}</span>
          ${t.created_at?i`<span><${Q} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </button>
  `}function m_({session:t}){return i`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.created_at?i`<span><${Q} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function v_(){const t=rn.value;return i`
    <div class="overview-sub-tabs" style="margin-bottom:12px;">
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{rn.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{rn.value="voting"}}>Voting</button>
    </div>
  `}function __(){return i`
    <div>
      <${T} title="Start Debate" class="section" semanticId="governance.debates">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${cn.value}
            onInput=${t=>{cn.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&so()}}
            disabled=${ln.value}
          />
          <button
            class="control-btn secondary"
            onClick=${so}
            disabled=${ln.value||cn.value.trim()===""}
          >
            ${ln.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Ys} disabled=${Os.value}>
            ${Os.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${In.value?i`<div class="council-error">${In.value}</div>`:null}
      <//>

      <${T} title="Debates" class="section" semanticId="governance.debates">
        <div class="council-list">
          ${Es.value.length===0?i`<div class="empty-state">No debates yet</div>`:Es.value.map(t=>i`<${p_} key=${t.id} debate=${t} />`)}
        </div>
      <//>

      <${T} title=${Fs.value?`Debate Detail (${Fs.value})`:"Debate Detail"} class="section" semanticId="governance.debates">
        ${Ga.value?i`<div class="loading-indicator">Loading debate detail...</div>`:yt.value?i`
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Status: ${yt.value.status}</span>
                  <span>Total arguments: ${yt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Support: ${yt.value.support_count}</span>
                  <span>Oppose: ${yt.value.oppose_count}</span>
                  <span>Neutral: ${yt.value.neutral_count}</span>
                </div>
                ${yt.value.summary_text?i`<pre class="council-detail">${yt.value.summary_text}</pre>`:null}
              `:i`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function f_(){return i`
    <${T} title="Voting Sessions" class="section" semanticId="governance.voting">
      <div class="council-list">
        ${js.value.length===0?i`<div class="empty-state">No active sessions</div>`:js.value.map(t=>i`<${m_} key=${t.id} session=${t} />`)}
      </div>
    <//>
  `}function g_(){return Z(()=>{Ys()},[]),i`
    <div>
      <${mt} surfaceId="governance" />
      <${u_} />
      <${v_} />
      ${rn.value==="debates"?i`<${__} />`:i`<${f_} />`}
    </div>
  `}const ye=g(""),ua=g("ability_check"),pa=g("10"),ma=g("12"),Yn=g(""),Qn=g("idle"),Ut=g(""),Xn=g("keeper-late"),va=g("player"),_a=g(""),ut=g("idle"),fa=g(null),Zn=g(""),ga=g(""),$a=g("player"),ha=g(""),ya=g(""),ba=g(""),dn=g("20"),ka=g("20"),xa=g(""),ts=g("idle"),Ja=g(null),Mr=g("overview"),Sa=g("all"),Ca=g("all"),Aa=g("all"),$_=12e4,Qs=g(null),ao=g(Date.now());function h_(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function y_(t,e){return e>0?Math.round(t/e*100):0}const b_={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},k_={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function es(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function x_(t){const e=t.trim().toLowerCase();return b_[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function S_(t){const e=t.trim().toLowerCase();return k_[e]??"상황에 따라 선택되는 전술 액션입니다."}function ct(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function bt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function Rn(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const C_=new Set(["str","dex","con","int","wis","cha"]);function A_(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!u(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const l=a.trim();if(l){if(typeof o=="number"&&Number.isFinite(o)){s[l]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const d=Number.parseFloat(o.trim());if(Number.isFinite(d)){s[l]=Math.max(0,Math.trunc(d));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function w_(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(dn.value.trim(),10);Number.isFinite(s)&&s>n&&(dn.value=String(n))}function Va(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function T_(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function I_(t){Mr.value=t}function Dr(t){const e=Qs.value;return e==null||e<=t}function R_(t){const e=Qs.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function qs(){Qs.value=null}function zr(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function P_(t,e){zr(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Qs.value=Date.now()+$_,P("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function us(t){return Dr(t)?(P("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Ya(t,e,n){return zr([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function N_({hp:t,max:e}){const n=y_(t,e),s=h_(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function L_({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function M_({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Er({actor:t}){var v,_,p,m;const e=(v=t.archetype)==null?void 0:v.trim(),n=(_=t.persona)==null?void 0:_.trim(),s=(p=t.portrait)==null?void 0:p.trim(),a=(m=t.background)==null?void 0:m.trim(),o=t.traits??[],l=t.skills??[],d=Object.entries(t.stats_raw??{}).filter(([f,h])=>Number.isFinite(h)).filter(([f])=>!C_.has(f.toLowerCase()));return i`
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
        <${Xt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${M_} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${N_} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${L_} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${es(e)}</div>`:null}
      ${a?i`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${d.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${d.map(([f,h])=>i`
                <span class="trpg-custom-stat-chip">${es(f)} ${h}</span>
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
                  <span class="trpg-annot-name">${es(f)}</span>
                  <span class="trpg-annot-desc">${x_(f)}</span>
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
                  <span class="trpg-annot-name">${es(f)}</span>
                  <span class="trpg-annot-desc">${S_(f)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function D_({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function jr({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?i`<div class="empty-state" style="font-size:13px">${e}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${T_(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Va(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${Q} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function z_({events:t}){const e="__none__",n=Sa.value,s=Ca.value,a=Aa.value,o=Array.from(new Set(t.map(Va).map(m=>m.trim()).filter(m=>m!==""))).sort((m,f)=>m.localeCompare(f)),l=Array.from(new Set(t.map(m=>(m.type??"").trim()).filter(m=>m!==""))).sort((m,f)=>m.localeCompare(f)),d=t.some(m=>(m.type??"").trim()===""),v=Array.from(new Set(t.map(m=>(m.phase??"").trim()).filter(m=>m!==""))).sort((m,f)=>m.localeCompare(f)),_=t.some(m=>(m.phase??"").trim()===""),p=t.filter(m=>{if(n!=="all"&&Va(m)!==n)return!1;const f=(m.type??"").trim(),h=(m.phase??"").trim();if(s===e){if(f!=="")return!1}else if(s!=="all"&&f!==s)return!1;if(a===e){if(h!=="")return!1}else if(a!=="all"&&h!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${m=>{Sa.value=m.target.value}}>
          <option value="all">all</option>
          ${o.map(m=>i`<option value=${m}>${m}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${m=>{Ca.value=m.target.value}}>
          <option value="all">all</option>
          ${d?i`<option value=${e}>(none)</option>`:null}
          ${l.map(m=>i`<option value=${m}>${m}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${m=>{Aa.value=m.target.value}}>
          <option value="all">all</option>
          ${_?i`<option value=${e}>(none)</option>`:null}
          ${v.map(m=>i`<option value=${m}>${m}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Sa.value="all",Ca.value="all",Aa.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${p.length} / 전체 ${t.length}
      </span>
    </div>
    <${jr} events=${p.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function E_({outcome:t}){if(!t)return null;const e=o=>{const l=o.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function Or({state:t}){const e=t.history??[];return e.length===0?null:i`
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
  `}function j_({state:t,nowMs:e}){var _;const n=Mt.value||((_=t.session)==null?void 0:_.room)||"",s=Qn.value,a=t.party??[];if(!a.find(p=>p.id===ye.value)&&a.length>0){const p=a[0];p&&(ye.value=p.id)}const l=async()=>{var m,f;if(!n){P("Room ID가 비어 있습니다.","error");return}if(!us(e))return;const p=((m=t.current_round)==null?void 0:m.phase)??((f=t.session)==null?void 0:f.status)??"unknown";if(Ya("라운드 실행",n,p)){Qn.value="running";try{const h=await sc(n);Ja.value=h,Qn.value="ok";const k=u(h.summary)?h.summary:null,x=k?Rn(k,"advanced",!1):!1,C=k?ct(k,"progress_reason",""):"";P(x?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${C?`: ${C}`:""}`,x?"success":"warning"),wt()}catch(h){Ja.value=null,Qn.value="error";const k=h instanceof Error?h.message:"라운드 실행에 실패했습니다.";P(k,"error")}finally{qs()}}},d=async()=>{var m,f;if(!n||!us(e))return;const p=((m=t.current_round)==null?void 0:m.phase)??((f=t.session)==null?void 0:f.status)??"unknown";if(Ya("턴 강제 진행",n,p))try{await oc(n),P("턴을 다음 단계로 이동했습니다.","success"),wt()}catch{P("턴 이동에 실패했습니다.","error")}finally{qs()}},v=async()=>{if(!n||!us(e))return;const p=ye.value.trim();if(!p){P("먼저 Actor를 선택하세요.","warning");return}const m=Number.parseInt(pa.value,10),f=Number.parseInt(ma.value,10);if(Number.isNaN(m)||Number.isNaN(f)){P("stat/dc는 숫자여야 합니다.","warning");return}const h=Number.parseInt(Yn.value,10),k=Yn.value.trim()===""||Number.isNaN(h)?void 0:h;try{await ic({roomId:n,actorId:p,action:ua.value.trim()||"ability_check",statValue:m,dc:f,rawD20:k}),P("주사위 판정을 기록했습니다.","success"),wt()}catch{P("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${p=>{Mt.value=p.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${ye.value}
            onChange=${p=>{ye.value=p.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(p=>i`<option value=${p.id}>${p.name} (${p.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${ua.value}
              onInput=${p=>{ua.value=p.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${pa.value}
              onInput=${p=>{pa.value=p.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${ma.value}
              onInput=${p=>{ma.value=p.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Yn.value}
              onInput=${p=>{Yn.value=p.target.value}}
              onKeyDown=${p=>{p.key==="Enter"&&v()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${v}>Roll</button>
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
  `}function O_({state:t}){var a;const e=Mt.value||((a=t.session)==null?void 0:a.room)||"",n=ts.value,s=async()=>{if(!e){P("Room ID가 비어 있습니다.","warning");return}const o=Zn.value.trim(),l=ga.value.trim();if(!l&&!o){P("이름 또는 Actor ID를 입력하세요.","warning");return}const d=Number.parseInt(dn.value.trim(),10),v=Number.parseInt(ka.value.trim(),10),_=Number.isFinite(v)?Math.max(1,v):20,p=Number.isFinite(d)?Math.max(0,Math.min(_,d)):_;let m={};try{m=A_(xa.value)}catch(f){P(f instanceof Error?f.message:"능력치 JSON 오류","error");return}ts.value="spawning";try{const f=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,h=await rc(e,{actor_id:o||void 0,name:l||void 0,role:$a.value,idempotencyKey:f,portrait:ya.value.trim()||void 0,background:ba.value.trim()||void 0,hp:p,max_hp:_,alive:p>0,stats:Object.keys(m).length>0?m:void 0}),k=typeof h.actor_id=="string"?h.actor_id.trim():"";if(!k)throw new Error("생성 응답에 actor_id가 없습니다.");const x=ha.value.trim();x&&await lc(e,k,x),ye.value=k,Ut.value=k,o||(Zn.value=""),ts.value="ok",P(`Actor 생성 완료: ${k}`,"success"),await wt()}catch(f){ts.value="error",P(f instanceof Error?f.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${ga.value}
            onInput=${o=>{ga.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${$a.value}
            onChange=${o=>{$a.value=o.target.value}}
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
            value=${ha.value}
            onInput=${o=>{ha.value=o.target.value}}
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
              value=${Zn.value}
              onInput=${o=>{Zn.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${ya.value}
              onInput=${o=>{ya.value=o.target.value}}
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
              value=${dn.value}
              onInput=${o=>{dn.value=o.target.value}}
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
              value=${ka.value}
              onInput=${o=>{const l=o.target.value;ka.value=l,w_(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${ba.value}
              onInput=${o=>{ba.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${xa.value}
              onInput=${o=>{xa.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function F_({state:t,nowMs:e}){var f;const n=Mt.value||((f=t.session)==null?void 0:f.room)||"",s=t.join_gate,a=fa.value,o=u(a)?a:null,l=(t.party??[]).filter(h=>h.role!=="dm"),d=Ut.value.trim(),v=l.some(h=>h.id===d),_=v?d:d?"__manual__":"",p=async()=>{const h=Ut.value.trim(),k=Xn.value.trim();if(!n||!h){P("Room/Actor가 필요합니다.","warning");return}ut.value="checking";try{const x=await cc(n,h,k||void 0);fa.value=x,ut.value="ok",P("참가 가능 여부를 갱신했습니다.","success")}catch(x){ut.value="error";const C=x instanceof Error?x.message:"참가 가능 여부 확인에 실패했습니다.";P(C,"error")}},m=async()=>{var w,A;const h=Ut.value.trim(),k=Xn.value.trim(),x=_a.value.trim();if(!n||!h||!k){P("Room/Actor/Keeper가 필요합니다.","warning");return}if(!us(e))return;const C=((w=t.current_round)==null?void 0:w.phase)??((A=t.session)==null?void 0:A.status)??"unknown";if(Ya("Mid-Join 승인 요청",n,C)){ut.value="requesting";try{const S=await dc({room_id:n,actor_id:h,keeper_name:k,role:va.value,...x?{name:x}:{}});fa.value=S;const I=u(S)?Rn(S,"granted",!1):!1,R=u(S)?ct(S,"reason_code",""):"";I?P("Mid-Join이 승인되었습니다.","success"):P(`Mid-Join이 거절되었습니다${R?`: ${R}`:""}`,"warning"),ut.value=I?"ok":"error",wt()}catch(S){ut.value="error";const I=S instanceof Error?S.message:"Mid-Join 요청에 실패했습니다.";P(I,"error")}finally{qs()}}};return i`
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
            onChange=${h=>{const k=h.target.value;if(k==="__manual__"){(v||!d)&&(Ut.value="");return}Ut.value=k}}
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
            value=${Xn.value}
            onInput=${h=>{Xn.value=h.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${va.value}
            onChange=${h=>{va.value=h.target.value}}
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
            value=${_a.value}
            onInput=${h=>{_a.value=h.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${p} disabled=${ut.value==="checking"||ut.value==="requesting"}>
              ${ut.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${m} disabled=${ut.value==="checking"||ut.value==="requesting"}>
              ${ut.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Rn(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${bt(o,"effective_score",0)}/${bt(o,"required_points",0)}</span>
            ${ct(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${ct(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Fr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function qr({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Kr(){const t=Ja.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=u(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(u).slice(-8),o=t.canon_check,l=u(o)?o:null,d=l&&Array.isArray(l.warnings)?l.warnings.filter(R=>typeof R=="string").slice(0,3):[],v=l&&Array.isArray(l.violations)?l.violations.filter(R=>typeof R=="string").slice(0,3):[],_=n?Rn(n,"advanced",!1):!1,p=n?ct(n,"progress_reason",""):"",m=n?ct(n,"progress_detail",""):"",f=n?bt(n,"player_successes",0):0,h=n?bt(n,"player_required_successes",0):0,k=n?Rn(n,"dm_success",!1):!1,x=n?bt(n,"timeouts",0):0,C=n?bt(n,"unavailable",0):0,w=n?bt(n,"reprompts",0):0,A=n?bt(n,"npc_attacks",0):0,S=n?bt(n,"keeper_timeout_sec",0):0,I=n?bt(n,"roll_audit_count",0):0;return i`
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
        ${p?i`<div style="margin-top:4px; font-size:12px;">${p}</div>`:null}
        ${m?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${m}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${w}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${S||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${I}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(R=>{const W=ct(R,"status","unknown"),U=ct(R,"actor_id","-"),$=ct(R,"role","-"),E=ct(R,"reason",""),J=ct(R,"action_type",""),F=ct(R,"reply","");return i`
                <div class="trpg-round-item ${W.includes("fallback")||W.includes("timeout")?"failed":"active"}">
                  <span>${U} (${$})</span>
                  <span style="margin-left:auto; font-size:11px;">${W}</span>
                  ${J?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${J}</div>`:null}
                  ${E?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${E}</div>`:null}
                  ${F?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${F.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${ct(l,"status","unknown")}</strong>
            </div>
            ${v.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${v.map(R=>i`<div>violation: ${R}</div>`)}
                </div>`:null}
            ${d.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${d.map(R=>i`<div>warning: ${R}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function q_({state:t,nowMs:e}){var l,d,v;const n=Mt.value||((l=t.session)==null?void 0:l.room)||"",s=((d=t.current_round)==null?void 0:d.phase)??((v=t.session)==null?void 0:v.status)??"unknown",a=Dr(e),o=R_(e);return i`
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
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>P_(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{qs(),P("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function K_({active:t}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>I_(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function U_({state:t}){const e=t.party??[],n=t.story_log??[];return i`
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
          <${jr} events=${n.slice(-20)} />
        <//>

        ${t.map?i`
            <${T} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${D_} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${T} title="현재 라운드" semanticId="lab.trpg">
          <${qr} state=${t} />
        <//>

        <${T} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${Fr} state=${t} />
        <//>

        <${T} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>i`<${Er} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?i`
            <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${Or} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function H_({state:t}){const e=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${T} title=${`이벤트 타임라인 (${e.length})`}>
          <${z_} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${T} title="최근 라운드 결과" semanticId="lab.trpg">
          <${Kr} />
        <//>

        <${T} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${qr} state=${t} />
        <//>
      </div>
    </div>
  `}function W_({state:t,nowMs:e}){const n=t.party??[];return i`
    <div>
      <${q_} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${T} title="조작 패널" semanticId="lab.trpg">
            <${j_} state=${t} nowMs=${e} />
          <//>

          <${T} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${O_} state=${t} />
          <//>

          <${T} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${F_} state=${t} nowMs=${e} />
          <//>

          <${T} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${Kr} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${T} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${Fr} state=${t} />
          <//>

          <${T} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${Er} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?i`
              <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${Or} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function B_(){var d,v,_,p,m;const t=Ao.value,e=ja.value;if(Z(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const f=window.setInterval(()=>{ao.value=Date.now()},1e3);return()=>{window.clearInterval(f)}},[]),e&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>wt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,o=Mr.value,l=ao.value;return i`
    <div>
      <${mt} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Mt.value||((d=t.session)==null?void 0:d.room)||"-"} · phase: ${((v=t.current_round)==null?void 0:v.phase)??((_=t.session)==null?void 0:_.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>wt()}>새로고침</button>
      </div>

      <${E_} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((p=t.session)==null?void 0:p.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((m=t.current_round)==null?void 0:m.round_number)??0}</div>
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

      <${K_} active=${o} />

      ${o==="overview"?i`<${U_} state=${t} />`:o==="timeline"?i`<${H_} state=${t} />`:i`<${W_} state=${t} nowMs=${l} />`}
    </div>
  `}function G_(){return i`
    <div>
      <${mt} surfaceId="lab" />
      <${T} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${T} title="TRPG" class="section" semanticId="lab.trpg">
        <${B_} />
      <//>
    </div>
  `}const Ks=g(new Set(["broadcast","tasks","keepers","system"]));function J_(t){const e=new Set(Ks.value);e.has(t)?e.delete(t):e.add(t),Ks.value=e}const bi=g(null);function Ur(t){bi.value=t}function V_(t){return t.kind==="board"?"broadcast":t.kind==="tasks"?"tasks":t.kind==="keepers"?"keepers":"system"}const Y_=ft(()=>{const t=Ks.value;return ms.value.filter(e=>t.has(V_(e)))}),Q_=12e4,X_=ft(()=>{const t=si.value,e=Date.now();return gt.value.map(n=>{const s=n.name.trim().toLowerCase(),a=t.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?o=e-new Date(l).getTime()>Q_?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),Z_=ft(()=>{const t=si.value;return gt.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle").map(e=>{const n=e.name.trim().toLowerCase(),s=t.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:e.name,emoji:e.emoji??"",koreanName:e.koreanName??null,currentTask:e.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((e,n)=>{const s={hot:0,normal:1,calm:2};return s[e.pressure]-s[n.pressure]})});function io(t){return t.kind==="board"?"live-event-broadcast":t.kind==="tasks"?"live-event-task":t.kind==="keepers"?"live-event-keeper":"live-event-system"}function tf(t){const e=t.eventType;return e==="broadcast"?"broadcast":e==="agent_joined"?"joined":e==="agent_left"?"left":e==="task_update"?"task":e==="board_post"?"post":e==="board_comment"?"comment":e==="keeper_heartbeat"?"heartbeat":e==="keeper_handoff"?"handoff":e==="keeper_compaction"?"compact":e==="keeper_guardrail"?"guardrail":t.kind==="board"?"board":t.kind==="tasks"?"task":t.kind==="keepers"?"keeper":"system"}function ef(t){switch(t){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function nf(){const t=X_.value,e=bi.value;return t.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${t.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${ef(n.state)} ${e===n.name?"pulse-selected":""}"
          onClick=${()=>Ur(e===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const sf=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function af(){const t=Ks.value;return i`
    <div class="activity-filter-bar">
      ${sf.map(e=>i`
        <button
          key=${e.kind}
          class="activity-filter-btn ${e.cssClass} ${t.has(e.kind)?"active":""}"
          onClick=${()=>J_(e.kind)}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function of(){const t=Y_.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${t.length} events</span>
      </div>
      <${af} />
      <div class="activity-stream-list">
        ${t.length===0?i`<div class="activity-empty">No events matching filters</div>`:t.map((e,n)=>i`
            <div
              key=${`${e.timestamp}-${n}`}
              class="activity-item ${io(e)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${io(e)}">${tf(e)}</span>
                <span class="activity-agent">${e.agent}</span>
                <span class="activity-time">${zo(e.timestamp)}</span>
              </div>
              <div class="activity-item-text">${e.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function rf(t){switch(t){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function lf(t){switch(t){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function cf(){const t=Z_.value,e=bi.value;return i`
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
              onClick=${()=>Ur(e===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?i`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${rf(n.pressure)}">
                  ${lf(n.pressure)}
                  ${n.assignedCount>0?i` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?i`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?i`<span class="focus-activity-text">${n.lastActivityText}</span>`:i`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?i`<${Q} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function df(){const t=Vt.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>Live Monitor</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${t?"connected":"disconnected"}"></span>
            ${t?"Connected":"Offline"}
          </span>
          <span class="live-stat">${gt.value.length} agents</span>
          <span class="live-stat">${Us.value} events</span>
        </div>
      </div>

      <${nf} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${of} />
        </div>
        <div class="live-panel-side">
          <${cf} />
        </div>
      </div>
    </div>
  `}const oo=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],Qa=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"live",label:"Live",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}];function uf(){const t=Vt.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Us.value} events</span>
    </div>
  `}function pf({currentTab:t,currentSectionLabel:e}){const n=Vt.value;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>Snapshot</h3>
        <${L} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${n?"ok":"bad"}">${n?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agents</span>
          <strong>${gt.value.length}</strong>
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
          <strong>${Us.value}</strong>
        </div>
      </div>
      <div class="rail-snapshot-copy">
        <span>Connection ${n?"healthy":"recovering"}</span>
        <span>${e} workspace active</span>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Nn(),No(),t==="command"&&(Wt(),Bt(),(q.value==="swarm"||q.value==="warroom")&&xt(),q.value==="warroom"&&tt()),t==="mission"&&(os(),_n()),t==="execution"&&Lt(),t==="intervene"&&(tt(),Et()),t==="memory"&&At(),t==="planning"&&vn(),t==="lab"&&wt()}}
        >
          Refresh Now
        </button>
        <button class="rail-secondary-btn" onClick=${()=>rt("intervene")}>
          Open Intervene
        </button>
      </div>
    </section>
  `}function mf(){const t=Tt.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return i`
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
          onClick=${()=>{tt(),Et()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>rt("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function vf(){const t=D.value.tab,e=Qa.find(s=>s.id===t),n=oo.find(s=>s.id===(e==null?void 0:e.group));return i`
    <aside class="dashboard-rail">
      <${mt} surfaceId="side_rail" compact=${!0} />
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
                    onClick=${()=>rt(a.id)}
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

      <${pf} currentTab=${t} currentSectionLabel=${(n==null?void 0:n.label)??"Observe"} />
      <${mf} />
    </aside>
  `}function _f(){switch(D.value.tab){case"mission":return i`<${Fi} />`;case"execution":return i`<${Vv} />`;case"live":return i`<${df} />`;case"memory":return i`<${jv} />`;case"governance":return i`<${g_} />`;case"planning":return i`<${c_} />`;case"intervene":return i`<${Cv} />`;case"command":return i`<${lv} />`;case"lab":return i`<${G_} />`;default:return i`<${Fi} />`}}function ff(){Z(()=>{el(),_o(),Lo(),Lt(),No(),os();const n=dd();return ud(),()=>{cl(),n(),pd()}},[]),Z(()=>{const n=setInterval(()=>{const s=D.value.tab;s==="command"?(Wt(),Bt(),(q.value==="swarm"||q.value==="warroom")&&xt(),q.value==="warroom"&&tt()):s==="mission"?os():s==="execution"?Lt():s==="intervene"?(tt(),Et()):s==="memory"?At():s==="planning"?vn():s==="lab"&&wt()},15e3);return()=>{clearInterval(n)}},[]),Z(()=>{const n=D.value.tab;n==="command"&&(Wt(),Bt(),(q.value==="swarm"||q.value==="warroom")&&xt(),q.value==="warroom"&&tt()),n==="mission"&&(os(),_n()),n==="execution"&&Lt(),n==="intervene"&&(tt(),Et()),n==="memory"&&At(),n==="planning"&&vn(),n==="lab"&&wt()},[D.value.tab]);const t=D.value.tab,e=Qa.find(n=>n.id===t);return i`
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
          <${uf} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${vf} />
        <main class="dashboard-main">
          ${Ea.value&&!Vt.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${_f} />`}
        </main>
      </div>

      <${ku} />
      <${Kd} />
      <${Dd} />
    </div>
  `}const ro=document.getElementById("app");ro&&Yr(i`<${ff} />`,ro);export{tm as _};
