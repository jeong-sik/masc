var Yr=Object.defineProperty;var Xr=(t,e,n)=>e in t?Yr(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var he=(t,e,n)=>Xr(t,typeof e!="symbol"?e+"":e,n);import{e as Qr,_ as Zr,c as v,b as ht,y as ot,A as vi,d as mo,G as tl}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var o=Qr.bind(Zr);const el=["mission","intervene","command","overview","board","goals","agents","ops","trpg"],_i={tab:"mission",params:{},postId:null},nl={overview:"mission",journal:"mission",mdal:"goals",tasks:"goals",execution:"mission",council:"board",activity:"mission",ops:"intervene"};function Po(t){return!!t&&el.includes(t)}function Aa(t){if(t)return nl[t]??t}function Xn(t){try{return decodeURIComponent(t)}catch{return t}}function wa(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function sl(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function fi(t,e){if(t[0]==="chains"){const r={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(r.operation=Xn(t[2])),{tab:"command",params:r,postId:null}}const n=Aa(t[0]),s=Aa(e.tab),a=Po(n)?n:Po(s)?s:"mission";let i=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=Xn(t[2]):t[0]==="post"&&t[1]&&(i=Xn(t[1]))),{tab:a,params:e,postId:i}}function ls(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return _i;const n=Xn(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const l=n.indexOf("?");l>=0&&(s=n.slice(0,l),a=n.slice(l+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=wa(a),r=sl(s);return fi(r,i)}function al(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{..._i,params:wa(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=wa(e.replace(/^\?/,""));return fi(s,a)}function gi(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const M=v(ls(window.location.hash));window.addEventListener("hashchange",()=>{M.value=ls(window.location.hash)});function $t(t,e){const s={tab:Aa(t)??t,params:e??{},postId:null};window.location.hash=gi(s)}function ol(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function il(){if(window.location.hash&&window.location.hash!=="#"){M.value=ls(window.location.hash);return}const t=al(window.location.pathname,window.location.search);if(t){M.value=t;const e=gi(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",M.value=ls(window.location.hash)}const Lo="masc_dashboard_sse_session_id",rl=1e3,ll=15e3,Ot=v(!1),Es=v(0),$i=v(null),cs=v([]);function cl(){let t=sessionStorage.getItem(Lo);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Lo,t)),t}const dl=200;function ul(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};cs.value=[a,...cs.value].slice(0,dl)}function Ca(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Do(t,e){const n=Ca(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function yt(t,e,n,s,a={}){ul(t,e,n,{eventType:s,...a})}let Ct=null,Ce=null,Ta=0;function hi(){Ce&&(clearTimeout(Ce),Ce=null)}function pl(){if(Ce)return;Ta++;const t=Math.min(Ta,5),e=Math.min(ll,rl*Math.pow(2,t));Ce=setTimeout(()=>{Ce=null,yi()},e)}function yi(){hi(),Ct&&(Ct.close(),Ct=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",cl());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);Ct=i,i.onopen=()=>{Ct===i&&(Ta=0,Ot.value=!0)},i.onerror=()=>{Ct===i&&(Ot.value=!1,i.close(),Ct=null,pl())},i.onmessage=r=>{try{const l=JSON.parse(r.data);Es.value++,$i.value=l,ml(l)}catch{}}}function ml(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":yt(n,"Joined","system","agent_joined");break;case"agent_left":yt(n,"Left","system","agent_left");break;case"broadcast":yt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":yt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":yt(n,Do("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Ca(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":yt(n,Do("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Ca(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":yt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":yt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":yt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":yt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:yt(n,e,"system","unknown")}}function vl(){hi(),Ct&&(Ct.close(),Ct=null),Ot.value=!1}function bi(){return new URLSearchParams(window.location.search)}function ki(){const t=bi(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function xi(){return{...ki(),"Content-Type":"application/json"}}const _l=15e3,vo=3e4,fl=6e4,Mo=new Set([408,425,429,500,502,503,504]);class Rn extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);he(this,"method");he(this,"path");he(this,"status");he(this,"statusText");he(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function _o(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Rn({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function gl(){var e,n;const t=bi();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function V(t){const e=await _o(t,{headers:ki()},_l);if(!e.ok)throw new Rn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function $l(t){return new Promise(e=>setTimeout(e,t))}function hl(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function yl(t){if(t instanceof Rn)return t.timeout||typeof t.status=="number"&&Mo.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=hl(t.message);return e!==null&&Mo.has(e)}async function Oe(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!yl(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${i}ms`,a),await $l(i),s+=1}}async function Pt(t,e,n,s=vo){const a=await _o(t,{method:"POST",headers:{...xi(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Rn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function bl(t,e,n,s=vo){const a=await _o(t,{method:"POST",headers:{...xi(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Rn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function kl(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function xl(t){var e,n,s,a,i,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((l=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function Ht(t,e){const n=await bl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},fl),s=kl(n);return xl(s)}function Sl(t="compact"){return V(`/api/v1/dashboard?mode=${t}`)}function Al(){return V("/api/v1/dashboard/semantics")}function wl(){return V("/api/v1/dashboard/mission")}function Cl(){return V("/api/v1/agents?limit=100")}function Tl(t){const e=new URLSearchParams({limit:"200"});return e.set("include_done","true"),e.set("include_cancelled","true"),V(`/api/v1/tasks?${e}`)}function Il(t){const e=new URLSearchParams({limit:"50"});return t!=null&&t>0&&e.set("since_seq",String(t)),V(`/api/v1/messages?${e}`)}function Rl(t={}){return Oe("fetchMdalLoops",async()=>{const e=new URLSearchParams;t.limit!=null&&e.set("limit",String(t.limit)),t.historyLimit!=null&&e.set("history_limit",String(t.historyLimit)),t.status&&e.set("status",t.status);const n=e.toString();return V(`/api/v1/mdal/loops${n?`?${n}`:""}`)})}function Nl(){return V("/api/v1/operator")}function Si(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return V(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Pl(){return V("/api/v1/command-plane")}function Ll(){return V("/api/v1/command-plane/summary")}function Dl(){return V("/api/v1/chains/summary")}function Ml(t){return V(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function El(){return V("/api/v1/command-plane/help")}function zl(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return V(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function Ol(t,e){return Pt(t,e)}function jl(t){switch(t.action_type){case"keeper_msg":case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return vo}}function zs(t){return Pt("/api/v1/operator/action",t,void 0,jl(t))}function Fl(t,e){return Pt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const ql=new Set(["lodge-system","team-session"]);function De(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function Kl(t){return ql.has(t.trim().toLowerCase())}function Hl(t){return t.filter(e=>!Kl(e.author))}function Ul(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Ai(t){if(!O(t))return null;const e=h(t.id,"").trim(),n=h(t.author,"").trim(),s=h(t.content,"").trim();if(!e||!n)return null;const a=q(t.score,0),i=q(t.votes_up,0),r=q(t.votes_down,0),l=q(t.votes,a||i-r),d=q(t.comment_count,q(t.reply_count,0)),m=(()=>{const y=t.flair;if(typeof y=="string"&&y.trim())return y.trim();if(O(y)){const C=h(y.name,"").trim();if(C)return C}return h(t.flair_name,"").trim()||void 0})(),p=h(t.created_at_iso,"").trim()||De(t.created_at),u=h(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?De(t.updated_at):p),$=h(t.title,"").trim()||Ul(s);return{id:e,author:n,title:$,content:s,tags:[],votes:l,vote_balance:a,comment_count:d,created_at:p,updated_at:u,flair:m,hearth_count:q(t.hearth_count,0)}}function Bl(t){if(!O(t))return null;const e=h(t.id,"").trim(),n=h(t.post_id,"").trim(),s=h(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:h(t.content,""),created_at:De(t.created_at)}}async function Wl(t,e){return Oe("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const s=n.toString(),a=await V(`/api/v1/board${s?`?${s}`:""}`),i=Array.isArray(a.posts)?a.posts.map(Ai).filter(l=>l!==null):[];return{posts:e!=null&&e.excludeSystem?Hl(i):i}})}async function Gl(t){return Oe("fetchBoardPost",async()=>{const e=await V(`/api/v1/board/${t}?format=flat`),n=O(e.post)?e.post:e,s=Ai(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(Bl).filter(r=>r!==null);return{...s,comments:i}})}function wi(t,e){return Pt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:gl()})}function Jl(t,e,n){return Pt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Vl(t){const e=h(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function it(...t){for(const e of t){const n=h(e,"");if(n.trim())return n.trim()}return""}function Eo(t){const e=Vl(it(t.outcome,t.result,t.result_code));if(!e)return;const n=it(t.reason,t.reason_code,t.description,t.detail),s=it(t.summary,t.summary_ko,t.summary_en,t.note),a=it(t.details,t.details_text,t.text,t.note),i=it(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=it(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=it(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const u=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof u=="string"?[u]:Array.isArray(u)?u.map(g=>{if(typeof g=="string")return g.trim();if(O(g)){const $=h(g.summary,"").trim();if($)return $;const y=h(g.text,"").trim();if(y)return y;const A=h(g.type,"").trim();return A||h(g.event_id,"").trim()}return""}).filter(g=>g.length>0):[]})(),m=(()=>{const u=q(t.turn,Number.NaN);if(Number.isFinite(u))return u;const g=q(t.turn_number,Number.NaN);if(Number.isFinite(g))return g;const $=q(t.current_turn,Number.NaN);if(Number.isFinite($))return $;const y=q(t.round,Number.NaN);return Number.isFinite(y)?y:void 0})(),p=it(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:l||void 0,turn:m,phase:p||void 0}}function Yl(t,e){const n=O(t.state)?t.state:{};if(h(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>O(r)?h(r.type,"")==="session.outcome":!1),i=O(n.session_outcome)?n.session_outcome:{};if(O(i)&&Object.keys(i).length>0){const r=Eo(i);if(r)return r}if(O(a))return Eo(O(a.payload)?a.payload:{})}function O(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function q(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Xl(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Ia(t,e=!1){return typeof t=="boolean"?t:e}function Be(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(O(e)){const n=h(e.name,"").trim(),s=h(e.id,"").trim(),a=h(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Ql(t){const e={};if(!O(t)&&!Array.isArray(t))return e;if(O(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=h(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!O(n))continue;const s=it(n.to,n.target,n.actor_id,n.name,n.id),a=it(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function Zl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function ft(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const tc=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function ec(t){const e=O(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const i=s.trim();i&&(tc.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function nc(t,e){if(t!=="dice.rolled")return;const n=q(e.raw_d20,0),s=q(e.total,0),a=q(e.bonus,0),i=h(e.action,"roll"),r=q(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function sc(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function ac(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function oc(t,e,n,s){const a=n||e||h(s.actor_id,"")||h(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=h(s.proposed_action,h(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=h(s.reply,h(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return h(s.reply,h(s.content,h(s.text,"Narration")));case"dice.rolled":{const i=h(s.action,"roll"),r=q(s.total,0),l=q(s.dc,0),d=h(s.label,""),m=a||"actor",p=l>0?` vs DC ${l}`:"",u=d?` (${d})`:"";return`${m} ${i}: ${r}${p}${u}`}case"turn.started":return`Turn ${q(s.turn,1)} started`;case"phase.changed":return`Phase: ${h(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(s.name,O(s.actor)?h(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${h(s.keeper_name,h(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${h(s.keeper_name,h(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${q(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${q(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||h(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||h(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${h(s.reason_code,"unknown")}`;case"memory.signal":{const i=O(s.entity_refs)?s.entity_refs:{},r=h(i.requested_tier,""),l=h(i.effective_tier,""),d=Ia(i.guardrail_applied,!1),m=h(s.summary_en,h(s.summary_ko,"Memory signal"));if(!r&&!l)return m;const p=r&&l?`${r}->${l}`:l||r;return`${m} [${p}${d?" (guardrail)":""}]`}case"world.event":{if(h(s.event_type,"")==="canon.check"){const r=h(s.status,"unknown"),l=h(s.contract_id,"n/a");return`Canon ${r}: ${l}`}return h(s.description,h(s.summary,"World event"))}case"combat.attack":return h(s.summary,h(s.result,"Attack resolved"));case"combat.defense":return h(s.summary,h(s.result,"Defense resolved"));case"session.outcome":return h(s.summary,h(s.outcome,"Session ended"));default:{const i=sc(s);return i?`${t}: ${i}`:t}}}function ic(t,e){const n=O(t)?t:{},s=h(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=h(n.actor_name,"").trim()||e[a]||h(O(n.payload)?n.payload.actor_name:"",""),r=O(n.payload)?n.payload:{},l=h(n.ts,h(n.timestamp,new Date().toISOString())),d=h(n.phase,h(r.phase,"")),m=h(n.category,"");return{type:s,actor:i||a||h(r.actor_name,""),actor_id:a||h(r.actor_id,""),actor_name:i,seq:n.seq,room_id:h(n.room_id,""),phase:d||void 0,category:m||ac(s),visibility:h(n.visibility,h(r.visibility,"public")),event_id:h(n.event_id,""),content:oc(s,a,i,r),dice_roll:nc(s,r),timestamp:l}}function rc(t,e,n){var nt,dt;const s=h(t.room_id,"")||n||"default",a=O(t.state)?t.state:{},i=O(a.party)?a.party:{},r=O(a.actor_control)?a.actor_control:{},l=O(a.join_gate)?a.join_gate:{},d=O(a.contribution_ledger)?a.contribution_ledger:{},m=Object.entries(i).map(([W,et])=>{const b=O(et)?et:{},ae=ft(b,"max_hp",void 0,10),Ue=ft(b,"hp",void 0,ae),Dn=ft(b,"max_mp",void 0,0),Mn=ft(b,"mp",void 0,0),E=ft(b,"level",void 0,1),oe=ft(b,"xp",void 0,0),En=Ia(b.alive,Ue>0),Ro=r[W],No=typeof Ro=="string"?Ro:void 0,Hr=Zl(b.role,W,No),Ur=Xl(b.generation),Br=it(b.joined_at,b.joinedAt,b.started_at,b.startedAt),Wr=it(b.claimed_at,b.claimedAt,b.assigned_at,b.assignedAt,b.assigned_time),Gr=it(b.last_seen,b.lastSeen,b.last_seen_at,b.lastSeenAt,b.last_active,b.lastActive),Jr=it(b.scene,b.current_scene,b.currentScene,b.world_scene,b.scene_name,b.sceneName),Vr=it(b.location,b.current_location,b.currentLocation,b.position,b.zone,b.area);return{id:W,name:h(b.name,W),role:Hr,keeper:No,archetype:h(b.archetype,""),persona:h(b.persona,""),portrait:h(b.portrait,"")||void 0,background:h(b.background,"")||void 0,traits:Be(b.traits),skills:Be(b.skills),stats_raw:ec(b),status:En?"active":"dead",generation:Ur,joined_at:Br||void 0,claimed_at:Wr||void 0,last_seen:Gr||void 0,scene:Jr||void 0,location:Vr||void 0,inventory:Be(b.inventory),notes:Be(b.notes),relationships:Ql(b.relationships),stats:{hp:Ue,max_hp:ae,mp:Mn,max_mp:Dn,level:E,xp:oe,strength:ft(b,"strength","str",10),dexterity:ft(b,"dexterity","dex",10),constitution:ft(b,"constitution","con",10),intelligence:ft(b,"intelligence","int",10),wisdom:ft(b,"wisdom","wis",10),charisma:ft(b,"charisma","cha",10)}}}),p=m.filter(W=>W.status!=="dead"),u=Yl(t,e),g={phase_open:Ia(l.phase_open,!0),min_points:q(l.min_points,3),window:h(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},$=Object.entries(d).map(([W,et])=>{const b=O(et)?et:{};return{actor_id:W,score:q(b.score,0),last_reason:h(b.last_reason,"")||null,reasons:Be(b.reasons)}}),y=m.reduce((W,et)=>(W[et.id]=et.name,W),{}),A=e.map(W=>ic(W,y)),C=q(a.turn,1),L=h(a.phase,"round"),j=h(a.map,""),D=O(a.world)?a.world:{},I=j||h(D.ascii_map,h(D.map,"")),R=A.filter((W,et)=>{const b=e[et];if(!O(b))return!1;const ae=O(b.payload)?b.payload:{};return q(ae.turn,-1)===C}),B=(R.length>0?R:A).slice(-12),H=h(a.status,"active");return{session:{id:s,room:s,status:H==="ended"?"ended":H==="paused"?"paused":"active",round:C,actors:p,created_at:((nt=A[0])==null?void 0:nt.timestamp)??new Date().toISOString()},current_round:{round_number:C,phase:L,events:B,timestamp:((dt=A[A.length-1])==null?void 0:dt.timestamp)??new Date().toISOString()},map:I||void 0,join_gate:g,contribution_ledger:$,outcome:u,party:p,story_log:A,history:[]}}async function lc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await V(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function cc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([V(`/api/v1/trpg/state${e}`),lc(t)]);return rc(n,s,t)}function dc(t){return Pt("/api/v1/trpg/rounds/run",{room_id:t})}function uc(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function pc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Pt("/api/v1/trpg/dice/roll",e)}function mc(t,e){const n=uc();return Pt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function vc(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Pt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function _c(t,e,n){return Pt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function fc(t,e,n){const s=await Ht("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function gc(t){const e=await Ht("trpg.mid_join.request",t);return JSON.parse(e)}async function $c(t,e){await Ht("masc_broadcast",{agent_name:t,message:e})}async function hc(t=40){return(await Ht("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function yc(t,e=20){return Ht("masc_task_history",{task_id:t,limit:e})}async function bc(){return Oe("fetchDebates",async()=>{const t=await V("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!O(e))return null;const n=h(e.id,"").trim(),s=h(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,status:h(e.status,"open"),argument_count:q(e.argument_count,0),created_at:De(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function kc(){return Oe("fetchCouncilSessions",async()=>{const t=await V("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!O(e))return null;const n=h(e.id,"").trim(),s=h(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,initiator:h(e.initiator,"system"),votes:q(e.votes,0),quorum:q(e.quorum,0),state:h(e.state,"open"),created_at:De(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function xc(t){const e=await Ht("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Sc(t){return Oe("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await V(`/api/v1/council/debates/${e}/summary`);if(!O(n))return null;const s=h(n.id,"").trim();return s?{id:s,topic:h(n.topic,""),status:h(n.status,"open"),support_count:q(n.support_count,0),oppose_count:q(n.oppose_count,0),neutral_count:q(n.neutral_count,0),total_arguments:q(n.total_arguments,0),created_at:De(n.created_at_iso??n.created_at),summary_text:h(n.summary_text,"")}:null})}function Ac(t,e,n){return Ht("masc_keeper_msg",{name:t,message:e})}async function wc(){try{const t=await Ht("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const Cc=v(""),jt=v({}),rt=v({}),Ra=v({}),Na=v({}),Pa=v({}),La=v({}),Ft=v({});function at(t,e,n){t.value={...t.value,[e]:n}}function Ut(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function U(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function xt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Se(t){return typeof t=="boolean"?t:void 0}function Da(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function Ma(t){return Array.isArray(t)?t.map(e=>U(e)).filter(e=>!!e):[]}function Tc(t){var n;const e=(n=U(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Ic(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Qs(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!Ut(s))continue;const a=U(s.name);if(!a)continue;const i=U(s[e]);e==="summary"?n.push({name:a,summary:i}):n.push({name:a,reason:i})}return n}function Rc(t){if(!Ut(t))return null;const e=U(t.name);return e?{name:e,trigger:U(t.trigger),outcome:U(t.outcome),summary:U(t.summary),reason:U(t.reason)}:null}function Nc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Pc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Ci(t,e,n){return U(t)??Pc(e,n)}function Ti(t,e){return typeof t=="boolean"?t:e==="recover"}function ds(t){if(!Ut(t))return null;const e=U(t.health_state),n=U(t.next_action_path),s=U(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:U(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:Da(t.last_reply_at),last_reply_preview:U(t.last_reply_preview)??null,last_error:U(t.last_error)??null,next_eligible_at_s:xt(t.next_eligible_at_s)??null,recoverable:Ti(t.recoverable,n),summary:Ci(t.summary,e,U(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Ii(t){return Ut(t)?{hour:xt(t.hour),checked:xt(t.checked)??0,acted:xt(t.acted)??0,acted_names:Ma(t.acted_names),activity_report:U(t.activity_report),quiet_hours_overridden:Se(t.quiet_hours_overridden),skipped_reason:U(t.skipped_reason),acted_rows:Qs(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:Qs(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:Qs(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Rc).filter(e=>e!==null):[]}:null}function Lc(t){return Ut(t)?{enabled:Se(t.enabled)??!1,interval_s:xt(t.interval_s)??0,quiet_start:xt(t.quiet_start),quiet_end:xt(t.quiet_end),quiet_active:Se(t.quiet_active),use_planner:Se(t.use_planner),delegate_llm:Se(t.delegate_llm),agent_count:xt(t.agent_count),agents:Ma(t.agents),last_tick_ago_s:xt(t.last_tick_ago_s)??null,last_tick_ago:U(t.last_tick_ago),total_ticks:xt(t.total_ticks),total_checkins:xt(t.total_checkins),last_skip_reason:U(t.last_skip_reason)??null,last_tick_result:Ii(t.last_tick_result),active_self_heartbeats:Ma(t.active_self_heartbeats)}:null}function Dc(t){return Ut(t)?{status:t.status,diagnostic:ds(t.diagnostic)}:null}function Mc(t){return Ut(t)?{recovered:Se(t.recovered)??!1,skipped_reason:U(t.skipped_reason)??null,before:ds(t.before),after:ds(t.after),down:t.down,up:t.up}:null}function Ec(t,e){var j,D;if(!(t!=null&&t.name))return null;const n=U((j=t.agent)==null?void 0:j.status)??U(t.status)??"unknown",s=U((D=t.agent)==null?void 0:D.error)??null,a=t.presence_keepalive??!0,i=t.keepalive_running??!1,r=t.turn_count??0,l=t.last_turn_ago_s??null,d=t.proactive_enabled??!1,m=t.proactive_cooldown_sec??0,p=t.last_proactive_ago_s??null,u=d&&p!=null?Math.max(0,m-p):null,g=r<=0||l==null?"never":l>900?"stale":"fresh",$=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,y=s??(a&&!i?"keeper keepalive is not running":null),A=n==="offline"||n==="inactive"?"offline":y?"degraded":g==="stale"?"stale":g==="never"?"idle":"healthy",C=y?Nc(y):e!=null&&e.quiet_active&&g!=="fresh"?"quiet_hours":a&&!i?"disabled":r<=0?"never_started":u!=null&&u>0?"min_gap":g==="fresh"||g==="stale"?"no_recent_activity":"unknown",L=A==="offline"||A==="degraded"||A==="stale"?"recover":C==="quiet_hours"?"manual_lodge_poke":C==="unknown"?"probe":"direct_message";return{health_state:A,quiet_reason:C,next_action_path:L,last_reply_status:g,last_reply_at:$,last_reply_preview:null,last_error:y,next_eligible_at_s:u!=null&&u>0?u:null,recoverable:Ti(void 0,L),summary:Ci(void 0,A,C),keepalive_running:i}}function zc(t,e){if(!Ut(t))return null;const n=Tc(t.role),s=U(t.content)??U(t.preview);if(!s)return null;const a=Da(t.ts_unix)??Da(t.timestamp);return{id:`${n}-${a??"entry"}-${e}`,role:n,label:Ic(n),text:s,timestamp:a,delivery:"history"}}function Oc(t,e,n){const s=Ut(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((i,r)=>zc(i,r)).filter(i=>i!==null):[];return{name:t,diagnostic:ds(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function zo(t,e){const n=rt.value[t]??[];rt.value={...rt.value,[t]:[...n,e].slice(-50)}}function jc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Fc(t,e){const s=(rt.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(i=>jc(a,i)));rt.value={...rt.value,[t]:[...e,...s].slice(-50)}}function Os(t,e){jt.value={...jt.value,[t]:e},Fc(t,e.history)}function Oo(t,e){const n=jt.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Os(t,{...n,diagnostic:{...s,...e}})}async function fo(){pn();try{await fe()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function qc(t){Cc.value=t.trim()}async function Ri(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&jt.value[n])return jt.value[n];at(Ra,n,!0),at(Ft,n,null);try{const s=await Ht("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const i=Oc(n,s,a);return Os(n,i),i}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return at(Ft,n,a),null}finally{at(Ra,n,!1)}}async function Kc(t,e){const n=t.trim(),s=e.trim();if(!n||!s)return;const a=`local-${Date.now()}`;zo(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),at(Na,n,!0),at(Ft,n,null);try{const i=await Ac(n,s);rt.value={...rt.value,[n]:(rt.value[n]??[]).map(r=>r.id===a?{...r,delivery:"delivered"}:r)},zo(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Oo(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await fo()}catch(i){const r=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw rt.value={...rt.value,[n]:(rt.value[n]??[]).map(l=>l.id===a?{...l,delivery:"error",error:r}:l)},Oo(n,{last_reply_status:"error",last_error:r}),at(Ft,n,r),i}finally{at(Na,n,!1)}}async function Hc(t,e){const n=t.trim();if(!n)return null;at(Pa,n,!0),at(Ft,n,null);try{const s=await zs({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=Dc(s.result),i=(a==null?void 0:a.diagnostic)??null;if(i){const r=jt.value[n];Os(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??rt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await fo(),i}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw at(Ft,n,a),s}finally{at(Pa,n,!1)}}async function Uc(t,e){const n=t.trim();if(!n)return null;at(La,n,!0),at(Ft,n,null);try{const s=await zs({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Mc(s.result),i=(a==null?void 0:a.after)??null;if(i){const r=jt.value[n];Os(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??rt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await fo(),i}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw at(Ft,n,a),s}finally{at(La,n,!1)}}function ie(t){return(t??"").trim().toLowerCase()}function pt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Qn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function zn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function We(t){return t.last_heartbeat??zn(t.last_turn_ago_s)??zn(t.last_proactive_ago_s)??zn(t.last_handoff_ago_s)??zn(t.last_compaction_ago_s)}function Bc(t){const e=t.title.trim();return e||Qn(t.content)}function Wc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Gc(t,e,n,s,a={}){var D;const i=ie(t),r=e.filter(I=>ie(I.assignee)===i&&(I.status==="claimed"||I.status==="in_progress")).length,l=n.filter(I=>ie(I.from)===i).sort((I,R)=>pt(R.timestamp)-pt(I.timestamp))[0],d=s.filter(I=>ie(I.agent)===i||ie(I.author)===i).sort((I,R)=>pt(R.timestamp)-pt(I.timestamp))[0],m=(a.boardPosts??[]).filter(I=>ie(I.author)===i).sort((I,R)=>pt(R.updated_at||R.created_at)-pt(I.updated_at||I.created_at))[0],p=(a.keepers??[]).filter(I=>ie(I.name)===i&&We(I)!==null).sort((I,R)=>pt(We(R)??0)-pt(We(I)??0))[0],u=l?pt(l.timestamp):0,g=d?pt(d.timestamp):0,$=m?pt(m.updated_at||m.created_at):0,y=p?pt(We(p)??0):0,A=a.lastSeen?pt(a.lastSeen):0,C=((D=a.currentTask)==null?void 0:D.trim())||(r>0?`${r} claimed tasks`:null);if(u===0&&g===0&&$===0&&y===0&&A===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:C};const j=[l?{timestamp:l.timestamp,ts:u,text:Qn(l.content)}:null,m?{timestamp:m.updated_at||m.created_at,ts:$,text:`Post: ${Qn(Bc(m))}`}:null,p?{timestamp:We(p),ts:y,text:Wc(p)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:g,text:Qn(d.text)}:null].filter(I=>I!==null).sort((I,R)=>R.ts-I.ts)[0];return j&&j.ts>=A?{activeAssignedCount:r,lastActivityAt:j.timestamp,lastActivityText:j.text}:{activeAssignedCount:r,lastActivityAt:a.lastSeen??null,lastActivityText:C??"Presence heartbeat"}}const Nt=v([]),St=v([]),ln=v([]),ge=v([]),je=v(null),Jc=v(null),Ea=v(new Map),Fe=v([]),cn=v("hot"),ce=v(!0),Ni=v(null),zt=v(""),dn=v([]),Ae=v(!1),Pi=v(new Map),za=v("unknown"),Oa=v(null),ja=v(!1),un=v(!1),Fa=v(!1),we=v(!1),go=v(null),us=v(!1),ps=v(null),Vc=v(null),qa=v(null),Li=v(null),Di=v(null),Yc=v(null);ht(()=>Nt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const Xc=ht(()=>{const t=St.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Mi=ht(()=>{const t=new Map,e=St.value,n=ln.value,s=cs.value,a=Fe.value,i=ge.value;for(const r of Nt.value)t.set(r.name.trim().toLowerCase(),Gc(r.name,e,n,s,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:a,keepers:i}));return t});function Qc(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const Zc=ht(()=>{const t=new Map;for(const e of ge.value)t.set(e.name,Qc(e));return t}),td=12e4;function ed(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof a=="number"?Date.now()-a*1e3:null}const nd=ht(()=>{const t=Date.now(),e=new Set,n=Ea.value;for(const s of ge.value){const a=ed(s,n);a!=null&&t-a>td&&e.add(s.name)}return e}),ms={},sd=5e3;let Zs=null;function ad(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function pn(){delete ms.compact,delete ms.full}function lt(t){return typeof t=="object"&&t!==null}function x(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function w(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function me(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Ka(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Ei(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function od(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function zi(t){if(!lt(t))return null;const e=x(t.name);return e?{name:e,status:Ei(t.status),current_task:x(t.current_task)??null,last_seen:x(t.last_seen),emoji:x(t.emoji),koreanName:x(t.koreanName)??x(t.korean_name),model:x(t.model),traits:me(t.traits),interests:me(t.interests),activityLevel:w(t.activityLevel)??w(t.activity_level),primaryValue:x(t.primaryValue)??x(t.primary_value)}:null}function Oi(t){if(!lt(t))return null;const e=x(t.id),n=x(t.title);return!e||!n?null:{id:e,title:n,status:od(t.status),priority:w(t.priority),assignee:x(t.assignee),description:x(t.description),created_at:x(t.created_at),updated_at:x(t.updated_at)}}function ji(t){if(!lt(t))return null;const e=x(t.from)??x(t.from_agent)??"system",n=x(t.content)??"",s=x(t.timestamp)??new Date().toISOString();return{id:x(t.id),seq:w(t.seq),from:e,content:n,timestamp:s,type:x(t.type)}}function id(t){return Array.isArray(t)?t.map(e=>{if(!lt(e))return null;const n=w(e.ts_unix);if(n==null)return null;const s=lt(e.handoff)?e.handoff:null;return{ts:n,context_ratio:w(e.context_ratio)??0,context_tokens:w(e.context_tokens)??0,context_max:w(e.context_max)??0,latency_ms:w(e.latency_ms)??0,generation:w(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:w(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:w(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?w(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function jo(t){if(!lt(t))return null;const e=x(t.health_state),n=x(t.next_action_path),s=x(t.last_reply_status);if(!e||!n||!s)return null;const a=x(t.quiet_reason)??null,i=x(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:Ka(t.last_reply_at)??x(t.last_reply_at)??null,last_reply_preview:x(t.last_reply_preview)??null,last_error:x(t.last_error)??null,next_eligible_at_s:w(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:i,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function rd(t,e){return(Array.isArray(t)?t:lt(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!lt(s))return null;const a=lt(s.agent)?s.agent:null,i=lt(s.context)?s.context:null,r=lt(s.metrics_window)?s.metrics_window:void 0,l=x(s.name);if(!l)return null;const d=w(s.context_ratio)??w(i==null?void 0:i.context_ratio),m=x(s.status)??x(a==null?void 0:a.status)??"offline",p=Ei(m),u=x(s.model)??x(s.active_model)??x(s.primary_model),g=me(s.skill_secondary),$=i?{source:x(i.source),context_ratio:w(i.context_ratio),context_tokens:w(i.context_tokens),context_max:w(i.context_max),message_count:w(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,y=a?{name:x(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:x(a.error),status:x(a.status),current_task:x(a.current_task)??null,last_seen:x(a.last_seen),last_seen_ago_s:w(a.last_seen_ago_s),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,A=id(s.metrics_series),C={name:l,emoji:x(s.emoji),koreanName:x(s.koreanName)??x(s.korean_name),agent_name:x(s.agent_name),trace_id:x(s.trace_id),model:u,primary_model:x(s.primary_model),active_model:x(s.active_model),next_model_hint:x(s.next_model_hint)??null,status:p,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:w(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:w(s.proactive_idle_sec),proactive_cooldown_sec:w(s.proactive_cooldown_sec),last_heartbeat:x(s.last_heartbeat)??x(a==null?void 0:a.last_seen),generation:w(s.generation),turn_count:w(s.turn_count)??w(s.total_turns),keeper_age_s:w(s.keeper_age_s),last_turn_ago_s:w(s.last_turn_ago_s),last_handoff_ago_s:w(s.last_handoff_ago_s),last_compaction_ago_s:w(s.last_compaction_ago_s),last_proactive_ago_s:w(s.last_proactive_ago_s),context_ratio:d,context_tokens:w(s.context_tokens)??w(i==null?void 0:i.context_tokens),context_max:w(s.context_max)??w(i==null?void 0:i.context_max),context_source:x(s.context_source)??x(i==null?void 0:i.source),context:$,traits:me(s.traits),interests:me(s.interests),primaryValue:x(s.primaryValue)??x(s.primary_value),activityLevel:w(s.activityLevel)??w(s.activity_level),memory_recent_note:x(s.memory_recent_note)??null,conversation_tail_count:w(s.conversation_tail_count),k2k_count:w(s.k2k_count),handoff_count_total:w(s.handoff_count_total)??w(s.trace_history_count),compaction_count:w(s.compaction_count),last_compaction_saved_tokens:w(s.last_compaction_saved_tokens),diagnostic:jo(s.diagnostic),skill_primary:x(s.skill_primary)??null,skill_secondary:g,skill_reason:x(s.skill_reason)??null,metrics_series:A.length>0?A:void 0,metrics_window:r,agent:y};return C.diagnostic=jo(s.diagnostic)??Ec(C,(e==null?void 0:e.lodge)??null),C}).filter(s=>s!==null)}function ld(t){return lt(t)?{...t,lodge:Lc(t.lodge)??void 0}:null}function cd(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function dd(t){if(!lt(t))return null;const e=w(t.iteration);if(e==null)return null;const n=w(t.metric_before)??0,s=w(t.metric_after)??n,a=lt(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:w(t.delta)??s-n,changes:x(t.changes)??"",failed_attempts:x(t.failed_attempts)??"",next_suggestion:x(t.next_suggestion)??"",elapsed_ms:w(t.elapsed_ms)??0,cost_usd:w(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:x(a.worker_model)??"",tool_call_count:w(a.tool_call_count)??0,tool_names:me(a.tool_names)??[],session_id:x(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function ud(t){var i,r;if(!lt(t))return null;const e=x(t.loop_id);if(!e)return null;const n=w(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(dd).filter(l=>l!==null):[],a=w(t.current_metric)??((i=s[0])==null?void 0:i.metric_after)??n;return{loop_id:e,profile:x(t.profile)??"unknown",status:cd(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:x(t.error_message)??x(t.error_reason)??null,stop_reason:x(t.stop_reason)??x(t.reason)??null,current_iteration:w(t.current_iteration)??((r=s[0])==null?void 0:r.iteration)??0,max_iterations:w(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:x(t.target)??"",stagnation_streak:w(t.stagnation_streak)??0,stagnation_limit:w(t.stagnation_limit)??0,elapsed_seconds:w(t.elapsed_seconds)??0,updated_at:Ka(t.updated_at)??null,stopped_at:Ka(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:x(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:w(t.latest_tool_call_count)??0,latest_tool_names:me(t.latest_tool_names)??[],session_id:x(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function fe(t="full"){var s,a,i;const e=Date.now(),n=ms[t];if(!(n&&e-n.time<sd)){ja.value=!0;try{const r=await Sl(t);ms[t]={data:r,time:e},Nt.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map(zi).filter(d=>d!==null),St.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map(Oi).filter(d=>d!==null),ln.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(ji).filter(d=>d!==null);const l=ld(r.status);je.value=l,ge.value=rd(r.keepers,l),Jc.value=r.perpetual??null,Vc.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{ja.value=!1}}}async function Fi(){us.value=!0,ps.value=null;try{const t=await Al();go.value=t,Yc.value=new Date().toISOString()}catch(t){ps.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{us.value=!1}}function pd(t){var e;return((e=go.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function md(t){var n;const e=((n=go.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(i=>i.id===t);if(a)return a}return null}async function vd(){try{const t=await Cl(),e=(Array.isArray(t.agents)?t.agents:[]).map(zi).filter(a=>a!==null),n=Nt.value,s=new Map(n.map(a=>[a.name,a]));Nt.value=e.map(a=>{const i=s.get(a.name);return i?{...i,status:a.status,current_task:a.current_task}:a})}catch(t){console.error("Agents selective fetch error:",t)}}async function _d(){try{const t=await Tl({includeDone:!0,includeCancelled:!0}),e=(Array.isArray(t.tasks)?t.tasks:[]).map(Oi).filter(a=>a!==null),n=St.value,s=new Map(n.map(a=>[a.id,a]));St.value=e.map(a=>{const i=s.get(a.id);return i?{...i,status:a.status,priority:a.priority??i.priority,assignee:a.assignee??i.assignee}:a})}catch(t){console.error("Tasks selective fetch error:",t)}}async function fd(){try{const t=ln.value,e=t.reduce((l,d)=>Math.max(l,d.seq??0),0),n=await Il(e),s=(Array.isArray(n.messages)?n.messages:[]).map(ji).filter(l=>l!==null);if(s.length===0)return;const a=new Set(t.map(l=>l.seq).filter(l=>l!=null)),i=new Set(t.filter(l=>l.seq==null).map(l=>`${l.timestamp}|${l.from}`)),r=s.filter(l=>{if(l.seq!=null)return!a.has(l.seq);const d=`${l.timestamp}|${l.from}`;return i.has(d)?!1:(i.add(d),!0)});if(r.length>0){const l=[...t,...r];ln.value=l.length>500?l.slice(-500):l}}catch(t){console.error("Messages selective fetch error:",t)}}async function It(){un.value=!0;try{const t=await Wl(cn.value,{excludeSystem:ce.value});Fe.value=t.posts??[],qa.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{un.value=!1}}async function Rt(){var t;Fa.value=!0;try{const e=zt.value||((t=je.value)==null?void 0:t.room)||"default";zt.value||(zt.value=e);const n=await cc(e);Ni.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Fa.value=!1}}async function mn(){Ae.value=!0;try{const t=await wc();dn.value=Array.isArray(t)?t:[],Li.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Ae.value=!1}}async function Me(){we.value=!0;try{const t=await Rl(),e=Array.isArray(t.loops)?t.loops:[],n=new Map;for(const s of e){const a=ud(s);a&&n.set(a.loop_id,a)}Pi.value=n,Di.value=new Date().toISOString(),Oa.value=null,za.value=n.size===0?"idle":"ready"}catch(t){console.error("MDAL fetch error:",t),za.value="error",Oa.value=t instanceof Error?t.message:String(t)}finally{we.value=!1}}let Zn=null;function gd(t){Zn=t}let ts=null;function $d(t){ts=t}let es=null;function hd(t){es=t}const de={};function re(t,e,n=500){de[t]&&clearTimeout(de[t]),de[t]=setTimeout(()=>{e(),delete de[t]},n)}function yd(){const t=$i.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Ea.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Ea.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&re("agents",vd),ad(e.type)&&(pn(),Zs||(Zs=setTimeout(()=>{fe(),ts==null||ts(),es==null||es(),Zs=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&re("tasks",_d),e.type==="broadcast"&&re("messages",fd),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&re("dashboard",()=>{pn(),fe()}),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&re("board",It),e.type.startsWith("decision_")&&re("council",()=>Zn==null?void 0:Zn()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&re("mdal",Me,350)}});return()=>{t();for(const e of Object.keys(de))clearTimeout(de[e]),delete de[e]}}let Ze=null;function bd(){Ze||(Ze=setInterval(()=>{Ot.value||pn(),fe()},1e4))}function kd(){Ze&&(clearInterval(Ze),Ze=null)}function xd({metric:t}){return o`
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
  `}function Sd({panel:t}){return o`
    <div class="semantic-body">
      <div class="semantic-grid">
        <span>Purpose</span><span>${t.purpose}</span>
        <span>Solves</span><span>${t.problem_solved}</span>
        <span>When</span><span>${t.when_active}</span>
        <span>Agent Role</span><span>${t.agent_role}</span>
        <span>Ecosystem</span><span>${t.ecosystem_function}</span>
      </div>
      ${t.related_tools.length>0?o`<div class="semantic-tag-row">
            ${t.related_tools.map(e=>o`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
      ${t.metrics.length>0?o`<div class="semantic-metric-list">
            ${t.metrics.map(e=>o`<${xd} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function z({panelId:t,compact:e=!1,label:n="Why"}){const s=md(t);return s?o`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${Sd} panel=${s} />
    </details>
  `:us.value?o`<span class="semantic-inline-state">Loading semantics…</span>`:null}function ee({surfaceId:t,compact:e=!1}){const n=pd(t);return n?o`
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
      ${n.panels.length>0?o`<div class="semantic-tag-row">
            ${n.panels.map(s=>o`<span class="semantic-tag">${s.title}</span>`)}
          </div>`:null}
    </section>
  `:us.value?o`<div class="semantic-surface-card ${e?"compact":""}">Loading semantics…</div>`:ps.value?o`<div class="semantic-surface-card ${e?"compact":""}">${ps.value}</div>`:null}function T({title:t,class:e,semanticId:n,children:s}){return o`
    <div class="card ${e??""}">
      ${t?o`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?o`<${z} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${s}
    </div>
  `}const qi=v(null),Ha=v(!1),vs=v(null);function X(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function P(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function J(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function $o(t){return typeof t=="boolean"?t:void 0}function Dt(t,e=[]){if(Array.isArray(t))return t;if(!X(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function js(t){if(!X(t))return null;const e=P(t.kind),n=P(t.summary),s=P(t.target_type);return!e||!n||!s?null:{kind:e,severity:P(t.severity)??"warn",summary:n,target_type:s,target_id:P(t.target_id)??null,actor:P(t.actor)??null,evidence:t.evidence}}function Fs(t){if(!X(t))return null;const e=P(t.action_type),n=P(t.target_type),s=P(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:P(t.target_id)??null,severity:P(t.severity)??"warn",reason:s,confirm_required:$o(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Ad(t){if(!X(t))return null;const e=P(t.session_id);return e?{session_id:e,goal:P(t.goal),status:P(t.status),health:P(t.health),scale_profile:P(t.scale_profile),control_profile:P(t.control_profile),planned_worker_count:J(t.planned_worker_count),active_agent_count:J(t.active_agent_count),last_turn_age_sec:J(t.last_turn_age_sec)??null,attention_count:J(t.attention_count),recommended_action_count:J(t.recommended_action_count),top_attention:js(t.top_attention),top_recommendation:Fs(t.top_recommendation)}:null}function wd(t){if(!X(t))return null;const e=P(t.session_id);return e?{session_id:e,status:P(t.status),progress_pct:J(t.progress_pct),elapsed_sec:J(t.elapsed_sec),remaining_sec:J(t.remaining_sec),done_delta_total:J(t.done_delta_total),summary:X(t.summary)?t.summary:void 0,team_health:X(t.team_health)?t.team_health:void 0,communication_metrics:X(t.communication_metrics)?t.communication_metrics:void 0,orchestration_state:X(t.orchestration_state)?t.orchestration_state:void 0,cascade_metrics:X(t.cascade_metrics)?t.cascade_metrics:void 0,report_paths:X(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([n,s])=>{const a=P(s);return a?[n,a]:null}).filter(n=>n!==null)):void 0,session:X(t.session)?t.session:void 0,recent_events:Dt(t.recent_events,["events"]).filter(X)}:null}function Cd(t){if(!X(t))return null;const e=P(t.name);return e?{name:e,agent_name:P(t.agent_name),status:P(t.status),autonomy_level:P(t.autonomy_level),context_ratio:J(t.context_ratio),generation:J(t.generation),active_goal_ids:Dt(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:P(t.last_autonomous_action_at)??null,last_turn_ago_s:J(t.last_turn_ago_s),model:P(t.model)}:null}function Td(t){if(!X(t))return null;const e=P(t.confirm_token)??P(t.token);return e?{confirm_token:e,actor:P(t.actor),action_type:P(t.action_type),target_type:P(t.target_type),target_id:P(t.target_id)??null,delegated_tool:P(t.delegated_tool),created_at:P(t.created_at),preview:t.preview}:null}function Id(t){if(!X(t))return null;const e=P(t.action_type),n=P(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:P(t.description),confirm_required:$o(t.confirm_required)}}function Rd(t){const e=X(t)?t:{};return{room_health:P(e.room_health),cluster:P(e.cluster),project:P(e.project),current_room:P(e.current_room)??null,paused:$o(e.paused),tempo_interval_s:J(e.tempo_interval_s),active_agents:J(e.active_agents),keeper_pressure:J(e.keeper_pressure),active_operations:J(e.active_operations),pending_approvals:J(e.pending_approvals),incident_count:J(e.incident_count),recommended_action_count:J(e.recommended_action_count),top_attention:js(e.top_attention),top_action:Fs(e.top_action)}}function Nd(t){const e=X(t)?t:{},n=X(e.swarm_overview)?e.swarm_overview:{};return{health:P(e.health),active_operations:J(e.active_operations),pending_approvals:J(e.pending_approvals),swarm_overview:{active_lanes:J(n.active_lanes),moving_lanes:J(n.moving_lanes),stalled_lanes:J(n.stalled_lanes),projected_lanes:J(n.projected_lanes),last_movement_at:P(n.last_movement_at)??null},top_attention:js(e.top_attention),top_action:Fs(e.top_action),session_cards:Dt(e.session_cards).map(Ad).filter(s=>s!==null)}}function Pd(t){const e=X(t)?t:{};return{sessions:Dt(e.sessions,["items"]).map(wd).filter(n=>n!==null),keepers:Dt(e.keepers,["items"]).map(Cd).filter(n=>n!==null),pending_confirms:Dt(e.pending_confirms).map(Td).filter(n=>n!==null),available_actions:Dt(e.available_actions).map(Id).filter(n=>n!==null)}}function Ld(t){const e=X(t)?t:{};return{generated_at:P(e.generated_at),summary:Rd(e.summary),incidents:Dt(e.incidents).map(js).filter(n=>n!==null),recommended_actions:Dt(e.recommended_actions).map(Fs).filter(n=>n!==null),command_focus:Nd(e.command_focus),operator_targets:Pd(e.operator_targets)}}async function Ua(){Ha.value=!0,vs.value=null;try{const t=await wl();qi.value=Ld(t)}catch(t){vs.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{Ha.value=!1}}const Ba="masc_dashboard_workflow_context";function ho(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function bt(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function Bt(t){const e=bt(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function Ki(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function Wa(t){return ho(t)?t:null}function Dd(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function Md(t){if(!t)return null;try{const e=JSON.parse(t);if(!ho(e))return null;const n=bt(e.id),s=bt(e.source_surface),a=bt(e.source_label),i=bt(e.summary),r=bt(e.created_at);return!n||s!=="mission"||!a||!i||!r?null:{id:n,source_surface:"mission",source_label:a,action_type:bt(e.action_type),target_type:bt(e.target_type),target_id:bt(e.target_id),focus_kind:bt(e.focus_kind),summary:i,payload_preview:bt(e.payload_preview),suggested_payload:Wa(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:r}}catch{return null}}function Ed(){const t=Ki();return Md((t==null?void 0:t.getItem(Ba))??null)}const Hi=v(Ed());function zd(t){Hi.value=t;const e=Ki();if(!e)return;if(!t){e.removeItem(Ba);return}const n=Dd(t);n&&e.setItem(Ba,n)}function Ui(t){if(!t)return null;const e=Wa(t.suggested_payload);if(e)return e;if(ho(t.preview)){const n=Wa(t.preview.payload);if(n)return n}return null}function Bi(t){if(!t)return null;const e=Bt(t.message);if(e)return e;const n=Bt(t.task_title)??Bt(t.title),s=Bt(t.task_description)??Bt(t.description),a=Bt(t.reason),i=Bt(t.priority)??Bt(t.task_priority);return n&&s?`${n} · ${s}`:n&&i?`${n} · P${i}`:n||s||a||null}function Wi(t,e,n,s,a,i){return["mission",t,e??"action",n??"target",s??"room",a??"focus",i].join(":")}function qe(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=Ui(t),i=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,r=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,l=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,d=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:Wi(n,(t==null?void 0:t.action_type)??null,i,r,l,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:i,target_id:r,focus_kind:l,summary:d,payload_preview:Bi(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function Od(t,e){return e.source==="mission"&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)}function Nn(t){const{params:e}=t;if(e.source!=="mission")return null;const n=Hi.value;if(n&&Od(n,e))return n;const s=new Date().toISOString();return{id:Wi("상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,s),source_surface:"mission",source_label:"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,summary:e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function jd(t){return{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function Gi(t){const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.target_type==="room"?"summary":"swarm"}function Fd(t){return{source:"mission",surface:Gi(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function yo(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function qs(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";default:return(t==null?void 0:t.trim())||"추천 액션"}}function qd(t){switch(t){case"summary":return"요약";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}function vt(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}function Ga(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:`${Math.round(n/3600)}h 전`}function Ji(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function Ja(t){return Bi(Ui(t))}function Vi(t){return yo(t?qe(t,null,"상황판 추천 액션"):null)}function Ks(t,e=qe()){zd(e),$t(t,t==="intervene"?jd(e):Fd(e))}function Kd(t){Ks("intervene",qe(null,t,"상황판 incident"))}function Hd(t){Ks("command",qe(null,t,"상황판 incident"))}function Yi(t,e,n="상황판 추천 액션"){Ks("intervene",qe(t,e,n))}function Xi(t,e,n="상황판 추천 액션"){Ks("command",qe(t,e,n))}function Ud({cluster:t,project:e,room:n,generatedAt:s}){return o`
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
        <strong>${s?Ga(s):"fresh"}</strong>
      </div>
    </div>
  `}function ye({label:t,value:e,detail:n,tone:s}){return o`
    <article class="mission-stat-card ${vt(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function Bd({item:t}){return o`
    <article class="mission-incident-card ${vt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${vt(t.severity)}">${t.severity}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <strong>${t.summary}</strong>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Kd(t)}>이 이슈로 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Hd(t)}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `}function Wd({action:t,incident:e}){const n=Ja(t);return o`
    <article class="mission-action-card ${vt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${vt(t.severity)}">${qs(t.action_type)}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.reason}</p>
      <div class="mission-action-detail">
        <span>${Ji(t)}</span>
        <span>${Vi(t)}</span>
      </div>
      ${n?o`<div class="mission-action-preview">${n}</div>`:null}
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Yi(t,e,"상황판 추천 액션")}>이 액션으로 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Xi(t,e,"상황판 추천 액션")}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `}function Gd({session:t}){return o`
    <article class="mission-session-card ${vt(t.health)}">
      <div class="mission-card-head">
        <strong>${t.goal??t.session_id}</strong>
        <span class="command-chip ${vt(t.health)}">${t.health??"ok"}</span>
      </div>
      <div class="mission-session-meta">
        <span>${t.status??"unknown"}</span>
        <span>worker ${t.active_agent_count??0}/${t.planned_worker_count??0}</span>
        <span>${t.last_turn_age_sec!=null?`${t.last_turn_age_sec}s ago`:"freshness n/a"}</span>
      </div>
      <div class="mission-session-summary">
        <span>attention ${t.attention_count??0}</span>
        <span>action ${t.recommended_action_count??0}</span>
      </div>
    </article>
  `}function ta(){var r,l,d;const t=qi.value;if(Ha.value&&!t)return o`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(vs.value&&!t)return o`<div class="empty-state error">${vs.value}</div>`;if(!t)return o`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;const e=t.summary,n=t.incidents[0]??e.top_attention??null,s=t.recommended_actions[0]??e.top_action??null,a=t.command_focus.session_cards.slice(0,3),i=t.operator_targets.keepers.slice(0,4);return o`
    <section class="dashboard-panel mission-view">
      <${ee} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 문제, 다음 액션, 운영 포커스를 한 번에 보는 운영 랜딩입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${vt(e.room_health)}">${e.room_health??"ok"}</span>
          <span class="command-chip">${e.project??"room"}${e.current_room?` · ${e.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?Ga(t.generated_at):"fresh"}</span>
        </div>
      </div>

      <${Ud}
        cluster=${e.cluster}
        project=${e.project}
        room=${e.current_room}
        generatedAt=${t.generated_at}
      />

      <div class="mission-stat-grid">
        <${ye} label="활성 에이전트" value=${e.active_agents??0} detail="실시간 응답 가능한 agent 수" tone=${e.active_agents&&e.active_agents>0?"ok":"warn"} />
        <${ye} label="Keeper 압력" value=${e.keeper_pressure??0} detail="stale / hot keeper 수" tone=${(e.keeper_pressure??0)>0?"warn":"ok"} />
        <${ye} label="활성 작전" value=${e.active_operations??0} detail="command plane active operation" tone=${(e.active_operations??0)>0?"ok":"warn"} />
        <${ye} label="승인 대기" value=${e.pending_approvals??0} detail="사람 확인이 필요한 decision" tone=${(e.pending_approvals??0)>0?"warn":"ok"} />
        <${ye} label="우선 Incident" value=${e.incident_count??t.incidents.length} detail="지금 우선순위로 볼 attention item" tone=${(n==null?void 0:n.severity)??"ok"} />
        <${ye} label="다음 액션" value=${e.recommended_action_count??t.recommended_actions.length} detail="digest 기준 추천 액션 수" tone=${(s==null?void 0:s.severity)??"ok"} />
      </div>

      <div class="mission-primary-grid">
        <${T} title="지금 가장 먼저 볼 것" class="mission-hero-card" semanticId="mission.hero">
          ${n?o`
                <div class="mission-priority-block ${vt(n.severity)}">
                  <div class="mission-card-head">
                    <span class="command-chip ${vt(n.severity)}">${n.kind}</span>
                    <span class="mission-card-target">${n.target_type}${n.target_id?` · ${n.target_id}`:""}</span>
                  </div>
                  <strong>${n.summary}</strong>
                </div>
              `:o`<div class="empty-state">우선 incident가 없습니다.</div>`}
          ${s?o`
                <div class="mission-action-highlight">
                  <div class="mission-card-head">
                    <span class="command-chip ${vt(s.severity)}">${qs(s.action_type)}</span>
                    <span class="mission-card-target">${s.target_type}${s.target_id?` · ${s.target_id}`:""}</span>
                  </div>
                  <p>${s.reason}</p>
                  <div class="mission-action-detail">
                    <span>${Ji(s)}</span>
                    <span>${Vi(s)}</span>
                  </div>
                  ${Ja(s)?o`<div class="mission-action-preview">${Ja(s)}</div>`:null}
                  <div class="mission-card-actions">
                    <button class="control-btn ghost" onClick=${()=>Yi(s,n,"상황판 hero 액션")}>이 액션으로 개입 열기</button>
                    <button class="control-btn ghost" onClick=${()=>Xi(s,n,"상황판 hero 액션")}>이 이슈의 원인 보기</button>
                  </div>
                </div>
              `:null}
        <//>

        <${T} title="운영 포커스" class="mission-focus-card" semanticId="mission.focus">
          <div class="mission-focus-grid">
            <div class="mission-focus-item">
              <span>지휘 건강도</span>
              <strong class=${vt(t.command_focus.health)}>${t.command_focus.health??"ok"}</strong>
            </div>
            <div class="mission-focus-item">
              <span>활성 레인</span>
              <strong>${((r=t.command_focus.swarm_overview)==null?void 0:r.active_lanes)??0}</strong>
            </div>
            <div class="mission-focus-item">
              <span>이동 레인</span>
              <strong>${((l=t.command_focus.swarm_overview)==null?void 0:l.moving_lanes)??0}</strong>
            </div>
            <div class="mission-focus-item">
              <span>마지막 이동</span>
              <strong>${Ga((d=t.command_focus.swarm_overview)==null?void 0:d.last_movement_at)}</strong>
            </div>
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>$t("command")}>지휘면 열기</button>
            <button class="control-btn ghost" onClick=${()=>$t("command",{surface:"swarm"})}>스웜 상세</button>
          </div>
        <//>
      </div>

      <div class="mission-content-grid">
        <${T} title="우선 Incident" class="mission-list-card" semanticId="mission.incidents">
          <div class="mission-list-stack">
            ${t.incidents.length>0?t.incidents.slice(0,5).map(m=>o`<${Bd} item=${m} />`):o`<div class="empty-state">attention item이 없습니다.</div>`}
          </div>
        <//>

        <${T} title="추천 액션" class="mission-list-card" semanticId="mission.actions">
          <div class="mission-list-stack">
            ${t.recommended_actions.length>0?t.recommended_actions.slice(0,4).map(m=>o`<${Wd} action=${m} />`):o`<div class="empty-state">추천 액션이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-content-grid">
        <${T} title="집중 세션" class="mission-list-card" semanticId="mission.sessions">
          <div class="mission-list-stack">
            ${a.length>0?a.map(m=>o`<${Gd} session=${m} />`):o`<div class="empty-state">지금 강조할 session이 없습니다.</div>`}
          </div>
        <//>

        <${T} title="바로 개입할 대상" class="mission-list-card" semanticId="mission.targets">
          <div class="mission-target-grid">
            <div class="mission-target-block">
              <span class="mission-target-title">Keepers</span>
              ${i.length>0?i.map(m=>o`<div class="mission-target-row"><strong>${m.name}</strong><span class="command-chip ${vt(m.status)}">${m.status??"unknown"}</span></div>`):o`<div class="mission-target-empty">keeper 대상이 없습니다.</div>`}
            </div>
            <div class="mission-target-block">
              <span class="mission-target-title">대기 중 confirm</span>
              <strong>${t.operator_targets.pending_confirms.length}</strong>
              <span class="mission-target-title">가능 액션</span>
              <strong>${t.operator_targets.available_actions.length}</strong>
            </div>
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>$t("intervene")}>개입 워크스페이스</button>
          </div>
        <//>
      </div>
    </section>
  `}const Jd="modulepreload",Vd=function(t){return"/dashboard/"+t},Fo={},Yd=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let r=function(m){return Promise.all(m.map(p=>Promise.resolve(p).then(u=>({status:"fulfilled",value:u}),u=>({status:"rejected",reason:u}))))};document.getElementsByTagName("link");const l=document.querySelector("meta[property=csp-nonce]"),d=(l==null?void 0:l.nonce)||(l==null?void 0:l.getAttribute("nonce"));a=r(n.map(m=>{if(m=Vd(m),m in Fo)return;Fo[m]=!0;const p=m.endsWith(".css"),u=p?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${m}"]${u}`))return;const g=document.createElement("link");if(g.rel=p?"stylesheet":Jd,p||(g.as="script"),g.crossOrigin="",g.href=m,d&&g.setAttribute("nonce",d),document.head.appendChild(g),p)return new Promise(($,y)=>{g.addEventListener("load",$),g.addEventListener("error",()=>y(new Error(`Unable to preload CSS for ${m}`)))})}))}function i(r){const l=new Event("vite:preloadError",{cancelable:!0});if(l.payload=r,window.dispatchEvent(l),!l.defaultPrevented)throw r}return a.then(r=>{for(const l of r||[])l.status==="rejected"&&i(l.reason);return e().catch(i)})},bo=v(null),Lt=v(null),_s=v(!1),fs=v(!1),gs=v(null),$s=v(null),Va=v(null),hs=v(null),_t=v("operations"),Pn=v(null),Ya=v(!1),ys=v(null),Hs=v(null),Xa=v(!1),bs=v(null),Us=v(null),Qa=v(!1),ks=v(null),vn=v(null),xs=v(!1),_n=v(null),Te=v(null);let Xe=null;function ko(t){return t!=="summary"&&t!=="swarm"}function S(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function c(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function _(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Y(t){return typeof t=="boolean"?t:void 0}function ct(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Qi(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,i)=>{t.has(i)||t.set(i,a)}),t}function Xd(){const e=Qi().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Qd(){const e=Qi().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Zd(t){if(S(t))return{policy_class:c(t.policy_class),approval_class:c(t.approval_class),tool_allowlist:ct(t.tool_allowlist),model_allowlist:ct(t.model_allowlist),requires_human_for:ct(t.requires_human_for),autonomy_level:c(t.autonomy_level),escalation_timeout_sec:_(t.escalation_timeout_sec),kill_switch:Y(t.kill_switch),frozen:Y(t.frozen)}}function tu(t){if(S(t))return{headcount_cap:_(t.headcount_cap),active_operation_cap:_(t.active_operation_cap),max_cost_usd:_(t.max_cost_usd),max_tokens:_(t.max_tokens)}}function xo(t){if(!S(t))return null;const e=c(t.unit_id),n=c(t.label),s=c(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:c(t.parent_unit_id)??null,leader_id:c(t.leader_id)??null,roster:ct(t.roster),capability_profile:ct(t.capability_profile),source:c(t.source),created_at:c(t.created_at),updated_at:c(t.updated_at),policy:Zd(t.policy),budget:tu(t.budget)}}function Zi(t){if(!S(t))return null;const e=xo(t.unit);return e?{unit:e,leader_status:c(t.leader_status),roster_total:_(t.roster_total),roster_live:_(t.roster_live),active_operation_count:_(t.active_operation_count),health:c(t.health),reasons:ct(t.reasons),children:Array.isArray(t.children)?t.children.map(Zi).filter(n=>n!==null):[]}:null}function eu(t){if(S(t))return{total_units:_(t.total_units),company_count:_(t.company_count),platoon_count:_(t.platoon_count),squad_count:_(t.squad_count),leaf_agent_unit_count:_(t.leaf_agent_unit_count),live_agent_count:_(t.live_agent_count),managed_unit_count:_(t.managed_unit_count),active_operation_count:_(t.active_operation_count)}}function tr(t){const e=S(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),source:c(e.source),summary:eu(e.summary),units:Array.isArray(e.units)?e.units.map(Zi).filter(n=>n!==null):[]}}function nu(t){if(!S(t))return null;const e=c(t.kind),n=c(t.status);return!e||!n?null:{kind:e,chain_id:c(t.chain_id)??null,goal:c(t.goal)??null,run_id:c(t.run_id)??null,status:n,viewer_path:c(t.viewer_path)??null,last_sync_at:c(t.last_sync_at)??null}}function Bs(t){if(!S(t))return null;const e=c(t.operation_id),n=c(t.objective),s=c(t.assigned_unit_id),a=c(t.trace_id),i=c(t.status);return!e||!n||!s||!a||!i?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:c(t.autonomy_level),policy_class:c(t.policy_class),budget_class:c(t.budget_class),detachment_session_id:c(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:c(t.checkpoint_ref)??null,active_goal_ids:ct(t.active_goal_ids),note:c(t.note)??null,created_by:c(t.created_by),source:c(t.source),status:i,chain:nu(t.chain),created_at:c(t.created_at),updated_at:c(t.updated_at)}}function su(t){if(!S(t))return null;const e=Bs(t.operation);return e?{operation:e,assigned_unit_label:c(t.assigned_unit_label)}:null}function Ge(t){if(S(t))return{tone:c(t.tone),pending_ops:_(t.pending_ops),blocked_ops:_(t.blocked_ops),in_flight_ops:_(t.in_flight_ops),pipeline_stalls:_(t.pipeline_stalls),bus_traffic:_(t.bus_traffic),l1_hit_rate:_(t.l1_hit_rate),invalidation_count:_(t.invalidation_count),current_pending:_(t.current_pending),current_in_flight:_(t.current_in_flight),cdb_wakeups:_(t.cdb_wakeups),total_stolen:_(t.total_stolen),avg_best_score:_(t.avg_best_score),avg_candidate_count:_(t.avg_candidate_count),best_first_operations:_(t.best_first_operations),active_sessions:_(t.active_sessions),commit_rate:_(t.commit_rate),total_speculations:_(t.total_speculations)}}function au(t){if(!S(t))return;const e=S(t.pipeline)?t.pipeline:void 0,n=S(t.cache)?t.cache:void 0,s=S(t.ooo)?t.ooo:void 0,a=S(t.speculative)?t.speculative:void 0,i=S(t.search_fabric)?t.search_fabric:void 0,r=S(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:_(e.total_ops),completed_ops:_(e.completed_ops),stalled_cycles:_(e.stalled_cycles),hazards_detected:_(e.hazards_detected),forwarding_used:_(e.forwarding_used),pipeline_flushes:_(e.pipeline_flushes),ipc:_(e.ipc)}:void 0,cache:n?{total_reads:_(n.total_reads),total_writes:_(n.total_writes),l1_hit_rate:_(n.l1_hit_rate),invalidation_count:_(n.invalidation_count),writeback_count:_(n.writeback_count),bus_traffic:_(n.bus_traffic)}:void 0,ooo:s?{agent_count:_(s.agent_count),total_added:_(s.total_added),total_issued:_(s.total_issued),total_completed:_(s.total_completed),total_stolen:_(s.total_stolen),cdb_wakeups:_(s.cdb_wakeups),stall_cycles:_(s.stall_cycles),global_cdb_events:_(s.global_cdb_events),current_pending:_(s.current_pending),current_in_flight:_(s.current_in_flight)}:void 0,speculative:a?{total_speculations:_(a.total_speculations),total_commits:_(a.total_commits),total_aborts:_(a.total_aborts),commit_rate:_(a.commit_rate),total_fast_calls:_(a.total_fast_calls),total_cost_usd:_(a.total_cost_usd),active_sessions:_(a.active_sessions)}:void 0,search_fabric:i?{total_operations:_(i.total_operations),best_first_operations:_(i.best_first_operations),legacy_operations:_(i.legacy_operations),blocked_operations:_(i.blocked_operations),ready_operations:_(i.ready_operations),research_pipeline_operations:_(i.research_pipeline_operations),avg_candidate_count:_(i.avg_candidate_count),avg_best_score:_(i.avg_best_score),top_stage:c(i.top_stage)??null}:void 0,signals:r?{issue_pressure:Ge(r.issue_pressure),cache_contention:Ge(r.cache_contention),scheduler_efficiency:Ge(r.scheduler_efficiency),routing_confidence:Ge(r.routing_confidence),speculative_posture:Ge(r.speculative_posture)}:void 0}}function er(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),summary:n?{total:_(n.total),active:_(n.active),paused:_(n.paused),managed:_(n.managed),projected:_(n.projected)}:void 0,microarch:au(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(su).filter(s=>s!==null):[]}}function nr(t){if(!S(t))return null;const e=c(t.detachment_id),n=c(t.operation_id),s=c(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:c(t.leader_id)??null,roster:ct(t.roster),session_id:c(t.session_id)??null,checkpoint_ref:c(t.checkpoint_ref)??null,runtime_kind:c(t.runtime_kind)??null,runtime_ref:c(t.runtime_ref)??null,source:c(t.source),status:c(t.status),last_event_at:c(t.last_event_at)??null,last_progress_at:c(t.last_progress_at)??null,heartbeat_deadline:c(t.heartbeat_deadline)??null,created_at:c(t.created_at),updated_at:c(t.updated_at)}}function ou(t){if(!S(t))return null;const e=nr(t.detachment);return e?{detachment:e,assigned_unit_label:c(t.assigned_unit_label),operation:Bs(t.operation)}:null}function sr(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),summary:n?{total:_(n.total),active:_(n.active),projected:_(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(ou).filter(s=>s!==null):[]}}function iu(t){if(!S(t))return null;const e=c(t.decision_id),n=c(t.trace_id),s=c(t.requested_action),a=c(t.scope_type),i=c(t.scope_id);return!e||!n||!s||!a||!i?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:i,operation_id:c(t.operation_id)??null,target_unit_id:c(t.target_unit_id)??null,requested_by:c(t.requested_by),status:c(t.status),reason:c(t.reason)??null,source:c(t.source),detail:t.detail,created_at:c(t.created_at),decided_at:c(t.decided_at)??null,expires_at:c(t.expires_at)??null}}function ar(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),summary:n?{total:_(n.total),pending:_(n.pending),approved:_(n.approved),denied:_(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(iu).filter(s=>s!==null):[]}}function ru(t){if(!S(t))return null;const e=xo(t.unit);return e?{unit:e,roster_total:_(t.roster_total),roster_live:_(t.roster_live),headcount_cap:_(t.headcount_cap),active_operations:_(t.active_operations),active_operation_cap:_(t.active_operation_cap),utilization:_(t.utilization)}:null}function lu(t){const e=S(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(ru).filter(n=>n!==null):[]}}function cu(t){if(!S(t))return null;const e=c(t.alert_id);return e?{alert_id:e,severity:c(t.severity),kind:c(t.kind),scope_type:c(t.scope_type),scope_id:c(t.scope_id),title:c(t.title),detail:c(t.detail),timestamp:c(t.timestamp)}:null}function or(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),summary:n?{total:_(n.total),bad:_(n.bad),warn:_(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(cu).filter(s=>s!==null):[]}}function ir(t){if(!S(t))return null;const e=c(t.event_id),n=c(t.trace_id),s=c(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:c(t.operation_id)??null,unit_id:c(t.unit_id)??null,actor:c(t.actor)??null,source:c(t.source),timestamp:c(t.timestamp),detail:t.detail}}function du(t){const e=S(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),events:Array.isArray(e.events)?e.events.map(ir).filter(n=>n!==null):[]}}function uu(t){if(!S(t))return null;const e=c(t.code),n=c(t.severity),s=c(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function pu(t){if(!S(t))return null;const e=c(t.lane_id),n=c(t.label),s=c(t.kind),a=c(t.phase),i=c(t.motion_state),r=c(t.source_of_truth),l=c(t.movement_reason),d=c(t.current_step);if(!e||!n||!s||!a||!i||!r||!l||!d)return null;const m=S(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:Y(t.present)??!1,phase:a,motion_state:i,source_of_truth:r,last_movement_at:c(t.last_movement_at)??null,movement_reason:l,current_step:d,blockers:ct(t.blockers),counts:{operations:_(m.operations),detachments:_(m.detachments),workers:_(m.workers),approvals:_(m.approvals),alerts:_(m.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(uu).filter(p=>p!==null):[]}}function mu(t){if(!S(t))return null;const e=c(t.event_id),n=c(t.lane_id),s=c(t.kind),a=c(t.timestamp),i=c(t.title),r=c(t.detail),l=c(t.tone),d=c(t.source);return!e||!n||!s||!a||!i||!r||!l||!d?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:i,detail:r,tone:l,source:d}}function vu(t){if(!S(t))return null;const e=c(t.code),n=c(t.severity),s=c(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,lane_ids:ct(t.lane_ids),count:_(t.count)??0}}function rr(t){if(!S(t))return;const e=S(t.overview)?t.overview:{},n=S(t.gaps)?t.gaps:{},s=S(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:c(t.generated_at),overview:{active_lanes:_(e.active_lanes),moving_lanes:_(e.moving_lanes),stalled_lanes:_(e.stalled_lanes),projected_lanes:_(e.projected_lanes),last_movement_at:c(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(pu).filter(a=>a!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(mu).filter(a=>a!==null):[],gaps:{count:_(n.count),items:Array.isArray(n.items)?n.items.map(vu).filter(a=>a!==null):[]},recommended_next_action:s?{tool:c(s.tool)??"masc_operator_snapshot",label:c(s.label)??"Observe operator state",reason:c(s.reason)??"",lane_id:c(s.lane_id)??null}:void 0}}function _u(t){if(!S(t))return;const e=S(t.workers)?t.workers:{},n=Y(t.pass);return{status:c(t.status)??"missing",source:c(t.source)??"none",run_id:c(t.run_id)??null,captured_at:c(t.captured_at)??null,...n!==void 0?{pass:n}:{},..._(t.peak_hot_slots)!=null?{peak_hot_slots:_(t.peak_hot_slots)}:{},..._(t.ctx_per_slot)!=null?{ctx_per_slot:_(t.ctx_per_slot)}:{},workers:{expected:_(e.expected),joined:_(e.joined),current_task_bound:_(e.current_task_bound),fresh_heartbeats:_(e.fresh_heartbeats),done:_(e.done),final:_(e.final)},artifact_ref:c(t.artifact_ref)??null,missing_reason:c(t.missing_reason)??null}}function fu(t){const e=S(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),topology:tr(e.topology),operations:er(e.operations),detachments:sr(e.detachments),alerts:or(e.alerts),decisions:ar(e.decisions),capacity:lu(e.capacity),traces:du(e.traces),swarm_status:rr(e.swarm_status)}}function gu(t){const e=S(t)?t:{},n=tr(e.topology),s=er(e.operations),a=sr(e.detachments),i=or(e.alerts),r=ar(e.decisions);return{version:c(e.version),generated_at:c(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:i.version,generated_at:i.generated_at,summary:i.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:rr(e.swarm_status),swarm_proof:_u(e.swarm_proof)}}function $u(t){return S(t)?{chain_id:c(t.chain_id)??null,started_at:_(t.started_at)??null,progress:_(t.progress)??null,elapsed_sec:_(t.elapsed_sec)??null}:null}function lr(t){if(!S(t))return null;const e=c(t.event);return e?{event:e,chain_id:c(t.chain_id)??null,timestamp:c(t.timestamp)??null,duration_ms:_(t.duration_ms)??null,message:c(t.message)??null,tokens:_(t.tokens)??null}:null}function hu(t){if(!S(t))return null;const e=Bs(t.operation);return e?{operation:e,runtime:$u(t.runtime),history:lr(t.history),mermaid:c(t.mermaid)??null,preview_run:cr(t.preview_run)}:null}function yu(t){const e=S(t)?t:{};return{status:c(e.status)??"disconnected",base_url:c(e.base_url)??null,message:c(e.message)??null}}function bu(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),connection:yu(e.connection),summary:n?{linked_operations:_(n.linked_operations),active_chains:_(n.active_chains),running_operations:_(n.running_operations),recent_failures:_(n.recent_failures),last_history_event_at:c(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(hu).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(lr).filter(s=>s!==null):[]}}function ku(t){if(!S(t))return null;const e=c(t.id);return e?{id:e,type:c(t.type),status:c(t.status),duration_ms:_(t.duration_ms)??null,error:c(t.error)??null}:null}function cr(t){if(!S(t))return null;const e=c(t.run_id),n=c(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:_(t.duration_ms),success:Y(t.success),mermaid:c(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(ku).filter(s=>s!==null):[]}:null}function xu(t){const e=S(t)?t:{};return{run:cr(e.run)}}function Su(t){if(!S(t))return null;const e=c(t.title),n=c(t.path);return!e||!n?null:{title:e,path:n}}function Au(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function wu(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.tool),a=c(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:ct(t.success_signals),pitfalls:ct(t.pitfalls)}}function Cu(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.summary),a=c(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(wu).filter(i=>i!==null):[]}}function Tu(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:ct(t.tools)}}function Iu(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.symptom),a=c(t.why),i=c(t.fix_tool),r=c(t.fix_summary);return!e||!n||!s||!a||!i||!r?null:{id:e,title:n,symptom:s,why:a,fix_tool:i,fix_summary:r}}function Ru(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.path_id),a=c(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:ct(t.notes)}}function Nu(t){const e=S(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(Su).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(Au).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(Cu).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Tu).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Iu).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Ru).filter(n=>n!==null):[]}}function Pu(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.status),a=c(t.detail),i=c(t.next_tool);return!e||!n||!s||!a||!i?null:{id:e,title:n,status:s,detail:a,next_tool:i}}function Lu(t){if(!S(t))return null;const e=c(t.code),n=c(t.severity),s=c(t.title),a=c(t.detail),i=c(t.next_tool);return!e||!n||!s||!a||!i?null:{code:e,severity:n,title:s,detail:a,next_tool:i}}function Du(t){if(!S(t))return null;const e=c(t.from),n=c(t.content),s=c(t.timestamp),a=_(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function Mu(t){if(!S(t))return null;const e=c(t.name),n=c(t.role),s=c(t.lane),a=c(t.status),i=c(t.claim_marker),r=c(t.done_marker),l=c(t.final_marker);if(!e||!n||!s||!a||!i||!r||!l)return null;const d=(()=>{if(!S(t.last_message))return null;const m=_(t.last_message.seq),p=c(t.last_message.content),u=c(t.last_message.timestamp);return m==null||!p||!u?null:{seq:m,content:p,timestamp:u}})();return{name:e,role:n,lane:s,joined:Y(t.joined)??!1,live_presence:Y(t.live_presence)??!1,completed:Y(t.completed)??!1,status:a,current_task:c(t.current_task)??null,bound_task_id:c(t.bound_task_id)??null,bound_task_title:c(t.bound_task_title)??null,bound_task_status:c(t.bound_task_status)??null,current_task_matches_run:Y(t.current_task_matches_run)??!1,squad_member:Y(t.squad_member)??!1,detachment_member:Y(t.detachment_member)??!1,last_seen:c(t.last_seen)??null,heartbeat_age_sec:_(t.heartbeat_age_sec)??null,heartbeat_fresh:Y(t.heartbeat_fresh)??!1,claim_marker_seen:Y(t.claim_marker_seen)??!1,done_marker_seen:Y(t.done_marker_seen)??!1,final_marker_seen:Y(t.final_marker_seen)??!1,claim_marker:i,done_marker:r,final_marker:l,last_message:d}}function Eu(t){if(!S(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!S(n))return null;const s=c(n.timestamp),a=_(n.active_slots);if(!s||a==null)return null;const i=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:i}}).filter(n=>n!==null):[];return{slot_url:c(t.slot_url)??null,provider_base_url:c(t.provider_base_url)??null,provider_reachable:Y(t.provider_reachable)??null,provider_status_code:_(t.provider_status_code)??null,provider_model_id:c(t.provider_model_id)??null,actual_model_id:c(t.actual_model_id)??null,expected_slots:_(t.expected_slots),actual_slots:_(t.actual_slots),expected_ctx:_(t.expected_ctx),actual_ctx:_(t.actual_ctx),slot_reachable:Y(t.slot_reachable)??null,slot_status_code:_(t.slot_status_code)??null,runtime_blocker:c(t.runtime_blocker)??null,detail:c(t.detail)??null,checked_at:c(t.checked_at)??null,total_slots:_(t.total_slots),ctx_per_slot:_(t.ctx_per_slot),active_slots_now:_(t.active_slots_now),peak_active_slots:_(t.peak_active_slots),sample_count:_(t.sample_count),last_sample_at:c(t.last_sample_at)??null,timeline:e}}function zu(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),run_id:c(e.run_id),room_id:c(e.room_id),operation_id:c(e.operation_id)??null,recommended_next_tool:c(e.recommended_next_tool),summary:n?{expected_workers:_(n.expected_workers),joined_workers:_(n.joined_workers),live_workers:_(n.live_workers),squad_roster_size:_(n.squad_roster_size),detachment_roster_size:_(n.detachment_roster_size),current_task_bound:_(n.current_task_bound),fresh_heartbeats:_(n.fresh_heartbeats),claim_markers_seen:_(n.claim_markers_seen),done_markers_seen:_(n.done_markers_seen),final_markers_seen:_(n.final_markers_seen),completed_workers:_(n.completed_workers),peak_hot_slots:_(n.peak_hot_slots),hot_window_ok:Y(n.hot_window_ok),pass_hot_concurrency:Y(n.pass_hot_concurrency),pass_end_to_end:Y(n.pass_end_to_end),pending_decisions:_(n.pending_decisions),pass:Y(n.pass)}:void 0,provider:Eu(e.provider),operation:Bs(e.operation),squad:xo(e.squad),detachment:nr(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Mu).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Pu).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Lu).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Du).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(ir).filter(s=>s!==null):[],truth_notes:ct(e.truth_notes)}}function Ie(t){_t.value=t,ko(t)&&Ou()}async function dr(){_s.value=!0,gs.value=null;try{const t=await Ll();bo.value=gu(t)}catch(t){gs.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{_s.value=!1}}function So(t){Te.value=t}async function Ao(){fs.value=!0,$s.value=null;try{const t=await Pl();Lt.value=fu(t)}catch(t){$s.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{fs.value=!1}}async function Ou(){Lt.value||fs.value||await Ao()}async function ve(){await dr(),ko(_t.value)&&await Ao()}async function Vt(){var t;Qa.value=!0,ks.value=null;try{const e=await Dl(),n=bu(e);Us.value=n;const s=Te.value;n.operations.length===0?Te.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Te.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){ks.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{Qa.value=!1}}function ju(){Xe=null,vn.value=null,xs.value=!1,_n.value=null}async function Fu(t){Xe=t,xs.value=!0,_n.value=null;try{const e=await Ml(t);if(Xe!==t)return;vn.value=xu(e)}catch(e){if(Xe!==t)return;vn.value=null,_n.value=e instanceof Error?e.message:"Failed to load chain run"}finally{Xe===t&&(xs.value=!1)}}async function qu(){Ya.value=!0,ys.value=null;try{const t=await El();Pn.value=Nu(t)}catch(t){ys.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Ya.value=!1}}async function Mt(t=Xd(),e=Qd()){Xa.value=!0,bs.value=null;try{const n=await zl(t,e);Hs.value=zu(n)}catch(n){bs.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{Xa.value=!1}}async function ne(t,e,n){Va.value=t,hs.value=null;try{await Ol(e,n),await dr(),(Lt.value||ko(_t.value))&&await Ao(),await Mt(),await Vt()}catch(s){throw hs.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{Va.value=null}}function Ku(t){return ne(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Hu(t){return ne(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function Uu(t){return ne(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Bu(t={}){return ne("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function Wu(t){return ne(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Gu(t){return ne(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Ju(t,e){return ne(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Vu(t,e){return ne(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}$d(()=>{ve(),Vt(),(_t.value==="swarm"||Hs.value!==null)&&Mt()});function Yu(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function tt(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function Xu(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Qu(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function F(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let qo=!1,Zu=0,ea=null;async function tp(){ea||(ea=Yd(()=>import("./mermaid.core-DzTfXL0u.js").then(e=>e.bE),[]).then(e=>e.default));const t=await ea;return qo||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),qo=!0),t}function Yt(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Ws(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function ep(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function Ln(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function le(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:Ln(t/e*100)}function np(t,e){const n=Ln(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function ur(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const pr=[{id:"operations",label:"작전"},{id:"swarm",label:"스웜"},{id:"chains",label:"체인"},{id:"topology",label:"토폴로지"},{id:"alerts",label:"알림"},{id:"trace",label:"트레이스"},{id:"control",label:"제어"},{id:"summary",label:"요약"}],sp=pr.map(t=>t.id),ap=["chain_start","node_start","node_complete","chain_complete","chain_error"],op={operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function Ko(t){return!!t&&sp.includes(t)}function ip(){const t=M.value.params;return t.source!=="mission"?{}:{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function rp(t){const e=ip();if(t==="operations")return e;if(t==="chains"){const n=Te.value;return n?{...e,surface:t,operation:n}:{...e,surface:t}}return{...e,surface:t}}function lp(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function cp(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function st(t){return Va.value===t}function Gs(){return bo.value}function dp(t){var a,i,r,l,d,m,p;const e=bo.value,n=Hs.value,s=Us.value;switch(t){case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((r=(i=e==null?void 0:e.swarm_status)==null?void 0:i.recommended_next_action)==null?void 0:r.tool)??"masc_observe_traces",reason:((d=(l=e==null?void 0:e.swarm_status)==null?void 0:l.recommended_next_action)==null?void 0:d.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(p=(m=s==null?void 0:s.operations[0])==null?void 0:m.preview_run)!=null&&p.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function up(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function pp(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function mp(){const t=Nn(M.value);return t?o`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${qs(t.action_type)}</span>
        <span class="command-chip">${yo(t)}</span>
        <span class="command-chip">${qd(M.value.params.surface??"operations")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?o`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function vp(){const t=_t.value,e=op[t],n=dp(t);return o`
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
  `}function On({label:t,value:e,subtext:n,percent:s,color:a}){return o`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${np(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(Ln(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function jn({label:t,value:e,detail:n,percent:s,tone:a}){return o`
    <article class="command-signal-rail ${F(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${F(a)}" style=${`width: ${Math.max(8,Math.round(Ln(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function _p(){var nt,dt,W,et;const t=Gs(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,i=t==null?void 0:t.alerts.summary,r=(nt=t==null?void 0:t.swarm_status)==null?void 0:nt.overview,l=t==null?void 0:t.swarm_proof,d=t==null?void 0:t.operations.microarch,m=(e==null?void 0:e.managed_unit_count)??0,p=(e==null?void 0:e.total_units)??0,u=(n==null?void 0:n.active)??0,g=(s==null?void 0:s.active)??0,$=(r==null?void 0:r.moving_lanes)??0,y=(r==null?void 0:r.active_lanes)??0,A=(l==null?void 0:l.workers.done)??0,C=(l==null?void 0:l.workers.expected)??0,L=(i==null?void 0:i.bad)??0,j=(i==null?void 0:i.warn)??0,D=(a==null?void 0:a.pending)??0,I=(a==null?void 0:a.total)??0,R=u+g,B=((dt=d==null?void 0:d.cache)==null?void 0:dt.l1_hit_rate)??((et=(W=d==null?void 0:d.signals)==null?void 0:W.cache_contention)==null?void 0:et.l1_hit_rate)??0,H=u>0||g>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",f=u>0||$>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return o`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${H}</h3>
        <p>${f}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${F(u>0?"ok":"warn")}">활성 작전 ${u}</span>
          <span class="command-chip ${F($>0?"ok":(y>0,"warn"))}">이동 레인 ${$}/${Math.max(y,$)}</span>
          <span class="command-chip ${F(L>0?"bad":j>0?"warn":"ok")}">치명 알림 ${L}</span>
          <span class="command-chip ${F(D>0?"warn":"ok")}">승인 대기 ${D}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${On}
          label="관리 단위 범위"
          value=${`${m}/${Math.max(p,m)}`}
          subtext=${p>0?`${p-m}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${le(m,Math.max(p,m))}
          color="#67e8f9"
        />
        <${On}
          label="실행 열도"
          value=${String(R)}
          subtext=${`${u}개 작전 + ${g}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${le(R,Math.max(m,R||1))}
          color="#4ade80"
        />
        <${On}
          label="스웜 이동감"
          value=${`${$}/${Math.max(y,$)}`}
          subtext=${r!=null&&r.last_movement_at?`마지막 이동 ${tt(r.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${le($,Math.max(y,$||1))}
          color="#fbbf24"
        />
        <${On}
          label="증거 수집률"
          value=${`${A}/${Math.max(C,A)}`}
          subtext=${l!=null&&l.status?`증거 소스 ${l.source} · ${l.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${le(A,Math.max(C,A||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${jn}
        label="승인 대기열"
        value=${`${D}건 대기`}
        detail=${`현재 정책 창에서 ${I}개 결정을 추적 중입니다`}
        percent=${le(D,Math.max(I,D||1))}
        tone=${D>0?"warn":"ok"}
      />
      <${jn}
        label="알림 압력"
        value=${`${L} bad / ${j} warn`}
        detail=${L>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${le(L*2+j,Math.max((L+j)*2,1))}
        tone=${L>0?"bad":j>0?"warn":"ok"}
      />
      <${jn}
        label="디스패치 점유"
          value=${`${g}개 가동`}
        detail=${m>0?`${m}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${le(g,Math.max(m,g||1))}
        tone=${g>0?"ok":"warn"}
      />
      <${jn}
        label="캐시 신뢰도"
        value=${B?Ws(B):"n/a"}
        detail=${B?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Ln((B??0)*100)}
        tone=${B>=.75?"ok":B>=.4?"warn":"bad"}
      />
    </div>
  `}function fp(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function mr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,i)=>{t.has(i)||t.set(i,a)}),t}function gp(){const e=mr().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function $p(){const e=mr().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function hp(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function yp(t){return t.status==="claimed"||t.status==="in_progress"}function bp(t){const e=Pn.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function na(t){var e;return((e=Pn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function kp(t){const e=Pn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function Xt(t){try{await t()}catch{}}function xp(){var g,$,y,A,C;const t=Gs(),e=Us.value,n=Nn(M.value),s=up(n),a=t==null?void 0:t.topology.summary,i=t==null?void 0:t.operations.summary,r=(g=t==null?void 0:t.swarm_status)==null?void 0:g.overview,l=t==null?void 0:t.operations.microarch,d=t==null?void 0:t.decisions.summary,m=t==null?void 0:t.alerts.summary,p=($=l==null?void 0:l.signals)==null?void 0:$.issue_pressure,u=l==null?void 0:l.cache;return o`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(i==null?void 0:i.active)??0}</strong><small>${((y=t==null?void 0:t.detachments.summary)==null?void 0:y.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(d==null?void 0:d.pending)??0}</strong><small>${(d==null?void 0:d.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(m==null?void 0:m.bad)??0}</strong><small>${(m==null?void 0:m.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((A=e==null?void 0:e.summary)==null?void 0:A.active_chains)??0}</strong><small>${((C=e==null?void 0:e.summary)==null?void 0:C.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(r==null?void 0:r.active_lanes)??0}</strong><small>${r?`${r.stalled_lanes??0}개 정체 · ${tt(r.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(p==null?void 0:p.pending_ops)??0}</strong><small>${(u==null?void 0:u.l1_hit_rate)!=null?`${Ws(u.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(p==null?void 0:p.tone)??"n/a"}</small></div>
    </div>
  `}function vr(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function Sp({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const i=a.motion_state;i in e?e[i]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return o`
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
  `}function Ap({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return o`
    <div class="swarm-worker-grid">
      ${a.map(()=>o`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?o`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function wp({lane:t}){const e=t.counts??{},n=vr(t),s=e.workers??0,a=e.operations??0,i=e.detachments??0,r=a+i,l=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return o`
    <article class="swarm-lane-strip ${F(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${F(n)}">${t.phase}</span>
          <span class="command-chip ${F(n)}">${t.motion_state}</span>
          <span class="command-chip">${tt(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${F(n)}" style=${`width:${l}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${s>0?o`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${Ap} total=${s} />
              </div>
            `:null}
        ${r>0?o`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">흐름</span>
                <div class="swarm-mini-bar">
                  <div class="swarm-mini-bar-fill" style="width: ${r>0?Math.round(a/r*100):0}%; background: var(--${n==="bad"?"bad":n==="warn"?"warn":"ok"})"></div>
                </div>
                <span class="swarm-worker-count">작전 ${a} · 실행체 ${i}</span>
              </div>
            `:null}
      </div>
      ${t.blockers.length>0?o`<div class="swarm-lane-blockers">막힘: ${t.blockers.join(" · ")}</div>`:null}
      ${t.hard_flags.length>0?o`
            <div class="swarm-lane-flags">
              ${t.hard_flags.map(d=>o`<span class="command-chip ${F(d.severity)}">${d.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Cp({lanes:t}){const e=t.slice(0,4);return e.length===0?null:o`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=vr(n),a=n.counts.workers??0,i=n.counts.operations??0,r=n.counts.detachments??0;return o`
          <article class="swarm-story-card ${F(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${F(s)}">${n.motion_state}</span>
              <span class="command-chip">${n.phase}</span>
            </div>
            <strong>${n.label}</strong>
            <p>${n.current_step}</p>
            <div class="swarm-story-strip">
              <span>워커 ${a}</span>
              <span>작전 ${i}</span>
              <span>실행체 ${r}</span>
            </div>
            <small>${n.movement_reason}</small>
          </article>
        `})}
    </div>
  `}function Tp({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return o`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${F(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?o`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function Ip({gap:t}){return o`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${F(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function Rp({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return o`
    <div class="command-guide-card ${F(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${F(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?o`
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${tt(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.artifact_ref?o`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?o`<p>${t.missing_reason}</p>`:null}
          `:o`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function Np(){const t=Gs(),e=Nn(M.value),n=pp(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,i=(s==null?void 0:s.lanes.filter(u=>u.present))??[],r=(s==null?void 0:s.gaps.items)??[],l=(s==null?void 0:s.timeline.slice(0,8))??[],d=s==null?void 0:s.overview,m=s==null?void 0:s.recommended_next_action,p=i.length<=1;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${z} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?o`
            <${Cp} lanes=${i} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(d==null?void 0:d.active_lanes)??0}</strong><small>${(d==null?void 0:d.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(d==null?void 0:d.stalled_lanes)??0}</strong><small>${(d==null?void 0:d.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${tt(d==null?void 0:d.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${tt(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong><small>${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${i.length>0?o`<${Sp} lanes=${i} />`:null}

            <div class="command-swarm-layout ${p?"compact":""}">
              <div class="command-card-stack">
                ${i.length>0?i.map(u=>o`<${wp} lane=${u} />`):o`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${Rp} proof=${a} />

                <div class="command-guide-card ${r.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${F(r.some(u=>u.severity==="bad")?"bad":r.length>0?"warn":"ok")}">${r.length}</span>
                  </div>
                  ${r.length>0?o`<div class="swarm-event-rail">${r.slice(0,4).map(u=>o`<${Ip} gap=${u} />`)}</div>`:o`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${l.length}</span>
                  </div>
                  ${l.length>0?o`<div class="swarm-event-rail">${l.map(u=>o`<${Tp} event=${u} />`)}</div>`:o`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:o`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function Pp(){return o`
    <div class="command-surface-tabs">
      ${pr.map(t=>o`
        <button
          class="command-surface-tab ${_t.value===t.id?"active":""}"
          onClick=${()=>{Ie(t.id),$t("command",rp(t.id))}}
        >
          ${t.label}
        </button>
      `)}
    </div>
  `}function Lp(){var nt,dt,W,et,b,ae,Ue,Dn,Mn;const t=Gs(),e=Lt.value,n=je.value,s=fp(),a=s?Nt.value.find(E=>E.name===s)??null:null,i=s?St.value.filter(E=>E.assignee===s&&yp(E)):[],r=((nt=t==null?void 0:t.operations.summary)==null?void 0:nt.active)??0,l=((dt=t==null?void 0:t.detachments.summary)==null?void 0:dt.total)??0,d=((W=t==null?void 0:t.decisions.summary)==null?void 0:W.pending)??0,m=e==null?void 0:e.detachments.detachments.find(E=>{const oe=E.detachment.heartbeat_deadline,En=oe?Date.parse(oe):Number.NaN;return E.detachment.status==="stalled"||!Number.isNaN(En)&&En<=Date.now()}),p=e==null?void 0:e.alerts.alerts.find(E=>E.severity==="bad"),u=!!(n!=null&&n.room||n!=null&&n.project),g=(a==null?void 0:a.current_task)??null,$=hp(a==null?void 0:a.last_seen),y=$!=null?$<=120:null,A=[u?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?i.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:St.value.length>0?"masc_claim":"masc_add_task"}:g?y===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${g} 이지만 heartbeat가 stale 합니다 (${$}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${g}${$!=null?` · 마지막 활동 ${$}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((et=t.topology.summary)==null?void 0:et.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:r===0?{title:"작전 준비도",tone:"warn",detail:`${((b=t.topology.summary)==null?void 0:b.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((ae=t.topology.summary)==null?void 0:ae.managed_unit_count)??0}개 관리 단위 위에서 ${r}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},d>0?{title:"디스패치 준비도",tone:"warn",detail:`${d}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:r>0&&l===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:m||p?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${m?` · detachment ${m.detachment.detachment_id} 가 stalled 상태입니다`:""}${p?` · alert ${p.title??p.alert_id}`:""}${!e&&!m&&!p?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:d>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${l}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],C=u?!s||!a?"masc_join":i.length===0?St.value.length>0?"masc_claim":"masc_add_task":g?y===!1?"masc_heartbeat":!t||(((Ue=t.topology.summary)==null?void 0:Ue.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":d>0?"masc_policy_approve":r>0&&l===0||m||p?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",L=bp(C),D=kp(C==="masc_set_room"?["repo-root-room"]:C==="masc_plan_set_task"?["claimed-not-current"]:C==="masc_heartbeat"?["heartbeat-stale"]:C==="masc_dispatch_tick"?["no-detachments"]:C==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),I=na("room_task_hygiene"),R=na("cpv2_benchmark"),B=na("supervisor_session"),H=((Dn=Pn.value)==null?void 0:Dn.docs)??[],f=[I,R,B].filter(E=>E!==null);return o`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${z} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(L==null?void 0:L.title)??C}</strong>
            <span class="command-chip ok">${C}</span>
          </div>
          <p>${(L==null?void 0:L.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(Mn=L==null?void 0:L.success_signals)!=null&&Mn.length?o`<div class="command-tag-row">
                ${L.success_signals.map(E=>o`<span class="command-tag ok">${E}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${A.map(E=>o`
            <article class="command-readiness-row ${F(E.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${E.title}</strong>
                  <span class="command-chip ${F(E.tone)}">${E.tone}</span>
                </div>
                <p>${E.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${E.tool}</div>
            </article>
          `)}
        </div>

        ${D.length>0?o`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${D.length}</span>
                </div>
                <div class="command-guide-list">
                  ${D.map(E=>o`
                    <article class="command-guide-inline">
                      <strong>${E.title}</strong>
                      <div>${E.symptom}</div>
                      <div class="command-card-sub">${E.fix_tool} 로 해결: ${E.fix_summary}</div>
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
        ${Ya.value?o`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:ys.value?o`<div class="empty-state error">${ys.value}</div>`:o`
                <div class="command-path-grid">
                  ${f.map(E=>o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${E.title}</strong>
                        <span class="command-chip">${E.id}</span>
                      </div>
                      <p>${E.summary}</p>
                      <div class="command-card-sub">${E.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${E.steps.slice(0,4).map(oe=>o`
                          <div class="command-step-row">
                            <span class="command-step-tool">${oe.tool}</span>
                            <span>${oe.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${H.length>0?o`<div class="command-doc-links">
                      ${H.map(E=>o`<span class="command-tag">${E.title}: ${E.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Dp(){return o`
    <${_p} />
    <${xp} />
    <${Lp} />
  `}function Mp(){return fs.value?o`<div class="empty-state">command-plane detail 불러오는 중…</div>`:$s.value?o`<div class="empty-state error">${$s.value}</div>`:o`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function _r({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,i=t.unit.policy;return o`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${cp(t.unit.kind)}</span>
            <span class="command-chip ${F(t.health)}">${t.health??"ok"}</span>
            ${i!=null&&i.frozen?o`<span class="command-chip warn">frozen</span>`:null}
            ${i!=null&&i.kill_switch?o`<span class="command-chip bad">kill-switch</span>`:null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${t.unit.unit_id}</span>
            <span>Leader ${t.unit.leader_id??"unassigned"} / ${t.leader_status??"unknown"}</span>
            <span>Roster ${n}/${s}</span>
            <span>Ops ${a}</span>
            <span>Autonomy ${(i==null?void 0:i.autonomy_level)??"n/a"}</span>
          </div>
          ${t.reasons&&t.reasons.length>0?o`<div class="command-tag-row">
                ${t.reasons.map(r=>o`<span class="command-tag warn">${r}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?o`<div class="command-tree-children">
            ${t.children.map(r=>o`<${_r} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function Ep({source:t}){const e=vi(null),[n,s]=mo(null);return ot(()=>{let a=!1;const i=e.current;return i?(i.innerHTML="",s(null),(async()=>{try{const l=await tp(),{svg:d}=await l.render(`command-chain-${++Zu}`,t);if(a||!e.current)return;e.current.innerHTML=d}catch(l){if(a)return;s(l instanceof Error?l.message:"Mermaid render failed")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),o`
    <div class="command-chain-graph-shell">
      ${n?o`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function zp({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return o`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${Yt(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?o`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?o`<span class="command-tag ${Yt(s==null?void 0:s.status)}">${Ws(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${ur(t.history)}</div>
    </button>
  `}function Op({item:t}){return o`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${Yt(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${tt(t.timestamp)}</div>
      <div class="command-card-sub">${ur(t)}</div>
    </article>
  `}function jp({node:t}){return o`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${Yt(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?o`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function Fp({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,i=e.chain,r=(i==null?void 0:i.run_id)??null;return o`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${F(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Autonomy</span><span>${e.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${e.budget_class??"standard"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Updated</span><span>${tt(e.updated_at)}</span>
      </div>
      ${i?o`
            <div class="command-tag-row">
              <span class="command-tag">${i.kind}</span>
              <span class="command-tag ${Yt(i.status)}">${i.status}</span>
              ${i.chain_id?o`<span class="command-tag">${i.chain_id}</span>`:null}
              ${i.run_id?o`<span class="command-tag">run ${i.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?o`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Ie("swarm"),$t("command",{surface:"swarm",operation_id:e.operation_id,...r?{run_id:r}:{}})}}
        >
          Swarm Live
        </button>
        ${i?o`
              <button
                class="control-btn ghost"
                onClick=${()=>{So(e.operation_id),Ie("chains"),$t("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?o`
              <button class="control-btn ghost" disabled=${st(n)} onClick=${()=>Xt(()=>Ku(e.operation_id))}>
                ${st(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${st(a)} onClick=${()=>Xt(()=>Uu(e.operation_id))}>
                ${st(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?o`
              <button class="control-btn ghost" disabled=${st(s)} onClick=${()=>Xt(()=>Hu(e.operation_id))}>
                ${st(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function qp({card:t}){var n;const e=t.detachment;return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${F(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${tt(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Qu(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${tt(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?o`<span class="command-tag ${Xu(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Kp({alert:t}){return o`
    <article class="command-alert ${F(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${F(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${tt(t.timestamp)}</span>
      </div>
      ${t.detail?o`<p>${t.detail}</p>`:null}
    </article>
  `}function fr({event:t}){return o`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${tt(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${Yu(t.detail)}</pre>
    </article>
  `}function Hp({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return o`
    <article class="command-card ${F(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${F(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${tt(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!s?o`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${st(e)} onClick=${()=>Xt(()=>Wu(t.decision_id))}>
                ${st(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${st(n)} onClick=${()=>Xt(()=>Gu(t.decision_id))}>
                ${st(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?o`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function Up({row:t}){var l,d,m;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((l=e.policy)!=null&&l.frozen),i=!!((d=e.policy)!=null&&d.kill_switch),r=Math.round((t.utilization??0)*100);return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${F(r>100?"bad":r>70?"warn":"ok")}">${r}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>Headcount Cap</span><span>${t.headcount_cap??0}</span>
        <span>Ops</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${((m=e.policy)==null?void 0:m.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${a?"yes":"no"}</span>
        <span>Kill Switch</span><span>${i?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${st(n)} onClick=${()=>Xt(()=>Ju(e.unit_id,!a))}>
          ${st(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${st(s)} onClick=${()=>Xt(()=>Vu(e.unit_id,!i))}>
          ${st(s)?"Applying…":i?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function Bp({item:t}){return o`
    <article class="command-guide-card ${F(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${F(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Wp({blocker:t}){return o`
    <article class="command-alert ${F(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${F(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function Gp({worker:t}){return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${F(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${t.last_message?o`<div class="command-card-foot">${tt(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function Jp(){var d,m,p,u,g,$,y,A,C,L,j,D,I,R,B,H,f,nt,dt,W,et;const t=Hs.value,e=gp(),n=$p(),s=(d=t==null?void 0:t.provider)!=null&&d.runtime_blocker?"blocked":(m=t==null?void 0:t.provider)!=null&&m.provider_reachable?"ready":"check",a=((p=t==null?void 0:t.provider)==null?void 0:p.actual_slots)??((u=t==null?void 0:t.provider)==null?void 0:u.total_slots)??0,i=((g=t==null?void 0:t.provider)==null?void 0:g.expected_slots)??"n/a",r=(($=t==null?void 0:t.provider)==null?void 0:$.actual_ctx)??((y=t==null?void 0:t.provider)==null?void 0:y.ctx_per_slot)??0,l=((A=t==null?void 0:t.provider)==null?void 0:A.expected_ctx)??"n/a";return o`
    <div class="command-section-stack">
      <${Np} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${Xa.value?o`<div class="empty-state">Loading swarm live state…</div>`:bs.value?o`<div class="empty-state error">${bs.value}</div>`:t?o`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((C=t.summary)==null?void 0:C.joined_workers)??0}/${((L=t.summary)==null?void 0:L.expected_workers)??0}</strong><small>${((j=t.summary)==null?void 0:j.live_workers)??0}개 가동 · ${((D=t.summary)==null?void 0:D.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${i} · ctx ${r}/${l}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(I=t.summary)!=null&&I.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((R=t.provider)==null?void 0:R.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(B=t.summary)!=null&&B.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((H=t.operation)==null?void 0:H.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((f=t.squad)==null?void 0:f.label)??"없음"}</span>
                      <span>실행체</span><span>${((nt=t.detachment)==null?void 0:nt.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((dt=t.summary)==null?void 0:dt.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((W=t.summary)==null?void 0:W.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((et=t.provider)==null?void 0:et.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?o`<div class="command-tag-row">
                          ${t.truth_notes.map(b=>o`<span class="command-tag">${b}</span>`)}
                        </div>`:null}
                  `:o`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?o`<div class="command-card-stack">
                ${t.checklist.map(b=>o`<${Bp} item=${b} />`)}
              </div>`:o`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?o`<div class="command-card-stack">
                ${t.workers.map(b=>o`<${Gp} worker=${b} />`)}
              </div>`:o`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t!=null&&t.provider?o`
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
                  <span>Last Sample</span><span>${t.provider.last_sample_at?tt(t.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${t.provider.checked_at?tt(t.provider.checked_at):"n/a"}</span>
                </div>
                ${t.provider.detail?o`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?o`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(b=>o`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${b.active_slots} active</strong>
                              <span class="command-chip">${tt(b.timestamp)}</span>
                            </div>
                            <div class="command-card-sub">slots ${b.active_slot_ids.join(", ")||"none"}</div>
                          </div>
                        </article>
                      `)}
                    </div>`:o`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:o`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?o`<div class="command-card-stack">
                ${t.blockers.map(b=>o`<${Wp} blocker=${b} />`)}
              </div>`:o`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?o`<div class="command-trace-stack">
                ${t.recent_messages.map(b=>o`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${b.from}</strong>
                        <span class="command-chip">${tt(b.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${b.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${b.content}</pre>
                  </article>
                `)}
              </div>`:o`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${z} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?o`<div class="command-trace-stack">
                ${t.recent_trace_events.map(b=>o`<${fr} event=${b} />`)}
              </div>`:o`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function Vp(){const t=Lt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${z} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?o`<div class="command-card-stack">
              ${t.operations.operations.map(e=>o`<${Fp} card=${e} />`)}
            </div>`:o`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${z} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?o`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>o`<${qp} card=${e} />`)}
            </div>`:o`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function Yp(){var l,d,m,p,u,g,$,y,A,C,L,j,D,I,R,B;const t=Us.value,e=(t==null?void 0:t.operations)??[],n=Te.value,s=e.find(H=>H.operation.operation_id===n)??e[0]??null,a=((l=s==null?void 0:s.operation.chain)==null?void 0:l.run_id)??null,i=((d=vn.value)==null?void 0:d.run)??(s==null?void 0:s.preview_run)??null,r=!((m=vn.value)!=null&&m.run)&&!!(s!=null&&s.preview_run);return ot(()=>{a?Fu(a):ju()},[a]),o`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${z} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${Yt(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${Yt(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(t==null?void 0:t.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((p=t==null?void 0:t.summary)==null?void 0:p.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((u=t==null?void 0:t.summary)==null?void 0:u.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((g=t==null?void 0:t.summary)==null?void 0:g.recent_failures)??0}</span>
            <span>Last Event</span><span>${tt(($=t==null?void 0:t.summary)==null?void 0:$.last_history_event_at)}</span>
          </div>
        </article>

        ${ks.value?o`<div class="empty-state error">${ks.value}</div>`:null}

        ${Qa.value&&!t?o`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?o`
                <div class="command-chain-list">
                  ${e.map(H=>o`
                    <${zp}
                      overlay=${H}
                      selected=${(s==null?void 0:s.operation.operation_id)===H.operation.operation_id}
                      onSelect=${()=>So(H.operation.operation_id)}
                    />
                  `)}
                </div>
              `:o`<div class="empty-state">No chain-backed operations yet.</div>`}

        <div class="command-chain-history">
          <div class="command-guide-head">
            <strong>Recent history</strong>
            <span class="command-chip">${(t==null?void 0:t.recent_history.length)??0}</span>
          </div>
          ${t&&t.recent_history.length>0?o`
                <div class="command-card-stack">
                  ${t.recent_history.slice(0,6).map(H=>o`<${Op} item=${H} />`)}
                </div>
              `:o`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chain Detail</div>
          <${z} panelId="command.chains" compact=${!0} />
        </div>
        ${s?o`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${Yt((y=s.operation.chain)==null?void 0:y.status)}">
                    ${((A=s.operation.chain)==null?void 0:A.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((C=s.operation.chain)==null?void 0:C.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((L=s.operation.chain)==null?void 0:L.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${Ws((j=s.runtime)==null?void 0:j.progress)}</span>
                  <span>Elapsed</span><span>${ep((D=s.runtime)==null?void 0:D.elapsed_sec)}</span>
                  <span>Updated</span><span>${tt(((I=s.operation.chain)==null?void 0:I.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(R=s.operation.chain)!=null&&R.goal?o`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?o`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((B=s.operation.chain)==null?void 0:B.chain_id)??"graph"}</span>
                      </div>
                      <${Ep} source=${s.mermaid} />
                    </div>
                  `:o`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(i==null?void 0:i.success)===!1?"bad":"ok"}">
                    ${i?i.success===!1?"failed":r?"preview":"captured":"pending"}
                  </span>
                </div>
                ${xs.value?o`<div class="empty-state">Loading run detail…</div>`:_n.value?o`<div class="empty-state error">${_n.value}</div>`:i&&i.nodes.length>0?o`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${i.chain_id}</span>
                            <span>Run</span><span>${i.run_id??"preview only"}</span>
                            <span>Duration</span><span>${i.duration_ms!=null?`${i.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${i.nodes.length}</span>
                          </div>
                          ${r?o`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${i.nodes.map(H=>o`<${jp} node=${H} />`)}
                          </div>
                        `:o`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:o`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function Xp(){const t=Lt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${z} panelId="command.topology" compact=${!0} />
      </div>
      ${t&&t.topology.units.length>0?o`${t.topology.units.map(e=>o`<${_r} node=${e} />`)}`:o`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function Qp(){const t=Lt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${z} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?o`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>o`<${Kp} alert=${e} />`)}
          </div>`:o`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function Zp(){const t=Lt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${z} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?o`<div class="command-trace-stack">
            ${t.traces.events.map(e=>o`<${fr} event=${e} />`)}
          </div>`:o`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function tm(){const t=Lt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${z} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?o`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>o`<${Hp} decision=${e} />`)}
            </div>`:o`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${z} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?o`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>o`<${Up} row=${e} />`)}
            </div>`:o`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function em(){if(_t.value==="summary")return o`<${Dp} />`;if(_t.value==="swarm")return o`<${Jp} />`;if(!Lt.value)return o`<${Mp} />`;switch(_t.value){case"chains":return o`<${Yp} />`;case"topology":return o`<${Xp} />`;case"alerts":return o`<${Qp} />`;case"trace":return o`<${Zp} />`;case"control":return o`<${tm} />`;case"operations":default:return o`<${Vp} />`}}function nm(){return ot(()=>{ve(),Vt(),qu(),Mt()},[]),ot(()=>{if(M.value.tab!=="command")return;const t=M.value.params.surface,e=M.value.params.operation,n=Nn(M.value);if(Ko(t))Ie(t);else if(n){const s=Gi(n);Ko(s)&&Ie(s)}else t||Ie("operations");e&&So(e),t==="swarm"&&Mt()},[M.value.tab,M.value.params.surface,M.value.params.operation,M.value.params.operation_id,M.value.params.run_id,M.value.params.source,M.value.params.action_type,M.value.params.target_type,M.value.params.target_id,M.value.params.focus_kind]),ot(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,ve(),Vt(),_t.value==="swarm"&&Mt()},250))},n=new EventSource(lp()),s=ap.map(a=>{const i=()=>e();return n.addEventListener(a,i),{type:a,handler:i}});return n.onerror=()=>{e()},()=>{s.forEach(({type:a,handler:i})=>{n.removeEventListener(a,i)}),n.close(),t&&window.clearTimeout(t)}},[]),o`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면 / Command Plane</h2>
          <p>기본 진입은 현재 작전입니다. 여기서는 지금 무엇이 움직이고 막히는지 확인한 뒤, 필요한 surface로만 더 깊게 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Xt(()=>Bu())}}
            disabled=${st("dispatch:tick")}
          >
            ${st("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{ve(),Vt(),Mt()}}
            disabled=${_s.value}
          >
            ${_s.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${gs.value?o`<div class="empty-state error">${gs.value}</div>`:null}
      ${hs.value?o`<div class="empty-state error">${hs.value}</div>`:null}
      <${ee} surfaceId="command" />
      <${mp} />
      <${vp} />
      <${Pp} />
      <${em} />
    </section>
  `}let sm=0;const ue=v([]);function N(t,e="success",n=4e3){const s=++sm;ue.value=[...ue.value,{id:s,message:t,type:e}],setTimeout(()=>{ue.value=ue.value.filter(a=>a.id!==s)},n)}function am(t){ue.value=ue.value.filter(e=>e.id!==t)}function om(){const t=ue.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>am(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Ke=v(null),gr=v(null),qt=v(null),Ss=v(!1),Zt=v(null),fn=v(!1),Ee=v(null),G=v(!1),As=v([]);let im=1;function K(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function k(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function Q(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Js(t){return typeof t=="boolean"?t:void 0}function rm(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Tt(t,e=[]){if(Array.isArray(t))return t;if(!K(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function lm(t){return K(t)?{id:k(t.id),seq:Q(t.seq),from:k(t.from)??k(t.from_agent)??"system",content:k(t.content)??"",timestamp:k(t.timestamp)??new Date().toISOString(),type:k(t.type)}:null}function cm(t){return K(t)?{room_id:k(t.room_id),current_room:k(t.current_room)??k(t.room),project:k(t.project),cluster:k(t.cluster),paused:Js(t.paused),pause_reason:k(t.pause_reason)??null,paused_by:k(t.paused_by)??null,paused_at:k(t.paused_at)??null}:{}}function Ho(t){if(!K(t))return;const e=Object.entries(t).map(([n,s])=>{const a=k(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function $r(t){if(!K(t))return null;const e=k(t.kind),n=k(t.summary),s=k(t.target_type);return!e||!n||!s?null:{kind:e,severity:k(t.severity)??"warn",summary:n,target_type:s,target_id:k(t.target_id)??null,actor:k(t.actor)??null,evidence:t.evidence}}function hr(t){if(!K(t))return null;const e=k(t.action_type),n=k(t.target_type),s=k(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:k(t.target_id)??null,severity:k(t.severity)??"warn",reason:s,confirm_required:Js(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function dm(t){return K(t)?{actor:k(t.actor)??null,spawn_agent:k(t.spawn_agent)??null,spawn_role:k(t.spawn_role)??null,spawn_model:k(t.spawn_model)??null,worker_class:k(t.worker_class)??null,parent_actor:k(t.parent_actor)??null,capsule_mode:k(t.capsule_mode)??null,runtime_pool:k(t.runtime_pool)??null,lane_id:k(t.lane_id)??null,controller_level:k(t.controller_level)??null,control_domain:k(t.control_domain)??null,supervisor_actor:k(t.supervisor_actor)??null,model_tier:k(t.model_tier)??null,task_profile:k(t.task_profile)??null,risk_level:k(t.risk_level)??null,routing_confidence:Q(t.routing_confidence)??null,routing_reason:k(t.routing_reason)??null,status:k(t.status)??"unknown",turn_count:Q(t.turn_count)??0,empty_note_turn_count:Q(t.empty_note_turn_count)??0,has_turn:Js(t.has_turn)??!1,last_turn_ts_iso:k(t.last_turn_ts_iso)??null}:null}function um(t){if(!K(t))return null;const e=k(t.session_id);return e?{session_id:e,goal:k(t.goal),status:k(t.status),health:k(t.health),scale_profile:k(t.scale_profile),control_profile:k(t.control_profile),planned_worker_count:Q(t.planned_worker_count),active_agent_count:Q(t.active_agent_count),last_turn_age_sec:Q(t.last_turn_age_sec)??null,attention_count:Q(t.attention_count),recommended_action_count:Q(t.recommended_action_count),top_attention:$r(t.top_attention),top_recommendation:hr(t.top_recommendation)}:null}function yr(t){const e=K(t)?t:{};return{trace_id:k(e.trace_id),target_type:k(e.target_type)??"room",target_id:k(e.target_id)??null,health:k(e.health),swarm_status:K(e.swarm_status)?e.swarm_status:void 0,attention_items:Tt(e.attention_items).map($r).filter(n=>n!==null),recommended_actions:Tt(e.recommended_actions).map(hr).filter(n=>n!==null),session_cards:Tt(e.session_cards).map(um).filter(n=>n!==null),worker_cards:Tt(e.worker_cards).map(dm).filter(n=>n!==null)}}function pm(t){if(!K(t))return null;const e=K(t.status)?t.status:void 0,n=K(t.summary)?t.summary:K(e==null?void 0:e.summary)?e.summary:void 0,s=K(t.session)?t.session:K(e==null?void 0:e.session)?e.session:void 0,a=k(t.session_id)??k(n==null?void 0:n.session_id)??k(s==null?void 0:s.session_id);if(!a)return null;const i=Ho(t.report_paths)??Ho(e==null?void 0:e.report_paths),r=Tt(t.recent_events,["events"]).filter(K);return{session_id:a,status:k(t.status)??k(n==null?void 0:n.status)??k(s==null?void 0:s.status),progress_pct:Q(t.progress_pct)??Q(n==null?void 0:n.progress_pct),elapsed_sec:Q(t.elapsed_sec)??Q(n==null?void 0:n.elapsed_sec),remaining_sec:Q(t.remaining_sec)??Q(n==null?void 0:n.remaining_sec),done_delta_total:Q(t.done_delta_total)??Q(n==null?void 0:n.done_delta_total),summary:n,team_health:K(t.team_health)?t.team_health:K(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:K(t.communication_metrics)?t.communication_metrics:K(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:K(t.orchestration_state)?t.orchestration_state:K(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:K(t.cascade_metrics)?t.cascade_metrics:K(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:s,recent_events:r}}function mm(t){if(!K(t))return null;const e=k(t.name);if(!e)return null;const n=K(t.context)?t.context:void 0;return{name:e,agent_name:k(t.agent_name),status:k(t.status),autonomy_level:k(t.autonomy_level),context_ratio:Q(t.context_ratio)??Q(n==null?void 0:n.context_ratio),generation:Q(t.generation),active_goal_ids:rm(t.active_goal_ids),last_autonomous_action_at:k(t.last_autonomous_action_at)??null,last_turn_ago_s:Q(t.last_turn_ago_s),model:k(t.model)??k(t.active_model)??k(t.primary_model)}}function vm(t){if(!K(t))return null;const e=k(t.confirm_token)??k(t.token);return e?{confirm_token:e,actor:k(t.actor),action_type:k(t.action_type),target_type:k(t.target_type),target_id:k(t.target_id)??null,delegated_tool:k(t.delegated_tool),created_at:k(t.created_at),preview:t.preview}:null}function _m(t){const e=K(t)?t:{};return{room:cm(e.room),sessions:Tt(e.sessions,["items","sessions"]).map(pm).filter(n=>n!==null),keepers:Tt(e.keepers,["items","keepers"]).map(mm).filter(n=>n!==null),recent_messages:Tt(e.recent_messages,["messages"]).map(lm).filter(n=>n!==null),pending_confirms:Tt(e.pending_confirms,["items","confirms"]).map(vm).filter(n=>n!==null),available_actions:Tt(e.available_actions,["actions"]).filter(K).map(n=>({action_type:k(n.action_type)??"unknown",target_type:k(n.target_type)??"unknown",description:k(n.description),confirm_required:Js(n.confirm_required)}))}}function Fn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Uo(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function ws(t){As.value=[{...t,id:im++,at:new Date().toISOString()},...As.value].slice(0,20)}function br(t){return t.confirm_required?Fn(t.preview)||"Confirmation required":Fn(t.result)||Fn(t.executed_action)||Fn(t.delegated_tool_result)||t.status}async function te(){Ss.value=!0,Zt.value=null;try{const t=await Nl();Ke.value=_m(t)}catch(t){Zt.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Ss.value=!1}}async function Kt(){fn.value=!0,Ee.value=null;try{const t=await Si({targetType:"room"});gr.value=yr(t)}catch(t){Ee.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{fn.value=!1}}async function gn(t){if(!t){qt.value=null;return}fn.value=!0,Ee.value=null;try{const e=await Si({targetType:"team_session",targetId:t,includeWorkers:!0});qt.value=yr(e)}catch(e){Ee.value=e instanceof Error?e.message:"Failed to load session digest"}finally{fn.value=!1}}async function fm(t){var e;G.value=!0,Zt.value=null;try{const n=await zs(t);return ws({actor:t.actor,action_type:t.action_type,target_label:Uo(t),outcome:n.confirm_required?"preview":"executed",message:br(n),delegated_tool:n.delegated_tool}),await te(),await Kt(),(e=qt.value)!=null&&e.target_id&&await gn(qt.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw Zt.value=s,ws({actor:t.actor,action_type:t.action_type,target_label:Uo(t),outcome:"error",message:s}),n}finally{G.value=!1}}async function gm(t,e){var n;G.value=!0,Zt.value=null;try{const s=await Fl(t,e);return ws({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:br(s),delegated_tool:s.delegated_tool}),await te(),await Kt(),(n=qt.value)!=null&&n.target_id&&await gn(qt.value.target_id),s}catch(s){const a=s instanceof Error?s.message:"Operator confirmation failed";throw Zt.value=a,ws({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),s}finally{G.value=!1}}hd(()=>{var t;te(),Kt(),(t=qt.value)!=null&&t.target_id&&gn(qt.value.target_id)});const kr="masc_dashboard_agent_name";function $m(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(kr))==null?void 0:s.trim())||"dashboard"}const Vs=v($m()),Re=v(""),Za=v("운영 점검"),Ne=v(""),$n=v(""),hn=v("2"),yn=v(""),Et=v("note"),bn=v(""),kn=v(""),xn=v(""),Sn=v("2"),Cs=v("운영자 중지 요청"),Ts=v(""),Pe=v(""),qn=v(null);function hm(t){const e=t.trim()||"dashboard";Vs.value=e,localStorage.setItem(kr,e)}function Bo(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function ym(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function ze(t){return typeof t=="string"?t.trim().toLowerCase():""}function bm(t){var s;const e=ze(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=ze((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function Wo(t){const e=ze(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function Go(t){return t.some(e=>ze(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function km(t){return t.target_type==="team_session"}function xm(t){return t.target_type==="keeper"}function Kn(t){switch(t){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업";case"team_stop":return"세션 중지";case"keeper_msg":return"keeper 메시지";case"task_inject":return"작업 주입";default:return(t==null?void 0:t.trim())||"액션"}}function Hn(t){switch(t){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";default:return(t==null?void 0:t.trim())||"target"}}function Je(t){switch(ze(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Jo(t){return t?"확인 후 실행":"즉시 실행"}function Sm(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";case"checkpoint":return"체크포인트";default:return t}}function ut(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function Am(t){if(t.action_type==="team_task_inject")return"task";if(t.action_type==="team_broadcast")return"broadcast";if(t.action_type==="team_note")return"note";if(t.action_type==="team_turn"){const e=ut(t.suggested_payload,"turn_kind");if(e==="broadcast"||e==="task"||e==="checkpoint")return e}return"note"}function wm(t){const e=t.suggested_payload;if(t.target_type==="room"){if(t.action_type==="broadcast"){Re.value=ut(e,"message")??t.summary;return}t.action_type==="task_inject"&&(Ne.value=ut(e,"title")??"운영자 주입 작업",$n.value=ut(e,"description")??t.summary,hn.value=ut(e,"priority")??hn.value);return}if(t.target_type==="team_session"){if(t.target_id&&(yn.value=t.target_id),t.action_type==="team_stop"){Cs.value=ut(e,"reason")??t.summary;return}Et.value=Am(t);const n=ut(e,"message");n&&(bn.value=n),Et.value==="task"&&(kn.value=ut(e,"task_title")??ut(e,"title")??"운영자 주입 작업",xn.value=ut(e,"task_description")??ut(e,"description")??t.summary,Sn.value=ut(e,"task_priority")??ut(e,"priority")??Sn.value);return}t.target_type==="keeper"&&(t.target_id&&(Ts.value=t.target_id),Pe.value=ut(e,"message")??t.summary)}function Cm(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function $e(t){const e=Vs.value.trim()||"dashboard";try{const n=await fm({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?N("확인 대기열에 올렸습니다","warning"):N(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return N(s,"error"),null}}async function Vo(){const t=Re.value.trim();if(!t)return;await $e({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(Re.value="")}async function Tm(){await $e({action_type:"room_pause",target_type:"room",payload:{reason:Za.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function Im(){await $e({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function Rm(){const t=Ne.value.trim();if(!t)return;await $e({action_type:"task_inject",target_type:"room",payload:{title:t,description:$n.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(hn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(Ne.value="",$n.value="")}async function Nm(){var i;const t=Ke.value,e=yn.value||((i=t==null?void 0:t.sessions[0])==null?void 0:i.session_id)||"";if(!e){N("먼저 세션을 고르세요","warning");return}const n={turn_kind:Et.value},s=bn.value.trim();s&&(n.message=s),Et.value==="task"&&(n.task_title=kn.value.trim()||"운영자 주입 작업",n.task_description=xn.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(Sn.value,10)||2),await $e({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(bn.value="",Et.value==="task"&&(kn.value="",xn.value=""))}async function Pm(){var n;const t=Ke.value,e=yn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){N("먼저 세션을 고르세요","warning");return}await $e({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Cs.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function Lm(){var a;const t=Ke.value,e=Ts.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=Pe.value.trim();if(!e){N("먼저 keeper를 고르세요","warning");return}if(!n)return;await $e({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`${e}에게 메시지를 보냈습니다`})&&(Pe.value="")}async function Dm(t){const e=Vs.value.trim()||"dashboard";try{await gm(e,t),N("확인 실행을 완료했습니다","success")}catch(n){const s=n instanceof Error?n.message:"확인 실행에 실패했습니다";N(s,"error")}}function Yo(){var R,B,H;const t=Ke.value,e=M.value.tab==="intervene"?Nn(M.value):null,n=gr.value,s=qt.value,a=(t==null?void 0:t.room)??{},i=(t==null?void 0:t.sessions)??[],r=(t==null?void 0:t.keepers)??[],l=(t==null?void 0:t.pending_confirms)??[],d=(t==null?void 0:t.recent_messages)??[],m=(n==null?void 0:n.recommended_actions)??[],p=(t==null?void 0:t.available_actions)??[],u=i.find(f=>f.session_id===yn.value)??i[0]??null,g=r.find(f=>f.name===Ts.value)??r[0]??null,$=(n==null?void 0:n.attention_items)??[],y=$.filter(km),A=$.filter(xm),C=i.filter(f=>bm(f)!=="ok"),L=r.filter(f=>Wo(f)!=="ok"),j=d.slice(0,5),D=Cm(e,i,r);ot(()=>{Kt()},[]),ot(()=>{if(M.value.tab!=="intervene"){qn.value=null;return}if(!e){qn.value=null;return}qn.value!==e.id&&(qn.value=e.id,wm(e))},[M.value.tab,M.value.params.source,M.value.params.action_type,M.value.params.target_type,M.value.params.target_id,M.value.params.focus_kind,e==null?void 0:e.id]),ot(()=>{const f=(u==null?void 0:u.session_id)??null;gn(f)},[u==null?void 0:u.session_id]);const I=[{key:"room",label:"Room 게이트",value:a.paused?"일시정지":"열림",detail:a.paused?`재개 전환 대기 중${a.pause_reason?` · ${a.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:a.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:l.length,detail:l.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:l.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:y.length>0?y.length:i.length,detail:y.length>0?((R=y[0])==null?void 0:R.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":i.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:y.length>0?Go(y):i.length===0?"warn":C.some(f=>ze(f.status)==="paused")?"bad":C.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:A.length>0?A.length:L.length,detail:A.length>0?((B=A[0])==null?void 0:B.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":L.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:A.length>0?Go(A):L.some(f=>Wo(f)==="bad")?"bad":L.length>0?"warn":"ok"}];return o`
    <section class="ops-view">
      <${ee} surfaceId="intervene" />
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
            value=${Vs.value}
            onInput=${f=>hm(f.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{te(),Kt(),gn((u==null?void 0:u.session_id)??null)}}
            disabled=${Ss.value||G.value}
          >
            ${Ss.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Zt.value?o`<section class="ops-banner error">${Zt.value}</section>`:null}
      ${Ee.value?o`<section class="ops-banner error">${Ee.value}</section>`:null}
      ${e?o`
        <section class="ops-banner ${D?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${qs(e.action_type)}</span>
            <span>${yo(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?o`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${D?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${z} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 room인지, session인지, keeper인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${I.map(f=>o`
            <div key=${f.key} class="ops-priority-card ${f.tone}">
              <span class="ops-priority-label">${f.label}</span>
              <strong>${f.value}</strong>
              <div class="ops-priority-detail">${f.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
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
                value=${Re.value}
                onInput=${f=>{Re.value=f.target.value}}
                onKeyDown=${f=>{f.key==="Enter"&&Vo()}}
                disabled=${G.value}
              />
              <button class="control-btn" onClick=${()=>{Vo()}} disabled=${G.value||Re.value.trim()===""}>
                보내기
              </button>
            </div>

            <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
            <div class="control-row ops-split-row">
              <input
                id="ops-pause-reason"
                class="control-input"
                type="text"
                value=${Za.value}
                onInput=${f=>{Za.value=f.target.value}}
                disabled=${G.value}
              />
              <button class="control-btn ghost" onClick=${()=>{Tm()}} disabled=${G.value}>
                일시정지
              </button>
              <button class="control-btn ghost" onClick=${()=>{Im()}} disabled=${G.value}>
                재개
              </button>
            </div>

            <div class="ops-section-head">작업 주입</div>
            <input
              class="control-input"
              type="text"
              placeholder="작업 제목"
              value=${Ne.value}
              onInput=${f=>{Ne.value=f.target.value}}
              disabled=${G.value}
            />
            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="작업 설명"
              value=${$n.value}
              onInput=${f=>{$n.value=f.target.value}}
              disabled=${G.value}
            ></textarea>
            <div class="control-row ops-split-row">
              <select
                class="control-input ops-select"
                value=${hn.value}
                onChange=${f=>{hn.value=f.target.value}}
                disabled=${G.value}
              >
                <option value="1">P1</option>
                <option value="2">P2</option>
                <option value="3">P3</option>
                <option value="4">P4</option>
                <option value="5">P5</option>
              </select>
              <button class="control-btn" onClick=${()=>{Rm()}} disabled=${G.value||Ne.value.trim()===""}>
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
            ${fn.value&&!n?o`
              <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
            `:m.length>0?o`
              <div class="ops-log-list">
                ${m.map(f=>o`
                  <article key=${`${f.action_type}:${f.target_type}:${f.target_id??"room"}`} class="ops-log-entry ${f.severity}">
                    <div class="ops-log-head">
                      <strong>${Kn(f.action_type)}</strong>
                      <span>${Hn(f.target_type)}${f.target_id?` · ${f.target_id}`:""}</span>
                      <span>${Jo(f.confirm_required)}</span>
                    </div>
                    <div class="ops-log-body">${f.reason}</div>
                  </article>
                `)}
              </div>
            `:o`
              <div class="ops-empty">지금 떠 있는 추천 개입은 없습니다.</div>
            `}
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">승인 대기</div>
              <${z} panelId="intervene.pending_confirmations" compact=${!0} />
            </div>
            <p class="ops-context-note">미리보기만 끝났고 아직 사람이 눌러줘야 하는 액션만 남깁니다.</p>
            ${l.length>0?o`
              <div class="ops-confirmation-list">
                ${l.map(f=>o`
                  <article key=${f.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${Kn(f.action_type)}</strong>
                      <span>${Hn(f.target_type)}${f.target_id?` · ${f.target_id}`:""}</span>
                      <span>${f.delegated_tool??"위임 도구 확인 필요"}</span>
                    </div>
                    ${f.preview?o`<pre class="ops-code-block compact">${Bo(f.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{Dm(f.confirm_token)}} disabled=${G.value}>
                        실행
                      </button>
                      <span class="ops-token">${f.confirm_token}</span>
                    </div>
                  </article>
                `)}
              </div>
            `:o`<div class="ops-empty">지금 승인 대기는 없습니다.</div>`}
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 Room 메시지</div>
              <${z} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
            ${j.length>0?o`
              <div class="ops-feed-list">
                ${j.map(f=>o`
                  <article key=${f.seq??f.id??f.timestamp} class="ops-feed-item">
                    <div class="ops-feed-meta">
                      <strong>${f.from}</strong>
                      <span>${f.timestamp}</span>
                    </div>
                    <div class="ops-feed-content">${f.content}</div>
                  </article>
                `)}
              </div>
            `:o`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">Session 개입</div>
              <${z} panelId="intervene.session_queue" compact=${!0} />
            </div>
            <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

            <div class="ops-entity-list">
              ${i.length===0?o`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:i.map(f=>{var nt;return o`
                <button
                  key=${f.session_id}
                  class="ops-entity-card ${(u==null?void 0:u.session_id)===f.session_id?"active":""}"
                  onClick=${()=>{yn.value=f.session_id}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${f.session_id}</strong>
                    <span class="status-badge ${f.status??"idle"}">${Je(f.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round(f.progress_pct??0)}%</span>
                    <span>${f.done_delta_total??0}건 완료</span>
                    <span>${(nt=f.team_health)!=null&&nt.status?Je(String(f.team_health.status)):"상태 확인 필요"}</span>
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
            ${u&&s?o`
              <div class="ops-log-list">
                ${s.attention_items.length>0?s.attention_items.map(f=>o`
                  <article key=${`${f.kind}:${f.target_id??"session"}`} class="ops-log-entry ${f.severity}">
                    <div class="ops-log-head">
                      <strong>${f.kind}</strong>
                      <span>${Hn(f.target_type)}${f.target_id?` · ${f.target_id}`:""}</span>
                    </div>
                    <div class="ops-log-body">${f.summary}</div>
                  </article>
                `):o`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
                ${s.worker_cards.length>0?s.worker_cards.map(f=>o`
                  <article key=${`${f.actor??f.spawn_role??"worker"}:${f.spawn_agent??f.runtime_pool??"runtime"}`} class="ops-log-entry">
                    <div class="ops-log-head">
                      <strong>${f.actor??f.spawn_role??"worker"}</strong>
                      <span>${Je(f.status)}</span>
                      <span>${f.spawn_agent??f.runtime_pool??"runtime 확인 필요"}</span>
                    </div>
                    <div class="ops-log-body">
                      ${f.worker_class??"worker"}${f.lane_id?` · ${f.lane_id}`:""}${f.routing_reason?` · ${f.routing_reason}`:""}
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
              <${z} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>

            ${u?o`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${u.session_id}</div>
                <div class="ops-detail-meta">
                  <span>상태: ${Je(u.status)}</span>
                  <span>경과: ${u.elapsed_sec??0}초</span>
                  <span>남은 시간: ${u.remaining_sec??0}초</span>
                </div>
                ${u.recent_events&&u.recent_events.length>0?o`
                  <pre class="ops-code-block compact">${Bo(u.recent_events.slice(-3))}</pre>
                `:null}
              </div>
            `:o`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

            <label class="control-label" for="ops-turn-kind">세션 액션</label>
            <div class="control-row ops-split-row">
              <select
                id="ops-turn-kind"
                class="control-input ops-select"
                value=${Et.value}
                onChange=${f=>{Et.value=f.target.value}}
                disabled=${G.value||!u}
              >
                <option value="note">노트</option>
                <option value="broadcast">방송</option>
                <option value="task">작업</option>
                <option value="checkpoint">체크포인트</option>
              </select>
              <button class="control-btn" onClick=${()=>{Nm()}} disabled=${G.value||!u}>
                적용
              </button>
            </div>
            <div class="ops-context-note">현재 선택: ${Sm(Et.value)}</div>

            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="세션에 남길 메시지"
              value=${bn.value}
              onInput=${f=>{bn.value=f.target.value}}
              disabled=${G.value||!u}
            ></textarea>

            ${Et.value==="task"?o`
              <input
                class="control-input"
                type="text"
                placeholder="주입할 작업 제목"
                value=${kn.value}
                onInput=${f=>{kn.value=f.target.value}}
                disabled=${G.value||!u}
              />
              <textarea
                class="control-textarea"
                rows=${2}
                placeholder="주입할 작업 설명"
                value=${xn.value}
                onInput=${f=>{xn.value=f.target.value}}
                disabled=${G.value||!u}
              ></textarea>
              <select
                class="control-input ops-select"
                value=${Sn.value}
                onChange=${f=>{Sn.value=f.target.value}}
                disabled=${G.value||!u}
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
                value=${Cs.value}
                onInput=${f=>{Cs.value=f.target.value}}
                disabled=${G.value||!u}
              />
              <button class="control-btn ghost" onClick=${()=>{Pm()}} disabled=${G.value||!u}>
                세션 중지
              </button>
            </div>
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">Keeper 개입</div>
              <${z} panelId="intervene.keeper_queue" compact=${!0} />
            </div>
            <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

            <div class="ops-entity-list">
              ${r.length===0?o`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:r.map(f=>o`
                <button
                  key=${f.name}
                  class="ops-entity-card ${(g==null?void 0:g.name)===f.name?"active":""}"
                  onClick=${()=>{Ts.value=f.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${f.name}</strong>
                    <span class="status-badge ${f.status??"idle"}">${Je(f.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${f.model??"model 확인 필요"}</span>
                    <span>${typeof f.context_ratio=="number"?`${Math.round(f.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                    <span>${ym(f.last_turn_ago_s)}</span>
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

            ${g?o`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${g.name}</div>
                <div class="ops-detail-meta">
                  <span>자율성: ${g.autonomy_level??"확인 없음"}</span>
                  <span>세대: ${g.generation??0}</span>
                  <span>활성 목표: ${((H=g.active_goal_ids)==null?void 0:H.length)??0}</span>
                </div>
              </div>
            `:o`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

            <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
            <textarea
              id="ops-keeper-message"
              class="control-textarea"
              rows=${6}
              placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
              value=${Pe.value}
              onInput=${f=>{Pe.value=f.target.value}}
              disabled=${G.value||!g}
            ></textarea>
            <div class="control-row">
              <button class="control-btn" onClick=${()=>{Lm()}} disabled=${G.value||!g||Pe.value.trim()===""}>
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
              ${p.length?p.map(f=>o`
                    <article key=${`${f.action_type}:${f.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${Kn(f.action_type)}</strong>
                        <span>${Hn(f.target_type)}</span>
                        <span>${Jo(f.confirm_required)}</span>
                      </div>
                      <div class="ops-log-body">${f.description??"설명이 아직 없습니다."}</div>
                    </article>
                  `):o`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 개입 로그</div>
              <${z} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <div class="ops-log-list">
              ${As.value.length===0?o`
                <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
              `:As.value.map(f=>o`
                <article key=${f.id} class="ops-log-entry ${f.outcome}">
                  <div class="ops-log-head">
                    <strong>${Kn(f.action_type)}</strong>
                    <span>${f.target_label}</span>
                    <span>${f.at}</span>
                  </div>
                  <div class="ops-log-body">${f.message}</div>
                </article>
              `)}
            </div>
          </section>
        </div>
      </div>
    </section>
  `}function Mm(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function Z({timestamp:t}){const e=Mm(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}function Em({text:t}){if(!t)return null;const e=zm(t);return o`<div class="markdown-content">${e}</div>`}function zm(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],l=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(o`<pre><code class=${l?`language-${l}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],l=a.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const m=e[s].replace("</think>","").trim();m&&r.push(m),s++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${sa(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${sa(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${sa(i.join(`
`))}</p>`)}return n}function sa(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Qe=v("posts"),to=v([]),eo=v([]),tn=v(""),Is=v(!1),en=v(!1),An=v(""),Rs=v(null),kt=v(null),no=v(!1),Jt=v(null),ns=v(null);async function Ys(){Is.value=!0,An.value="";try{const[t,e]=await Promise.all([bc(),kc()]);to.value=t,eo.value=e,Jt.value=!0,ns.value=Date.now()}catch(t){An.value=t instanceof Error?t.message:"Failed to load council data",Jt.value=!1}finally{Is.value=!1}}gd(Ys);async function Xo(){const t=tn.value.trim();if(t){en.value=!0;try{const e=await xc(t);tn.value="",N(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Ys()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";N(n,"error")}finally{en.value=!1}}}async function Om(t){Rs.value=t,no.value=!0,kt.value=null;try{kt.value=await Sc(t)}catch(e){An.value=e instanceof Error?e.message:"Failed to load debate status",kt.value=null}finally{no.value=!1}}const xr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],ss=v(null),nn=v([]),_e=v(!1),pe=v(null),sn=v("");function jm(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Fm=v(jm()),an=v(!1);async function wo(t){pe.value=t,ss.value=null,nn.value=[],_e.value=!0;try{const e=await Gl(t);if(pe.value!==t)return;ss.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},nn.value=e.comments??[]}catch{pe.value===t&&(ss.value=null,nn.value=[])}finally{pe.value===t&&(_e.value=!1)}}async function Qo(t){const e=sn.value.trim();if(e){an.value=!0;try{await Jl(t,Fm.value,e),sn.value="",N("Comment posted","success"),await wo(t),It()}catch{N("Failed to post comment","error")}finally{an.value=!1}}}function qm(){const t=cn.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${xr.map(e=>o`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{cn.value=e.id,It()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${ce.value?"is-active":""}"
          onClick=${()=>{ce.value=!ce.value,It()}}
        >
          ${ce.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${It} disabled=${un.value}>
          ${un.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function so(){var e;const t=(e=je.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${Z} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Sr({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Km(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function Zo(t){return t.updated_at!==t.created_at}function ao(){var n;const t=((n=xr.find(s=>s.id===cn.value))==null?void 0:n.label)??cn.value,e=Fe.value.length;return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Visible posts</span>
        <strong>${e}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Sort</span>
        <strong>${t}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${ce.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${qa.value?o`<${Z} timestamp=${qa.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Hm({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await wi(t.id,n),It()}catch{N("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>ol(t.id)}>
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
              <${Sr} flair=${t.flair} />
              ${Zo(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${Z} timestamp=${t.created_at} /></span>
            ${Zo(t)?o`<span>Updated <${Z} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${Km(t.content)}</div>
      </div>
    </div>
  `}function Um({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${Z} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Bm({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${sn.value}
        onInput=${e=>{sn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Qo(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${an.value}
      />
      <button
        onClick=${()=>Qo(t)}
        disabled=${an.value||sn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${an.value?"...":"Post"}
      </button>
    </div>
  `}function Wm({post:t}){pe.value!==t.id&&!_e.value&&wo(t.id);const e=async n=>{try{await wi(t.id,n),It()}catch{N("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>$t("board")}>← Back to Board</button>
      <${T} title=${o`${t.title} <${Sr} flair=${t.flair} />`} semanticId="board.post_feed">
        <div class="board-detail">
          <div class="post-body">
            <${Em} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${Z} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${T} title="Comments (${_e.value?"...":nn.value.length})" semanticId="board.post_feed">
        ${_e.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Um} comments=${nn.value} />`}
        <${Bm} postId=${t.id} />
      <//>
    </div>
  `}function Gm({debate:t}){const e=Rs.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Om(t.id)}
    >
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Args: ${t.argument_count}</span>
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </button>
  `}function Jm({session:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.state?o`<span>State: ${t.state}</span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function Ar(){return Jt.value===null||Jt.value&&!ns.value?null:o`
    <div class="feed-health-banner ${Jt.value===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${Jt.value===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${ns.value?o`<span class="feed-health-meta">Last sync: <${Z} timestamp=${ns.value} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Vm(){const t=Jt.value===!1;return o`
    <div>
      <${Ar} />
      <${T} title="Start Debate" class="section" semanticId="board.debates">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${tn.value}
            onInput=${e=>{tn.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&Xo()}}
            disabled=${en.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Xo}
            disabled=${en.value||tn.value.trim()===""}
          >
            ${en.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Ys} disabled=${Is.value}>
            ${Is.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${An.value?o`<div class="council-error">${An.value}</div>`:null}
      <//>

      <${T} title="Debates" class="section" semanticId="board.debates">
        <div class="council-list">
          ${to.value.length===0?o`<div class="empty-state">${t?"No debates loaded (council feed degraded).":"No debates yet"}</div>`:to.value.map(e=>o`<${Gm} key=${e.id} debate=${e} />`)}
        </div>
      <//>

      <${T} title=${Rs.value?`Debate Detail (${Rs.value})`:"Debate Detail"} class="section" semanticId="board.debates">
        ${no.value?o`<div class="loading-indicator">Loading debate detail...</div>`:kt.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${kt.value.status}</span>
                  <span>Total arguments: ${kt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${kt.value.support_count}</span>
                  <span>Oppose: ${kt.value.oppose_count}</span>
                  <span>Neutral: ${kt.value.neutral_count}</span>
                </div>
                ${kt.value.summary_text?o`<pre class="council-detail">${kt.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Ym(){const t=Jt.value===!1;return o`
    <div>
      <${Ar} />
      <${T} title="Voting Sessions" class="section" semanticId="board.voting">
        <div class="council-list">
          ${eo.value.length===0?o`<div class="empty-state">${t?"No sessions loaded (council feed degraded).":"No active sessions"}</div>`:eo.value.map(e=>o`<${Jm} key=${e.id} session=${e} />`)}
        </div>
      <//>
    </div>
  `}function Xm(){const t=Qe.value;return o`
    <div class="overview-sub-tabs" style="margin-bottom: 12px;">
      <button class="sub-tab-btn ${t==="posts"?"active":""}" onClick=${()=>{Qe.value="posts"}}>Posts</button>
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{Qe.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{Qe.value="voting"}}>Voting</button>
    </div>
  `}function Qm(){var s,a;const t=Fe.value,e=un.value,n=((a=(s=je.value)==null?void 0:s.data_quality)==null?void 0:a.board_contract_ok)===!1;return o`
    <div>
      <${so} />
      <${ao} />
      <${qm} />
      ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
              <div class="empty-state">
                ${n?"No posts loaded (board feed degraded). Check board contract sync.":ce.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
              </div>
            `:o`<div class="board-post-list">
              ${t.map(i=>o`<${Hm} key=${i.id} post=${i} />`)}
            </div>`}
    </div>
  `}function Zm(){var i,r;const t=Fe.value,e=M.value.postId,n=((r=(i=je.value)==null?void 0:i.data_quality)==null?void 0:r.board_contract_ok)===!1,s=Qe.value,a=o`<${ee} surfaceId="board" />`;if(ot(()=>{(s==="debates"||s==="voting")&&Ys()},[s]),e){const l=t.find(d=>d.id===e)??(pe.value===e?ss.value:null);return!l&&pe.value!==e&&!_e.value&&wo(e),l?o`
          ${a}
          <${so} />
          <${ao} />
          <${Wm} post=${l} />
        `:o`
          <div>
            ${a}
            <${so} />
            <${ao} />
            <button class="back-btn" onClick=${()=>$t("board")}>← Back to Board</button>
            ${_e.value?o`<div class="loading-indicator">Loading post...</div>`:o`
                  <div class="empty-state">
                    ${n?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return o`
    ${a}
    <${Xm} />
    ${s==="debates"?o`<${Vm} />`:s==="voting"?o`<${Ym} />`:o`<${Qm} />`}
  `}const tv=40;function ev({items:t,itemHeight:e,overscan:n=5,renderItem:s,getKey:a,className:i=""}){const r=vi(null),[l,d]=mo({start:0,end:30}),m=t.length>tv;if(ot(()=>{if(!m)return;const $=r.current;if(!$)return;let y=!1;const A=()=>{const{scrollTop:D,clientHeight:I}=$,R=Math.max(0,Math.floor(D/e)-n),B=Math.min(t.length,Math.ceil((D+I)/e)+n);d(H=>H.start===R&&H.end===B?H:{start:R,end:B})};let C=!1;const L=()=>{C||y||(C=!0,requestAnimationFrame(()=>{y||A(),C=!1}))},j=new ResizeObserver(()=>{y||A()});return A(),$.addEventListener("scroll",L,{passive:!0}),j.observe($),()=>{y=!0,$.removeEventListener("scroll",L),j.disconnect()}},[m,t.length,e,n]),!m)return o`
      <div class=${i}>
        ${t.map(($,y)=>s($,y))}
      </div>
    `;const p=t.length*e,u=l.start*e,g=t.slice(l.start,l.end);return o`
    <div ref=${r} class=${i}>
      <div class="virtual-list-spacer" style=${{height:`${p}px`,position:"relative"}}>
        <div
          class="virtual-list-viewport"
          style=${{position:"absolute",top:0,left:0,right:0,willChange:"transform",transform:`translateY(${u}px)`}}
        >
          ${g.map(($,y)=>{const A=l.start+y;return o`<div key=${a($)}>${s($,A)}</div>`})}
        </div>
      </div>
    </div>
  `}function nv(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function sv(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function av(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const wr=120,ov=12,iv=16,rv=12,as=v("all"),lv={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},cv={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function dv(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function uv(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:nv(t),actor:sv(t),content:av(t),timestamp:new Date(t.timestamp).toISOString()}}function pv(t,e){var a;const n=(a=t.assignee)==null?void 0:a.trim(),s=t.updated_at??t.created_at;return!n||!s?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:s}}function mv(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function Un(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function oo(t){return t.last_heartbeat??Un(t.last_turn_ago_s)??Un(t.last_proactive_ago_s)??Un(t.last_handoff_ago_s)??Un(t.last_compaction_ago_s)}function vv(t,e){const n=oo(t);if(!n)return null;const s=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${s}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${s}`,timestamp:n}}function At(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const io=ht(()=>{const t=ln.value.map(dv),e=cs.value.map(uv),n=[...St.value].sort((i,r)=>At(r.updated_at??r.created_at??0)-At(i.updated_at??i.created_at??0)).slice(0,ov).map(pv).filter(i=>i!==null),s=[...Fe.value].sort((i,r)=>At(r.updated_at||r.created_at)-At(i.updated_at||i.created_at)).slice(0,iv).map(mv),a=[...ge.value].sort((i,r)=>At(oo(r)??0)-At(oo(i)??0)).slice(0,rv).map(vv).filter(i=>i!==null);return[...t,...e,...n,...s,...a].sort((i,r)=>At(r.timestamp)-At(i.timestamp))}),_v=ht(()=>{const t=io.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),fv=ht(()=>{const t=as.value;return(t==="all"?io.value:io.value.filter(n=>n.kind===t)).slice(0,wr)}),gv=ht(()=>{const t=Mi.value,e={activeAssignedCount:0,lastActivityAt:null,lastActivityText:null};return Nt.value.map(n=>({agent:n,motion:t.get(n.name.trim().toLowerCase())??e})).sort((n,s)=>{const a=s.motion.activeAssignedCount-n.motion.activeAssignedCount;return a!==0?a:At(s.motion.lastActivityAt??0)-At(n.motion.lastActivityAt??0)})});function $v(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function Ve({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function hv({row:t}){return o`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${$v(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${cv[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function yv(){const t=_v.value,e=fv.value,n=e[0],s=gv.value;return o`
    <div class="stats-grid">
      <${Ve} label="Visible rows 표시 행" value=${e.length} />
      <${Ve} label="Tracked messages 추적 메시지" value=${t.messages} color="#47b8ff" />
      <${Ve} label="Keeper signals 키퍼 신호" value=${t.keepers} color="#4ade80" />
      <${Ve} label="Board signals 보드 신호" value=${t.board} color="#fbbf24" />
      <${Ve} label="SSE events SSE 이벤트" value=${Es.value} color="#c084fc" />
    </div>

    <${T} title="Unified Activity 통합 활동" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(a=>o`
            <button
              class="goal-filter-btn ${as.value===a?"active":""}"
              aria-pressed="${as.value===a}"
              onClick=${()=>{as.value=a}}
            >
              ${lv[a]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${Ot.value?"":"pill-stale"}">
            ${Ot.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?o`Latest: <${Z} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${wr} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      ${e.length===0?o`<div class="terminal-feed"><div class="empty-state">Waiting for live or snapshot signals...</div></div>`:o`<${ev}
            items=${e}
            itemHeight=${28}
            overscan=${8}
            getKey=${a=>a.id}
            renderItem=${a=>o`<${hv} row=${a} />`}
            className="terminal-feed"
          />`}
    <//>

    <${T} title="Agent Motion 에이전트 동향" class="section">
      <div class="activity-motion-list">
        ${s.length===0?o`<div class="empty-state">No active agents</div>`:s.map(({agent:a,motion:i})=>o`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${a.name}</div>
                  <div class="activity-motion-meta">
                    ${i.activeAssignedCount>0?`${i.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${i.lastActivityAt?o` · <${Z} timestamp=${i.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${i.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function se({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Cr({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${l}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${l}">${Math.round(t*100)}%</span>
    </div>
  `}function bv(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function kv(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function xv(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function ti(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function Tr(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Sv(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Ir(t){if(!t)return null;const e=jt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function Av({keeper:t,showRawStatus:e=!1}){if(ot(()=>{t!=null&&t.name&&Ri(t.name)},[t==null?void 0:t.name]),!t)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=jt.value[t.name],s=Ir(t),a=Ra.value[t.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${bv(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${kv((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?o` · ${Tr(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?o` · next eligible ${Sv(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?o`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function wv({keeperName:t,placeholder:e}){const[n,s]=mo("");ot(()=>{t&&Ri(t)},[t]);const a=rt.value[t]??[],i=Na.value[t]??!1,r=Ft.value[t],l=async()=>{const d=n.trim();if(!(!t||!d)){s("");try{await Kc(t,d)}catch(m){const p=m instanceof Error?m.message:`Failed to message ${t}`;N(p,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?o`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(d=>o`
              <div class="keeper-conversation-item" key=${d.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${ti(d)}`}>${d.label}</span>
                  <span class=${`keeper-role-chip ${ti(d)}`}>${xv(d)}</span>
                  ${d.timestamp?o`<span class="keeper-conversation-time">${Tr(d.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${d.text}</div>
                ${d.error?o`<div class="keeper-conversation-error">${d.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${e}
          value=${n}
          onInput=${d=>{s(d.target.value)}}
          disabled=${i||!t}
        ></textarea>
        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${()=>{l()}}
            disabled=${i||n.trim()===""||!t}
          >
            ${i?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${r?o`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function Cv({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=Ir(e),a=Pa.value[e.name]??!1,i=La.value[e.name]??!1,r=(s==null?void 0:s.next_action_path)??"direct_message",l=(s==null?void 0:s.recoverable)??r==="recover";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{Hc(e.name,t).catch(d=>{const m=d instanceof Error?d.message:`Failed to probe ${e.name}`;N(m,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{Uc(e.name,t).catch(d=>{const m=d instanceof Error?d.message:`Failed to recover ${e.name}`;N(m,"error")})}}
        disabled=${i||!l||!t.trim()}
      >
        ${i?"Recovering...":"Recover"}
      </button>
      <button
        class=${`control-btn ghost ${r==="manual_lodge_poke"?"is-active":""}`}
        onClick=${n}
      >
        Poke Lodge
      </button>
    </div>
  `}const Co=v(null);function Rr(t){Co.value=t,qc(t.name)}function ei(){Co.value=null}const ke=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Tv(t){if(!t)return 0;const e=ke.findIndex(n=>n.level===t);return e>=0?e:0}function Iv({keeper:t}){const e=Tv(t.autonomy_level),n=ke[e]??ke[0];if(!n)return null;const s=(e+1)/ke.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${ke.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${ke.map((a,i)=>o`
            <span style="width:8px; height:8px; border-radius:50%; background:${i<=e?a.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${t.autonomous_action_count??0}</strong>
      </div>
      ${t.last_autonomous_action_at?o`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${Z} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function os(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Rv({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${os(t.context_tokens)}</div>
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
  `}function Nv({keeper:t}){var p,u;const e=t.metrics_series??[];if(e.length<2){const g=(((p=t.context)==null?void 0:p.context_ratio)??0)*100,$=g>85?"#ef4444":g>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${g.toFixed(1)}%;background:${$}"></div>
        </div>
        <span class="chart-pct">${g.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((g,$)=>{const y=a+$/(i-1)*(n-2*a),A=s-a-(g.context_ratio??0)*(s-2*a);return{x:y,y:A,p:g}}),l=r.map(({x:g,y:$})=>`${g.toFixed(1)},${$.toFixed(1)}`).join(" "),d=(((u=e[e.length-1])==null?void 0:u.context_ratio)??0)*100,m=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:g})=>g.is_handoff).map(({x:g})=>o`
          <line x1="${g.toFixed(1)}" y1="${a}" x2="${g.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${m}" stroke-width="1.5"/>
        ${r.filter(({p:g})=>g.is_compaction).map(({x:g,y:$})=>o`
          <circle cx="${g.toFixed(1)}" cy="${$.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const aa=v("");function Pv({keeper:t}){var a,i,r,l;const e=aa.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${aa.value}
        onInput=${d=>{aa.value=d.target.value}}
      />
      ${s.map(d=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${d.title}</span>
          <span class="keeper-field-key">${d.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${d.value}</span>
        </div>
      `)}
      ${t.trace_id?o`<div class="keeper-field-row"><span class="keeper-field-title">Trace ID</span><span class="keeper-field-key mono">${t.trace_id}</span></div>`:""}
      ${t.agent_name?o`<div class="keeper-field-row"><span class="keeper-field-title">Agent</span><span style="flex:1; text-align:right; color:#ccc;">${t.agent_name}</span></div>`:""}
      ${t.primary_model?o`<div class="keeper-field-row"><span class="keeper-field-title">Primary Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.primary_model}</span></div>`:""}
      ${t.active_model?o`<div class="keeper-field-row"><span class="keeper-field-title">Active Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.active_model}</span></div>`:""}
      ${t.next_model_hint?o`<div class="keeper-field-row"><span class="keeper-field-title">Next Model Hint</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.next_model_hint}</span></div>`:""}
      ${t.skill_primary?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Primary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_primary}</span></div>`:""}
      ${t.skill_secondary?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Secondary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_secondary}</span></div>`:""}
      ${t.skill_reason?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill Reason</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_reason}</span></div>`:""}
      ${t.context_source?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Source</span><span style="flex:1; text-align:right; color:#ccc;">${t.context_source}</span></div>`:""}
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${os(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${os(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${os(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Lv({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(s=>o`
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
  `}function Dv({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Mv({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function ni({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function oa(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Ev({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:oa(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:oa(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:oa(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function Nr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function zv(){try{const t=await zs({actor:Nr(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Ii(t.result);pn(),await fe(),e!=null&&e.skipped_reason?N(e.skipped_reason,"warning"):N(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";N(e,"error")}}function Ov({keeper:t}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Av} keeper=${t} />
          <${Cv}
            actor=${Nr()}
            keeper=${t}
            onPokeLodge=${()=>{zv()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${wv}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function jv(){var e,n,s;const t=Co.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&ei()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${""}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${t.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${t.name}</h2>
              ${t.koreanName?o`<div style="font-size:13px; color:#888;">${t.koreanName}</div>`:null}
            </div>
            <${se} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>ei()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Rv} keeper=${t} />

        ${""}
        <${Nv} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${T} title="Field Dictionary">
            <${Pv} keeper=${t} />
          <//>

          ${""}
          <${T} title="Profile">
            <${ni} traits=${t.traits??[]} label="Traits" />
            <${ni} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${Z} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${T} title="Autonomy">
                <${Iv} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${T} title="TRPG Stats">
                <${Lv} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${T} title="Equipment (${t.inventory.length})">
                <${Dv} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${T} title="Relationships (${Object.keys(t.relationships).length})">
                <${Mv} rels=${t.relationships} />
              <//>
            `:null}

          <${T} title="Runtime Signals">
            <${Ev} keeper=${t} />
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
              ${t.memory_recent_note?o`
                  <div class="keeper-memory-note">
                    ${t.memory_recent_note}
                  </div>
                `:o`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${Ov} keeper=${t} />
      </div>
    </div>
  `:null}const Fv="masc_dashboard_agent_name",He=v(null),Ns=v(!1),wn=v(""),Ps=v([]),Cn=v([]),Le=v(""),on=v(!1);function Pr(t){He.value=t,To()}function si(){He.value=null,wn.value="",Ps.value=[],Cn.value=[],Le.value=""}function qv(){const t=He.value;return t?Nt.value.find(e=>e.name===t)??null:null}function Lr(t){return t?St.value.filter(e=>e.assignee===t):[]}async function To(){const t=He.value;if(t){Ns.value=!0,wn.value="",Ps.value=[],Cn.value=[];try{const e=await hc(80);Ps.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Lr(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await yc(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));Cn.value=s}catch(e){wn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Ns.value=!1}}}async function ai(){var s;const t=He.value,e=Le.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Fv))==null?void 0:s.trim())||"dashboard";on.value=!0;try{await $c(n,`@${t} ${e}`),Le.value="",N(`Mention sent to ${t}`,"success"),To()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";N(i,"error")}finally{on.value=!1}}function Kv({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${se} status=${t.status} />
    </div>
  `}function Hv({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Uv(){var a,i,r,l;const t=He.value;if(!t)return null;const e=qv(),n=Lr(t),s=Ps.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&si()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${e!=null&&e.emoji?o`<span style="font-size:2rem">${e.emoji}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${t}
                  ${e!=null&&e.koreanName?o`<span style="font-size:0.75em;color:#888">(${e.koreanName})</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  ${e?o`
                        <${se} status=${e.status} />
                        ${e.model?o`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                        ${e.primaryValue?o`<span style="font-size:0.75rem;color:#a78bfa">${e.primaryValue}</span>`:""}
                      `:o`<span>Agent snapshot not found in current state</span>`}
                </div>
              </div>
            </div>
            ${(e==null?void 0:e.activityLevel)!=null?o`
              <div style="display:flex;align-items:center;gap:8px;font-size:0.8rem">
                <span style="color:#888">Activity</span>
                <div style="flex:1;max-width:120px;height:6px;background:#1a1a2e;border-radius:3px;overflow:hidden">
                  <div style="width:${Math.min(e.activityLevel*10,100)}%;height:100%;background:${e.activityLevel>=8?"#22c55e":e.activityLevel>=5?"#f59e0b":"#666"};border-radius:3px"></div>
                </div>
                <span style="color:#888">${e.activityLevel}/10</span>
              </div>
            `:""}
            ${(((a=e==null?void 0:e.traits)==null?void 0:a.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(i=e==null?void 0:e.traits)==null?void 0:i.map(d=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(l=e==null?void 0:e.interests)==null?void 0:l.map(d=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${Z} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{To()}} disabled=${Ns.value}>
              ${Ns.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${si}>Close</button>
          </div>
        </div>

        ${wn.value?o`<div class="council-error">${wn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${T} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${Kv} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${T} title="Recent Activity">
            ${s.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${s.map((d,m)=>o`<div key=${m} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${T} title="Task History">
          ${Cn.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Cn.value.map(d=>o`<${Hv} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${T} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Le.value}
              onInput=${d=>{Le.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&ai()}}
              disabled=${on.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{ai()}}
              disabled=${on.value||Le.value.trim()===""}
            >
              ${on.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const ia=600*1e3,Bv=1200*1e3,oi=.8;function Wt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function be(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Wv(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function Gv(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Jv(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Vv(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function Yv(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function Xv(t){var d,m;const e=Mi.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,s=n?Math.max(0,Date.now()-Wt(n)):Number.POSITIVE_INFINITY,a=!!((d=t.current_task)!=null&&d.trim())||e.activeAssignedCount>0;let i="watching",r="ok",l="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",l=n?"Offline or inactive":"No recent presence"):s>Bv?(i="quiet",r="bad",l=a?"Working without a fresh signal":"No fresh agent signal"):a?(i="working",r=s>ia?"warn":"ok",l=s>ia?"Execution looks quiet for too long":"Task and live signal aligned"):s>ia?(i="quiet",r="warn",l="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",l="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((m=t.current_task)==null?void 0:m.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:l}}function Qv(t){const e=Zc.value.get(t.name)??"idle",n=nd.value.has(t.name),s=t.context_ratio??0;let a="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(a="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||s>=oi)&&(a="warning",i="warn",r=s>=oi?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:a,tone:i,focus:Vv(t),note:r}}function Ye({label:t,value:e,color:n,caption:s}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?o`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function Zv({item:t}){const e=t.kind==="agent"?()=>Pr(t.agent.name):()=>Rr(t.keeper);return o`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?o`<span><${Z} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </button>
  `}function ii({row:t}){const{agent:e,motion:n}=t;return o`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Pr(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Cr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${se} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${Wv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${Z} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
        ${e.last_seen?o`<span>Seen <${Z} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?o`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function t_({row:t}){const{keeper:e}=t;return o`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Rr(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Cr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${se} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Gv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?o`<span>Heartbeat <${Z} timestamp=${e.last_heartbeat} /></span>`:o`<span>No heartbeat</span>`}
        <span>${Yv(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${Jv(e.context_ratio)}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?o`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function e_(){const t=[...Nt.value].map(Xv).sort((p,u)=>{const g=be(u.tone)-be(p.tone);if(g!==0)return g;const $=u.activeTaskCount-p.activeTaskCount;return $!==0?$:Wt(u.lastSignalAt)-Wt(p.lastSignalAt)}),e=[...ge.value].map(Qv).sort((p,u)=>{const g=be(u.tone)-be(p.tone);if(g!==0)return g;const $=(u.keeper.context_ratio??0)-(p.keeper.context_ratio??0);return $!==0?$:Wt(u.keeper.last_heartbeat)-Wt(p.keeper.last_heartbeat)}),n=t.filter(p=>p.state!=="offline"),s=t.filter(p=>p.state==="offline"),a=n.length,i=t.filter(p=>p.state==="working").length,r=t.filter(p=>p.lastSignalAt&&Date.now()-Wt(p.lastSignalAt)<=12e4).length,l=t.filter(p=>p.tone!=="ok"),d=e.filter(p=>p.tone!=="ok"),m=[...d.map(p=>({kind:"keeper",key:`keeper-${p.keeper.name}`,tone:p.tone,title:p.keeper.name,subtitle:`${p.note} · ${p.focus}`,timestamp:p.keeper.last_heartbeat??null,keeper:p.keeper})),...l.map(p=>({kind:"agent",key:`agent-${p.agent.name}`,tone:p.tone,title:p.agent.name,subtitle:`${p.note} · ${p.focus}`,timestamp:p.lastSignalAt,agent:p.agent}))].sort((p,u)=>{const g=be(u.tone)-be(p.tone);return g!==0?g:Wt(u.timestamp)-Wt(p.timestamp)}).slice(0,8);return o`
    <div class="agents-monitor">
      <${ee} surfaceId="agents" />
      <div class="stats-grid">
        <${Ye} label="Agents online 온라인" value=${a} color="#4ade80" caption="활성 + 대기 에이전트" />
        <${Ye} label="Working now 작업중" value=${i} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${Ye} label="Fresh signals 최신 신호" value=${r} color="#22d3ee" caption="최근 2분 이내" />
        <${Ye} label="Agent alerts 에이전트 경고" value=${l.length} color=${l.length>0?"#fb7185":"#4ade80"} caption="비활성 또는 오프라인" />
        <${Ye} label="Keeper alerts 키퍼 경고" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="오래되거나 높은 부하" />
      </div>

      <${T} title="Attention Queue 주의 필요" class="section" semanticId="agents.attention_queue">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${m.length===0?o`<div class="empty-state">No agent or keeper alerts right now</div>`:m.map(p=>o`<${Zv} key=${p.key} item=${p} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${T} title="Active Agents 활성 에이전트" class="section" semanticId="agents.active_agents">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Live agents stay grouped here first so execution drift is visible before you scan offline history.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?o`<div class="empty-state">No active agents visible</div>`:n.map(p=>o`<${ii} key=${p.agent.name} row=${p} />`)}
          </div>
        <//>

        <${T} title="Keeper Watch 키퍼 감시" class="section" semanticId="agents.keeper_watch">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?o`<div class="empty-state">No keepers active</div>`:e.map(p=>o`<${t_} key=${p.keeper.name} row=${p} />`)}
          </div>
        <//>

        <${T} title="Offline Agents 오프라인" class="section" semanticId="agents.offline_agents">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who dropped out of the live loop</h2>
            <p class="monitor-subheadline">Offline rows are separated so they do not drown the active execution monitor.</p>
          </div>
          <div class="monitor-list">
            ${s.length===0?o`<div class="empty-state">No offline agents right now</div>`:s.map(p=>o`<${ii} key=${p.agent.name} row=${p} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Ls=v("all"),Ds=v("all"),ro=ht(()=>{let t=dn.value;return Ls.value!=="all"&&(t=t.filter(e=>e.horizon===Ls.value)),Ds.value!=="all"&&(t=t.filter(e=>e.status===Ds.value)),t}),n_=ht(()=>{const t={short:[],mid:[],long:[]};for(const e of ro.value){const n=t[e.horizon];n&&n.push(e)}return t}),s_=ht(()=>{const t=Array.from(Pi.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function a_(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Io(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function is(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function o_(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function ri(t){return t.toFixed(4)}function li(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function i_({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${is(t.horizon)}">
            ${Io(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${a_(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${Z} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${se} status=${t.status} />
        <div class="goal-updated">
          <${Z} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function ci({label:t,timestamp:e,source:n,note:s}){return o`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${s?o`<div class="planning-freshness-source">${s}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?o`<${Z} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function ra({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${T} title="${Io(t)} Goals (${e.length})" class="section" semanticId="goals.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>o`<${i_} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function r_(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Ls.value===t?"active":""}"
            onClick=${()=>{Ls.value=t}}
          >
            ${t==="all"?"All":Io(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Ds.value===t?"active":""}"
            onClick=${()=>{Ds.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function l_(){const t=dn.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${is("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${is("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${is("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function c_({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${se} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${ri(t.baseline_metric)}</span>
          <span>Current ${ri(t.current_metric)}</span>
          <span class=${li(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${li(t)}
          </span>
          <span>Elapsed ${o_(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"No explicit target provided"}</div>
        ${t.stop_reason||t.error_message?o`
              <div class="planning-loop-footnote">
                ${t.error_message??t.stop_reason}
              </div>
            `:null}
        <div class="planning-loop-footnote">
          ${t.strict_mode?"Strict hard evidence":"Legacy"} · ${t.worker_engine??"unknown engine"} · ${n}
        </div>
        ${e?o`
              <div class="planning-loop-footnote">
                Latest iteration #${e.iteration}: ${e.changes||e.next_suggestion||"No narrative"}
              </div>
            `:o`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function la({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${Z} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function d_(){const{todo:t,inProgress:e,done:n}=Xc.value;return o`
    <${T} title="Task Backlog" class="section" semanticId="goals.task_backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>o`<${la} key=${s.id} task=${s} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>o`<${la} key=${s.id} task=${s} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>o`<${la} key=${s.id} task=${s} />`)}
          ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function u_(){const t=n_.value,e=s_.value,n=e.filter(l=>l.status==="running").length,s=e.filter(l=>l.recoverable).length,a=dn.value.filter(l=>l.status==="active").length,i=za.value,r=i==="idle"?"No loop running":i==="error"?Oa.value??"MDAL snapshot unavailable":"Current loop snapshot";return o`
    <div>
      <${ee} surfaceId="goals" />
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${a}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${ro.value.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Running loops</div>
          <div class="stat-value" style="color:#fbbf24">${n}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Recoverable loops</div>
          <div class="stat-value" style="color:#38bdf8">${s}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Known loops</div>
          <div class="stat-value">${e.length}</div>
        </div>
      </div>

      <${T} title="Planning Surface" class="section" semanticId="goals.planning_surface">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>/api/v1/mdal/loops</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${mn} disabled=${Ae.value}>
              ${Ae.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${Me} disabled=${we.value}>
              ${we.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{mn(),Me()}}
              disabled=${Ae.value||we.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${ci} label="Goals" timestamp=${Li.value} source="masc_goal_list" />
          <${ci}
            label="MDAL loops"
            timestamp=${Di.value}
            source="/api/v1/mdal/loops"
            note=${r}
          />
        </div>
      <//>

      <${T} title="Goal Pipeline" class="section" semanticId="goals.goal_pipeline">
        <${l_} />
        <${r_} />
      <//>

      ${Ae.value&&dn.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:ro.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${ra} horizon="short" items=${t.short??[]} />
              <${ra} horizon="mid" items=${t.mid??[]} />
              <${ra} horizon="long" items=${t.long??[]} />
            `}

      <${T} title="MDAL Loops" class="section" semanticId="goals.mdal_loops">
        ${we.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&i==="error"?o`
                <div class="empty-state">
                  MDAL snapshot could not be loaded right now. Check the backend tool contract or runtime health.
                </div>
              `:e.length===0&&i==="idle"?o`
                <div class="empty-state">
                  No loop is running right now. This section wakes up when <code>masc_mdal_start</code> exposes a live loop.
                </div>
              `:e.length===0?o`
                  <div class="empty-state">
                    No loop snapshot is visible yet. Refresh once the backend has reported a planning loop.
                  </div>
                `:o`
                <div class="planning-loop-list">
                  ${e.map(l=>o`<${c_} key=${l.loop_id} loop=${l} />`)}
                </div>
              `}
      <//>

      <${d_} />
    </div>
  `}const xe=v(""),ca=v("ability_check"),da=v("10"),ua=v("12"),Bn=v(""),Wn=v("idle"),Gt=v(""),Gn=v("keeper-late"),pa=v("player"),ma=v(""),gt=v("idle"),va=v(null),Jn=v(""),_a=v(""),fa=v("player"),ga=v(""),$a=v(""),ha=v(""),rn=v("20"),ya=v("20"),ba=v(""),Vn=v("idle"),lo=v(null),Dr=v("overview"),ka=v("all"),xa=v("all"),Sa=v("all"),p_=12e4,Xs=v(null),di=v(Date.now());function m_(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function v_(t,e){return e>0?Math.round(t/e*100):0}const __={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},f_={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Yn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function g_(t){const e=t.trim().toLowerCase();return __[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function $_(t){const e=t.trim().toLowerCase();return f_[e]??"상황에 따라 선택되는 전술 액션입니다."}function Qt(t){return typeof t=="object"&&t!==null}function mt(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function wt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function Tn(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const h_=new Set(["str","dex","con","int","wis","cha"]);function y_(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!Qt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const r=a.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){s[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const l=Number.parseFloat(i.trim());if(Number.isFinite(l)){s[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),s}function b_(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(rn.value.trim(),10);Number.isFinite(s)&&s>n&&(rn.value=String(n))}function co(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function k_(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function x_(t){Dr.value=t}function Mr(t){const e=Xs.value;return e==null||e<=t}function S_(t){const e=Xs.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Ms(){Xs.value=null}function Er(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function A_(t,e){Er(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Xs.value=Date.now()+p_,N("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function rs(t){return Mr(t)?(N("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function uo(t,e,n){return Er([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function w_({hp:t,max:e}){const n=v_(t,e),s=m_(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function C_({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function T_({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function zr({actor:t}){var d,m,p,u;const e=(d=t.archetype)==null?void 0:d.trim(),n=(m=t.persona)==null?void 0:m.trim(),s=(p=t.portrait)==null?void 0:p.trim(),a=(u=t.background)==null?void 0:u.trim(),i=t.traits??[],r=t.skills??[],l=Object.entries(t.stats_raw??{}).filter(([g,$])=>Number.isFinite($)).filter(([g])=>!h_.has(g.toLowerCase()));return o`
    <div class="trpg-actor">
      ${s?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${g=>{const $=g.target;$&&($.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${se} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${T_} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${w_} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${C_} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${Yn(e)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${l.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${l.map(([g,$])=>o`
                <span class="trpg-custom-stat-chip">${Yn(g)} ${$}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(g=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Yn(g)}</span>
                  <span class="trpg-annot-desc">${g_(g)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(g=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Yn(g)}</span>
                  <span class="trpg-annot-desc">${$_(g)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function I_({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Or({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${k_(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${co(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${Z} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function R_({events:t}){const e="__none__",n=ka.value,s=xa.value,a=Sa.value,i=Array.from(new Set(t.map(co).map(u=>u.trim()).filter(u=>u!==""))).sort((u,g)=>u.localeCompare(g)),r=Array.from(new Set(t.map(u=>(u.type??"").trim()).filter(u=>u!==""))).sort((u,g)=>u.localeCompare(g)),l=t.some(u=>(u.type??"").trim()===""),d=Array.from(new Set(t.map(u=>(u.phase??"").trim()).filter(u=>u!==""))).sort((u,g)=>u.localeCompare(g)),m=t.some(u=>(u.phase??"").trim()===""),p=t.filter(u=>{if(n!=="all"&&co(u)!==n)return!1;const g=(u.type??"").trim(),$=(u.phase??"").trim();if(s===e){if(g!=="")return!1}else if(s!=="all"&&g!==s)return!1;if(a===e){if($!=="")return!1}else if(a!=="all"&&$!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${u=>{ka.value=u.target.value}}>
          <option value="all">all</option>
          ${i.map(u=>o`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${u=>{xa.value=u.target.value}}>
          <option value="all">all</option>
          ${l?o`<option value=${e}>(none)</option>`:null}
          ${r.map(u=>o`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${u=>{Sa.value=u.target.value}}>
          <option value="all">all</option>
          ${m?o`<option value=${e}>(none)</option>`:null}
          ${d.map(u=>o`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{ka.value="all",xa.value="all",Sa.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${p.length} / 전체 ${t.length}
      </span>
    </div>
    <${Or} events=${p.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function N_({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function jr({state:t}){const e=t.history??[];return e.length===0?null:o`
    <div class="trpg-round-list">
      ${e.slice(-10).map(n=>o`
        <div class="trpg-round-item ${n.status}">
          <span>Session ${n.id.slice(0,8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${n.round} — ${n.status}
          </span>
        </div>
      `)}
    </div>
  `}function P_({state:t,nowMs:e}){var m;const n=zt.value||((m=t.session)==null?void 0:m.room)||"",s=Wn.value,a=t.party??[];if(!a.find(p=>p.id===xe.value)&&a.length>0){const p=a[0];p&&(xe.value=p.id)}const r=async()=>{var u,g;if(!n){N("Room ID가 비어 있습니다.","error");return}if(!rs(e))return;const p=((u=t.current_round)==null?void 0:u.phase)??((g=t.session)==null?void 0:g.status)??"unknown";if(uo("라운드 실행",n,p)){Wn.value="running";try{const $=await dc(n);lo.value=$,Wn.value="ok";const y=Qt($.summary)?$.summary:null,A=y?Tn(y,"advanced",!1):!1,C=y?mt(y,"progress_reason",""):"";N(A?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${C?`: ${C}`:""}`,A?"success":"warning"),Rt()}catch($){lo.value=null,Wn.value="error";const y=$ instanceof Error?$.message:"라운드 실행에 실패했습니다.";N(y,"error")}finally{Ms()}}},l=async()=>{var u,g;if(!n||!rs(e))return;const p=((u=t.current_round)==null?void 0:u.phase)??((g=t.session)==null?void 0:g.status)??"unknown";if(uo("턴 강제 진행",n,p))try{await mc(n),N("턴을 다음 단계로 이동했습니다.","success"),Rt()}catch{N("턴 이동에 실패했습니다.","error")}finally{Ms()}},d=async()=>{if(!n||!rs(e))return;const p=xe.value.trim();if(!p){N("먼저 Actor를 선택하세요.","warning");return}const u=Number.parseInt(da.value,10),g=Number.parseInt(ua.value,10);if(Number.isNaN(u)||Number.isNaN(g)){N("stat/dc는 숫자여야 합니다.","warning");return}const $=Number.parseInt(Bn.value,10),y=Bn.value.trim()===""||Number.isNaN($)?void 0:$;try{await pc({roomId:n,actorId:p,action:ca.value.trim()||"ability_check",statValue:u,dc:g,rawD20:y}),N("주사위 판정을 기록했습니다.","success"),Rt()}catch{N("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${p=>{zt.value=p.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${xe.value}
            onChange=${p=>{xe.value=p.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(p=>o`<option value=${p.id}>${p.name} (${p.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${ca.value}
              onInput=${p=>{ca.value=p.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${da.value}
              onInput=${p=>{da.value=p.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${ua.value}
              onInput=${p=>{ua.value=p.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Bn.value}
              onInput=${p=>{Bn.value=p.target.value}}
              onKeyDown=${p=>{p.key==="Enter"&&d()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${d}>Roll</button>
            <button
              class="trpg-run-btn recommend"
              onClick=${r}
              disabled=${s==="running"}
            >
              ${s==="running"?"실행 중...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${l}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${s!=="idle"?o`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function L_({state:t}){var a;const e=zt.value||((a=t.session)==null?void 0:a.room)||"",n=Vn.value,s=async()=>{if(!e){N("Room ID가 비어 있습니다.","warning");return}const i=Jn.value.trim(),r=_a.value.trim();if(!r&&!i){N("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt(rn.value.trim(),10),d=Number.parseInt(ya.value.trim(),10),m=Number.isFinite(d)?Math.max(1,d):20,p=Number.isFinite(l)?Math.max(0,Math.min(m,l)):m;let u={};try{u=y_(ba.value)}catch(g){N(g instanceof Error?g.message:"능력치 JSON 오류","error");return}Vn.value="spawning";try{const g=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,$=await vc(e,{actor_id:i||void 0,name:r||void 0,role:fa.value,idempotencyKey:g,portrait:$a.value.trim()||void 0,background:ha.value.trim()||void 0,hp:p,max_hp:m,alive:p>0,stats:Object.keys(u).length>0?u:void 0}),y=typeof $.actor_id=="string"?$.actor_id.trim():"";if(!y)throw new Error("생성 응답에 actor_id가 없습니다.");const A=ga.value.trim();A&&await _c(e,y,A),xe.value=y,Gt.value=y,i||(Jn.value=""),Vn.value="ok",N(`Actor 생성 완료: ${y}`,"success"),await Rt()}catch(g){Vn.value="error",N(g instanceof Error?g.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${_a.value}
            onInput=${i=>{_a.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${fa.value}
            onChange=${i=>{fa.value=i.target.value}}
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
            value=${ga.value}
            onInput=${i=>{ga.value=i.target.value}}
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
              value=${Jn.value}
              onInput=${i=>{Jn.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${$a.value}
              onInput=${i=>{$a.value=i.target.value}}
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
              value=${rn.value}
              onInput=${i=>{rn.value=i.target.value}}
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
              value=${ya.value}
              onInput=${i=>{const r=i.target.value;ya.value=r,b_(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${ha.value}
              onInput=${i=>{ha.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${ba.value}
              onInput=${i=>{ba.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function D_({state:t,nowMs:e}){var g;const n=zt.value||((g=t.session)==null?void 0:g.room)||"",s=t.join_gate,a=va.value,i=Qt(a)?a:null,r=(t.party??[]).filter($=>$.role!=="dm"),l=Gt.value.trim(),d=r.some($=>$.id===l),m=d?l:l?"__manual__":"",p=async()=>{const $=Gt.value.trim(),y=Gn.value.trim();if(!n||!$){N("Room/Actor가 필요합니다.","warning");return}gt.value="checking";try{const A=await fc(n,$,y||void 0);va.value=A,gt.value="ok",N("참가 가능 여부를 갱신했습니다.","success")}catch(A){gt.value="error";const C=A instanceof Error?A.message:"참가 가능 여부 확인에 실패했습니다.";N(C,"error")}},u=async()=>{var L,j;const $=Gt.value.trim(),y=Gn.value.trim(),A=ma.value.trim();if(!n||!$||!y){N("Room/Actor/Keeper가 필요합니다.","warning");return}if(!rs(e))return;const C=((L=t.current_round)==null?void 0:L.phase)??((j=t.session)==null?void 0:j.status)??"unknown";if(uo("Mid-Join 승인 요청",n,C)){gt.value="requesting";try{const D=await gc({room_id:n,actor_id:$,keeper_name:y,role:pa.value,...A?{name:A}:{}});va.value=D;const I=Qt(D)?Tn(D,"granted",!1):!1,R=Qt(D)?mt(D,"reason_code",""):"";I?N("Mid-Join이 승인되었습니다.","success"):N(`Mid-Join이 거절되었습니다${R?`: ${R}`:""}`,"warning"),gt.value=I?"ok":"error",Rt()}catch(D){gt.value="error";const I=D instanceof Error?D.message:"Mid-Join 요청에 실패했습니다.";N(I,"error")}finally{Ms()}}};return o`
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
            onChange=${$=>{const y=$.target.value;if(y==="__manual__"){(d||!l)&&(Gt.value="");return}Gt.value=y}}
          >
            <option value="">Actor 선택</option>
            ${r.map($=>o`
              <option value=${$.id}>${$.name} (${$.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${m==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${Gt.value}
                onInput=${$=>{Gt.value=$.target.value}}
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
            value=${Gn.value}
            onInput=${$=>{Gn.value=$.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${pa.value}
            onChange=${$=>{pa.value=$.target.value}}
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
            value=${ma.value}
            onInput=${$=>{ma.value=$.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${p} disabled=${gt.value==="checking"||gt.value==="requesting"}>
              ${gt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${u} disabled=${gt.value==="checking"||gt.value==="requesting"}>
              ${gt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Tn(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${wt(i,"effective_score",0)}/${wt(i,"required_points",0)}</span>
            ${mt(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${mt(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Fr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function qr({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Kr(){const t=lo.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=Qt(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(Qt).slice(-8),i=t.canon_check,r=Qt(i)?i:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(R=>typeof R=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(R=>typeof R=="string").slice(0,3):[],m=n?Tn(n,"advanced",!1):!1,p=n?mt(n,"progress_reason",""):"",u=n?mt(n,"progress_detail",""):"",g=n?wt(n,"player_successes",0):0,$=n?wt(n,"player_required_successes",0):0,y=n?Tn(n,"dm_success",!1):!1,A=n?wt(n,"timeouts",0):0,C=n?wt(n,"unavailable",0):0,L=n?wt(n,"reprompts",0):0,j=n?wt(n,"npc_attacks",0):0,D=n?wt(n,"keeper_timeout_sec",0):0,I=n?wt(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${m?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${m?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${y?"DM ok":"DM stalled"} / players ${g}/${$}
          </span>
        </div>
        ${p?o`<div style="margin-top:4px; font-size:12px;">${p}</div>`:null}
        ${u?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${u}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${L}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${j}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${D||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${I}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(R=>{const B=mt(R,"status","unknown"),H=mt(R,"actor_id","-"),f=mt(R,"role","-"),nt=mt(R,"reason",""),dt=mt(R,"action_type",""),W=mt(R,"reply","");return o`
                <div class="trpg-round-item ${B.includes("fallback")||B.includes("timeout")?"failed":"active"}">
                  <span>${H} (${f})</span>
                  <span style="margin-left:auto; font-size:11px;">${B}</span>
                  ${dt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${dt}</div>`:null}
                  ${nt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${nt}</div>`:null}
                  ${W?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${W.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${mt(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(R=>o`<div>violation: ${R}</div>`)}
                </div>`:null}
            ${l.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${l.map(R=>o`<div>warning: ${R}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function M_({state:t,nowMs:e}){var r,l,d;const n=zt.value||((r=t.session)==null?void 0:r.room)||"",s=((l=t.current_round)==null?void 0:l.phase)??((d=t.session)==null?void 0:d.status)??"unknown",a=Mr(e),i=S_(e);return o`
    <${T} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="trpg.control">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>A_(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Ms(),N("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function E_({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>x_(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function z_({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${T} title="관전 가이드" semanticId="trpg.overview">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${T} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${Or} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${T} title="맵" style="margin-top:16px;" semanticId="trpg.overview">
              <${I_} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${T} title="현재 라운드" semanticId="trpg.overview">
          <${qr} state=${t} />
        <//>

        <${T} title="기여도" style="margin-top:16px;" semanticId="trpg.overview">
          <${Fr} state=${t} />
        <//>

        <${T} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>o`<${zr} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${jr} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function O_({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${T} title=${`이벤트 타임라인 (${e.length})`}>
          <${R_} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${T} title="최근 라운드 결과" semanticId="trpg.timeline">
          <${Kr} />
        <//>

        <${T} title="현재 라운드" style="margin-top:16px;" semanticId="trpg.timeline">
          <${qr} state=${t} />
        <//>
      </div>
    </div>
  `}function j_({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${M_} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${T} title="조작 패널" semanticId="trpg.control">
            <${P_} state=${t} nowMs=${e} />
          <//>

          <${T} title="Actor Spawn" style="margin-top:16px;" semanticId="trpg.control">
            <${L_} state=${t} />
          <//>

          <${T} title="Mid-Join Gate" style="margin-top:16px;" semanticId="trpg.control">
            <${D_} state=${t} nowMs=${e} />
          <//>

          <${T} title="최근 라운드 결과" style="margin-top:16px;" semanticId="trpg.control">
            <${Kr} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${T} title="기여도" style="margin-top:0;" semanticId="trpg.control">
            <${Fr} state=${t} />
          <//>

          <${T} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${zr} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${jr} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function F_(){var l,d,m,p,u;const t=Ni.value,e=Fa.value;if(ot(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const g=window.setInterval(()=>{di.value=Date.now()},1e3);return()=>{window.clearInterval(g)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Rt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,i=Dr.value,r=di.value;return o`
    <div>
      <${ee} surfaceId="trpg" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${zt.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((m=t.session)==null?void 0:m.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Rt()}>새로고침</button>
      </div>

      <${N_} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((p=t.session)==null?void 0:p.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((u=t.current_round)==null?void 0:u.round_number)??0}</div>
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

      <${E_} active=${i} />

      ${i==="overview"?o`<${z_} state=${t} />`:i==="timeline"?o`<${O_} state=${t} />`:o`<${j_} state=${t} nowMs=${r} />`}
    </div>
  `}const ui=[{id:"observe",label:"먼저 보기",description:"지금 상태와 우선순위를 먼저 읽는 운영 랜딩"},{id:"coordinate",label:"보조 공간",description:"대화, 계획, 에이전트 상태를 보조 작업 공간으로 분리"},{id:"command",label:"통제",description:"개입과 지휘를 직접 실행하는 화면"}],po=[{id:"mission",label:"상황판",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"intervene",label:"개입",icon:"🎮",group:"command",description:"room, session, supervisor 액션을 실행하는 개입 화면"},{id:"command",label:"지휘",icon:"🧭",group:"command",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"agents",label:"에이전트",icon:"🤖",group:"observe",description:"agent 상태, 활동 신호, 작업 배정을 보는 모니터"},{id:"board",label:"보드",icon:"💬",group:"coordinate",description:"사람과 agent 대화를 시스템 노이즈를 줄여서 보는 피드"},{id:"goals",label:"계획",icon:"🎯",group:"coordinate",description:"goal, 메트릭 루프, backlog를 보는 계획 화면"},{id:"trpg",label:"TRPG 롤플레이",icon:"⚔️",group:"command",description:"서사 세션 제어와 게임 상태"}],In=v(!1);function pi(){In.value=!1}function q_(){In.value=!In.value}function K_(){const t=Ot.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Es.value} events</span>
    </div>
  `}function H_({currentTab:t,currentSectionLabel:e}){const n=Ot.value;return o`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>Snapshot</h3>
        <${z} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${n?"ok":"bad"}">${n?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agents</span>
          <strong>${Nt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keepers</span>
          <strong>${ge.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Tasks</span>
          <strong>${St.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Events</span>
          <strong>${Es.value}</strong>
        </div>
      </div>
      <div class="rail-snapshot-copy">
        <span>Connection ${n?"healthy":"recovering"}</span>
        <span>${e} workspace active</span>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{fe(),Fi(),t==="command"&&(ve(),Vt(),_t.value==="swarm"&&Mt()),(t==="mission"||t==="overview")&&Ua(),(t==="intervene"||t==="ops")&&(te(),Kt()),t==="board"&&It(),t==="trpg"&&Rt(),t==="goals"&&(mn(),Me())}}
        >
          Refresh Now
        </button>
        <button class="rail-secondary-btn" onClick=${()=>$t("intervene")}>
          Open Intervene
        </button>
      </div>
    </section>
  `}function U_(){const t=Ke.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return o`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${z} panelId="side_rail.quick_actions" compact=${!0} />
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
          onClick=${()=>{te(),Kt()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>$t("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function B_(){const t=M.value.tab,e=po.find(s=>s.id===t),n=ui.find(s=>s.id===(e==null?void 0:e.group));return o`
    <aside class="dashboard-rail">
      <${ee} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          <${z} panelId="side_rail.navigate" compact=${!0} />
          ${n?o`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${ui.map(s=>o`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${po.filter(a=>a.group===s.id).map(a=>o`
                  <button
                    class="rail-tab-btn ${t===a.id?"active":""}"
                    onClick=${()=>$t(a.id)}
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

      <${H_} currentTab=${t} currentSectionLabel=${(n==null?void 0:n.label)??"Observe"} />
      <${U_} />
    </aside>
  `}function W_(){switch(M.value.tab){case"mission":return o`<${ta} />`;case"intervene":return o`<${Yo} />`;case"command":return o`<${nm} />`;case"overview":return o`<${ta} />`;case"ops":return o`<${Yo} />`;case"board":return o`<${Zm} />`;case"agents":return o`<${e_} />`;case"goals":return o`<${u_} />`;case"trpg":return o`<${F_} />`;default:return o`<${ta} />`}}function G_(){ot(()=>{il(),yi(),fe(),Fi();const n=yd();return bd(),()=>{vl(),n(),kd()}},[]),ot(()=>{const n=setInterval(()=>{const s=M.value.tab;s==="command"?(ve(),Vt(),_t.value==="swarm"&&Mt()):s==="mission"||s==="overview"?Ua():s==="intervene"||s==="ops"?(te(),Kt()):s==="board"?It():s==="trpg"?Rt():s==="goals"&&(mn(),Me())},15e3);return()=>{clearInterval(n)}},[]),ot(()=>{const n=M.value.tab;n==="command"&&(ve(),Vt(),_t.value==="swarm"&&Mt()),(n==="mission"||n==="overview")&&Ua(),(n==="intervene"||n==="ops")&&(te(),Kt()),n==="board"&&It(),n==="trpg"&&Rt(),n==="goals"&&(mn(),Me())},[M.value.tab]);const t=M.value.tab,e=po.find(n=>n.id===t);return o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">${(e==null?void 0:e.description)??"Decision and execution operations console"}</p>
        </div>
        <div class="header-right">
          <button
            class="activity-panel-toggle ${In.value?"active":""}"
            onClick=${q_}
            title="Toggle Activity Panel"
          >
            Activity
          </button>
          <${K_} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${B_} />
        <main class="dashboard-main">
          ${ja.value&&!Ot.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${W_} />`}
        </main>
      </div>

      ${In.value?o`
        <div class="activity-panel-backdrop" onClick=${pi} />
        <aside class="activity-panel">
          <div class="activity-panel-header">
            <h3>Activity Feed</h3>
            <button class="activity-panel-close" onClick=${pi}>Close</button>
          </div>
          <div class="activity-panel-body">
            <${yv} />
          </div>
        </aside>
      `:null}

      <${jv} />
      <${Uv} />
      <${om} />
    </div>
  `}const mi=document.getElementById("app");mi&&tl(o`<${G_} />`,mi);export{Yd as _};
