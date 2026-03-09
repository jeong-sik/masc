var Yr=Object.defineProperty;var Qr=(t,e,n)=>e in t?Yr(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var _e=(t,e,n)=>Qr(t,typeof e!="symbol"?e+"":e,n);import{e as Xr,_ as Zr,c as m,b as $t,y as tt,A as gi,d as zs,G as tl}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var o=Xr.bind(Zr);const el=["mission","intervene","command","overview","board","goals","agents","ops","trpg"],$i={tab:"mission",params:{},postId:null},nl={overview:"mission",journal:"mission",mdal:"goals",tasks:"goals",execution:"mission",council:"board",activity:"mission",ops:"intervene"};function Lo(t){return!!t&&el.includes(t)}function xa(t){if(t)return nl[t]??t}function Bn(t){try{return decodeURIComponent(t)}catch{return t}}function Sa(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function sl(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function hi(t,e){if(t[0]==="chains"){const r={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(r.operation=Bn(t[2])),{tab:"command",params:r,postId:null}}const n=xa(t[0]),s=xa(e.tab),a=Lo(n)?n:Lo(s)?s:"mission";let i=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=Bn(t[2]):t[0]==="post"&&t[1]&&(i=Bn(t[1]))),{tab:a,params:e,postId:i}}function ss(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return $i;const n=Bn(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const l=n.indexOf("?");l>=0&&(s=n.slice(0,l),a=n.slice(l+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=Sa(a),r=sl(s);return hi(r,i)}function al(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...$i,params:Sa(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Sa(e.replace(/^\?/,""));return hi(s,a)}function yi(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const Z=m(ss(window.location.hash));window.addEventListener("hashchange",()=>{Z.value=ss(window.location.hash)});function nt(t,e){const s={tab:xa(t)??t,params:e??{},postId:null};window.location.hash=yi(s)}function ol(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function il(){if(window.location.hash&&window.location.hash!=="#"){Z.value=ss(window.location.hash);return}const t=al(window.location.pathname,window.location.search);if(t){Z.value=t;const e=yi(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",Z.value=ss(window.location.hash)}const Mo="masc_dashboard_sse_session_id",rl=1e3,ll=15e3,Et=m(!1),Os=m(0),bi=m(null),as=m([]);function cl(){let t=sessionStorage.getItem(Mo);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Mo,t)),t}const dl=200;function ul(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};as.value=[a,...as.value].slice(0,dl)}function Aa(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Do(t,e){const n=Aa(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function ht(t,e,n,s,a={}){ul(t,e,n,{eventType:s,...a})}let At=null,Se=null,Ca=0;function ki(){Se&&(clearTimeout(Se),Se=null)}function pl(){if(Se)return;Ca++;const t=Math.min(Ca,5),e=Math.min(ll,rl*Math.pow(2,t));Se=setTimeout(()=>{Se=null,xi()},e)}function xi(){ki(),At&&(At.close(),At=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",cl());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);At=i,i.onopen=()=>{At===i&&(Ca=0,Et.value=!0)},i.onerror=()=>{At===i&&(Et.value=!1,i.close(),At=null,pl())},i.onmessage=r=>{try{const l=JSON.parse(r.data);Os.value++,bi.value=l,ml(l)}catch{}}}function ml(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":ht(n,"Joined","system","agent_joined");break;case"agent_left":ht(n,"Left","system","agent_left");break;case"broadcast":ht(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":ht(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":ht(n,Do("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Aa(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":ht(n,Do("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Aa(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":ht(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":ht(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":ht(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":ht(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:ht(n,e,"system","unknown")}}function vl(){ki(),At&&(At.close(),At=null),Et.value=!1}function Si(){return new URLSearchParams(window.location.search)}function Ai(){const t=Si(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function Ci(){return{...Ai(),"Content-Type":"application/json"}}const _l=15e3,mo=3e4,fl=6e4,Io=new Set([408,425,429,500,502,503,504]);class Cn extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);_e(this,"method");_e(this,"path");_e(this,"status");_e(this,"statusText");_e(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function vo(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Cn({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function gl(){var e,n;const t=Si();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function Y(t){const e=await vo(t,{headers:Ai()},_l);if(!e.ok)throw new Cn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function $l(t){return new Promise(e=>setTimeout(e,t))}function hl(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function yl(t){if(t instanceof Cn)return t.timeout||typeof t.status=="number"&&Io.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=hl(t.message);return e!==null&&Io.has(e)}async function Me(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!yl(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${i}ms`,a),await $l(i),s+=1}}async function Rt(t,e,n,s=mo){const a=await vo(t,{method:"POST",headers:{...Ci(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Cn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function bl(t,e,n,s=mo){const a=await vo(t,{method:"POST",headers:{...Ci(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Cn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function kl(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function xl(t){var e,n,s,a,i,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((l=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function vt(t,e){const n=await bl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},fl),s=kl(n);return xl(s)}function Sl(t="compact"){return Y(`/api/v1/dashboard?mode=${t}`)}function Al(){return Y("/api/v1/dashboard/mission")}function Cl(){return Y("/api/v1/agents?limit=100")}function wl(t){const e=new URLSearchParams({limit:"200"});return e.set("include_done","true"),e.set("include_cancelled","true"),Y(`/api/v1/tasks?${e}`)}function Tl(t){const e=new URLSearchParams({limit:"50"});return t!=null&&t>0&&e.set("since_seq",String(t)),Y(`/api/v1/messages?${e}`)}function Nl(t={}){return Me("fetchMdalLoops",async()=>{const e=new URLSearchParams;t.limit!=null&&e.set("limit",String(t.limit)),t.historyLimit!=null&&e.set("history_limit",String(t.historyLimit)),t.status&&e.set("status",t.status);const n=e.toString();return Y(`/api/v1/mdal/loops${n?`?${n}`:""}`)})}function Rl(){return Y("/api/v1/operator")}function wi(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return Y(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Pl(){return Y("/api/v1/command-plane")}function Ll(){return Y("/api/v1/command-plane/summary")}function Ml(){return Y("/api/v1/chains/summary")}function Dl(t){return Y(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Il(){return Y("/api/v1/command-plane/help")}function El(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return Y(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function zl(t,e){return Rt(t,e)}function Ol(t){switch(t.action_type){case"keeper_msg":case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return mo}}function wn(t){return Rt("/api/v1/operator/action",t,void 0,Ol(t))}function jl(t,e){return Rt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const Fl=new Set(["lodge-system","team-session"]);function Te(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function ql(t){return Fl.has(t.trim().toLowerCase())}function Kl(t){return t.filter(e=>!ql(e.author))}function Hl(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Ti(t){if(!I(t))return null;const e=h(t.id,"").trim(),n=h(t.author,"").trim(),s=h(t.content,"").trim();if(!e||!n)return null;const a=O(t.score,0),i=O(t.votes_up,0),r=O(t.votes_down,0),l=O(t.votes,a||i-r),d=O(t.comment_count,O(t.reply_count,0)),_=(()=>{const y=t.flair;if(typeof y=="string"&&y.trim())return y.trim();if(I(y)){const N=h(y.name,"").trim();if(N)return N}return h(t.flair_name,"").trim()||void 0})(),p=h(t.created_at_iso,"").trim()||Te(t.created_at),f=h(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Te(t.updated_at):p),$=h(t.title,"").trim()||Hl(s);return{id:e,author:n,title:$,content:s,tags:[],votes:l,vote_balance:a,comment_count:d,created_at:p,updated_at:f,flair:_,hearth_count:O(t.hearth_count,0)}}function Ul(t){if(!I(t))return null;const e=h(t.id,"").trim(),n=h(t.post_id,"").trim(),s=h(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:h(t.content,""),created_at:Te(t.created_at)}}async function Bl(t,e){return Me("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const s=n.toString(),a=await Y(`/api/v1/board${s?`?${s}`:""}`),i=Array.isArray(a.posts)?a.posts.map(Ti).filter(l=>l!==null):[];return{posts:e!=null&&e.excludeSystem?Kl(i):i}})}async function Wl(t){return Me("fetchBoardPost",async()=>{const e=await Y(`/api/v1/board/${t}?format=flat`),n=I(e.post)?e.post:e,s=Ti(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(Ul).filter(r=>r!==null);return{...s,comments:i}})}function Ni(t,e){return Rt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:gl()})}function Gl(t,e,n){return Rt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Jl(t){const e=h(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function at(...t){for(const e of t){const n=h(e,"");if(n.trim())return n.trim()}return""}function Eo(t){const e=Jl(at(t.outcome,t.result,t.result_code));if(!e)return;const n=at(t.reason,t.reason_code,t.description,t.detail),s=at(t.summary,t.summary_ko,t.summary_en,t.note),a=at(t.details,t.details_text,t.text,t.note),i=at(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=at(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=at(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const f=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof f=="string"?[f]:Array.isArray(f)?f.map(g=>{if(typeof g=="string")return g.trim();if(I(g)){const $=h(g.summary,"").trim();if($)return $;const y=h(g.text,"").trim();if(y)return y;const A=h(g.type,"").trim();return A||h(g.event_id,"").trim()}return""}).filter(g=>g.length>0):[]})(),_=(()=>{const f=O(t.turn,Number.NaN);if(Number.isFinite(f))return f;const g=O(t.turn_number,Number.NaN);if(Number.isFinite(g))return g;const $=O(t.current_turn,Number.NaN);if(Number.isFinite($))return $;const y=O(t.round,Number.NaN);return Number.isFinite(y)?y:void 0})(),p=at(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:l||void 0,turn:_,phase:p||void 0}}function Vl(t,e){const n=I(t.state)?t.state:{};if(h(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>I(r)?h(r.type,"")==="session.outcome":!1),i=I(n.session_outcome)?n.session_outcome:{};if(I(i)&&Object.keys(i).length>0){const r=Eo(i);if(r)return r}if(I(a))return Eo(I(a.payload)?a.payload:{})}function I(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function O(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Yl(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function wa(t,e=!1){return typeof t=="boolean"?t:e}function Oe(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(I(e)){const n=h(e.name,"").trim(),s=h(e.id,"").trim(),a=h(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Ql(t){const e={};if(!I(t)&&!Array.isArray(t))return e;if(I(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=h(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!I(n))continue;const s=at(n.to,n.target,n.actor_id,n.name,n.id),a=at(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function Xl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function _t(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const Zl=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function tc(t){const e=I(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const i=s.trim();i&&(Zl.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function ec(t,e){if(t!=="dice.rolled")return;const n=O(e.raw_d20,0),s=O(e.total,0),a=O(e.bonus,0),i=h(e.action,"roll"),r=O(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function nc(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function sc(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function ac(t,e,n,s){const a=n||e||h(s.actor_id,"")||h(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=h(s.proposed_action,h(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=h(s.reply,h(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return h(s.reply,h(s.content,h(s.text,"Narration")));case"dice.rolled":{const i=h(s.action,"roll"),r=O(s.total,0),l=O(s.dc,0),d=h(s.label,""),_=a||"actor",p=l>0?` vs DC ${l}`:"",f=d?` (${d})`:"";return`${_} ${i}: ${r}${p}${f}`}case"turn.started":return`Turn ${O(s.turn,1)} started`;case"phase.changed":return`Phase: ${h(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(s.name,I(s.actor)?h(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${h(s.keeper_name,h(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${h(s.keeper_name,h(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${O(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${O(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||h(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||h(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${h(s.reason_code,"unknown")}`;case"memory.signal":{const i=I(s.entity_refs)?s.entity_refs:{},r=h(i.requested_tier,""),l=h(i.effective_tier,""),d=wa(i.guardrail_applied,!1),_=h(s.summary_en,h(s.summary_ko,"Memory signal"));if(!r&&!l)return _;const p=r&&l?`${r}->${l}`:l||r;return`${_} [${p}${d?" (guardrail)":""}]`}case"world.event":{if(h(s.event_type,"")==="canon.check"){const r=h(s.status,"unknown"),l=h(s.contract_id,"n/a");return`Canon ${r}: ${l}`}return h(s.description,h(s.summary,"World event"))}case"combat.attack":return h(s.summary,h(s.result,"Attack resolved"));case"combat.defense":return h(s.summary,h(s.result,"Defense resolved"));case"session.outcome":return h(s.summary,h(s.outcome,"Session ended"));default:{const i=nc(s);return i?`${t}: ${i}`:t}}}function oc(t,e){const n=I(t)?t:{},s=h(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=h(n.actor_name,"").trim()||e[a]||h(I(n.payload)?n.payload.actor_name:"",""),r=I(n.payload)?n.payload:{},l=h(n.ts,h(n.timestamp,new Date().toISOString())),d=h(n.phase,h(r.phase,"")),_=h(n.category,"");return{type:s,actor:i||a||h(r.actor_name,""),actor_id:a||h(r.actor_id,""),actor_name:i,seq:n.seq,room_id:h(n.room_id,""),phase:d||void 0,category:_||sc(s),visibility:h(n.visibility,h(r.visibility,"public")),event_id:h(n.event_id,""),content:ac(s,a,i,r),dice_roll:ec(s,r),timestamp:l}}function ic(t,e,n){var lt,ct;const s=h(t.room_id,"")||n||"default",a=I(t.state)?t.state:{},i=I(a.party)?a.party:{},r=I(a.actor_control)?a.actor_control:{},l=I(a.join_gate)?a.join_gate:{},d=I(a.contribution_ledger)?a.contribution_ledger:{},_=Object.entries(i).map(([H,X])=>{const b=I(X)?X:{},te=_t(b,"max_hp",void 0,10),ze=_t(b,"hp",void 0,te),Pn=_t(b,"max_mp",void 0,0),Ln=_t(b,"mp",void 0,0),D=_t(b,"level",void 0,1),ee=_t(b,"xp",void 0,0),Mn=wa(b.alive,ze>0),Ro=r[H],Po=typeof Ro=="string"?Ro:void 0,Hr=Xl(b.role,H,Po),Ur=Yl(b.generation),Br=at(b.joined_at,b.joinedAt,b.started_at,b.startedAt),Wr=at(b.claimed_at,b.claimedAt,b.assigned_at,b.assignedAt,b.assigned_time),Gr=at(b.last_seen,b.lastSeen,b.last_seen_at,b.lastSeenAt,b.last_active,b.lastActive),Jr=at(b.scene,b.current_scene,b.currentScene,b.world_scene,b.scene_name,b.sceneName),Vr=at(b.location,b.current_location,b.currentLocation,b.position,b.zone,b.area);return{id:H,name:h(b.name,H),role:Hr,keeper:Po,archetype:h(b.archetype,""),persona:h(b.persona,""),portrait:h(b.portrait,"")||void 0,background:h(b.background,"")||void 0,traits:Oe(b.traits),skills:Oe(b.skills),stats_raw:tc(b),status:Mn?"active":"dead",generation:Ur,joined_at:Br||void 0,claimed_at:Wr||void 0,last_seen:Gr||void 0,scene:Jr||void 0,location:Vr||void 0,inventory:Oe(b.inventory),notes:Oe(b.notes),relationships:Ql(b.relationships),stats:{hp:ze,max_hp:te,mp:Ln,max_mp:Pn,level:D,xp:ee,strength:_t(b,"strength","str",10),dexterity:_t(b,"dexterity","dex",10),constitution:_t(b,"constitution","con",10),intelligence:_t(b,"intelligence","int",10),wisdom:_t(b,"wisdom","wis",10),charisma:_t(b,"charisma","cha",10)}}}),p=_.filter(H=>H.status!=="dead"),f=Vl(t,e),g={phase_open:wa(l.phase_open,!0),min_points:O(l.min_points,3),window:h(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},$=Object.entries(d).map(([H,X])=>{const b=I(X)?X:{};return{actor_id:H,score:O(b.score,0),last_reason:h(b.last_reason,"")||null,reasons:Oe(b.reasons)}}),y=_.reduce((H,X)=>(H[X.id]=X.name,H),{}),A=e.map(H=>oc(H,y)),N=O(a.turn,1),M=h(a.phase,"round"),E=h(a.map,""),L=I(a.world)?a.world:{},R=E||h(L.ascii_map,h(L.map,"")),u=A.filter((H,X)=>{const b=e[X];if(!I(b))return!1;const te=I(b.payload)?b.payload:{};return O(te.turn,-1)===N}),q=(u.length>0?u:A).slice(-12),K=h(a.status,"active");return{session:{id:s,room:s,status:K==="ended"?"ended":K==="paused"?"paused":"active",round:N,actors:p,created_at:((lt=A[0])==null?void 0:lt.timestamp)??new Date().toISOString()},current_round:{round_number:N,phase:M,events:q,timestamp:((ct=A[A.length-1])==null?void 0:ct.timestamp)??new Date().toISOString()},map:R||void 0,join_gate:g,contribution_ledger:$,outcome:f,party:p,story_log:A,history:[]}}async function rc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await Y(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function lc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([Y(`/api/v1/trpg/state${e}`),rc(t)]);return ic(n,s,t)}function cc(t){return Rt("/api/v1/trpg/rounds/run",{room_id:t})}function dc(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function uc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Rt("/api/v1/trpg/dice/roll",e)}function pc(t,e){const n=dc();return Rt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function mc(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Rt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function vc(t,e,n){return Rt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function _c(t,e,n){const s=await vt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function fc(t){const e=await vt("trpg.mid_join.request",t);return JSON.parse(e)}async function Ri(t,e){await vt("masc_broadcast",{agent_name:t,message:e})}async function gc(t,e,n=1){await vt("masc_add_task",{title:t,description:e,priority:n})}async function $c(t){return vt("masc_join",{agent_name:t})}async function Pi(t){await vt("masc_leave",{agent_name:t})}async function hc(t){await vt("masc_heartbeat",{agent_name:t})}async function yc(t=40){return(await vt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function bc(t,e=20){return vt("masc_task_history",{task_id:t,limit:e})}async function kc(){return Me("fetchDebates",async()=>{const t=await Y("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!I(e))return null;const n=h(e.id,"").trim(),s=h(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,status:h(e.status,"open"),argument_count:O(e.argument_count,0),created_at:Te(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function xc(){return Me("fetchCouncilSessions",async()=>{const t=await Y("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!I(e))return null;const n=h(e.id,"").trim(),s=h(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,initiator:h(e.initiator,"system"),votes:O(e.votes,0),quorum:O(e.quorum,0),state:h(e.state,"open"),created_at:Te(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Sc(t){const e=await vt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Ac(t){return Me("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await Y(`/api/v1/council/debates/${e}/summary`);if(!I(n))return null;const s=h(n.id,"").trim();return s?{id:s,topic:h(n.topic,""),status:h(n.status,"open"),support_count:O(n.support_count,0),oppose_count:O(n.oppose_count,0),neutral_count:O(n.neutral_count,0),total_arguments:O(n.total_arguments,0),created_at:Te(n.created_at_iso??n.created_at),summary_text:h(n.summary_text,"")}:null})}function Cc(t,e,n){return vt("masc_keeper_msg",{name:t,message:e})}async function wc(){try{const t=await vt("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const Be=m(""),zt=m({}),ot=m({}),Ta=m({}),Na=m({}),Ra=m({}),Pa=m({}),Ot=m({});function st(t,e,n){t.value={...t.value,[e]:n}}function Ft(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function F(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function bt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function ye(t){return typeof t=="boolean"?t:void 0}function La(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function Ma(t){return Array.isArray(t)?t.map(e=>F(e)).filter(e=>!!e):[]}function Tc(t){var n;const e=(n=F(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Nc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Vs(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!Ft(s))continue;const a=F(s.name);if(!a)continue;const i=F(s[e]);e==="summary"?n.push({name:a,summary:i}):n.push({name:a,reason:i})}return n}function Rc(t){if(!Ft(t))return null;const e=F(t.name);return e?{name:e,trigger:F(t.trigger),outcome:F(t.outcome),summary:F(t.summary),reason:F(t.reason)}:null}function Pc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Lc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Li(t,e,n){return F(t)??Lc(e,n)}function Mi(t,e){return typeof t=="boolean"?t:e==="recover"}function os(t){if(!Ft(t))return null;const e=F(t.health_state),n=F(t.next_action_path),s=F(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:F(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:La(t.last_reply_at),last_reply_preview:F(t.last_reply_preview)??null,last_error:F(t.last_error)??null,next_eligible_at_s:bt(t.next_eligible_at_s)??null,recoverable:Mi(t.recoverable,n),summary:Li(t.summary,e,F(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function _o(t){return Ft(t)?{hour:bt(t.hour),checked:bt(t.checked)??0,acted:bt(t.acted)??0,acted_names:Ma(t.acted_names),activity_report:F(t.activity_report),quiet_hours_overridden:ye(t.quiet_hours_overridden),skipped_reason:F(t.skipped_reason),acted_rows:Vs(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:Vs(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:Vs(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Rc).filter(e=>e!==null):[]}:null}function Mc(t){return Ft(t)?{enabled:ye(t.enabled)??!1,interval_s:bt(t.interval_s)??0,quiet_start:bt(t.quiet_start),quiet_end:bt(t.quiet_end),quiet_active:ye(t.quiet_active),use_planner:ye(t.use_planner),delegate_llm:ye(t.delegate_llm),agent_count:bt(t.agent_count),agents:Ma(t.agents),last_tick_ago_s:bt(t.last_tick_ago_s)??null,last_tick_ago:F(t.last_tick_ago),total_ticks:bt(t.total_ticks),total_checkins:bt(t.total_checkins),last_skip_reason:F(t.last_skip_reason)??null,last_tick_result:_o(t.last_tick_result),active_self_heartbeats:Ma(t.active_self_heartbeats)}:null}function Dc(t){return Ft(t)?{status:t.status,diagnostic:os(t.diagnostic)}:null}function Ic(t){return Ft(t)?{recovered:ye(t.recovered)??!1,skipped_reason:F(t.skipped_reason)??null,before:os(t.before),after:os(t.after),down:t.down,up:t.up}:null}function Ec(t,e){var E,L;if(!(t!=null&&t.name))return null;const n=F((E=t.agent)==null?void 0:E.status)??F(t.status)??"unknown",s=F((L=t.agent)==null?void 0:L.error)??null,a=t.presence_keepalive??!0,i=t.keepalive_running??!1,r=t.turn_count??0,l=t.last_turn_ago_s??null,d=t.proactive_enabled??!1,_=t.proactive_cooldown_sec??0,p=t.last_proactive_ago_s??null,f=d&&p!=null?Math.max(0,_-p):null,g=r<=0||l==null?"never":l>900?"stale":"fresh",$=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,y=s??(a&&!i?"keeper keepalive is not running":null),A=n==="offline"||n==="inactive"?"offline":y?"degraded":g==="stale"?"stale":g==="never"?"idle":"healthy",N=y?Pc(y):e!=null&&e.quiet_active&&g!=="fresh"?"quiet_hours":a&&!i?"disabled":r<=0?"never_started":f!=null&&f>0?"min_gap":g==="fresh"||g==="stale"?"no_recent_activity":"unknown",M=A==="offline"||A==="degraded"||A==="stale"?"recover":N==="quiet_hours"?"manual_lodge_poke":N==="unknown"?"probe":"direct_message";return{health_state:A,quiet_reason:N,next_action_path:M,last_reply_status:g,last_reply_at:$,last_reply_preview:null,last_error:y,next_eligible_at_s:f!=null&&f>0?f:null,recoverable:Mi(void 0,M),summary:Li(void 0,A,N),keepalive_running:i}}function zc(t,e){if(!Ft(t))return null;const n=Tc(t.role),s=F(t.content)??F(t.preview);if(!s)return null;const a=La(t.ts_unix)??La(t.timestamp);return{id:`${n}-${a??"entry"}-${e}`,role:n,label:Nc(n),text:s,timestamp:a,delivery:"history"}}function Oc(t,e,n){const s=Ft(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((i,r)=>zc(i,r)).filter(i=>i!==null):[];return{name:t,diagnostic:os(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function zo(t,e){const n=ot.value[t]??[];ot.value={...ot.value,[t]:[...n,e].slice(-50)}}function jc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Fc(t,e){const s=(ot.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(i=>jc(a,i)));ot.value={...ot.value,[t]:[...e,...s].slice(-50)}}function js(t,e){zt.value={...zt.value,[t]:e},Fc(t,e.history)}function Oo(t,e){const n=zt.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};js(t,{...n,diagnostic:{...s,...e}})}async function fo(){Ne();try{await Jt()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Wn(t){Be.value=t.trim()}async function Di(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&zt.value[n])return zt.value[n];st(Ta,n,!0),st(Ot,n,null);try{const s=await vt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const i=Oc(n,s,a);return js(n,i),i}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return st(Ot,n,a),null}finally{st(Ta,n,!1)}}async function qc(t,e){const n=t.trim(),s=e.trim();if(!n||!s)return;const a=`local-${Date.now()}`;zo(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),st(Na,n,!0),st(Ot,n,null);try{const i=await Cc(n,s);ot.value={...ot.value,[n]:(ot.value[n]??[]).map(r=>r.id===a?{...r,delivery:"delivered"}:r)},zo(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Oo(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await fo()}catch(i){const r=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw ot.value={...ot.value,[n]:(ot.value[n]??[]).map(l=>l.id===a?{...l,delivery:"error",error:r}:l)},Oo(n,{last_reply_status:"error",last_error:r}),st(Ot,n,r),i}finally{st(Na,n,!1)}}async function Kc(t,e){const n=t.trim();if(!n)return null;st(Ra,n,!0),st(Ot,n,null);try{const s=await wn({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=Dc(s.result),i=(a==null?void 0:a.diagnostic)??null;if(i){const r=zt.value[n];js(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??ot.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await fo(),i}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw st(Ot,n,a),s}finally{st(Ra,n,!1)}}async function Hc(t,e){const n=t.trim();if(!n)return null;st(Pa,n,!0),st(Ot,n,null);try{const s=await wn({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Ic(s.result),i=(a==null?void 0:a.after)??null;if(i){const r=zt.value[n];js(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??ot.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await fo(),i}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw st(Ot,n,a),s}finally{st(Pa,n,!1)}}function ne(t){return(t??"").trim().toLowerCase()}function dt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Gn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Dn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function je(t){return t.last_heartbeat??Dn(t.last_turn_ago_s)??Dn(t.last_proactive_ago_s)??Dn(t.last_handoff_ago_s)??Dn(t.last_compaction_ago_s)}function Uc(t){const e=t.title.trim();return e||Gn(t.content)}function Bc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Wc(t,e,n,s,a={}){var L;const i=ne(t),r=e.filter(R=>ne(R.assignee)===i&&(R.status==="claimed"||R.status==="in_progress")).length,l=n.filter(R=>ne(R.from)===i).sort((R,u)=>dt(u.timestamp)-dt(R.timestamp))[0],d=s.filter(R=>ne(R.agent)===i||ne(R.author)===i).sort((R,u)=>dt(u.timestamp)-dt(R.timestamp))[0],_=(a.boardPosts??[]).filter(R=>ne(R.author)===i).sort((R,u)=>dt(u.updated_at||u.created_at)-dt(R.updated_at||R.created_at))[0],p=(a.keepers??[]).filter(R=>ne(R.name)===i&&je(R)!==null).sort((R,u)=>dt(je(u)??0)-dt(je(R)??0))[0],f=l?dt(l.timestamp):0,g=d?dt(d.timestamp):0,$=_?dt(_.updated_at||_.created_at):0,y=p?dt(je(p)??0):0,A=a.lastSeen?dt(a.lastSeen):0,N=((L=a.currentTask)==null?void 0:L.trim())||(r>0?`${r} claimed tasks`:null);if(f===0&&g===0&&$===0&&y===0&&A===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:N};const E=[l?{timestamp:l.timestamp,ts:f,text:Gn(l.content)}:null,_?{timestamp:_.updated_at||_.created_at,ts:$,text:`Post: ${Gn(Uc(_))}`}:null,p?{timestamp:je(p),ts:y,text:Bc(p)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:g,text:Gn(d.text)}:null].filter(R=>R!==null).sort((R,u)=>u.ts-R.ts)[0];return E&&E.ts>=A?{activeAssignedCount:r,lastActivityAt:E.timestamp,lastActivityText:E.text}:{activeAssignedCount:r,lastActivityAt:a.lastSeen??null,lastActivityText:N??"Presence heartbeat"}}const Nt=m([]),kt=m([]),cn=m([]),Qt=m([]),me=m(null),Gc=m(null),Da=m(new Map),De=m([]),dn=m("hot"),oe=m(!0),Ii=m(null),It=m(""),un=m([]),be=m(!1),Ei=m(new Map),Ia=m("unknown"),Ea=m(null),za=m(!1),pn=m(!1),Oa=m(!1),ke=m(!1),Jc=m(null),ja=m(null),zi=m(null),Oi=m(null);$t(()=>Nt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const Vc=$t(()=>{const t=kt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),ji=$t(()=>{const t=new Map,e=kt.value,n=cn.value,s=as.value,a=De.value,i=Qt.value;for(const r of Nt.value)t.set(r.name.trim().toLowerCase(),Wc(r.name,e,n,s,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:a,keepers:i}));return t});function Yc(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const Qc=$t(()=>{const t=new Map;for(const e of Qt.value)t.set(e.name,Yc(e));return t}),Xc=12e4;function Zc(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof a=="number"?Date.now()-a*1e3:null}const td=$t(()=>{const t=Date.now(),e=new Set,n=Da.value;for(const s of Qt.value){const a=Zc(s,n);a!=null&&t-a>Xc&&e.add(s.name)}return e}),is={},ed=5e3;let Ys=null;function nd(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function Ne(){delete is.compact,delete is.full}function it(t){return typeof t=="object"&&t!==null}function x(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function C(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function ce(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Fa(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Fi(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function sd(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function qi(t){if(!it(t))return null;const e=x(t.name);return e?{name:e,status:Fi(t.status),current_task:x(t.current_task)??null,last_seen:x(t.last_seen),emoji:x(t.emoji),koreanName:x(t.koreanName)??x(t.korean_name),model:x(t.model),traits:ce(t.traits),interests:ce(t.interests),activityLevel:C(t.activityLevel)??C(t.activity_level),primaryValue:x(t.primaryValue)??x(t.primary_value)}:null}function Ki(t){if(!it(t))return null;const e=x(t.id),n=x(t.title);return!e||!n?null:{id:e,title:n,status:sd(t.status),priority:C(t.priority),assignee:x(t.assignee),description:x(t.description),created_at:x(t.created_at),updated_at:x(t.updated_at)}}function Hi(t){if(!it(t))return null;const e=x(t.from)??x(t.from_agent)??"system",n=x(t.content)??"",s=x(t.timestamp)??new Date().toISOString();return{id:x(t.id),seq:C(t.seq),from:e,content:n,timestamp:s,type:x(t.type)}}function ad(t){return Array.isArray(t)?t.map(e=>{if(!it(e))return null;const n=C(e.ts_unix);if(n==null)return null;const s=it(e.handoff)?e.handoff:null;return{ts:n,context_ratio:C(e.context_ratio)??0,context_tokens:C(e.context_tokens)??0,context_max:C(e.context_max)??0,latency_ms:C(e.latency_ms)??0,generation:C(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:C(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:C(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?C(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function jo(t){if(!it(t))return null;const e=x(t.health_state),n=x(t.next_action_path),s=x(t.last_reply_status);if(!e||!n||!s)return null;const a=x(t.quiet_reason)??null,i=x(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:Fa(t.last_reply_at)??x(t.last_reply_at)??null,last_reply_preview:x(t.last_reply_preview)??null,last_error:x(t.last_error)??null,next_eligible_at_s:C(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:i,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function od(t,e){return(Array.isArray(t)?t:it(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!it(s))return null;const a=it(s.agent)?s.agent:null,i=it(s.context)?s.context:null,r=it(s.metrics_window)?s.metrics_window:void 0,l=x(s.name);if(!l)return null;const d=C(s.context_ratio)??C(i==null?void 0:i.context_ratio),_=x(s.status)??x(a==null?void 0:a.status)??"offline",p=Fi(_),f=x(s.model)??x(s.active_model)??x(s.primary_model),g=ce(s.skill_secondary),$=i?{source:x(i.source),context_ratio:C(i.context_ratio),context_tokens:C(i.context_tokens),context_max:C(i.context_max),message_count:C(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,y=a?{name:x(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:x(a.error),status:x(a.status),current_task:x(a.current_task)??null,last_seen:x(a.last_seen),last_seen_ago_s:C(a.last_seen_ago_s),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,A=ad(s.metrics_series),N={name:l,emoji:x(s.emoji),koreanName:x(s.koreanName)??x(s.korean_name),agent_name:x(s.agent_name),trace_id:x(s.trace_id),model:f,primary_model:x(s.primary_model),active_model:x(s.active_model),next_model_hint:x(s.next_model_hint)??null,status:p,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:C(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:C(s.proactive_idle_sec),proactive_cooldown_sec:C(s.proactive_cooldown_sec),last_heartbeat:x(s.last_heartbeat)??x(a==null?void 0:a.last_seen),generation:C(s.generation),turn_count:C(s.turn_count)??C(s.total_turns),keeper_age_s:C(s.keeper_age_s),last_turn_ago_s:C(s.last_turn_ago_s),last_handoff_ago_s:C(s.last_handoff_ago_s),last_compaction_ago_s:C(s.last_compaction_ago_s),last_proactive_ago_s:C(s.last_proactive_ago_s),context_ratio:d,context_tokens:C(s.context_tokens)??C(i==null?void 0:i.context_tokens),context_max:C(s.context_max)??C(i==null?void 0:i.context_max),context_source:x(s.context_source)??x(i==null?void 0:i.source),context:$,traits:ce(s.traits),interests:ce(s.interests),primaryValue:x(s.primaryValue)??x(s.primary_value),activityLevel:C(s.activityLevel)??C(s.activity_level),memory_recent_note:x(s.memory_recent_note)??null,conversation_tail_count:C(s.conversation_tail_count),k2k_count:C(s.k2k_count),handoff_count_total:C(s.handoff_count_total)??C(s.trace_history_count),compaction_count:C(s.compaction_count),last_compaction_saved_tokens:C(s.last_compaction_saved_tokens),diagnostic:jo(s.diagnostic),skill_primary:x(s.skill_primary)??null,skill_secondary:g,skill_reason:x(s.skill_reason)??null,metrics_series:A.length>0?A:void 0,metrics_window:r,agent:y};return N.diagnostic=jo(s.diagnostic)??Ec(N,(e==null?void 0:e.lodge)??null),N}).filter(s=>s!==null)}function id(t){return it(t)?{...t,lodge:Mc(t.lodge)??void 0}:null}function rd(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function ld(t){if(!it(t))return null;const e=C(t.iteration);if(e==null)return null;const n=C(t.metric_before)??0,s=C(t.metric_after)??n,a=it(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:C(t.delta)??s-n,changes:x(t.changes)??"",failed_attempts:x(t.failed_attempts)??"",next_suggestion:x(t.next_suggestion)??"",elapsed_ms:C(t.elapsed_ms)??0,cost_usd:C(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:x(a.worker_model)??"",tool_call_count:C(a.tool_call_count)??0,tool_names:ce(a.tool_names)??[],session_id:x(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function cd(t){var i,r;if(!it(t))return null;const e=x(t.loop_id);if(!e)return null;const n=C(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(ld).filter(l=>l!==null):[],a=C(t.current_metric)??((i=s[0])==null?void 0:i.metric_after)??n;return{loop_id:e,profile:x(t.profile)??"unknown",status:rd(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:x(t.error_message)??x(t.error_reason)??null,stop_reason:x(t.stop_reason)??x(t.reason)??null,current_iteration:C(t.current_iteration)??((r=s[0])==null?void 0:r.iteration)??0,max_iterations:C(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:x(t.target)??"",stagnation_streak:C(t.stagnation_streak)??0,stagnation_limit:C(t.stagnation_limit)??0,elapsed_seconds:C(t.elapsed_seconds)??0,updated_at:Fa(t.updated_at)??null,stopped_at:Fa(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:x(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:C(t.latest_tool_call_count)??0,latest_tool_names:ce(t.latest_tool_names)??[],session_id:x(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function Jt(t="full"){var s,a,i;const e=Date.now(),n=is[t];if(!(n&&e-n.time<ed)){za.value=!0;try{const r=await Sl(t);is[t]={data:r,time:e},Nt.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map(qi).filter(d=>d!==null),kt.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map(Ki).filter(d=>d!==null),cn.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(Hi).filter(d=>d!==null);const l=id(r.status);me.value=l,Qt.value=od(r.keepers,l),Gc.value=r.perpetual??null,Jc.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{za.value=!1}}}async function dd(){try{const t=await Cl(),e=(Array.isArray(t.agents)?t.agents:[]).map(qi).filter(a=>a!==null),n=Nt.value,s=new Map(n.map(a=>[a.name,a]));Nt.value=e.map(a=>{const i=s.get(a.name);return i?{...i,status:a.status,current_task:a.current_task}:a})}catch(t){console.error("Agents selective fetch error:",t)}}async function ud(){try{const t=await wl({includeDone:!0,includeCancelled:!0}),e=(Array.isArray(t.tasks)?t.tasks:[]).map(Ki).filter(a=>a!==null),n=kt.value,s=new Map(n.map(a=>[a.id,a]));kt.value=e.map(a=>{const i=s.get(a.id);return i?{...i,status:a.status,priority:a.priority??i.priority,assignee:a.assignee??i.assignee}:a})}catch(t){console.error("Tasks selective fetch error:",t)}}async function pd(){try{const t=cn.value,e=t.reduce((l,d)=>Math.max(l,d.seq??0),0),n=await Tl(e),s=(Array.isArray(n.messages)?n.messages:[]).map(Hi).filter(l=>l!==null);if(s.length===0)return;const a=new Set(t.map(l=>l.seq).filter(l=>l!=null)),i=new Set(t.filter(l=>l.seq==null).map(l=>`${l.timestamp}|${l.from}`)),r=s.filter(l=>{if(l.seq!=null)return!a.has(l.seq);const d=`${l.timestamp}|${l.from}`;return i.has(d)?!1:(i.add(d),!0)});if(r.length>0){const l=[...t,...r];cn.value=l.length>500?l.slice(-500):l}}catch(t){console.error("Messages selective fetch error:",t)}}async function wt(){pn.value=!0;try{const t=await Bl(dn.value,{excludeSystem:oe.value});De.value=t.posts??[],ja.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{pn.value=!1}}async function Tt(){var t;Oa.value=!0;try{const e=It.value||((t=me.value)==null?void 0:t.room)||"default";It.value||(It.value=e);const n=await lc(e);Ii.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Oa.value=!1}}async function mn(){be.value=!0;try{const t=await wc();un.value=Array.isArray(t)?t:[],zi.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{be.value=!1}}async function Re(){ke.value=!0;try{const t=await Nl(),e=Array.isArray(t.loops)?t.loops:[],n=new Map;for(const s of e){const a=cd(s);a&&n.set(a.loop_id,a)}Ei.value=n,Oi.value=new Date().toISOString(),Ea.value=null,Ia.value=n.size===0?"idle":"ready"}catch(t){console.error("MDAL fetch error:",t),Ia.value="error",Ea.value=t instanceof Error?t.message:String(t)}finally{ke.value=!1}}let Jn=null;function md(t){Jn=t}let Vn=null;function vd(t){Vn=t}let Yn=null;function _d(t){Yn=t}const ie={};function se(t,e,n=500){ie[t]&&clearTimeout(ie[t]),ie[t]=setTimeout(()=>{e(),delete ie[t]},n)}function fd(){const t=bi.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Da.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Da.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&se("agents",dd),nd(e.type)&&(Ne(),Ys||(Ys=setTimeout(()=>{Jt(),Vn==null||Vn(),Yn==null||Yn(),Ys=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&se("tasks",ud),e.type==="broadcast"&&se("messages",pd),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&se("dashboard",()=>{Ne(),Jt()}),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&se("board",wt),e.type.startsWith("decision_")&&se("council",()=>Jn==null?void 0:Jn()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&se("mdal",Re,350)}});return()=>{t();for(const e of Object.keys(ie))clearTimeout(ie[e]),delete ie[e]}}let We=null;function gd(){We||(We=setInterval(()=>{Et.value||Ne(),Jt()},1e4))}function $d(){We&&(clearInterval(We),We=null)}function T({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}const Ui=m(null),qa=m(!1),rs=m(null);function G(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function P(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function B(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function go(t){return typeof t=="boolean"?t:void 0}function Mt(t,e=[]){if(Array.isArray(t))return t;if(!G(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Fs(t){if(!G(t))return null;const e=P(t.kind),n=P(t.summary),s=P(t.target_type);return!e||!n||!s?null:{kind:e,severity:P(t.severity)??"warn",summary:n,target_type:s,target_id:P(t.target_id)??null,actor:P(t.actor)??null,evidence:t.evidence}}function qs(t){if(!G(t))return null;const e=P(t.action_type),n=P(t.target_type),s=P(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:P(t.target_id)??null,severity:P(t.severity)??"warn",reason:s,confirm_required:go(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function hd(t){if(!G(t))return null;const e=P(t.session_id);return e?{session_id:e,goal:P(t.goal),status:P(t.status),health:P(t.health),scale_profile:P(t.scale_profile),control_profile:P(t.control_profile),planned_worker_count:B(t.planned_worker_count),active_agent_count:B(t.active_agent_count),last_turn_age_sec:B(t.last_turn_age_sec)??null,attention_count:B(t.attention_count),recommended_action_count:B(t.recommended_action_count),top_attention:Fs(t.top_attention),top_recommendation:qs(t.top_recommendation)}:null}function yd(t){if(!G(t))return null;const e=P(t.session_id);return e?{session_id:e,status:P(t.status),progress_pct:B(t.progress_pct),elapsed_sec:B(t.elapsed_sec),remaining_sec:B(t.remaining_sec),done_delta_total:B(t.done_delta_total),summary:G(t.summary)?t.summary:void 0,team_health:G(t.team_health)?t.team_health:void 0,communication_metrics:G(t.communication_metrics)?t.communication_metrics:void 0,orchestration_state:G(t.orchestration_state)?t.orchestration_state:void 0,cascade_metrics:G(t.cascade_metrics)?t.cascade_metrics:void 0,report_paths:G(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([n,s])=>{const a=P(s);return a?[n,a]:null}).filter(n=>n!==null)):void 0,session:G(t.session)?t.session:void 0,recent_events:Mt(t.recent_events,["events"]).filter(G)}:null}function bd(t){if(!G(t))return null;const e=P(t.name);return e?{name:e,agent_name:P(t.agent_name),status:P(t.status),autonomy_level:P(t.autonomy_level),context_ratio:B(t.context_ratio),generation:B(t.generation),active_goal_ids:Mt(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:P(t.last_autonomous_action_at)??null,last_turn_ago_s:B(t.last_turn_ago_s),model:P(t.model)}:null}function kd(t){if(!G(t))return null;const e=P(t.confirm_token)??P(t.token);return e?{confirm_token:e,actor:P(t.actor),action_type:P(t.action_type),target_type:P(t.target_type),target_id:P(t.target_id)??null,delegated_tool:P(t.delegated_tool),created_at:P(t.created_at),preview:t.preview}:null}function xd(t){if(!G(t))return null;const e=P(t.action_type),n=P(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:P(t.description),confirm_required:go(t.confirm_required)}}function Sd(t){const e=G(t)?t:{};return{room_health:P(e.room_health),cluster:P(e.cluster),project:P(e.project),current_room:P(e.current_room)??null,paused:go(e.paused),tempo_interval_s:B(e.tempo_interval_s),active_agents:B(e.active_agents),keeper_pressure:B(e.keeper_pressure),active_operations:B(e.active_operations),pending_approvals:B(e.pending_approvals),incident_count:B(e.incident_count),recommended_action_count:B(e.recommended_action_count),top_attention:Fs(e.top_attention),top_action:qs(e.top_action)}}function Ad(t){const e=G(t)?t:{},n=G(e.swarm_overview)?e.swarm_overview:{};return{health:P(e.health),active_operations:B(e.active_operations),pending_approvals:B(e.pending_approvals),swarm_overview:{active_lanes:B(n.active_lanes),moving_lanes:B(n.moving_lanes),stalled_lanes:B(n.stalled_lanes),projected_lanes:B(n.projected_lanes),last_movement_at:P(n.last_movement_at)??null},top_attention:Fs(e.top_attention),top_action:qs(e.top_action),session_cards:Mt(e.session_cards).map(hd).filter(s=>s!==null)}}function Cd(t){const e=G(t)?t:{};return{sessions:Mt(e.sessions,["items"]).map(yd).filter(n=>n!==null),keepers:Mt(e.keepers,["items"]).map(bd).filter(n=>n!==null),pending_confirms:Mt(e.pending_confirms).map(kd).filter(n=>n!==null),available_actions:Mt(e.available_actions).map(xd).filter(n=>n!==null)}}function wd(t){const e=G(t)?t:{};return{generated_at:P(e.generated_at),summary:Sd(e.summary),incidents:Mt(e.incidents).map(Fs).filter(n=>n!==null),recommended_actions:Mt(e.recommended_actions).map(qs).filter(n=>n!==null),command_focus:Ad(e.command_focus),operator_targets:Cd(e.operator_targets)}}async function Ka(){qa.value=!0,rs.value=null;try{const t=await Al();Ui.value=wd(t)}catch(t){rs.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{qa.value=!1}}function pt(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}function Fo(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:`${Math.round(n/3600)}h 전`}function Bi(t){return t?t.target_type==="room"||t.target_type==="team_session"||t.target_type==="keeper"?()=>nt("intervene"):()=>nt("command"):()=>nt("intervene")}function fe({label:t,value:e,detail:n,tone:s}){return o`
    <article class="mission-stat-card ${pt(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function Td({item:t}){return o`
    <article class="mission-incident-card ${pt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${pt(t.severity)}">${t.severity}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <strong>${t.summary}</strong>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>nt("intervene")}>개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>nt("command")}>지휘면 보기</button>
      </div>
    </article>
  `}function Nd({action:t}){return o`
    <article class="mission-action-card ${pt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${pt(t.severity)}">${t.action_type}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.reason}</p>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${Bi(t)}>개입 워크스페이스</button>
      </div>
    </article>
  `}function Rd({session:t}){return o`
    <article class="mission-session-card ${pt(t.health)}">
      <div class="mission-card-head">
        <strong>${t.goal??t.session_id}</strong>
        <span class="command-chip ${pt(t.health)}">${t.health??"ok"}</span>
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
  `}function Qs(){var r,l,d;const t=Ui.value;if(qa.value&&!t)return o`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(rs.value&&!t)return o`<div class="empty-state error">${rs.value}</div>`;if(!t)return o`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;const e=t.summary,n=t.incidents[0]??e.top_attention??null,s=t.recommended_actions[0]??e.top_action??null,a=t.command_focus.session_cards.slice(0,3),i=t.operator_targets.keepers.slice(0,4);return o`
    <section class="dashboard-panel mission-view">
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 문제, 다음 액션, 운영 포커스를 한 번에 보는 운영 랜딩입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${pt(e.room_health)}">${e.room_health??"ok"}</span>
          <span class="command-chip">${e.project??"room"}${e.current_room?` · ${e.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?Fo(t.generated_at):"fresh"}</span>
        </div>
      </div>

      <div class="mission-stat-grid">
        <${fe} label="활성 에이전트" value=${e.active_agents??0} detail="실시간 응답 가능한 agent 수" tone=${e.active_agents&&e.active_agents>0?"ok":"warn"} />
        <${fe} label="Keeper 압력" value=${e.keeper_pressure??0} detail="stale / hot keeper 수" tone=${(e.keeper_pressure??0)>0?"warn":"ok"} />
        <${fe} label="활성 작전" value=${e.active_operations??0} detail="command plane active operation" tone=${(e.active_operations??0)>0?"ok":"warn"} />
        <${fe} label="승인 대기" value=${e.pending_approvals??0} detail="사람 확인이 필요한 decision" tone=${(e.pending_approvals??0)>0?"warn":"ok"} />
        <${fe} label="우선 Incident" value=${e.incident_count??t.incidents.length} detail="지금 우선순위로 볼 attention item" tone=${(n==null?void 0:n.severity)??"ok"} />
        <${fe} label="다음 액션" value=${e.recommended_action_count??t.recommended_actions.length} detail="digest 기준 추천 액션 수" tone=${(s==null?void 0:s.severity)??"ok"} />
      </div>

      <div class="mission-primary-grid">
        <${T} title="지금 가장 먼저 볼 것" class="mission-hero-card">
          ${n?o`
                <div class="mission-priority-block ${pt(n.severity)}">
                  <div class="mission-card-head">
                    <span class="command-chip ${pt(n.severity)}">${n.kind}</span>
                    <span class="mission-card-target">${n.target_type}${n.target_id?` · ${n.target_id}`:""}</span>
                  </div>
                  <strong>${n.summary}</strong>
                </div>
              `:o`<div class="empty-state">우선 incident가 없습니다.</div>`}
          ${s?o`
                <div class="mission-action-highlight">
                  <div class="mission-card-head">
                    <span class="command-chip ${pt(s.severity)}">${s.action_type}</span>
                    <span class="mission-card-target">${s.target_type}${s.target_id?` · ${s.target_id}`:""}</span>
                  </div>
                  <p>${s.reason}</p>
                  <div class="mission-card-actions">
                    <button class="control-btn ghost" onClick=${Bi(s)}>개입하러 가기</button>
                    <button class="control-btn ghost" onClick=${()=>nt("command",{surface:"swarm"})}>지휘면 상세</button>
                  </div>
                </div>
              `:null}
        <//>

        <${T} title="운영 포커스" class="mission-focus-card">
          <div class="mission-focus-grid">
            <div class="mission-focus-item">
              <span>지휘 건강도</span>
              <strong class=${pt(t.command_focus.health)}>${t.command_focus.health??"ok"}</strong>
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
              <strong>${Fo((d=t.command_focus.swarm_overview)==null?void 0:d.last_movement_at)}</strong>
            </div>
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>nt("command")}>지휘면 열기</button>
            <button class="control-btn ghost" onClick=${()=>nt("command",{surface:"swarm"})}>스웜 상세</button>
          </div>
        <//>
      </div>

      <div class="mission-content-grid">
        <${T} title="우선 Incident" class="mission-list-card">
          <div class="mission-list-stack">
            ${t.incidents.length>0?t.incidents.slice(0,5).map(_=>o`<${Td} item=${_} />`):o`<div class="empty-state">attention item이 없습니다.</div>`}
          </div>
        <//>

        <${T} title="추천 액션" class="mission-list-card">
          <div class="mission-list-stack">
            ${t.recommended_actions.length>0?t.recommended_actions.slice(0,4).map(_=>o`<${Nd} action=${_} />`):o`<div class="empty-state">추천 액션이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-content-grid">
        <${T} title="집중 세션" class="mission-list-card">
          <div class="mission-list-stack">
            ${a.length>0?a.map(_=>o`<${Rd} session=${_} />`):o`<div class="empty-state">지금 강조할 session이 없습니다.</div>`}
          </div>
        <//>

        <${T} title="바로 개입할 대상" class="mission-list-card">
          <div class="mission-target-grid">
            <div class="mission-target-block">
              <span class="mission-target-title">Keepers</span>
              ${i.length>0?i.map(_=>o`<div class="mission-target-row"><strong>${_.name}</strong><span class="command-chip ${pt(_.status)}">${_.status??"unknown"}</span></div>`):o`<div class="mission-target-empty">keeper 대상이 없습니다.</div>`}
            </div>
            <div class="mission-target-block">
              <span class="mission-target-title">대기 중 confirm</span>
              <strong>${t.operator_targets.pending_confirms.length}</strong>
              <span class="mission-target-title">가능 액션</span>
              <strong>${t.operator_targets.available_actions.length}</strong>
            </div>
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>nt("intervene")}>개입 워크스페이스</button>
          </div>
        <//>
      </div>
    </section>
  `}const Pd="modulepreload",Ld=function(t){return"/dashboard/"+t},qo={},Md=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let r=function(_){return Promise.all(_.map(p=>Promise.resolve(p).then(f=>({status:"fulfilled",value:f}),f=>({status:"rejected",reason:f}))))};document.getElementsByTagName("link");const l=document.querySelector("meta[property=csp-nonce]"),d=(l==null?void 0:l.nonce)||(l==null?void 0:l.getAttribute("nonce"));a=r(n.map(_=>{if(_=Ld(_),_ in qo)return;qo[_]=!0;const p=_.endsWith(".css"),f=p?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${_}"]${f}`))return;const g=document.createElement("link");if(g.rel=p?"stylesheet":Pd,p||(g.as="script"),g.crossOrigin="",g.href=_,d&&g.setAttribute("nonce",d),document.head.appendChild(g),p)return new Promise(($,y)=>{g.addEventListener("load",$),g.addEventListener("error",()=>y(new Error(`Unable to preload CSS for ${_}`)))})}))}function i(r){const l=new Event("vite:preloadError",{cancelable:!0});if(l.payload=r,window.dispatchEvent(l),!l.defaultPrevented)throw r}return a.then(r=>{for(const l of r||[])l.status==="rejected"&&i(l.reason);return e().catch(i)})},Wi=m(null),Pt=m(null),ls=m(!1),cs=m(!1),ds=m(null),us=m(null),Ha=m(null),ps=m(null),gt=m("summary"),Tn=m(null),Ua=m(!1),ms=m(null),$o=m(null),Ba=m(!1),vs=m(null),ho=m(null),Wa=m(!1),_s=m(null),vn=m(null),fs=m(!1),_n=m(null),Ae=m(null);let He=null;function yo(t){return t!=="summary"&&t!=="swarm"}function S(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function c(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function v(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function W(t){return typeof t=="boolean"?t:void 0}function rt(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Gi(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,i)=>{t.has(i)||t.set(i,a)}),t}function Dd(){const e=Gi().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Id(){const e=Gi().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Ed(t){if(S(t))return{policy_class:c(t.policy_class),approval_class:c(t.approval_class),tool_allowlist:rt(t.tool_allowlist),model_allowlist:rt(t.model_allowlist),requires_human_for:rt(t.requires_human_for),autonomy_level:c(t.autonomy_level),escalation_timeout_sec:v(t.escalation_timeout_sec),kill_switch:W(t.kill_switch),frozen:W(t.frozen)}}function zd(t){if(S(t))return{headcount_cap:v(t.headcount_cap),active_operation_cap:v(t.active_operation_cap),max_cost_usd:v(t.max_cost_usd),max_tokens:v(t.max_tokens)}}function bo(t){if(!S(t))return null;const e=c(t.unit_id),n=c(t.label),s=c(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:c(t.parent_unit_id)??null,leader_id:c(t.leader_id)??null,roster:rt(t.roster),capability_profile:rt(t.capability_profile),source:c(t.source),created_at:c(t.created_at),updated_at:c(t.updated_at),policy:Ed(t.policy),budget:zd(t.budget)}}function Ji(t){if(!S(t))return null;const e=bo(t.unit);return e?{unit:e,leader_status:c(t.leader_status),roster_total:v(t.roster_total),roster_live:v(t.roster_live),active_operation_count:v(t.active_operation_count),health:c(t.health),reasons:rt(t.reasons),children:Array.isArray(t.children)?t.children.map(Ji).filter(n=>n!==null):[]}:null}function Od(t){if(S(t))return{total_units:v(t.total_units),company_count:v(t.company_count),platoon_count:v(t.platoon_count),squad_count:v(t.squad_count),leaf_agent_unit_count:v(t.leaf_agent_unit_count),live_agent_count:v(t.live_agent_count),managed_unit_count:v(t.managed_unit_count),active_operation_count:v(t.active_operation_count)}}function Vi(t){const e=S(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),source:c(e.source),summary:Od(e.summary),units:Array.isArray(e.units)?e.units.map(Ji).filter(n=>n!==null):[]}}function jd(t){if(!S(t))return null;const e=c(t.kind),n=c(t.status);return!e||!n?null:{kind:e,chain_id:c(t.chain_id)??null,goal:c(t.goal)??null,run_id:c(t.run_id)??null,status:n,viewer_path:c(t.viewer_path)??null,last_sync_at:c(t.last_sync_at)??null}}function Ks(t){if(!S(t))return null;const e=c(t.operation_id),n=c(t.objective),s=c(t.assigned_unit_id),a=c(t.trace_id),i=c(t.status);return!e||!n||!s||!a||!i?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:c(t.autonomy_level),policy_class:c(t.policy_class),budget_class:c(t.budget_class),detachment_session_id:c(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:c(t.checkpoint_ref)??null,active_goal_ids:rt(t.active_goal_ids),note:c(t.note)??null,created_by:c(t.created_by),source:c(t.source),status:i,chain:jd(t.chain),created_at:c(t.created_at),updated_at:c(t.updated_at)}}function Fd(t){if(!S(t))return null;const e=Ks(t.operation);return e?{operation:e,assigned_unit_label:c(t.assigned_unit_label)}:null}function Fe(t){if(S(t))return{tone:c(t.tone),pending_ops:v(t.pending_ops),blocked_ops:v(t.blocked_ops),in_flight_ops:v(t.in_flight_ops),pipeline_stalls:v(t.pipeline_stalls),bus_traffic:v(t.bus_traffic),l1_hit_rate:v(t.l1_hit_rate),invalidation_count:v(t.invalidation_count),current_pending:v(t.current_pending),current_in_flight:v(t.current_in_flight),cdb_wakeups:v(t.cdb_wakeups),total_stolen:v(t.total_stolen),avg_best_score:v(t.avg_best_score),avg_candidate_count:v(t.avg_candidate_count),best_first_operations:v(t.best_first_operations),active_sessions:v(t.active_sessions),commit_rate:v(t.commit_rate),total_speculations:v(t.total_speculations)}}function qd(t){if(!S(t))return;const e=S(t.pipeline)?t.pipeline:void 0,n=S(t.cache)?t.cache:void 0,s=S(t.ooo)?t.ooo:void 0,a=S(t.speculative)?t.speculative:void 0,i=S(t.search_fabric)?t.search_fabric:void 0,r=S(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:v(e.total_ops),completed_ops:v(e.completed_ops),stalled_cycles:v(e.stalled_cycles),hazards_detected:v(e.hazards_detected),forwarding_used:v(e.forwarding_used),pipeline_flushes:v(e.pipeline_flushes),ipc:v(e.ipc)}:void 0,cache:n?{total_reads:v(n.total_reads),total_writes:v(n.total_writes),l1_hit_rate:v(n.l1_hit_rate),invalidation_count:v(n.invalidation_count),writeback_count:v(n.writeback_count),bus_traffic:v(n.bus_traffic)}:void 0,ooo:s?{agent_count:v(s.agent_count),total_added:v(s.total_added),total_issued:v(s.total_issued),total_completed:v(s.total_completed),total_stolen:v(s.total_stolen),cdb_wakeups:v(s.cdb_wakeups),stall_cycles:v(s.stall_cycles),global_cdb_events:v(s.global_cdb_events),current_pending:v(s.current_pending),current_in_flight:v(s.current_in_flight)}:void 0,speculative:a?{total_speculations:v(a.total_speculations),total_commits:v(a.total_commits),total_aborts:v(a.total_aborts),commit_rate:v(a.commit_rate),total_fast_calls:v(a.total_fast_calls),total_cost_usd:v(a.total_cost_usd),active_sessions:v(a.active_sessions)}:void 0,search_fabric:i?{total_operations:v(i.total_operations),best_first_operations:v(i.best_first_operations),legacy_operations:v(i.legacy_operations),blocked_operations:v(i.blocked_operations),ready_operations:v(i.ready_operations),research_pipeline_operations:v(i.research_pipeline_operations),avg_candidate_count:v(i.avg_candidate_count),avg_best_score:v(i.avg_best_score),top_stage:c(i.top_stage)??null}:void 0,signals:r?{issue_pressure:Fe(r.issue_pressure),cache_contention:Fe(r.cache_contention),scheduler_efficiency:Fe(r.scheduler_efficiency),routing_confidence:Fe(r.routing_confidence),speculative_posture:Fe(r.speculative_posture)}:void 0}}function Yi(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),summary:n?{total:v(n.total),active:v(n.active),paused:v(n.paused),managed:v(n.managed),projected:v(n.projected)}:void 0,microarch:qd(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(Fd).filter(s=>s!==null):[]}}function Qi(t){if(!S(t))return null;const e=c(t.detachment_id),n=c(t.operation_id),s=c(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:c(t.leader_id)??null,roster:rt(t.roster),session_id:c(t.session_id)??null,checkpoint_ref:c(t.checkpoint_ref)??null,runtime_kind:c(t.runtime_kind)??null,runtime_ref:c(t.runtime_ref)??null,source:c(t.source),status:c(t.status),last_event_at:c(t.last_event_at)??null,last_progress_at:c(t.last_progress_at)??null,heartbeat_deadline:c(t.heartbeat_deadline)??null,created_at:c(t.created_at),updated_at:c(t.updated_at)}}function Kd(t){if(!S(t))return null;const e=Qi(t.detachment);return e?{detachment:e,assigned_unit_label:c(t.assigned_unit_label),operation:Ks(t.operation)}:null}function Xi(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),summary:n?{total:v(n.total),active:v(n.active),projected:v(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(Kd).filter(s=>s!==null):[]}}function Hd(t){if(!S(t))return null;const e=c(t.decision_id),n=c(t.trace_id),s=c(t.requested_action),a=c(t.scope_type),i=c(t.scope_id);return!e||!n||!s||!a||!i?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:i,operation_id:c(t.operation_id)??null,target_unit_id:c(t.target_unit_id)??null,requested_by:c(t.requested_by),status:c(t.status),reason:c(t.reason)??null,source:c(t.source),detail:t.detail,created_at:c(t.created_at),decided_at:c(t.decided_at)??null,expires_at:c(t.expires_at)??null}}function Zi(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),summary:n?{total:v(n.total),pending:v(n.pending),approved:v(n.approved),denied:v(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(Hd).filter(s=>s!==null):[]}}function Ud(t){if(!S(t))return null;const e=bo(t.unit);return e?{unit:e,roster_total:v(t.roster_total),roster_live:v(t.roster_live),headcount_cap:v(t.headcount_cap),active_operations:v(t.active_operations),active_operation_cap:v(t.active_operation_cap),utilization:v(t.utilization)}:null}function Bd(t){const e=S(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(Ud).filter(n=>n!==null):[]}}function Wd(t){if(!S(t))return null;const e=c(t.alert_id);return e?{alert_id:e,severity:c(t.severity),kind:c(t.kind),scope_type:c(t.scope_type),scope_id:c(t.scope_id),title:c(t.title),detail:c(t.detail),timestamp:c(t.timestamp)}:null}function tr(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),summary:n?{total:v(n.total),bad:v(n.bad),warn:v(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(Wd).filter(s=>s!==null):[]}}function er(t){if(!S(t))return null;const e=c(t.event_id),n=c(t.trace_id),s=c(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:c(t.operation_id)??null,unit_id:c(t.unit_id)??null,actor:c(t.actor)??null,source:c(t.source),timestamp:c(t.timestamp),detail:t.detail}}function Gd(t){const e=S(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),events:Array.isArray(e.events)?e.events.map(er).filter(n=>n!==null):[]}}function Jd(t){if(!S(t))return null;const e=c(t.code),n=c(t.severity),s=c(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function Vd(t){if(!S(t))return null;const e=c(t.lane_id),n=c(t.label),s=c(t.kind),a=c(t.phase),i=c(t.motion_state),r=c(t.source_of_truth),l=c(t.movement_reason),d=c(t.current_step);if(!e||!n||!s||!a||!i||!r||!l||!d)return null;const _=S(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:W(t.present)??!1,phase:a,motion_state:i,source_of_truth:r,last_movement_at:c(t.last_movement_at)??null,movement_reason:l,current_step:d,blockers:rt(t.blockers),counts:{operations:v(_.operations),detachments:v(_.detachments),workers:v(_.workers),approvals:v(_.approvals),alerts:v(_.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(Jd).filter(p=>p!==null):[]}}function Yd(t){if(!S(t))return null;const e=c(t.event_id),n=c(t.lane_id),s=c(t.kind),a=c(t.timestamp),i=c(t.title),r=c(t.detail),l=c(t.tone),d=c(t.source);return!e||!n||!s||!a||!i||!r||!l||!d?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:i,detail:r,tone:l,source:d}}function Qd(t){if(!S(t))return null;const e=c(t.code),n=c(t.severity),s=c(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,lane_ids:rt(t.lane_ids),count:v(t.count)??0}}function nr(t){if(!S(t))return;const e=S(t.overview)?t.overview:{},n=S(t.gaps)?t.gaps:{},s=S(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:c(t.generated_at),overview:{active_lanes:v(e.active_lanes),moving_lanes:v(e.moving_lanes),stalled_lanes:v(e.stalled_lanes),projected_lanes:v(e.projected_lanes),last_movement_at:c(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(Vd).filter(a=>a!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(Yd).filter(a=>a!==null):[],gaps:{count:v(n.count),items:Array.isArray(n.items)?n.items.map(Qd).filter(a=>a!==null):[]},recommended_next_action:s?{tool:c(s.tool)??"masc_operator_snapshot",label:c(s.label)??"Observe operator state",reason:c(s.reason)??"",lane_id:c(s.lane_id)??null}:void 0}}function Xd(t){if(!S(t))return;const e=S(t.workers)?t.workers:{},n=W(t.pass);return{status:c(t.status)??"missing",source:c(t.source)??"none",run_id:c(t.run_id)??null,captured_at:c(t.captured_at)??null,...n!==void 0?{pass:n}:{},...v(t.peak_hot_slots)!=null?{peak_hot_slots:v(t.peak_hot_slots)}:{},...v(t.ctx_per_slot)!=null?{ctx_per_slot:v(t.ctx_per_slot)}:{},workers:{expected:v(e.expected),joined:v(e.joined),current_task_bound:v(e.current_task_bound),fresh_heartbeats:v(e.fresh_heartbeats),done:v(e.done),final:v(e.final)},artifact_ref:c(t.artifact_ref)??null,missing_reason:c(t.missing_reason)??null}}function Zd(t){const e=S(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),topology:Vi(e.topology),operations:Yi(e.operations),detachments:Xi(e.detachments),alerts:tr(e.alerts),decisions:Zi(e.decisions),capacity:Bd(e.capacity),traces:Gd(e.traces),swarm_status:nr(e.swarm_status)}}function tu(t){const e=S(t)?t:{},n=Vi(e.topology),s=Yi(e.operations),a=Xi(e.detachments),i=tr(e.alerts),r=Zi(e.decisions);return{version:c(e.version),generated_at:c(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:i.version,generated_at:i.generated_at,summary:i.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:nr(e.swarm_status),swarm_proof:Xd(e.swarm_proof)}}function eu(t){return S(t)?{chain_id:c(t.chain_id)??null,started_at:v(t.started_at)??null,progress:v(t.progress)??null,elapsed_sec:v(t.elapsed_sec)??null}:null}function sr(t){if(!S(t))return null;const e=c(t.event);return e?{event:e,chain_id:c(t.chain_id)??null,timestamp:c(t.timestamp)??null,duration_ms:v(t.duration_ms)??null,message:c(t.message)??null,tokens:v(t.tokens)??null}:null}function nu(t){if(!S(t))return null;const e=Ks(t.operation);return e?{operation:e,runtime:eu(t.runtime),history:sr(t.history),mermaid:c(t.mermaid)??null,preview_run:ar(t.preview_run)}:null}function su(t){const e=S(t)?t:{};return{status:c(e.status)??"disconnected",base_url:c(e.base_url)??null,message:c(e.message)??null}}function au(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),connection:su(e.connection),summary:n?{linked_operations:v(n.linked_operations),active_chains:v(n.active_chains),running_operations:v(n.running_operations),recent_failures:v(n.recent_failures),last_history_event_at:c(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(nu).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(sr).filter(s=>s!==null):[]}}function ou(t){if(!S(t))return null;const e=c(t.id);return e?{id:e,type:c(t.type),status:c(t.status),duration_ms:v(t.duration_ms)??null,error:c(t.error)??null}:null}function ar(t){if(!S(t))return null;const e=c(t.run_id),n=c(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:v(t.duration_ms),success:W(t.success),mermaid:c(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(ou).filter(s=>s!==null):[]}:null}function iu(t){const e=S(t)?t:{};return{run:ar(e.run)}}function ru(t){if(!S(t))return null;const e=c(t.title),n=c(t.path);return!e||!n?null:{title:e,path:n}}function lu(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function cu(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.tool),a=c(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:rt(t.success_signals),pitfalls:rt(t.pitfalls)}}function du(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.summary),a=c(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(cu).filter(i=>i!==null):[]}}function uu(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:rt(t.tools)}}function pu(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.symptom),a=c(t.why),i=c(t.fix_tool),r=c(t.fix_summary);return!e||!n||!s||!a||!i||!r?null:{id:e,title:n,symptom:s,why:a,fix_tool:i,fix_summary:r}}function mu(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.path_id),a=c(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:rt(t.notes)}}function vu(t){const e=S(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(ru).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(lu).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(du).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(uu).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(pu).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(mu).filter(n=>n!==null):[]}}function _u(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.status),a=c(t.detail),i=c(t.next_tool);return!e||!n||!s||!a||!i?null:{id:e,title:n,status:s,detail:a,next_tool:i}}function fu(t){if(!S(t))return null;const e=c(t.code),n=c(t.severity),s=c(t.title),a=c(t.detail),i=c(t.next_tool);return!e||!n||!s||!a||!i?null:{code:e,severity:n,title:s,detail:a,next_tool:i}}function gu(t){if(!S(t))return null;const e=c(t.from),n=c(t.content),s=c(t.timestamp),a=v(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function $u(t){if(!S(t))return null;const e=c(t.name),n=c(t.role),s=c(t.lane),a=c(t.status),i=c(t.claim_marker),r=c(t.done_marker),l=c(t.final_marker);if(!e||!n||!s||!a||!i||!r||!l)return null;const d=(()=>{if(!S(t.last_message))return null;const _=v(t.last_message.seq),p=c(t.last_message.content),f=c(t.last_message.timestamp);return _==null||!p||!f?null:{seq:_,content:p,timestamp:f}})();return{name:e,role:n,lane:s,joined:W(t.joined)??!1,live_presence:W(t.live_presence)??!1,completed:W(t.completed)??!1,status:a,current_task:c(t.current_task)??null,bound_task_id:c(t.bound_task_id)??null,bound_task_title:c(t.bound_task_title)??null,bound_task_status:c(t.bound_task_status)??null,current_task_matches_run:W(t.current_task_matches_run)??!1,squad_member:W(t.squad_member)??!1,detachment_member:W(t.detachment_member)??!1,last_seen:c(t.last_seen)??null,heartbeat_age_sec:v(t.heartbeat_age_sec)??null,heartbeat_fresh:W(t.heartbeat_fresh)??!1,claim_marker_seen:W(t.claim_marker_seen)??!1,done_marker_seen:W(t.done_marker_seen)??!1,final_marker_seen:W(t.final_marker_seen)??!1,claim_marker:i,done_marker:r,final_marker:l,last_message:d}}function hu(t){if(!S(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!S(n))return null;const s=c(n.timestamp),a=v(n.active_slots);if(!s||a==null)return null;const i=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:i}}).filter(n=>n!==null):[];return{slot_url:c(t.slot_url)??null,provider_base_url:c(t.provider_base_url)??null,provider_reachable:W(t.provider_reachable)??null,provider_status_code:v(t.provider_status_code)??null,provider_model_id:c(t.provider_model_id)??null,actual_model_id:c(t.actual_model_id)??null,expected_slots:v(t.expected_slots),actual_slots:v(t.actual_slots),expected_ctx:v(t.expected_ctx),actual_ctx:v(t.actual_ctx),slot_reachable:W(t.slot_reachable)??null,slot_status_code:v(t.slot_status_code)??null,runtime_blocker:c(t.runtime_blocker)??null,detail:c(t.detail)??null,checked_at:c(t.checked_at)??null,total_slots:v(t.total_slots),ctx_per_slot:v(t.ctx_per_slot),active_slots_now:v(t.active_slots_now),peak_active_slots:v(t.peak_active_slots),sample_count:v(t.sample_count),last_sample_at:c(t.last_sample_at)??null,timeline:e}}function yu(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),run_id:c(e.run_id),room_id:c(e.room_id),operation_id:c(e.operation_id)??null,recommended_next_tool:c(e.recommended_next_tool),summary:n?{expected_workers:v(n.expected_workers),joined_workers:v(n.joined_workers),live_workers:v(n.live_workers),squad_roster_size:v(n.squad_roster_size),detachment_roster_size:v(n.detachment_roster_size),current_task_bound:v(n.current_task_bound),fresh_heartbeats:v(n.fresh_heartbeats),claim_markers_seen:v(n.claim_markers_seen),done_markers_seen:v(n.done_markers_seen),final_markers_seen:v(n.final_markers_seen),completed_workers:v(n.completed_workers),peak_hot_slots:v(n.peak_hot_slots),hot_window_ok:W(n.hot_window_ok),pass_hot_concurrency:W(n.pass_hot_concurrency),pass_end_to_end:W(n.pass_end_to_end),pending_decisions:v(n.pending_decisions),pass:W(n.pass)}:void 0,provider:hu(e.provider),operation:Ks(e.operation),squad:bo(e.squad),detachment:Qi(e.detachment),workers:Array.isArray(e.workers)?e.workers.map($u).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(_u).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(fu).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(gu).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(er).filter(s=>s!==null):[],truth_notes:rt(e.truth_notes)}}function fn(t){gt.value=t,yo(t)&&bu()}async function or(){ls.value=!0,ds.value=null;try{const t=await Ll();Wi.value=tu(t)}catch(t){ds.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{ls.value=!1}}function ko(t){Ae.value=t}async function xo(){cs.value=!0,us.value=null;try{const t=await Pl();Pt.value=Zd(t)}catch(t){us.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{cs.value=!1}}async function bu(){Pt.value||cs.value||await xo()}async function de(){await or(),yo(gt.value)&&await xo()}async function Ut(){var t;Wa.value=!0,_s.value=null;try{const e=await Ml(),n=au(e);ho.value=n;const s=Ae.value;n.operations.length===0?Ae.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Ae.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){_s.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{Wa.value=!1}}function ku(){He=null,vn.value=null,fs.value=!1,_n.value=null}async function xu(t){He=t,fs.value=!0,_n.value=null;try{const e=await Dl(t);if(He!==t)return;vn.value=iu(e)}catch(e){if(He!==t)return;vn.value=null,_n.value=e instanceof Error?e.message:"Failed to load chain run"}finally{He===t&&(fs.value=!1)}}async function Su(){Ua.value=!0,ms.value=null;try{const t=await Il();Tn.value=vu(t)}catch(t){ms.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Ua.value=!1}}async function Dt(t=Dd(),e=Id()){Ba.value=!0,vs.value=null;try{const n=await El(t,e);$o.value=yu(n)}catch(n){vs.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{Ba.value=!1}}async function Xt(t,e,n){Ha.value=t,ps.value=null;try{await zl(e,n),await or(),(Pt.value||yo(gt.value))&&await xo(),await Dt(),await Ut()}catch(s){throw ps.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{Ha.value=null}}function Au(t){return Xt(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Cu(t){return Xt(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function wu(t){return Xt(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Tu(t={}){return Xt("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function Nu(t){return Xt(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Ru(t){return Xt(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Pu(t,e){return Xt(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Lu(t,e){return Xt(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}vd(()=>{de(),Ut(),(gt.value==="swarm"||$o.value!==null)&&Dt()});function Mu(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Q(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function Du(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Iu(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function z(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let Ko=!1,Eu=0,Xs=null;async function zu(){Xs||(Xs=Md(()=>import("./mermaid.core-DTGMLNSe.js").then(e=>e.bE),[]).then(e=>e.default));const t=await Xs;return Ko||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),Ko=!0),t}function Bt(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Hs(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function Ou(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function Nn(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function ae(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:Nn(t/e*100)}function ju(t,e){const n=Nn(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function ir(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const rr=[{id:"summary",label:"요약"},{id:"swarm",label:"스웜"},{id:"operations",label:"작전"},{id:"chains",label:"체인"},{id:"topology",label:"토폴로지"},{id:"alerts",label:"알림"},{id:"trace",label:"트레이스"},{id:"control",label:"제어"}],Fu=rr.map(t=>t.id),qu=["chain_start","node_start","node_complete","chain_complete","chain_error"];function Ku(t){return!!t&&Fu.includes(t)}function Hu(t){if(t==="summary")return{};if(t==="chains"){const e=Ae.value;return e?{surface:t,operation:e}:{surface:t}}return{surface:t}}function Uu(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function Bu(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function et(t){return Ha.value===t}function Us(){return Wi.value}function In({label:t,value:e,subtext:n,percent:s,color:a}){return o`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${ju(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(Nn(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function En({label:t,value:e,detail:n,percent:s,tone:a}){return o`
    <article class="command-signal-rail ${z(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${z(a)}" style=${`width: ${Math.max(8,Math.round(Nn(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function Wu(){var lt,ct,H,X;const t=Us(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,i=t==null?void 0:t.alerts.summary,r=(lt=t==null?void 0:t.swarm_status)==null?void 0:lt.overview,l=t==null?void 0:t.swarm_proof,d=t==null?void 0:t.operations.microarch,_=(e==null?void 0:e.managed_unit_count)??0,p=(e==null?void 0:e.total_units)??0,f=(n==null?void 0:n.active)??0,g=(s==null?void 0:s.active)??0,$=(r==null?void 0:r.moving_lanes)??0,y=(r==null?void 0:r.active_lanes)??0,A=(l==null?void 0:l.workers.done)??0,N=(l==null?void 0:l.workers.expected)??0,M=(i==null?void 0:i.bad)??0,E=(i==null?void 0:i.warn)??0,L=(a==null?void 0:a.pending)??0,R=(a==null?void 0:a.total)??0,u=f+g,q=((ct=d==null?void 0:d.cache)==null?void 0:ct.l1_hit_rate)??((X=(H=d==null?void 0:d.signals)==null?void 0:H.cache_contention)==null?void 0:X.l1_hit_rate)??0,K=f>0||g>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",Lt=f>0||$>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return o`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${K}</h3>
        <p>${Lt}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${z(f>0?"ok":"warn")}">활성 작전 ${f}</span>
          <span class="command-chip ${z($>0?"ok":(y>0,"warn"))}">이동 레인 ${$}/${Math.max(y,$)}</span>
          <span class="command-chip ${z(M>0?"bad":E>0?"warn":"ok")}">치명 알림 ${M}</span>
          <span class="command-chip ${z(L>0?"warn":"ok")}">승인 대기 ${L}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${In}
          label="관리 단위 범위"
          value=${`${_}/${Math.max(p,_)}`}
          subtext=${p>0?`${p-_}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${ae(_,Math.max(p,_))}
          color="#67e8f9"
        />
        <${In}
          label="실행 열도"
          value=${String(u)}
          subtext=${`${f}개 작전 + ${g}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${ae(u,Math.max(_,u||1))}
          color="#4ade80"
        />
        <${In}
          label="스웜 이동감"
          value=${`${$}/${Math.max(y,$)}`}
          subtext=${r!=null&&r.last_movement_at?`마지막 이동 ${Q(r.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${ae($,Math.max(y,$||1))}
          color="#fbbf24"
        />
        <${In}
          label="증거 수집률"
          value=${`${A}/${Math.max(N,A)}`}
          subtext=${l!=null&&l.status?`증거 소스 ${l.source} · ${l.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${ae(A,Math.max(N,A||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${En}
        label="승인 대기열"
        value=${`${L}건 대기`}
        detail=${`현재 정책 창에서 ${R}개 결정을 추적 중입니다`}
        percent=${ae(L,Math.max(R,L||1))}
        tone=${L>0?"warn":"ok"}
      />
      <${En}
        label="알림 압력"
        value=${`${M} bad / ${E} warn`}
        detail=${M>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${ae(M*2+E,Math.max((M+E)*2,1))}
        tone=${M>0?"bad":E>0?"warn":"ok"}
      />
      <${En}
        label="디스패치 점유"
          value=${`${g}개 가동`}
        detail=${_>0?`${_}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${ae(g,Math.max(_,g||1))}
        tone=${g>0?"ok":"warn"}
      />
      <${En}
        label="캐시 신뢰도"
        value=${q?Hs(q):"n/a"}
        detail=${q?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Nn((q??0)*100)}
        tone=${q>=.75?"ok":q>=.4?"warn":"bad"}
      />
    </div>
  `}function Gu(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function lr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,i)=>{t.has(i)||t.set(i,a)}),t}function Ju(){const e=lr().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Vu(){const e=lr().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Yu(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function Qu(t){return t.status==="claimed"||t.status==="in_progress"}function Xu(t){const e=Tn.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function Zs(t){var e;return((e=Tn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function Zu(t){const e=Tn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function Wt(t){try{await t()}catch{}}function tp(){var p,f,g,$,y;const t=Us(),e=ho.value,n=t==null?void 0:t.topology.summary,s=t==null?void 0:t.operations.summary,a=(p=t==null?void 0:t.swarm_status)==null?void 0:p.overview,i=t==null?void 0:t.operations.microarch,r=t==null?void 0:t.decisions.summary,l=t==null?void 0:t.alerts.summary,d=(f=i==null?void 0:i.signals)==null?void 0:f.issue_pressure,_=i==null?void 0:i.cache;return o`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(n==null?void 0:n.total_units)??0}</strong><small>${(n==null?void 0:n.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(s==null?void 0:s.active)??0}</strong><small>${((g=t==null?void 0:t.detachments.summary)==null?void 0:g.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(r==null?void 0:r.pending)??0}</strong><small>${(r==null?void 0:r.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card"><span>알림</span><strong>${(l==null?void 0:l.bad)??0}</strong><small>${(l==null?void 0:l.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${(($=e==null?void 0:e.summary)==null?void 0:$.active_chains)??0}</strong><small>${((y=e==null?void 0:e.summary)==null?void 0:y.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card"><span>스웜</span><strong>${(a==null?void 0:a.active_lanes)??0}</strong><small>${a?`${a.stalled_lanes??0}개 정체 · ${Q(a.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card"><span>마이크로아크</span><strong>${(d==null?void 0:d.pending_ops)??0}</strong><small>${(_==null?void 0:_.l1_hit_rate)!=null?`${Hs(_.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(d==null?void 0:d.tone)??"n/a"}</small></div>
    </div>
  `}function cr(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function ep({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const i=a.motion_state;i in e?e[i]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return o`
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
  `}function np({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return o`
    <div class="swarm-worker-grid">
      ${a.map(()=>o`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?o`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function sp({lane:t}){const e=t.counts??{},n=cr(t),s=e.workers??0,a=e.operations??0,i=e.detachments??0,r=a+i,l=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return o`
    <article class="swarm-lane-strip ${z(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${z(n)}">${t.phase}</span>
          <span class="command-chip ${z(n)}">${t.motion_state}</span>
          <span class="command-chip">${Q(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${z(n)}" style=${`width:${l}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${s>0?o`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${np} total=${s} />
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
              ${t.hard_flags.map(d=>o`<span class="command-chip ${z(d.severity)}">${d.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function ap({lanes:t}){const e=t.slice(0,4);return e.length===0?null:o`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=cr(n),a=n.counts.workers??0,i=n.counts.operations??0,r=n.counts.detachments??0;return o`
          <article class="swarm-story-card ${z(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${z(s)}">${n.motion_state}</span>
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
  `}function op({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return o`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${z(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?o`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function ip({gap:t}){return o`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${z(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function rp({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return o`
    <div class="command-guide-card ${z(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${z(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?o`
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${Q(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.artifact_ref?o`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?o`<p>${t.missing_reason}</p>`:null}
          `:o`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function lp(){const t=Us(),e=t==null?void 0:t.swarm_status,n=t==null?void 0:t.swarm_proof,s=(e==null?void 0:e.lanes.filter(_=>_.present))??[],a=(e==null?void 0:e.gaps.items)??[],i=(e==null?void 0:e.timeline.slice(0,8))??[],r=e==null?void 0:e.overview,l=e==null?void 0:e.recommended_next_action,d=s.length<=1;return o`
    <section class="card command-section">
      <div class="card-title">스웜</div>
      ${e?o`
            <${ap} lanes=${s} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(r==null?void 0:r.active_lanes)??0}</strong><small>${(r==null?void 0:r.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(r==null?void 0:r.stalled_lanes)??0}</strong><small>${(r==null?void 0:r.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${Q(r==null?void 0:r.last_movement_at)}</strong><small>${e.generated_at?`스냅샷 ${Q(e.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(l==null?void 0:l.label)??"운영자 상태 확인"}</strong><small>${(l==null?void 0:l.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${s.length>0?o`<${ep} lanes=${s} />`:null}

            <div class="command-swarm-layout ${d?"compact":""}">
              <div class="command-card-stack">
                ${s.length>0?s.map(_=>o`<${sp} lane=${_} />`):o`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight">
                  <div class="command-guide-head">
                    <strong>${(l==null?void 0:l.label)??"운영자 상태 확인"}</strong>
                    <span class="command-chip">${(l==null?void 0:l.lane_id)??"전체"}</span>
                  </div>
                  <p>${(l==null?void 0:l.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="command-card-foot">${(l==null?void 0:l.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${rp} proof=${n} />

                <div class="command-guide-card ${a.length>0?"warn":"ok"}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${z(a.some(_=>_.severity==="bad")?"bad":a.length>0?"warn":"ok")}">${a.length}</span>
                  </div>
                  ${a.length>0?o`<div class="swarm-event-rail">${a.slice(0,4).map(_=>o`<${ip} gap=${_} />`)}</div>`:o`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${i.length}</span>
                  </div>
                  ${i.length>0?o`<div class="swarm-event-rail">${i.map(_=>o`<${op} event=${_} />`)}</div>`:o`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:o`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function cp(){return o`
    <div class="command-surface-tabs">
      ${rr.map(t=>o`
        <button
          class="command-surface-tab ${gt.value===t.id?"active":""}"
          onClick=${()=>{fn(t.id),nt("command",Hu(t.id))}}
        >
          ${t.label}
        </button>
      `)}
    </div>
  `}function dp(){var lt,ct,H,X,b,te,ze,Pn,Ln;const t=Us(),e=Pt.value,n=me.value,s=Gu(),a=s?Nt.value.find(D=>D.name===s)??null:null,i=s?kt.value.filter(D=>D.assignee===s&&Qu(D)):[],r=((lt=t==null?void 0:t.operations.summary)==null?void 0:lt.active)??0,l=((ct=t==null?void 0:t.detachments.summary)==null?void 0:ct.total)??0,d=((H=t==null?void 0:t.decisions.summary)==null?void 0:H.pending)??0,_=e==null?void 0:e.detachments.detachments.find(D=>{const ee=D.detachment.heartbeat_deadline,Mn=ee?Date.parse(ee):Number.NaN;return D.detachment.status==="stalled"||!Number.isNaN(Mn)&&Mn<=Date.now()}),p=e==null?void 0:e.alerts.alerts.find(D=>D.severity==="bad"),f=!!(n!=null&&n.room||n!=null&&n.project),g=(a==null?void 0:a.current_task)??null,$=Yu(a==null?void 0:a.last_seen),y=$!=null?$<=120:null,A=[f?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?i.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:kt.value.length>0?"masc_claim":"masc_add_task"}:g?y===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${g} 이지만 heartbeat가 stale 합니다 (${$}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${g}${$!=null?` · 마지막 활동 ${$}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((X=t.topology.summary)==null?void 0:X.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:r===0?{title:"작전 준비도",tone:"warn",detail:`${((b=t.topology.summary)==null?void 0:b.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((te=t.topology.summary)==null?void 0:te.managed_unit_count)??0}개 관리 단위 위에서 ${r}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},d>0?{title:"디스패치 준비도",tone:"warn",detail:`${d}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:r>0&&l===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:_||p?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${_?` · detachment ${_.detachment.detachment_id} 가 stalled 상태입니다`:""}${p?` · alert ${p.title??p.alert_id}`:""}${!e&&!_&&!p?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:d>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${l}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],N=f?!s||!a?"masc_join":i.length===0?kt.value.length>0?"masc_claim":"masc_add_task":g?y===!1?"masc_heartbeat":!t||(((ze=t.topology.summary)==null?void 0:ze.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":d>0?"masc_policy_approve":r>0&&l===0||_||p?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",M=Xu(N),L=Zu(N==="masc_set_room"?["repo-root-room"]:N==="masc_plan_set_task"?["claimed-not-current"]:N==="masc_heartbeat"?["heartbeat-stale"]:N==="masc_dispatch_tick"?["no-detachments"]:N==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),R=Zs("room_task_hygiene"),u=Zs("cpv2_benchmark"),q=Zs("supervisor_session"),K=((Pn=Tn.value)==null?void 0:Pn.docs)??[],Lt=[R,u,q].filter(D=>D!==null);return o`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title">즉시 조치</div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(M==null?void 0:M.title)??N}</strong>
            <span class="command-chip ok">${N}</span>
          </div>
          <p>${(M==null?void 0:M.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(Ln=M==null?void 0:M.success_signals)!=null&&Ln.length?o`<div class="command-tag-row">
                ${M.success_signals.map(D=>o`<span class="command-tag ok">${D}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${A.map(D=>o`
            <article class="command-readiness-row ${z(D.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${D.title}</strong>
                  <span class="command-chip ${z(D.tone)}">${D.tone}</span>
                </div>
                <p>${D.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${D.tool}</div>
            </article>
          `)}
        </div>

        ${L.length>0?o`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${L.length}</span>
                </div>
                <div class="command-guide-list">
                  ${L.map(D=>o`
                    <article class="command-guide-inline">
                      <strong>${D.title}</strong>
                      <div>${D.symptom}</div>
                      <div class="command-card-sub">${D.fix_tool} 로 해결: ${D.fix_summary}</div>
                    </article>
                  `)}
                </div>
              </div>
            `:null}
      </section>

      <section class="card command-section">
        <div class="card-title">운영 경로</div>
        ${Ua.value?o`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:ms.value?o`<div class="empty-state error">${ms.value}</div>`:o`
                <div class="command-path-grid">
                  ${Lt.map(D=>o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${D.title}</strong>
                        <span class="command-chip">${D.id}</span>
                      </div>
                      <p>${D.summary}</p>
                      <div class="command-card-sub">${D.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${D.steps.slice(0,4).map(ee=>o`
                          <div class="command-step-row">
                            <span class="command-step-tool">${ee.tool}</span>
                            <span>${ee.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${K.length>0?o`<div class="command-doc-links">
                      ${K.map(D=>o`<span class="command-tag">${D.title}: ${D.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function up(){return o`
    <${Wu} />
    <${tp} />
    <${dp} />
  `}function pp(){return cs.value?o`<div class="empty-state">command-plane detail 불러오는 중…</div>`:us.value?o`<div class="empty-state error">${us.value}</div>`:o`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function dr({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,i=t.unit.policy;return o`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${Bu(t.unit.kind)}</span>
            <span class="command-chip ${z(t.health)}">${t.health??"ok"}</span>
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
            ${t.children.map(r=>o`<${dr} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function mp({source:t}){const e=gi(null),[n,s]=zs(null);return tt(()=>{let a=!1;const i=e.current;return i?(i.innerHTML="",s(null),(async()=>{try{const l=await zu(),{svg:d}=await l.render(`command-chain-${++Eu}`,t);if(a||!e.current)return;e.current.innerHTML=d}catch(l){if(a)return;s(l instanceof Error?l.message:"Mermaid render failed")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),o`
    <div class="command-chain-graph-shell">
      ${n?o`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function vp({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return o`
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
        ${s!=null&&s.chain_id?o`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?o`<span class="command-tag ${Bt(s==null?void 0:s.status)}">${Hs(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${ir(t.history)}</div>
    </button>
  `}function _p({item:t}){return o`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${Bt(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${Q(t.timestamp)}</div>
      <div class="command-card-sub">${ir(t)}</div>
    </article>
  `}function fp({node:t}){return o`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${Bt(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?o`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function gp({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,i=e.chain,r=(i==null?void 0:i.run_id)??null;return o`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${z(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Autonomy</span><span>${e.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${e.budget_class??"standard"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Updated</span><span>${Q(e.updated_at)}</span>
      </div>
      ${i?o`
            <div class="command-tag-row">
              <span class="command-tag">${i.kind}</span>
              <span class="command-tag ${Bt(i.status)}">${i.status}</span>
              ${i.chain_id?o`<span class="command-tag">${i.chain_id}</span>`:null}
              ${i.run_id?o`<span class="command-tag">run ${i.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?o`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{fn("swarm"),nt("command",{surface:"swarm",operation_id:e.operation_id,...r?{run_id:r}:{}})}}
        >
          Swarm Live
        </button>
        ${i?o`
              <button
                class="control-btn ghost"
                onClick=${()=>{ko(e.operation_id),fn("chains"),nt("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?o`
              <button class="control-btn ghost" disabled=${et(n)} onClick=${()=>Wt(()=>Au(e.operation_id))}>
                ${et(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${et(a)} onClick=${()=>Wt(()=>wu(e.operation_id))}>
                ${et(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?o`
              <button class="control-btn ghost" disabled=${et(s)} onClick=${()=>Wt(()=>Cu(e.operation_id))}>
                ${et(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function $p({card:t}){var n;const e=t.detachment;return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${z(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${Q(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Iu(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${Q(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?o`<span class="command-tag ${Du(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function hp({alert:t}){return o`
    <article class="command-alert ${z(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${z(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${Q(t.timestamp)}</span>
      </div>
      ${t.detail?o`<p>${t.detail}</p>`:null}
    </article>
  `}function ur({event:t}){return o`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${Q(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${Mu(t.detail)}</pre>
    </article>
  `}function yp({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return o`
    <article class="command-card ${z(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${z(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${Q(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!s?o`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${et(e)} onClick=${()=>Wt(()=>Nu(t.decision_id))}>
                ${et(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${et(n)} onClick=${()=>Wt(()=>Ru(t.decision_id))}>
                ${et(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?o`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function bp({row:t}){var l,d,_;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((l=e.policy)!=null&&l.frozen),i=!!((d=e.policy)!=null&&d.kill_switch),r=Math.round((t.utilization??0)*100);return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${z(r>100?"bad":r>70?"warn":"ok")}">${r}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>Headcount Cap</span><span>${t.headcount_cap??0}</span>
        <span>Ops</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${((_=e.policy)==null?void 0:_.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${a?"yes":"no"}</span>
        <span>Kill Switch</span><span>${i?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${et(n)} onClick=${()=>Wt(()=>Pu(e.unit_id,!a))}>
          ${et(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${et(s)} onClick=${()=>Wt(()=>Lu(e.unit_id,!i))}>
          ${et(s)?"Applying…":i?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function kp({item:t}){return o`
    <article class="command-guide-card ${z(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${z(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function xp({blocker:t}){return o`
    <article class="command-alert ${z(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${z(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function Sp({worker:t}){return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${z(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${t.last_message?o`<div class="command-card-foot">${Q(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function Ap(){var d,_,p,f,g,$,y,A,N,M,E,L,R,u,q,K,Lt,lt,ct,H,X;const t=$o.value,e=Ju(),n=Vu(),s=(d=t==null?void 0:t.provider)!=null&&d.runtime_blocker?"blocked":(_=t==null?void 0:t.provider)!=null&&_.provider_reachable?"ready":"check",a=((p=t==null?void 0:t.provider)==null?void 0:p.actual_slots)??((f=t==null?void 0:t.provider)==null?void 0:f.total_slots)??0,i=((g=t==null?void 0:t.provider)==null?void 0:g.expected_slots)??"n/a",r=(($=t==null?void 0:t.provider)==null?void 0:$.actual_ctx)??((y=t==null?void 0:t.provider)==null?void 0:y.ctx_per_slot)??0,l=((A=t==null?void 0:t.provider)==null?void 0:A.expected_ctx)??"n/a";return o`
    <div class="command-section-stack">
      <${lp} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title">스웜 라이브 런</div>
          ${Ba.value?o`<div class="empty-state">Loading swarm live state…</div>`:vs.value?o`<div class="empty-state error">${vs.value}</div>`:t?o`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((N=t.summary)==null?void 0:N.joined_workers)??0}/${((M=t.summary)==null?void 0:M.expected_workers)??0}</strong><small>${((E=t.summary)==null?void 0:E.live_workers)??0}개 가동 · ${((L=t.summary)==null?void 0:L.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${i} · ctx ${r}/${l}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(R=t.summary)!=null&&R.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((u=t.provider)==null?void 0:u.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(q=t.summary)!=null&&q.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((K=t.operation)==null?void 0:K.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((Lt=t.squad)==null?void 0:Lt.label)??"없음"}</span>
                      <span>실행체</span><span>${((lt=t.detachment)==null?void 0:lt.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((ct=t.summary)==null?void 0:ct.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((H=t.summary)==null?void 0:H.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((X=t.provider)==null?void 0:X.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?o`<div class="command-tag-row">
                          ${t.truth_notes.map(b=>o`<span class="command-tag">${b}</span>`)}
                        </div>`:null}
                  `:o`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">체크리스트</div>
          ${t&&t.checklist.length>0?o`<div class="command-card-stack">
                ${t.checklist.map(b=>o`<${kp} item=${b} />`)}
              </div>`:o`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">워커</div>
          ${t&&t.workers.length>0?o`<div class="command-card-stack">
                ${t.workers.map(b=>o`<${Sp} worker=${b} />`)}
              </div>`:o`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">런타임</div>
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
                  <span>Last Sample</span><span>${t.provider.last_sample_at?Q(t.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${t.provider.checked_at?Q(t.provider.checked_at):"n/a"}</span>
                </div>
                ${t.provider.detail?o`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?o`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(b=>o`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${b.active_slots} active</strong>
                              <span class="command-chip">${Q(b.timestamp)}</span>
                            </div>
                            <div class="command-card-sub">slots ${b.active_slot_ids.join(", ")||"none"}</div>
                          </div>
                        </article>
                      `)}
                    </div>`:o`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:o`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">막힘 요인</div>
          ${t&&t.blockers.length>0?o`<div class="command-card-stack">
                ${t.blockers.map(b=>o`<${xp} blocker=${b} />`)}
              </div>`:o`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">최근 메시지</div>
          ${t&&t.recent_messages.length>0?o`<div class="command-trace-stack">
                ${t.recent_messages.map(b=>o`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${b.from}</strong>
                        <span class="command-chip">${Q(b.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${b.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${b.content}</pre>
                  </article>
                `)}
              </div>`:o`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">최근 트레이스 이벤트</div>
          ${t&&t.recent_trace_events.length>0?o`<div class="command-trace-stack">
                ${t.recent_trace_events.map(b=>o`<${ur} event=${b} />`)}
              </div>`:o`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function Cp(){const t=Pt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Operations</div>
        ${t&&t.operations.operations.length>0?o`<div class="command-card-stack">
              ${t.operations.operations.map(e=>o`<${gp} card=${e} />`)}
            </div>`:o`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title">Detachments</div>
        ${t&&t.detachments.detachments.length>0?o`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>o`<${$p} card=${e} />`)}
            </div>`:o`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function wp(){var l,d,_,p,f,g,$,y,A,N,M,E,L,R,u,q;const t=ho.value,e=(t==null?void 0:t.operations)??[],n=Ae.value,s=e.find(K=>K.operation.operation_id===n)??e[0]??null,a=((l=s==null?void 0:s.operation.chain)==null?void 0:l.run_id)??null,i=((d=vn.value)==null?void 0:d.run)??(s==null?void 0:s.preview_run)??null,r=!((_=vn.value)!=null&&_.run)&&!!(s!=null&&s.preview_run);return tt(()=>{a?xu(a):ku()},[a]),o`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title">Chains</div>
        <article class="command-guide-card ${Bt(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${Bt(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(t==null?void 0:t.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((p=t==null?void 0:t.summary)==null?void 0:p.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((f=t==null?void 0:t.summary)==null?void 0:f.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((g=t==null?void 0:t.summary)==null?void 0:g.recent_failures)??0}</span>
            <span>Last Event</span><span>${Q(($=t==null?void 0:t.summary)==null?void 0:$.last_history_event_at)}</span>
          </div>
        </article>

        ${_s.value?o`<div class="empty-state error">${_s.value}</div>`:null}

        ${Wa.value&&!t?o`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?o`
                <div class="command-chain-list">
                  ${e.map(K=>o`
                    <${vp}
                      overlay=${K}
                      selected=${(s==null?void 0:s.operation.operation_id)===K.operation.operation_id}
                      onSelect=${()=>ko(K.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(K=>o`<${_p} item=${K} />`)}
                </div>
              `:o`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title">Chain Detail</div>
        ${s?o`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${Bt((y=s.operation.chain)==null?void 0:y.status)}">
                    ${((A=s.operation.chain)==null?void 0:A.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((N=s.operation.chain)==null?void 0:N.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((M=s.operation.chain)==null?void 0:M.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${Hs((E=s.runtime)==null?void 0:E.progress)}</span>
                  <span>Elapsed</span><span>${Ou((L=s.runtime)==null?void 0:L.elapsed_sec)}</span>
                  <span>Updated</span><span>${Q(((R=s.operation.chain)==null?void 0:R.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(u=s.operation.chain)!=null&&u.goal?o`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?o`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((q=s.operation.chain)==null?void 0:q.chain_id)??"graph"}</span>
                      </div>
                      <${mp} source=${s.mermaid} />
                    </div>
                  `:o`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(i==null?void 0:i.success)===!1?"bad":"ok"}">
                    ${i?i.success===!1?"failed":r?"preview":"captured":"pending"}
                  </span>
                </div>
                ${fs.value?o`<div class="empty-state">Loading run detail…</div>`:_n.value?o`<div class="empty-state error">${_n.value}</div>`:i&&i.nodes.length>0?o`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${i.chain_id}</span>
                            <span>Run</span><span>${i.run_id??"preview only"}</span>
                            <span>Duration</span><span>${i.duration_ms!=null?`${i.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${i.nodes.length}</span>
                          </div>
                          ${r?o`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${i.nodes.map(K=>o`<${fp} node=${K} />`)}
                          </div>
                        `:o`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:o`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function Tp(){const t=Pt.value;return o`
    <section class="card command-section">
      <div class="card-title">Topology</div>
      ${t&&t.topology.units.length>0?o`${t.topology.units.map(e=>o`<${dr} node=${e} />`)}`:o`<div class="empty-state">No command topology projected yet.</div>`}
    </section>
  `}function Np(){const t=Pt.value;return o`
    <section class="card command-section">
      <div class="card-title">Alerts</div>
      ${t&&t.alerts.alerts.length>0?o`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>o`<${hp} alert=${e} />`)}
          </div>`:o`<div class="empty-state">No command-plane alerts right now.</div>`}
    </section>
  `}function Rp(){const t=Pt.value;return o`
    <section class="card command-section">
      <div class="card-title">Trace</div>
      ${t&&t.traces.events.length>0?o`<div class="command-trace-stack">
            ${t.traces.events.map(e=>o`<${ur} event=${e} />`)}
          </div>`:o`<div class="empty-state">No recent trace events.</div>`}
    </section>
  `}function Pp(){const t=Pt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Approval Queue</div>
        ${t&&t.decisions.decisions.length>0?o`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>o`<${yp} decision=${e} />`)}
            </div>`:o`<div class="empty-state">No approval queue items.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Unit Controls</div>
        ${t&&t.capacity.capacity.length>0?o`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>o`<${bp} row=${e} />`)}
            </div>`:o`<div class="empty-state">No capacity rows projected.</div>`}
      </section>
    </div>
  `}function Lp(){if(gt.value==="summary")return o`<${up} />`;if(gt.value==="swarm")return o`<${Ap} />`;if(!Pt.value)return o`<${pp} />`;switch(gt.value){case"chains":return o`<${wp} />`;case"topology":return o`<${Tp} />`;case"alerts":return o`<${Np} />`;case"trace":return o`<${Rp} />`;case"control":return o`<${Pp} />`;case"operations":default:return o`<${Cp} />`}}function Mp(){return tt(()=>{de(),Ut(),Su(),Dt()},[]),tt(()=>{if(Z.value.tab!=="command")return;const t=Z.value.params.surface,e=Z.value.params.operation;Ku(t)?fn(t):t||fn("summary"),e&&ko(e),t==="swarm"&&Dt()},[Z.value.tab,Z.value.params.surface,Z.value.params.operation,Z.value.params.operation_id,Z.value.params.run_id]),tt(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,de(),Ut(),gt.value==="swarm"&&Dt()},250))},n=new EventSource(Uu()),s=qu.map(a=>{const i=()=>e();return n.addEventListener(a,i),{type:a,handler:i}});return n.onerror=()=>{e()},()=>{s.forEach(({type:a,handler:i})=>{n.removeEventListener(a,i)}),n.close(),t&&window.clearTimeout(t)}},[]),o`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면 / Command Plane</h2>
          <p>Operations-first command surface for company → platoon → squad → agent orchestration, approvals, alerts, and traceability.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Wt(()=>Tu())}}
            disabled=${et("dispatch:tick")}
          >
            ${et("dispatch:tick")?"Reconciling…":"Run Tick"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{de(),Ut(),Dt()}}
            disabled=${ls.value}
          >
            ${ls.value?"Refreshing…":"Refresh"}
          </button>
        </div>
      </div>

      ${ds.value?o`<div class="empty-state error">${ds.value}</div>`:null}
      ${ps.value?o`<div class="empty-state error">${ps.value}</div>`:null}
      <${cp} />
      <${Lp} />
    </section>
  `}let Dp=0;const re=m([]);function w(t,e="success",n=4e3){const s=++Dp;re.value=[...re.value,{id:s,message:t,type:e}],setTimeout(()=>{re.value=re.value.filter(a=>a.id!==s)},n)}function Ip(t){re.value=re.value.filter(e=>e.id!==t)}function Ep(){const t=re.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Ip(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Rn=m(null),pr=m(null),jt=m(null),gs=m(!1),Vt=m(null),gn=m(!1),Pe=m(null),U=m(!1),$s=m([]);let zp=1;function j(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function k(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function J(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Bs(t){return typeof t=="boolean"?t:void 0}function Op(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Ct(t,e=[]){if(Array.isArray(t))return t;if(!j(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function jp(t){return j(t)?{id:k(t.id),seq:J(t.seq),from:k(t.from)??k(t.from_agent)??"system",content:k(t.content)??"",timestamp:k(t.timestamp)??new Date().toISOString(),type:k(t.type)}:null}function Fp(t){return j(t)?{room_id:k(t.room_id),current_room:k(t.current_room)??k(t.room),project:k(t.project),cluster:k(t.cluster),paused:Bs(t.paused),pause_reason:k(t.pause_reason)??null,paused_by:k(t.paused_by)??null,paused_at:k(t.paused_at)??null}:{}}function Ho(t){if(!j(t))return;const e=Object.entries(t).map(([n,s])=>{const a=k(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function mr(t){if(!j(t))return null;const e=k(t.kind),n=k(t.summary),s=k(t.target_type);return!e||!n||!s?null:{kind:e,severity:k(t.severity)??"warn",summary:n,target_type:s,target_id:k(t.target_id)??null,actor:k(t.actor)??null,evidence:t.evidence}}function vr(t){if(!j(t))return null;const e=k(t.action_type),n=k(t.target_type),s=k(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:k(t.target_id)??null,severity:k(t.severity)??"warn",reason:s,confirm_required:Bs(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function qp(t){return j(t)?{actor:k(t.actor)??null,spawn_agent:k(t.spawn_agent)??null,spawn_role:k(t.spawn_role)??null,spawn_model:k(t.spawn_model)??null,worker_class:k(t.worker_class)??null,parent_actor:k(t.parent_actor)??null,capsule_mode:k(t.capsule_mode)??null,runtime_pool:k(t.runtime_pool)??null,lane_id:k(t.lane_id)??null,controller_level:k(t.controller_level)??null,control_domain:k(t.control_domain)??null,supervisor_actor:k(t.supervisor_actor)??null,model_tier:k(t.model_tier)??null,task_profile:k(t.task_profile)??null,risk_level:k(t.risk_level)??null,routing_confidence:J(t.routing_confidence)??null,routing_reason:k(t.routing_reason)??null,status:k(t.status)??"unknown",turn_count:J(t.turn_count)??0,empty_note_turn_count:J(t.empty_note_turn_count)??0,has_turn:Bs(t.has_turn)??!1,last_turn_ts_iso:k(t.last_turn_ts_iso)??null}:null}function Kp(t){if(!j(t))return null;const e=k(t.session_id);return e?{session_id:e,goal:k(t.goal),status:k(t.status),health:k(t.health),scale_profile:k(t.scale_profile),control_profile:k(t.control_profile),planned_worker_count:J(t.planned_worker_count),active_agent_count:J(t.active_agent_count),last_turn_age_sec:J(t.last_turn_age_sec)??null,attention_count:J(t.attention_count),recommended_action_count:J(t.recommended_action_count),top_attention:mr(t.top_attention),top_recommendation:vr(t.top_recommendation)}:null}function _r(t){const e=j(t)?t:{};return{trace_id:k(e.trace_id),target_type:k(e.target_type)??"room",target_id:k(e.target_id)??null,health:k(e.health),swarm_status:j(e.swarm_status)?e.swarm_status:void 0,attention_items:Ct(e.attention_items).map(mr).filter(n=>n!==null),recommended_actions:Ct(e.recommended_actions).map(vr).filter(n=>n!==null),session_cards:Ct(e.session_cards).map(Kp).filter(n=>n!==null),worker_cards:Ct(e.worker_cards).map(qp).filter(n=>n!==null)}}function Hp(t){if(!j(t))return null;const e=j(t.status)?t.status:void 0,n=j(t.summary)?t.summary:j(e==null?void 0:e.summary)?e.summary:void 0,s=j(t.session)?t.session:j(e==null?void 0:e.session)?e.session:void 0,a=k(t.session_id)??k(n==null?void 0:n.session_id)??k(s==null?void 0:s.session_id);if(!a)return null;const i=Ho(t.report_paths)??Ho(e==null?void 0:e.report_paths),r=Ct(t.recent_events,["events"]).filter(j);return{session_id:a,status:k(t.status)??k(n==null?void 0:n.status)??k(s==null?void 0:s.status),progress_pct:J(t.progress_pct)??J(n==null?void 0:n.progress_pct),elapsed_sec:J(t.elapsed_sec)??J(n==null?void 0:n.elapsed_sec),remaining_sec:J(t.remaining_sec)??J(n==null?void 0:n.remaining_sec),done_delta_total:J(t.done_delta_total)??J(n==null?void 0:n.done_delta_total),summary:n,team_health:j(t.team_health)?t.team_health:j(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:j(t.communication_metrics)?t.communication_metrics:j(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:j(t.orchestration_state)?t.orchestration_state:j(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:j(t.cascade_metrics)?t.cascade_metrics:j(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:s,recent_events:r}}function Up(t){if(!j(t))return null;const e=k(t.name);if(!e)return null;const n=j(t.context)?t.context:void 0;return{name:e,agent_name:k(t.agent_name),status:k(t.status),autonomy_level:k(t.autonomy_level),context_ratio:J(t.context_ratio)??J(n==null?void 0:n.context_ratio),generation:J(t.generation),active_goal_ids:Op(t.active_goal_ids),last_autonomous_action_at:k(t.last_autonomous_action_at)??null,last_turn_ago_s:J(t.last_turn_ago_s),model:k(t.model)??k(t.active_model)??k(t.primary_model)}}function Bp(t){if(!j(t))return null;const e=k(t.confirm_token)??k(t.token);return e?{confirm_token:e,actor:k(t.actor),action_type:k(t.action_type),target_type:k(t.target_type),target_id:k(t.target_id)??null,delegated_tool:k(t.delegated_tool),created_at:k(t.created_at),preview:t.preview}:null}function Wp(t){const e=j(t)?t:{};return{room:Fp(e.room),sessions:Ct(e.sessions,["items","sessions"]).map(Hp).filter(n=>n!==null),keepers:Ct(e.keepers,["items","keepers"]).map(Up).filter(n=>n!==null),recent_messages:Ct(e.recent_messages,["messages"]).map(jp).filter(n=>n!==null),pending_confirms:Ct(e.pending_confirms,["items","confirms"]).map(Bp).filter(n=>n!==null),available_actions:Ct(e.available_actions,["actions"]).filter(j).map(n=>({action_type:k(n.action_type)??"unknown",target_type:k(n.target_type)??"unknown",description:k(n.description),confirm_required:Bs(n.confirm_required)}))}}function zn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Uo(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function hs(t){$s.value=[{...t,id:zp++,at:new Date().toISOString()},...$s.value].slice(0,20)}function fr(t){return t.confirm_required?zn(t.preview)||"Confirmation required":zn(t.result)||zn(t.executed_action)||zn(t.delegated_tool_result)||t.status}async function pe(){gs.value=!0,Vt.value=null;try{const t=await Rl();Rn.value=Wp(t)}catch(t){Vt.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{gs.value=!1}}async function Yt(){gn.value=!0,Pe.value=null;try{const t=await wi({targetType:"room"});pr.value=_r(t)}catch(t){Pe.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{gn.value=!1}}async function $n(t){if(!t){jt.value=null;return}gn.value=!0,Pe.value=null;try{const e=await wi({targetType:"team_session",targetId:t,includeWorkers:!0});jt.value=_r(e)}catch(e){Pe.value=e instanceof Error?e.message:"Failed to load session digest"}finally{gn.value=!1}}async function Gp(t){var e;U.value=!0,Vt.value=null;try{const n=await wn(t);return hs({actor:t.actor,action_type:t.action_type,target_label:Uo(t),outcome:n.confirm_required?"preview":"executed",message:fr(n),delegated_tool:n.delegated_tool}),await pe(),await Yt(),(e=jt.value)!=null&&e.target_id&&await $n(jt.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw Vt.value=s,hs({actor:t.actor,action_type:t.action_type,target_label:Uo(t),outcome:"error",message:s}),n}finally{U.value=!1}}async function Jp(t,e){var n;U.value=!0,Vt.value=null;try{const s=await jl(t,e);return hs({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:fr(s),delegated_tool:s.delegated_tool}),await pe(),await Yt(),(n=jt.value)!=null&&n.target_id&&await $n(jt.value.target_id),s}catch(s){const a=s instanceof Error?s.message:"Operator confirmation failed";throw Vt.value=a,hs({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),s}finally{U.value=!1}}_d(()=>{var t;pe(),Yt(),(t=jt.value)!=null&&t.target_id&&$n(jt.value.target_id)});const gr="masc_dashboard_agent_name";function Vp(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(gr))==null?void 0:s.trim())||"dashboard"}const Ws=m(Vp()),Ge=m(""),Ga=m("Operator pause"),Je=m(""),ys=m(""),Ja=m("2"),bs=m(""),Ce=m("note"),ks=m(""),xs=m(""),Ss=m(""),Va=m("2"),Ya=m("Operator stop request"),Qa=m(""),Ve=m("");function Yp(t){const e=t.trim()||"dashboard";Ws.value=e,localStorage.setItem(gr,e)}function ta(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Qp(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function hn(t){return typeof t=="string"?t.trim().toLowerCase():""}function Xp(t){var s;const e=hn(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=hn((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function Bo(t){const e=hn(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function Wo(t){return t.some(e=>hn(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function Zp(t){return t.target_type==="team_session"}function tm(t){return t.target_type==="keeper"}async function ve(t){const e=Ws.value.trim()||"dashboard";try{const n=await Gp({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?w("Confirmation queued","warning"):w(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";return w(s,"error"),null}}async function Go(){const t=Ge.value.trim();if(!t)return;await ve({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(Ge.value="")}async function em(){await ve({action_type:"room_pause",target_type:"room",payload:{reason:Ga.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function nm(){await ve({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function sm(){const t=Je.value.trim();if(!t)return;await ve({action_type:"task_inject",target_type:"room",payload:{title:t,description:ys.value.trim()||"Injected from Ops tab",priority:Number.parseInt(Ja.value,10)||2},successMessage:"Task injection submitted"})&&(Je.value="",ys.value="")}async function am(){var i;const t=Rn.value,e=bs.value||((i=t==null?void 0:t.sessions[0])==null?void 0:i.session_id)||"";if(!e){w("Select a team session first","warning");return}const n={turn_kind:Ce.value},s=ks.value.trim();s&&(n.message=s),Ce.value==="task"&&(n.task_title=xs.value.trim()||"Operator injected task",n.task_description=Ss.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(Va.value,10)||2),await ve({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(ks.value="",Ce.value==="task"&&(xs.value="",Ss.value=""))}async function om(){var n;const t=Rn.value,e=bs.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){w("Select a team session first","warning");return}await ve({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Ya.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function im(){var a;const t=Rn.value,e=Qa.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=Ve.value.trim();if(!e){w("Select a keeper first","warning");return}if(!n)return;await ve({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(Ve.value="")}async function Jo(t){const e=Ws.value.trim()||"dashboard";try{await Jp(e,t),w("Confirmation executed","success")}catch(n){const s=n instanceof Error?n.message:"Confirmation failed";w(s,"error")}}function Vo(){var M,E,L,R;const t=Rn.value,e=pr.value,n=jt.value,s=(t==null?void 0:t.room)??{},a=(t==null?void 0:t.sessions)??[],i=(t==null?void 0:t.keepers)??[],r=(t==null?void 0:t.pending_confirms)??[],l=(t==null?void 0:t.recent_messages)??[],d=a.find(u=>u.session_id===bs.value)??a[0]??null,_=i.find(u=>u.name===Qa.value)??i[0]??null,p=(e==null?void 0:e.attention_items)??[],f=p.filter(Zp),g=p.filter(tm),$=a.filter(u=>Xp(u)!=="ok"),y=i.filter(u=>Bo(u)!=="ok"),A=l.slice(0,5);tt(()=>{Yt()},[]),tt(()=>{const u=(d==null?void 0:d.session_id)??null;$n(u)},[d==null?void 0:d.session_id]);const N=[{key:"room",label:"Room Gate",value:s.paused?"Paused":"Open",detail:s.paused?`Resume gate armed${s.pause_reason?` · ${s.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:s.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:r.length,detail:r.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:r.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:f.length>0?f.length:a.length,detail:f.length>0?((M=f[0])==null?void 0:M.summary)??"Team sessions need steering, stop, or checkpoint attention":a.length===0?"No supervised team session is active right now":"No session-level attention items are currently active",tone:f.length>0?Wo(f):a.length===0?"warn":$.some(u=>hn(u.status)==="paused")?"bad":$.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:g.length>0?g.length:y.length,detail:g.length>0?((E=g[0])==null?void 0:E.summary)??"At least one keeper needs direct intervention":y.length>0?"At least one keeper is stale, offline, or missing telemetry":"Keepers are available for direct intervention",tone:g.length>0?Wo(g):y.some(u=>Bo(u)==="bad")?"bad":y.length>0?"warn":"ok"}];return o`
    <section class="ops-view">
      <div class="ops-header card">
      <div>
          <div class="card-title">Intervene</div>
          <h2 class="ops-heading">room, session, keeper를 위한 개입 워크스페이스</h2>
          <p class="ops-subheading">
            즉시 실행 가능한 액션만 모읍니다. 위험한 변경은 confirmation token 뒤에 둡니다.
          </p>
        </div>
        <div class="ops-toolbar">
          <label class="control-label" for="ops-actor">Actor</label>
          <input
            id="ops-actor"
            class="control-input ops-actor-input"
            type="text"
            value=${Ws.value}
            onInput=${u=>Yp(u.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{pe(),Yt(),$n((d==null?void 0:d.session_id)??null)}}
            disabled=${gs.value||U.value}
          >
            ${gs.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${Vt.value?o`
        <section class="ops-banner error">${Vt.value}</section>
      `:null}
      ${Pe.value?o`
        <section class="ops-banner error">${Pe.value}</section>
      `:null}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <p class="monitor-subheadline">지금 어디를 먼저 손대야 하는지, 그리고 어떤 표면으로 내려가야 하는지를 여기서 먼저 판단합니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${N.map(u=>o`
            <div key=${u.key} class="ops-priority-card ${u.tone}">
              <span class="ops-priority-label">${u.label}</span>
              <strong>${u.value}</strong>
              <div class="ops-priority-detail">${u.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title">Recommended Actions</div>
        <p class="ops-context-note">Digest-backed recommendations are the smallest next interventions the backend currently suggests.</p>
        ${gn.value&&!e?o`
          <div class="ops-empty">Loading operator digest…</div>
        `:e&&e.recommended_actions.length>0?o`
          <div class="ops-log-list">
            ${e.recommended_actions.map(u=>o`
              <article key=${`${u.action_type}:${u.target_type}:${u.target_id??"room"}`} class="ops-log-entry ${u.severity}">
                <div class="ops-log-head">
                  <strong>${u.action_type}</strong>
                  <span>${u.target_type}${u.target_id?`:${u.target_id}`:""}</span>
                  <span>${u.confirm_required?"confirm":"direct"}</span>
                </div>
                <div class="ops-log-body">${u.reason}</div>
              </article>
            `)}
          </div>
        `:o`
          <div class="ops-empty">No digest recommendations are active right now.</div>
        `}
      </section>

      ${r.length>0?o`
        <section class="card ops-confirmations">
          <div class="card-title">Pending Confirmations</div>
          <p class="ops-context-note">Only previewed actions that still need an explicit operator confirmation stay here.</p>
          <div class="ops-confirmation-list">
            ${r.map(u=>o`
              <article key=${u.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${u.action_type??"unknown"}</strong>
                  <span>${u.target_type??"target"}${u.target_id?`:${u.target_id}`:""}</span>
                  <span>${u.delegated_tool??"delegated tool pending"}</span>
                </div>
                ${u.preview?o`<pre class="ops-code-block">${ta(u.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{Jo(u.confirm_token)}} disabled=${U.value}>
                    Confirm
                  </button>
                  <span class="ops-token">${u.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        </section>
      `:null}

      <div class="ops-workbench">
        <div class="ops-column">
          <section class="card ops-panel">
            <div class="card-title">Priority Queue</div>
            ${r.length>0?o`
              <div class="ops-confirmation-list">
                ${r.map(u=>o`
                  <article key=${u.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${u.action_type??"unknown"}</strong>
                      <span>${u.target_type??"target"}${u.target_id?`:${u.target_id}`:""}</span>
                      <span>${u.delegated_tool??"delegated tool pending"}</span>
                    </div>
                    ${u.preview?o`<pre class="ops-code-block compact">${ta(u.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{Jo(u.confirm_token)}} disabled=${U.value}>
                        Confirm
                      </button>
                      <span class="ops-token">${u.confirm_token}</span>
                    </div>
                  </article>
                `)}
              </div>
            `:o`<div class="ops-empty">No pending confirmations.</div>`}
          </section>

          <section class="card ops-panel">
            <div class="card-title">Operator Log</div>
            <div class="ops-log-list">
              ${$s.value.length===0?o`
                <div class="ops-empty">No operator actions in this session yet.</div>
              `:$s.value.map(u=>o`
                <article key=${u.id} class="ops-log-entry ${u.outcome}">
                  <div class="ops-log-head">
                    <strong>${u.action_type}</strong>
                    <span>${u.target_label}</span>
                    <span>${u.at}</span>
                  </div>
                  <div class="ops-log-body">${u.message}</div>
                </article>
              `)}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title">Room Feed</div>
            <p class="ops-context-note">Recent chatter stays available for operator context, but it is secondary to the intervention queue.</p>
            ${A.length>0?o`
              <div class="ops-feed-list">
                ${A.map(u=>o`
                  <article key=${u.seq??u.id??u.timestamp} class="ops-feed-item">
                    <div class="ops-feed-meta">
                      <strong>${u.from}</strong>
                      <span>${u.timestamp}</span>
                    </div>
                    <div class="ops-feed-content">${u.content}</div>
                  </article>
                `)}
              </div>
            `:o`<div class="ops-empty">No recent room messages.</div>`}
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel">
            <div class="card-title">Session Queue</div>
            <p class="ops-context-note">Select the session that needs steering. This queue should answer which run is hot, paused, or drifting.</p>
            <div class="ops-entity-list">
              ${a.length===0?o`<div class="ops-empty">No team sessions available.</div>`:a.map(u=>{var q;return o`
                <button
                  key=${u.session_id}
                  class="ops-entity-card ${(d==null?void 0:d.session_id)===u.session_id?"active":""}"
                  onClick=${()=>{bs.value=u.session_id}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${u.session_id}</strong>
                    <span class="status-badge ${u.status??"idle"}">${u.status??"unknown"}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round(u.progress_pct??0)}%</span>
                    <span>${u.done_delta_total??0} done</span>
                    <span>${(q=u.team_health)!=null&&q.status?String(u.team_health.status):"health n/a"}</span>
                  </div>
                </button>
              `})}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title">Session Digest</div>
            <p class="ops-context-note">Worker cards and attention items come from operator digest, not the lighter snapshot.</p>
            ${d&&n?o`
              <div class="ops-log-list">
                ${n.attention_items.length>0?n.attention_items.map(u=>o`
                  <article key=${`${u.kind}:${u.target_id??"session"}`} class="ops-log-entry ${u.severity}">
                    <div class="ops-log-head">
                      <strong>${u.kind}</strong>
                      <span>${u.target_type}${u.target_id?`:${u.target_id}`:""}</span>
                    </div>
                    <div class="ops-log-body">${u.summary}</div>
                  </article>
                `):o`<div class="ops-empty">No session-specific attention items.</div>`}
                ${n.worker_cards.length>0?n.worker_cards.map(u=>o`
                  <article key=${`${u.actor??u.spawn_role??"worker"}:${u.spawn_agent??"runtime"}`} class="ops-log-entry">
                    <div class="ops-log-head">
                      <strong>${u.actor??u.spawn_role??"worker"}</strong>
                      <span>${u.status}</span>
                      <span>${u.spawn_agent??u.runtime_pool??"runtime n/a"}</span>
                    </div>
                    <div class="ops-log-body">
                      ${u.worker_class??"worker"}${u.lane_id?` · ${u.lane_id}`:""}${u.routing_reason?` · ${u.routing_reason}`:""}
                    </div>
                  </article>
                `):null}
              </div>
            `:o`
              <div class="ops-empty">Select a team session to load digest-backed worker cards.</div>
            `}
          </section>

          <section class="card ops-panel">
            <div class="card-title">Keeper Queue</div>
            <p class="ops-context-note">Keepers are long-lived operators. Pick one when you need recovery, course correction, or a direct probe.</p>
            <div class="ops-entity-list">
              ${i.length===0?o`<div class="ops-empty">No keepers available.</div>`:i.map(u=>o`
                <button
                  key=${u.name}
                  class="ops-entity-card ${(_==null?void 0:_.name)===u.name?"active":""}"
                  onClick=${()=>{Qa.value=u.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${u.name}</strong>
                    <span class="status-badge ${u.status??"idle"}">${u.status??"unknown"}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${u.model??"model n/a"}</span>
                    <span>${typeof u.context_ratio=="number"?`${Math.round(u.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                    <span>${Qp(u.last_turn_ago_s)}</span>
                  </div>
                </button>
              `)}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title">Available Actions</div>
            <p class="ops-context-note">These are the actions the backend currently advertises, even if they are not all wired into inline controls yet.</p>
            <div class="ops-log-list">
              ${(L=t==null?void 0:t.available_actions)!=null&&L.length?t.available_actions.map(u=>o`
                    <article key=${`${u.action_type}:${u.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${u.action_type}</strong>
                        <span>${u.target_type}</span>
                        <span>${u.confirm_required?"confirm":"direct"}</span>
                      </div>
                      <div class="ops-log-body">${u.description??"No description"}</div>
                    </article>
                  `):o`<div class="ops-empty">No available action descriptors.</div>`}
            </div>
          </section>
        </div>

        <div class="ops-column ops-studio-column">
          <section class="card ops-panel ops-studio-panel">
            <div class="card-title">Action Studio</div>
            <p class="ops-context-note">All write controls are centralized here. Room actions stay global; session and keeper actions always target the currently selected entity.</p>

            <div class="ops-studio-group">
              <div class="ops-section-head">Room Gate</div>
              <div class="ops-stat-grid">
                <div class="ops-stat">
                  <span>Room</span>
                  <strong>${s.current_room??s.room_id??"default"}</strong>
                </div>
                <div class="ops-stat">
                  <span>Project</span>
                  <strong>${s.project??"n/a"}</strong>
                </div>
                <div class="ops-stat">
                  <span>Cluster</span>
                  <strong>${s.cluster??"n/a"}</strong>
                </div>
                <div class="ops-stat ${s.paused?"warn":"ok"}">
                  <span>Status</span>
                  <strong>${s.paused?"Paused":"Running"}</strong>
                </div>
              </div>

              <label class="control-label" for="ops-broadcast">Room Broadcast</label>
              <div class="control-row">
                <input
                  id="ops-broadcast"
                  class="control-input"
                  type="text"
                  placeholder="@agent or room-wide operator update"
                  value=${Ge.value}
                  onInput=${u=>{Ge.value=u.target.value}}
                  onKeyDown=${u=>{u.key==="Enter"&&Go()}}
                  disabled=${U.value}
                />
                <button class="control-btn" onClick=${()=>{Go()}} disabled=${U.value||Ge.value.trim()===""}>
                  Send
                </button>
              </div>

              <label class="control-label" for="ops-pause-reason">Pause or Resume</label>
              <div class="control-row ops-split-row">
                <input
                  id="ops-pause-reason"
                  class="control-input"
                  type="text"
                  value=${Ga.value}
                  onInput=${u=>{Ga.value=u.target.value}}
                  disabled=${U.value}
                />
                <button class="control-btn ghost" onClick=${()=>{em()}} disabled=${U.value}>
                  Pause
                </button>
                <button class="control-btn ghost" onClick=${()=>{nm()}} disabled=${U.value}>
                  Resume
                </button>
              </div>

              <div class="ops-section-head">Inject Work</div>
              <input
                class="control-input"
                type="text"
                placeholder="Task title"
                value=${Je.value}
                onInput=${u=>{Je.value=u.target.value}}
                disabled=${U.value}
              />
              <textarea
                class="control-textarea"
                rows=${3}
                placeholder="Task description"
                value=${ys.value}
                onInput=${u=>{ys.value=u.target.value}}
                disabled=${U.value}
              ></textarea>
              <div class="control-row ops-split-row">
                <select
                  class="control-input ops-select"
                  value=${Ja.value}
                  onChange=${u=>{Ja.value=u.target.value}}
                  disabled=${U.value}
                >
                  <option value="1">P1</option>
                  <option value="2">P2</option>
                  <option value="3">P3</option>
                  <option value="4">P4</option>
                  <option value="5">P5</option>
                </select>
                <button class="control-btn" onClick=${()=>{sm()}} disabled=${U.value||Je.value.trim()===""}>
                  Inject
                </button>
              </div>
            </div>

            <div class="ops-studio-group">
              <div class="ops-section-head">Selected Session</div>
              ${d?o`
                <div class="ops-detail-card">
                  <div class="ops-detail-title">${d.session_id}</div>
                  <div class="ops-detail-meta">
                    <span>Status: ${d.status??"unknown"}</span>
                    <span>Elapsed: ${d.elapsed_sec??0}s</span>
                    <span>Remaining: ${d.remaining_sec??0}s</span>
                  </div>
                  ${d.recent_events&&d.recent_events.length>0?o`
                    <pre class="ops-code-block compact">${ta(d.recent_events.slice(-3))}</pre>
                  `:null}
                </div>
              `:o`<div class="ops-empty">Select a team session to edit notes, inject tasks, or stop the run.</div>`}

              <label class="control-label" for="ops-turn-kind">Session Action</label>
              <div class="control-row ops-split-row">
                <select
                  id="ops-turn-kind"
                  class="control-input ops-select"
                  value=${Ce.value}
                  onChange=${u=>{Ce.value=u.target.value}}
                  disabled=${U.value||!d}
                >
                  <option value="note">Note</option>
                  <option value="broadcast">Broadcast</option>
                  <option value="task">Task</option>
                  <option value="checkpoint">Checkpoint</option>
                </select>
                <button class="control-btn" onClick=${()=>{am()}} disabled=${U.value||!d}>
                  Apply
                </button>
              </div>
              <textarea
                class="control-textarea"
                rows=${3}
                placeholder="Session message"
                value=${ks.value}
                onInput=${u=>{ks.value=u.target.value}}
                disabled=${U.value||!d}
              ></textarea>
              ${Ce.value==="task"?o`
                <input
                  class="control-input"
                  type="text"
                  placeholder="Injected task title"
                  value=${xs.value}
                  onInput=${u=>{xs.value=u.target.value}}
                  disabled=${U.value||!d}
                />
                <textarea
                  class="control-textarea"
                  rows=${2}
                  placeholder="Injected task description"
                  value=${Ss.value}
                  onInput=${u=>{Ss.value=u.target.value}}
                  disabled=${U.value||!d}
                ></textarea>
                <select
                  class="control-input ops-select"
                  value=${Va.value}
                  onChange=${u=>{Va.value=u.target.value}}
                  disabled=${U.value||!d}
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
                  value=${Ya.value}
                  onInput=${u=>{Ya.value=u.target.value}}
                  disabled=${U.value||!d}
                />
                <button class="control-btn ghost" onClick=${()=>{om()}} disabled=${U.value||!d}>
                  Stop
                </button>
              </div>
            </div>

            <div class="ops-studio-group">
              <div class="ops-section-head">Selected Keeper</div>
              ${_?o`
                <div class="ops-detail-card">
                  <div class="ops-detail-title">${_.name}</div>
                  <div class="ops-detail-meta">
                    <span>Autonomy: ${_.autonomy_level??"n/a"}</span>
                    <span>Generation: ${_.generation??0}</span>
                    <span>Goals: ${((R=_.active_goal_ids)==null?void 0:R.length)??0}</span>
                  </div>
                </div>
              `:o`<div class="ops-empty">Select a keeper to send a direct intervention.</div>`}

              <label class="control-label" for="ops-keeper-message">Keeper Message</label>
              <textarea
                id="ops-keeper-message"
                class="control-textarea"
                rows=${6}
                placeholder="Send a structured intervention or course correction"
                value=${Ve.value}
                onInput=${u=>{Ve.value=u.target.value}}
                disabled=${U.value||!_}
              ></textarea>
              <div class="control-row">
                <button class="control-btn" onClick=${()=>{im()}} disabled=${U.value||!_||Ve.value.trim()===""}>
                  Send Keeper Message
                </button>
              </div>
            </div>
          </section>
        </div>
      </div>
    </section>
  `}function rm(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function V({timestamp:t}){const e=rm(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}function lm({text:t}){if(!t)return null;const e=cm(t);return o`<div class="markdown-content">${e}</div>`}function cm(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],l=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(o`<pre><code class=${l?`language-${l}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],l=a.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const _=e[s].replace("</think>","").trim();_&&r.push(_),s++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${ea(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${ea(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${ea(i.join(`
`))}</p>`)}return n}function ea(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Ue=m("posts"),Xa=m([]),Za=m([]),Ye=m(""),As=m(!1),Qe=m(!1),yn=m(""),Cs=m(null),yt=m(null),to=m(!1),Ht=m(null),Qn=m(null);async function Gs(){As.value=!0,yn.value="";try{const[t,e]=await Promise.all([kc(),xc()]);Xa.value=t,Za.value=e,Ht.value=!0,Qn.value=Date.now()}catch(t){yn.value=t instanceof Error?t.message:"Failed to load council data",Ht.value=!1}finally{As.value=!1}}md(Gs);async function Yo(){const t=Ye.value.trim();if(t){Qe.value=!0;try{const e=await Sc(t);Ye.value="",w(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Gs()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";w(n,"error")}finally{Qe.value=!1}}}async function dm(t){Cs.value=t,to.value=!0,yt.value=null;try{yt.value=await Ac(t)}catch(e){yn.value=e instanceof Error?e.message:"Failed to load debate status",yt.value=null}finally{to.value=!1}}const $r=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Xn=m(null),Xe=m([]),ue=m(!1),le=m(null),Ze=m("");function um(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const pm=m(um()),tn=m(!1);async function So(t){le.value=t,Xn.value=null,Xe.value=[],ue.value=!0;try{const e=await Wl(t);if(le.value!==t)return;Xn.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},Xe.value=e.comments??[]}catch{le.value===t&&(Xn.value=null,Xe.value=[])}finally{le.value===t&&(ue.value=!1)}}async function Qo(t){const e=Ze.value.trim();if(e){tn.value=!0;try{await Gl(t,pm.value,e),Ze.value="",w("Comment posted","success"),await So(t),wt()}catch{w("Failed to post comment","error")}finally{tn.value=!1}}}function mm(){const t=dn.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${$r.map(e=>o`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{dn.value=e.id,wt()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${oe.value?"is-active":""}"
          onClick=${()=>{oe.value=!oe.value,wt()}}
        >
          ${oe.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${wt} disabled=${pn.value}>
          ${pn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function eo(){var e;const t=(e=me.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${V} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function hr({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function vm(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function Xo(t){return t.updated_at!==t.created_at}function no(){var n;const t=((n=$r.find(s=>s.id===dn.value))==null?void 0:n.label)??dn.value,e=De.value.length;return o`
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
        <strong>${oe.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${ja.value?o`<${V} timestamp=${ja.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function _m({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Ni(t.id,n),wt()}catch{w("Failed to vote","error")}};return o`
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
              <${hr} flair=${t.flair} />
              ${Xo(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${V} timestamp=${t.created_at} /></span>
            ${Xo(t)?o`<span>Updated <${V} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${vm(t.content)}</div>
      </div>
    </div>
  `}function fm({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${V} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function gm({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Ze.value}
        onInput=${e=>{Ze.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Qo(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${tn.value}
      />
      <button
        onClick=${()=>Qo(t)}
        disabled=${tn.value||Ze.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${tn.value?"...":"Post"}
      </button>
    </div>
  `}function $m({post:t}){le.value!==t.id&&!ue.value&&So(t.id);const e=async n=>{try{await Ni(t.id,n),wt()}catch{w("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>nt("board")}>← Back to Board</button>
      <${T} title=${o`${t.title} <${hr} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${lm} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${V} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${T} title="Comments (${ue.value?"...":Xe.value.length})">
        ${ue.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${fm} comments=${Xe.value} />`}
        <${gm} postId=${t.id} />
      <//>
    </div>
  `}function hm({debate:t}){const e=Cs.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>dm(t.id)}
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
  `}function ym({session:t}){return o`
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
  `}function yr(){return Ht.value===null||Ht.value&&!Qn.value?null:o`
    <div class="feed-health-banner ${Ht.value===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${Ht.value===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${Qn.value?o`<span class="feed-health-meta">Last sync: <${V} timestamp=${Qn.value} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function bm(){const t=Ht.value===!1;return o`
    <div>
      <${yr} />
      <${T} title="Start Debate" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Ye.value}
            onInput=${e=>{Ye.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&Yo()}}
            disabled=${Qe.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Yo}
            disabled=${Qe.value||Ye.value.trim()===""}
          >
            ${Qe.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Gs} disabled=${As.value}>
            ${As.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${yn.value?o`<div class="council-error">${yn.value}</div>`:null}
      <//>

      <${T} title="Debates" class="section">
        <div class="council-list">
          ${Xa.value.length===0?o`<div class="empty-state">${t?"No debates loaded (council feed degraded).":"No debates yet"}</div>`:Xa.value.map(e=>o`<${hm} key=${e.id} debate=${e} />`)}
        </div>
      <//>

      <${T} title=${Cs.value?`Debate Detail (${Cs.value})`:"Debate Detail"} class="section">
        ${to.value?o`<div class="loading-indicator">Loading debate detail...</div>`:yt.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${yt.value.status}</span>
                  <span>Total arguments: ${yt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${yt.value.support_count}</span>
                  <span>Oppose: ${yt.value.oppose_count}</span>
                  <span>Neutral: ${yt.value.neutral_count}</span>
                </div>
                ${yt.value.summary_text?o`<pre class="council-detail">${yt.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function km(){const t=Ht.value===!1;return o`
    <div>
      <${yr} />
      <${T} title="Voting Sessions" class="section">
        <div class="council-list">
          ${Za.value.length===0?o`<div class="empty-state">${t?"No sessions loaded (council feed degraded).":"No active sessions"}</div>`:Za.value.map(e=>o`<${ym} key=${e.id} session=${e} />`)}
        </div>
      <//>
    </div>
  `}function xm(){const t=Ue.value;return o`
    <div class="overview-sub-tabs" style="margin-bottom: 12px;">
      <button class="sub-tab-btn ${t==="posts"?"active":""}" onClick=${()=>{Ue.value="posts"}}>Posts</button>
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{Ue.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{Ue.value="voting"}}>Voting</button>
    </div>
  `}function Sm(){var s,a;const t=De.value,e=pn.value,n=((a=(s=me.value)==null?void 0:s.data_quality)==null?void 0:a.board_contract_ok)===!1;return o`
    <div>
      <${eo} />
      <${no} />
      <${mm} />
      ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
              <div class="empty-state">
                ${n?"No posts loaded (board feed degraded). Check board contract sync.":oe.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
              </div>
            `:o`<div class="board-post-list">
              ${t.map(i=>o`<${_m} key=${i.id} post=${i} />`)}
            </div>`}
    </div>
  `}function Am(){var a,i;const t=De.value,e=Z.value.postId,n=((i=(a=me.value)==null?void 0:a.data_quality)==null?void 0:i.board_contract_ok)===!1,s=Ue.value;if(tt(()=>{(s==="debates"||s==="voting")&&Gs()},[s]),e){const r=t.find(l=>l.id===e)??(le.value===e?Xn.value:null);return!r&&le.value!==e&&!ue.value&&So(e),r?o`
          <${eo} />
          <${no} />
          <${$m} post=${r} />
        `:o`
          <div>
            <${eo} />
            <${no} />
            <button class="back-btn" onClick=${()=>nt("board")}>← Back to Board</button>
            ${ue.value?o`<div class="loading-indicator">Loading post...</div>`:o`
                  <div class="empty-state">
                    ${n?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return o`
    <${xm} />
    ${s==="debates"?o`<${bm} />`:s==="voting"?o`<${km} />`:o`<${Sm} />`}
  `}const Cm=40;function wm({items:t,itemHeight:e,overscan:n=5,renderItem:s,getKey:a,className:i=""}){const r=gi(null),[l,d]=zs({start:0,end:30}),_=t.length>Cm;if(tt(()=>{if(!_)return;const $=r.current;if(!$)return;let y=!1;const A=()=>{const{scrollTop:L,clientHeight:R}=$,u=Math.max(0,Math.floor(L/e)-n),q=Math.min(t.length,Math.ceil((L+R)/e)+n);d(K=>K.start===u&&K.end===q?K:{start:u,end:q})};let N=!1;const M=()=>{N||y||(N=!0,requestAnimationFrame(()=>{y||A(),N=!1}))},E=new ResizeObserver(()=>{y||A()});return A(),$.addEventListener("scroll",M,{passive:!0}),E.observe($),()=>{y=!0,$.removeEventListener("scroll",M),E.disconnect()}},[_,t.length,e,n]),!_)return o`
      <div class=${i}>
        ${t.map(($,y)=>s($,y))}
      </div>
    `;const p=t.length*e,f=l.start*e,g=t.slice(l.start,l.end);return o`
    <div ref=${r} class=${i}>
      <div class="virtual-list-spacer" style=${{height:`${p}px`,position:"relative"}}>
        <div
          class="virtual-list-viewport"
          style=${{position:"absolute",top:0,left:0,right:0,willChange:"transform",transform:`translateY(${f}px)`}}
        >
          ${g.map(($,y)=>{const A=l.start+y;return o`<div key=${a($)}>${s($,A)}</div>`})}
        </div>
      </div>
    </div>
  `}function Tm(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function Nm(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function Rm(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const br=120,Pm=12,Lm=16,Mm=12,so=m("all"),Dm={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},Im={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function Em(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function zm(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:Tm(t),actor:Nm(t),content:Rm(t),timestamp:new Date(t.timestamp).toISOString()}}function Om(t,e){var a;const n=(a=t.assignee)==null?void 0:a.trim(),s=t.updated_at??t.created_at;return!n||!s?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:s}}function jm(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function On(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function ao(t){return t.last_heartbeat??On(t.last_turn_ago_s)??On(t.last_proactive_ago_s)??On(t.last_handoff_ago_s)??On(t.last_compaction_ago_s)}function Fm(t,e){const n=ao(t);if(!n)return null;const s=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${s}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${s}`,timestamp:n}}function xt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const oo=$t(()=>{const t=cn.value.map(Em),e=as.value.map(zm),n=[...kt.value].sort((i,r)=>xt(r.updated_at??r.created_at??0)-xt(i.updated_at??i.created_at??0)).slice(0,Pm).map(Om).filter(i=>i!==null),s=[...De.value].sort((i,r)=>xt(r.updated_at||r.created_at)-xt(i.updated_at||i.created_at)).slice(0,Lm).map(jm),a=[...Qt.value].sort((i,r)=>xt(ao(r)??0)-xt(ao(i)??0)).slice(0,Mm).map(Fm).filter(i=>i!==null);return[...t,...e,...n,...s,...a].sort((i,r)=>xt(r.timestamp)-xt(i.timestamp))}),qm=$t(()=>{const t=oo.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),Km=$t(()=>{const t=so.value;return(t==="all"?oo.value:oo.value.filter(n=>n.kind===t)).slice(0,br)}),Hm=$t(()=>{const t=ji.value,e={activeAssignedCount:0,lastActivityAt:null,lastActivityText:null};return Nt.value.map(n=>({agent:n,motion:t.get(n.name.trim().toLowerCase())??e})).sort((n,s)=>{const a=s.motion.activeAssignedCount-n.motion.activeAssignedCount;return a!==0?a:xt(s.motion.lastActivityAt??0)-xt(n.motion.lastActivityAt??0)})});function Um(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function qe({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function Bm({row:t}){return o`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${Um(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${Im[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function Wm(){const t=qm.value,e=Km.value,n=e[0],s=Hm.value;return o`
    <div class="stats-grid">
      <${qe} label="Visible rows 표시 행" value=${e.length} />
      <${qe} label="Tracked messages 추적 메시지" value=${t.messages} color="#47b8ff" />
      <${qe} label="Keeper signals 키퍼 신호" value=${t.keepers} color="#4ade80" />
      <${qe} label="Board signals 보드 신호" value=${t.board} color="#fbbf24" />
      <${qe} label="SSE events SSE 이벤트" value=${Os.value} color="#c084fc" />
    </div>

    <${T} title="Unified Activity 통합 활동" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(a=>o`
            <button
              class="goal-filter-btn ${so.value===a?"active":""}"
              onClick=${()=>{so.value=a}}
            >
              ${Dm[a]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${Et.value?"":"pill-stale"}">
            ${Et.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?o`Latest: <${V} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${br} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      ${e.length===0?o`<div class="terminal-feed"><div class="empty-state">Waiting for live or snapshot signals...</div></div>`:o`<${wm}
            items=${e}
            itemHeight=${28}
            overscan=${8}
            getKey=${a=>a.id}
            renderItem=${a=>o`<${Bm} row=${a} />`}
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
                    ${i.lastActivityAt?o` · <${V} timestamp=${i.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${i.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function Zt({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function kr({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),o`
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
  `}function Gm(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Jm(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Vm(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Zo(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function xr(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Ym(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Sr(t){if(!t)return null;const e=zt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function Ar({keeper:t,showRawStatus:e=!1}){if(tt(()=>{t!=null&&t.name&&Di(t.name)},[t==null?void 0:t.name]),!t)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=zt.value[t.name],s=Sr(t),a=Ta.value[t.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${Gm(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Jm((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?o` · ${xr(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?o` · next eligible ${Ym(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?o`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Cr({keeperName:t,placeholder:e}){const[n,s]=zs("");tt(()=>{t&&Di(t)},[t]);const a=ot.value[t]??[],i=Na.value[t]??!1,r=Ot.value[t],l=async()=>{const d=n.trim();if(!(!t||!d)){s("");try{await qc(t,d)}catch(_){const p=_ instanceof Error?_.message:`Failed to message ${t}`;w(p,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?o`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(d=>o`
              <div class="keeper-conversation-item" key=${d.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Zo(d)}`}>${d.label}</span>
                  <span class=${`keeper-role-chip ${Zo(d)}`}>${Vm(d)}</span>
                  ${d.timestamp?o`<span class="keeper-conversation-time">${xr(d.timestamp)}</span>`:null}
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
  `}function wr({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=Sr(e),a=Ra.value[e.name]??!1,i=Pa.value[e.name]??!1,r=(s==null?void 0:s.next_action_path)??"direct_message",l=(s==null?void 0:s.recoverable)??r==="recover";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{Kc(e.name,t).catch(d=>{const _=d instanceof Error?d.message:`Failed to probe ${e.name}`;w(_,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{Hc(e.name,t).catch(d=>{const _=d instanceof Error?d.message:`Failed to recover ${e.name}`;w(_,"error")})}}
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
  `}const Ao=m(null);function Tr(t){Ao.value=t,Wn(t.name)}function ti(){Ao.value=null}const $e=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Qm(t){if(!t)return 0;const e=$e.findIndex(n=>n.level===t);return e>=0?e:0}function Xm({keeper:t}){const e=Qm(t.autonomy_level),n=$e[e]??$e[0];if(!n)return null;const s=(e+1)/$e.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${$e.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${$e.map((a,i)=>o`
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
            <strong><${V} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Zn(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Zm({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Zn(t.context_tokens)}</div>
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
  `}function tv({keeper:t}){var p,f;const e=t.metrics_series??[];if(e.length<2){const g=(((p=t.context)==null?void 0:p.context_ratio)??0)*100,$=g>85?"#ef4444":g>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${g.toFixed(1)}%;background:${$}"></div>
        </div>
        <span class="chart-pct">${g.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((g,$)=>{const y=a+$/(i-1)*(n-2*a),A=s-a-(g.context_ratio??0)*(s-2*a);return{x:y,y:A,p:g}}),l=r.map(({x:g,y:$})=>`${g.toFixed(1)},${$.toFixed(1)}`).join(" "),d=(((f=e[e.length-1])==null?void 0:f.context_ratio)??0)*100,_=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:g})=>g.is_handoff).map(({x:g})=>o`
          <line x1="${g.toFixed(1)}" y1="${a}" x2="${g.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${_}" stroke-width="1.5"/>
        ${r.filter(({p:g})=>g.is_compaction).map(({x:g,y:$})=>o`
          <circle cx="${g.toFixed(1)}" cy="${$.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const na=m("");function ev({keeper:t}){var a,i,r,l;const e=na.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${na.value}
        onInput=${d=>{na.value=d.target.value}}
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Zn(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Zn(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Zn(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function nv({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function sv({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function av({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function ei({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function sa(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function ov({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:sa(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:sa(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:sa(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function Nr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function iv(){try{const t=await wn({actor:Nr(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=_o(t.result);Ne(),await Jt(),e!=null&&e.skipped_reason?w(e.skipped_reason,"warning"):w(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";w(e,"error")}}function rv({keeper:t}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Ar} keeper=${t} />
          <${wr}
            actor=${Nr()}
            keeper=${t}
            onPokeLodge=${()=>{iv()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Cr}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function lv(){var e,n,s;const t=Ao.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&ti()}}
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
            <${Zt} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>ti()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Zm} keeper=${t} />

        ${""}
        <${tv} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${T} title="Field Dictionary">
            <${ev} keeper=${t} />
          <//>

          ${""}
          <${T} title="Profile">
            <${ei} traits=${t.traits??[]} label="Traits" />
            <${ei} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${V} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${T} title="Autonomy">
                <${Xm} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${T} title="TRPG Stats">
                <${nv} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${T} title="Equipment (${t.inventory.length})">
                <${sv} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${T} title="Relationships (${Object.keys(t.relationships).length})">
                <${av} rels=${t.relationships} />
              <//>
            `:null}

          <${T} title="Runtime Signals">
            <${ov} keeper=${t} />
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
        <${rv} keeper=${t} />
      </div>
    </div>
  `:null}const cv="masc_dashboard_agent_name",Ie=m(null),ws=m(!1),bn=m(""),Ts=m([]),kn=m([]),we=m(""),en=m(!1);function Rr(t){Ie.value=t,Co()}function ni(){Ie.value=null,bn.value="",Ts.value=[],kn.value=[],we.value=""}function dv(){const t=Ie.value;return t?Nt.value.find(e=>e.name===t)??null:null}function Pr(t){return t?kt.value.filter(e=>e.assignee===t):[]}async function Co(){const t=Ie.value;if(t){ws.value=!0,bn.value="",Ts.value=[],kn.value=[];try{const e=await yc(80);Ts.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Pr(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await bc(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));kn.value=s}catch(e){bn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{ws.value=!1}}}async function si(){var s;const t=Ie.value,e=we.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(cv))==null?void 0:s.trim())||"dashboard";en.value=!0;try{await Ri(n,`@${t} ${e}`),we.value="",w(`Mention sent to ${t}`,"success"),Co()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";w(i,"error")}finally{en.value=!1}}function uv({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Zt} status=${t.status} />
    </div>
  `}function pv({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function mv(){var a,i,r,l;const t=Ie.value;if(!t)return null;const e=dv(),n=Pr(t),s=Ts.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&ni()}}
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
                        <${Zt} status=${e.status} />
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
                    ${e.last_seen?o`<span>Last seen: <${V} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Co()}} disabled=${ws.value}>
              ${ws.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${ni}>Close</button>
          </div>
        </div>

        ${bn.value?o`<div class="council-error">${bn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${T} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${uv} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${T} title="Recent Activity">
            ${s.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${s.map((d,_)=>o`<div key=${_} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${T} title="Task History">
          ${kn.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${kn.value.map(d=>o`<${pv} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${T} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${we.value}
              onInput=${d=>{we.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&si()}}
              disabled=${en.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{si()}}
              disabled=${en.value||we.value.trim()===""}
            >
              ${en.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const aa=600*1e3,vv=1200*1e3,ai=.8;function qt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ge(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function _v(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function fv(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function gv(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function $v(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function hv(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function yv(t){var d,_;const e=ji.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,s=n?Math.max(0,Date.now()-qt(n)):Number.POSITIVE_INFINITY,a=!!((d=t.current_task)!=null&&d.trim())||e.activeAssignedCount>0;let i="watching",r="ok",l="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",l=n?"Offline or inactive":"No recent presence"):s>vv?(i="quiet",r="bad",l=a?"Working without a fresh signal":"No fresh agent signal"):a?(i="working",r=s>aa?"warn":"ok",l=s>aa?"Execution looks quiet for too long":"Task and live signal aligned"):s>aa?(i="quiet",r="warn",l="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",l="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((_=t.current_task)==null?void 0:_.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:l}}function bv(t){const e=Qc.value.get(t.name)??"idle",n=td.value.has(t.name),s=t.context_ratio??0;let a="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(a="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||s>=ai)&&(a="warning",i="warn",r=s>=ai?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:a,tone:i,focus:$v(t),note:r}}function Ke({label:t,value:e,color:n,caption:s}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?o`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function kv({item:t}){const e=t.kind==="agent"?()=>Rr(t.agent.name):()=>Tr(t.keeper);return o`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?o`<span><${V} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </button>
  `}function oi({row:t}){const{agent:e,motion:n}=t;return o`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Rr(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${kr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Zt} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${_v(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${V} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
        ${e.last_seen?o`<span>Seen <${V} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?o`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function xv({row:t}){const{keeper:e}=t;return o`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Tr(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${kr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Zt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${fv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?o`<span>Heartbeat <${V} timestamp=${e.last_heartbeat} /></span>`:o`<span>No heartbeat</span>`}
        <span>${hv(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${gv(e.context_ratio)}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?o`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function Sv(){const t=[...Nt.value].map(yv).sort((p,f)=>{const g=ge(f.tone)-ge(p.tone);if(g!==0)return g;const $=f.activeTaskCount-p.activeTaskCount;return $!==0?$:qt(f.lastSignalAt)-qt(p.lastSignalAt)}),e=[...Qt.value].map(bv).sort((p,f)=>{const g=ge(f.tone)-ge(p.tone);if(g!==0)return g;const $=(f.keeper.context_ratio??0)-(p.keeper.context_ratio??0);return $!==0?$:qt(f.keeper.last_heartbeat)-qt(p.keeper.last_heartbeat)}),n=t.filter(p=>p.state!=="offline"),s=t.filter(p=>p.state==="offline"),a=n.length,i=t.filter(p=>p.state==="working").length,r=t.filter(p=>p.lastSignalAt&&Date.now()-qt(p.lastSignalAt)<=12e4).length,l=t.filter(p=>p.tone!=="ok"),d=e.filter(p=>p.tone!=="ok"),_=[...d.map(p=>({kind:"keeper",key:`keeper-${p.keeper.name}`,tone:p.tone,title:p.keeper.name,subtitle:`${p.note} · ${p.focus}`,timestamp:p.keeper.last_heartbeat??null,keeper:p.keeper})),...l.map(p=>({kind:"agent",key:`agent-${p.agent.name}`,tone:p.tone,title:p.agent.name,subtitle:`${p.note} · ${p.focus}`,timestamp:p.lastSignalAt,agent:p.agent}))].sort((p,f)=>{const g=ge(f.tone)-ge(p.tone);return g!==0?g:qt(f.timestamp)-qt(p.timestamp)}).slice(0,8);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${Ke} label="Agents online 온라인" value=${a} color="#4ade80" caption="활성 + 대기 에이전트" />
        <${Ke} label="Working now 작업중" value=${i} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${Ke} label="Fresh signals 최신 신호" value=${r} color="#22d3ee" caption="최근 2분 이내" />
        <${Ke} label="Agent alerts 에이전트 경고" value=${l.length} color=${l.length>0?"#fb7185":"#4ade80"} caption="비활성 또는 오프라인" />
        <${Ke} label="Keeper alerts 키퍼 경고" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="오래되거나 높은 부하" />
      </div>

      <${T} title="Attention Queue 주의 필요" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${_.length===0?o`<div class="empty-state">No agent or keeper alerts right now</div>`:_.map(p=>o`<${kv} key=${p.key} item=${p} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${T} title="Active Agents 활성 에이전트" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Live agents stay grouped here first so execution drift is visible before you scan offline history.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?o`<div class="empty-state">No active agents visible</div>`:n.map(p=>o`<${oi} key=${p.agent.name} row=${p} />`)}
          </div>
        <//>

        <${T} title="Keeper Watch 키퍼 감시" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?o`<div class="empty-state">No keepers active</div>`:e.map(p=>o`<${xv} key=${p.keeper.name} row=${p} />`)}
          </div>
        <//>

        <${T} title="Offline Agents 오프라인" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who dropped out of the live loop</h2>
            <p class="monitor-subheadline">Offline rows are separated so they do not drown the active execution monitor.</p>
          </div>
          <div class="monitor-list">
            ${s.length===0?o`<div class="empty-state">No offline agents right now</div>`:s.map(p=>o`<${oi} key=${p.agent.name} row=${p} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Ns=m("all"),Rs=m("all"),io=$t(()=>{let t=un.value;return Ns.value!=="all"&&(t=t.filter(e=>e.horizon===Ns.value)),Rs.value!=="all"&&(t=t.filter(e=>e.status===Rs.value)),t}),Av=$t(()=>{const t={short:[],mid:[],long:[]};for(const e of io.value){const n=t[e.horizon];n&&n.push(e)}return t}),Cv=$t(()=>{const t=Array.from(Ei.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function wv(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function wo(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function ts(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Tv(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function ii(t){return t.toFixed(4)}function ri(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function Nv({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ts(t.horizon)}">
            ${wo(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${wv(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${V} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${Zt} status=${t.status} />
        <div class="goal-updated">
          <${V} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function li({label:t,timestamp:e,source:n,note:s}){return o`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${s?o`<div class="planning-freshness-source">${s}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?o`<${V} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function oa({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${T} title="${wo(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(s=>o`<${Nv} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function Rv(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Ns.value===t?"active":""}"
            onClick=${()=>{Ns.value=t}}
          >
            ${t==="all"?"All":wo(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Rs.value===t?"active":""}"
            onClick=${()=>{Rs.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function Pv(){const t=un.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${ts("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ts("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ts("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function Lv({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${Zt} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${ii(t.baseline_metric)}</span>
          <span>Current ${ii(t.current_metric)}</span>
          <span class=${ri(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${ri(t)}
          </span>
          <span>Elapsed ${Tv(t.elapsed_seconds)}</span>
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
  `}function ia({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${V} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Mv(){const{todo:t,inProgress:e,done:n}=Vc.value;return o`
    <${T} title="Task Backlog" class="section">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>o`<${ia} key=${s.id} task=${s} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>o`<${ia} key=${s.id} task=${s} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>o`<${ia} key=${s.id} task=${s} />`)}
          ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function Dv(){const t=Av.value,e=Cv.value,n=e.filter(l=>l.status==="running").length,s=e.filter(l=>l.recoverable).length,a=un.value.filter(l=>l.status==="active").length,i=Ia.value,r=i==="idle"?"No loop running":i==="error"?Ea.value??"MDAL snapshot unavailable":"Current loop snapshot";return o`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${a}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${io.value.length}</div>
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

      <${T} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>/api/v1/mdal/loops</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${mn} disabled=${be.value}>
              ${be.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${Re} disabled=${ke.value}>
              ${ke.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{mn(),Re()}}
              disabled=${be.value||ke.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${li} label="Goals" timestamp=${zi.value} source="masc_goal_list" />
          <${li}
            label="MDAL loops"
            timestamp=${Oi.value}
            source="/api/v1/mdal/loops"
            note=${r}
          />
        </div>
      <//>

      <${T} title="Goal Pipeline" class="section">
        <${Pv} />
        <${Rv} />
      <//>

      ${be.value&&un.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:io.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${oa} horizon="short" items=${t.short??[]} />
              <${oa} horizon="mid" items=${t.mid??[]} />
              <${oa} horizon="long" items=${t.long??[]} />
            `}

      <${T} title="MDAL Loops" class="section">
        ${ke.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&i==="error"?o`
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
                  ${e.map(l=>o`<${Lv} key=${l.loop_id} loop=${l} />`)}
                </div>
              `}
      <//>

      <${Mv} />
    </div>
  `}const he=m(""),ra=m("ability_check"),la=m("10"),ca=m("12"),jn=m(""),Fn=m("idle"),Kt=m(""),qn=m("keeper-late"),da=m("player"),ua=m(""),ft=m("idle"),pa=m(null),Kn=m(""),ma=m(""),va=m("player"),_a=m(""),fa=m(""),ga=m(""),nn=m("20"),$a=m("20"),ha=m(""),Hn=m("idle"),ro=m(null),Lr=m("overview"),ya=m("all"),ba=m("all"),ka=m("all"),Iv=12e4,Js=m(null),ci=m(Date.now());function Ev(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function zv(t,e){return e>0?Math.round(t/e*100):0}const Ov={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},jv={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Un(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Fv(t){const e=t.trim().toLowerCase();return Ov[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function qv(t){const e=t.trim().toLowerCase();return jv[e]??"상황에 따라 선택되는 전술 액션입니다."}function Gt(t){return typeof t=="object"&&t!==null}function ut(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function St(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function xn(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const Kv=new Set(["str","dex","con","int","wis","cha"]);function Hv(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!Gt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const r=a.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){s[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const l=Number.parseFloat(i.trim());if(Number.isFinite(l)){s[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),s}function Uv(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(nn.value.trim(),10);Number.isFinite(s)&&s>n&&(nn.value=String(n))}function lo(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Bv(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Wv(t){Lr.value=t}function Mr(t){const e=Js.value;return e==null||e<=t}function Gv(t){const e=Js.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Ps(){Js.value=null}function Dr(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Jv(t,e){Dr(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Js.value=Date.now()+Iv,w("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function es(t){return Mr(t)?(w("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function co(t,e,n){return Dr([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Vv({hp:t,max:e}){const n=zv(t,e),s=Ev(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Yv({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Qv({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Ir({actor:t}){var d,_,p,f;const e=(d=t.archetype)==null?void 0:d.trim(),n=(_=t.persona)==null?void 0:_.trim(),s=(p=t.portrait)==null?void 0:p.trim(),a=(f=t.background)==null?void 0:f.trim(),i=t.traits??[],r=t.skills??[],l=Object.entries(t.stats_raw??{}).filter(([g,$])=>Number.isFinite($)).filter(([g])=>!Kv.has(g.toLowerCase()));return o`
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
        <${Zt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Qv} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Vv} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Yv} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${Un(e)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${l.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${l.map(([g,$])=>o`
                <span class="trpg-custom-stat-chip">${Un(g)} ${$}</span>
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
                  <span class="trpg-annot-name">${Un(g)}</span>
                  <span class="trpg-annot-desc">${Fv(g)}</span>
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
                  <span class="trpg-annot-name">${Un(g)}</span>
                  <span class="trpg-annot-desc">${qv(g)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Xv({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Er({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Bv(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${lo(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${V} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Zv({events:t}){const e="__none__",n=ya.value,s=ba.value,a=ka.value,i=Array.from(new Set(t.map(lo).map(f=>f.trim()).filter(f=>f!==""))).sort((f,g)=>f.localeCompare(g)),r=Array.from(new Set(t.map(f=>(f.type??"").trim()).filter(f=>f!==""))).sort((f,g)=>f.localeCompare(g)),l=t.some(f=>(f.type??"").trim()===""),d=Array.from(new Set(t.map(f=>(f.phase??"").trim()).filter(f=>f!==""))).sort((f,g)=>f.localeCompare(g)),_=t.some(f=>(f.phase??"").trim()===""),p=t.filter(f=>{if(n!=="all"&&lo(f)!==n)return!1;const g=(f.type??"").trim(),$=(f.phase??"").trim();if(s===e){if(g!=="")return!1}else if(s!=="all"&&g!==s)return!1;if(a===e){if($!=="")return!1}else if(a!=="all"&&$!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${f=>{ya.value=f.target.value}}>
          <option value="all">all</option>
          ${i.map(f=>o`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${f=>{ba.value=f.target.value}}>
          <option value="all">all</option>
          ${l?o`<option value=${e}>(none)</option>`:null}
          ${r.map(f=>o`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${f=>{ka.value=f.target.value}}>
          <option value="all">all</option>
          ${_?o`<option value=${e}>(none)</option>`:null}
          ${d.map(f=>o`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{ya.value="all",ba.value="all",ka.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${p.length} / 전체 ${t.length}
      </span>
    </div>
    <${Er} events=${p.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function t_({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function zr({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function e_({state:t,nowMs:e}){var _;const n=It.value||((_=t.session)==null?void 0:_.room)||"",s=Fn.value,a=t.party??[];if(!a.find(p=>p.id===he.value)&&a.length>0){const p=a[0];p&&(he.value=p.id)}const r=async()=>{var f,g;if(!n){w("Room ID가 비어 있습니다.","error");return}if(!es(e))return;const p=((f=t.current_round)==null?void 0:f.phase)??((g=t.session)==null?void 0:g.status)??"unknown";if(co("라운드 실행",n,p)){Fn.value="running";try{const $=await cc(n);ro.value=$,Fn.value="ok";const y=Gt($.summary)?$.summary:null,A=y?xn(y,"advanced",!1):!1,N=y?ut(y,"progress_reason",""):"";w(A?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${N?`: ${N}`:""}`,A?"success":"warning"),Tt()}catch($){ro.value=null,Fn.value="error";const y=$ instanceof Error?$.message:"라운드 실행에 실패했습니다.";w(y,"error")}finally{Ps()}}},l=async()=>{var f,g;if(!n||!es(e))return;const p=((f=t.current_round)==null?void 0:f.phase)??((g=t.session)==null?void 0:g.status)??"unknown";if(co("턴 강제 진행",n,p))try{await pc(n),w("턴을 다음 단계로 이동했습니다.","success"),Tt()}catch{w("턴 이동에 실패했습니다.","error")}finally{Ps()}},d=async()=>{if(!n||!es(e))return;const p=he.value.trim();if(!p){w("먼저 Actor를 선택하세요.","warning");return}const f=Number.parseInt(la.value,10),g=Number.parseInt(ca.value,10);if(Number.isNaN(f)||Number.isNaN(g)){w("stat/dc는 숫자여야 합니다.","warning");return}const $=Number.parseInt(jn.value,10),y=jn.value.trim()===""||Number.isNaN($)?void 0:$;try{await uc({roomId:n,actorId:p,action:ra.value.trim()||"ability_check",statValue:f,dc:g,rawD20:y}),w("주사위 판정을 기록했습니다.","success"),Tt()}catch{w("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${p=>{It.value=p.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${he.value}
            onChange=${p=>{he.value=p.target.value}}
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
              value=${ra.value}
              onInput=${p=>{ra.value=p.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${la.value}
              onInput=${p=>{la.value=p.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${ca.value}
              onInput=${p=>{ca.value=p.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${jn.value}
              onInput=${p=>{jn.value=p.target.value}}
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
  `}function n_({state:t}){var a;const e=It.value||((a=t.session)==null?void 0:a.room)||"",n=Hn.value,s=async()=>{if(!e){w("Room ID가 비어 있습니다.","warning");return}const i=Kn.value.trim(),r=ma.value.trim();if(!r&&!i){w("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt(nn.value.trim(),10),d=Number.parseInt($a.value.trim(),10),_=Number.isFinite(d)?Math.max(1,d):20,p=Number.isFinite(l)?Math.max(0,Math.min(_,l)):_;let f={};try{f=Hv(ha.value)}catch(g){w(g instanceof Error?g.message:"능력치 JSON 오류","error");return}Hn.value="spawning";try{const g=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,$=await mc(e,{actor_id:i||void 0,name:r||void 0,role:va.value,idempotencyKey:g,portrait:fa.value.trim()||void 0,background:ga.value.trim()||void 0,hp:p,max_hp:_,alive:p>0,stats:Object.keys(f).length>0?f:void 0}),y=typeof $.actor_id=="string"?$.actor_id.trim():"";if(!y)throw new Error("생성 응답에 actor_id가 없습니다.");const A=_a.value.trim();A&&await vc(e,y,A),he.value=y,Kt.value=y,i||(Kn.value=""),Hn.value="ok",w(`Actor 생성 완료: ${y}`,"success"),await Tt()}catch(g){Hn.value="error",w(g instanceof Error?g.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${ma.value}
            onInput=${i=>{ma.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${va.value}
            onChange=${i=>{va.value=i.target.value}}
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
            value=${_a.value}
            onInput=${i=>{_a.value=i.target.value}}
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
              value=${Kn.value}
              onInput=${i=>{Kn.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${fa.value}
              onInput=${i=>{fa.value=i.target.value}}
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
              value=${nn.value}
              onInput=${i=>{nn.value=i.target.value}}
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
              value=${$a.value}
              onInput=${i=>{const r=i.target.value;$a.value=r,Uv(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${ga.value}
              onInput=${i=>{ga.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${ha.value}
              onInput=${i=>{ha.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function s_({state:t,nowMs:e}){var g;const n=It.value||((g=t.session)==null?void 0:g.room)||"",s=t.join_gate,a=pa.value,i=Gt(a)?a:null,r=(t.party??[]).filter($=>$.role!=="dm"),l=Kt.value.trim(),d=r.some($=>$.id===l),_=d?l:l?"__manual__":"",p=async()=>{const $=Kt.value.trim(),y=qn.value.trim();if(!n||!$){w("Room/Actor가 필요합니다.","warning");return}ft.value="checking";try{const A=await _c(n,$,y||void 0);pa.value=A,ft.value="ok",w("참가 가능 여부를 갱신했습니다.","success")}catch(A){ft.value="error";const N=A instanceof Error?A.message:"참가 가능 여부 확인에 실패했습니다.";w(N,"error")}},f=async()=>{var M,E;const $=Kt.value.trim(),y=qn.value.trim(),A=ua.value.trim();if(!n||!$||!y){w("Room/Actor/Keeper가 필요합니다.","warning");return}if(!es(e))return;const N=((M=t.current_round)==null?void 0:M.phase)??((E=t.session)==null?void 0:E.status)??"unknown";if(co("Mid-Join 승인 요청",n,N)){ft.value="requesting";try{const L=await fc({room_id:n,actor_id:$,keeper_name:y,role:da.value,...A?{name:A}:{}});pa.value=L;const R=Gt(L)?xn(L,"granted",!1):!1,u=Gt(L)?ut(L,"reason_code",""):"";R?w("Mid-Join이 승인되었습니다.","success"):w(`Mid-Join이 거절되었습니다${u?`: ${u}`:""}`,"warning"),ft.value=R?"ok":"error",Tt()}catch(L){ft.value="error";const R=L instanceof Error?L.message:"Mid-Join 요청에 실패했습니다.";w(R,"error")}finally{Ps()}}};return o`
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
            value=${_}
            onChange=${$=>{const y=$.target.value;if(y==="__manual__"){(d||!l)&&(Kt.value="");return}Kt.value=y}}
          >
            <option value="">Actor 선택</option>
            ${r.map($=>o`
              <option value=${$.id}>${$.name} (${$.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${_==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${Kt.value}
                onInput=${$=>{Kt.value=$.target.value}}
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
            value=${qn.value}
            onInput=${$=>{qn.value=$.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${da.value}
            onChange=${$=>{da.value=$.target.value}}
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
            value=${ua.value}
            onInput=${$=>{ua.value=$.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${p} disabled=${ft.value==="checking"||ft.value==="requesting"}>
              ${ft.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${f} disabled=${ft.value==="checking"||ft.value==="requesting"}>
              ${ft.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${xn(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${St(i,"effective_score",0)}/${St(i,"required_points",0)}</span>
            ${ut(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${ut(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Or({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function jr({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Fr(){const t=ro.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=Gt(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(Gt).slice(-8),i=t.canon_check,r=Gt(i)?i:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(u=>typeof u=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(u=>typeof u=="string").slice(0,3):[],_=n?xn(n,"advanced",!1):!1,p=n?ut(n,"progress_reason",""):"",f=n?ut(n,"progress_detail",""):"",g=n?St(n,"player_successes",0):0,$=n?St(n,"player_required_successes",0):0,y=n?xn(n,"dm_success",!1):!1,A=n?St(n,"timeouts",0):0,N=n?St(n,"unavailable",0):0,M=n?St(n,"reprompts",0):0,E=n?St(n,"npc_attacks",0):0,L=n?St(n,"keeper_timeout_sec",0):0,R=n?St(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${_?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${_?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${y?"DM ok":"DM stalled"} / players ${g}/${$}
          </span>
        </div>
        ${p?o`<div style="margin-top:4px; font-size:12px;">${p}</div>`:null}
        ${f?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${f}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${N}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${M}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${E}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${L||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${R}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(u=>{const q=ut(u,"status","unknown"),K=ut(u,"actor_id","-"),Lt=ut(u,"role","-"),lt=ut(u,"reason",""),ct=ut(u,"action_type",""),H=ut(u,"reply","");return o`
                <div class="trpg-round-item ${q.includes("fallback")||q.includes("timeout")?"failed":"active"}">
                  <span>${K} (${Lt})</span>
                  <span style="margin-left:auto; font-size:11px;">${q}</span>
                  ${ct?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${ct}</div>`:null}
                  ${lt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${lt}</div>`:null}
                  ${H?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${H.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${ut(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(u=>o`<div>violation: ${u}</div>`)}
                </div>`:null}
            ${l.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${l.map(u=>o`<div>warning: ${u}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function a_({state:t,nowMs:e}){var r,l,d;const n=It.value||((r=t.session)==null?void 0:r.room)||"",s=((l=t.current_round)==null?void 0:l.phase)??((d=t.session)==null?void 0:d.status)??"unknown",a=Mr(e),i=Gv(e);return o`
    <${T} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>Jv(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Ps(),w("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function o_({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Wv(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function i_({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${T} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${T} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${Er} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${T} title="맵" style="margin-top:16px;">
              <${Xv} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${T} title="현재 라운드">
          <${jr} state=${t} />
        <//>

        <${T} title="기여도" style="margin-top:16px;">
          <${Or} state=${t} />
        <//>

        <${T} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>o`<${Ir} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${zr} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function r_({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${T} title=${`이벤트 타임라인 (${e.length})`}>
          <${Zv} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${T} title="최근 라운드 결과">
          <${Fr} />
        <//>

        <${T} title="현재 라운드" style="margin-top:16px;">
          <${jr} state=${t} />
        <//>
      </div>
    </div>
  `}function l_({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${a_} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${T} title="조작 패널">
            <${e_} state=${t} nowMs=${e} />
          <//>

          <${T} title="Actor Spawn" style="margin-top:16px;">
            <${n_} state=${t} />
          <//>

          <${T} title="Mid-Join Gate" style="margin-top:16px;">
            <${s_} state=${t} nowMs=${e} />
          <//>

          <${T} title="최근 라운드 결과" style="margin-top:16px;">
            <${Fr} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${T} title="기여도" style="margin-top:0;">
            <${Or} state=${t} />
          <//>

          <${T} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${Ir} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${zr} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function c_(){var l,d,_,p,f;const t=Ii.value,e=Oa.value;if(tt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const g=window.setInterval(()=>{ci.value=Date.now()},1e3);return()=>{window.clearInterval(g)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Tt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,i=Lr.value,r=ci.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${It.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((_=t.session)==null?void 0:_.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Tt()}>새로고침</button>
      </div>

      <${t_} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((p=t.session)==null?void 0:p.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((f=t.current_round)==null?void 0:f.round_number)??0}</div>
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

      <${o_} active=${i} />

      ${i==="overview"?o`<${i_} state=${t} />`:i==="timeline"?o`<${r_} state=${t} />`:o`<${l_} state=${t} nowMs=${r} />`}
    </div>
  `}const To="masc_dashboard_agent_name";function d_(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(To);return e??n??"dashboard"}const mt=m(d_()),sn=m(""),an=m(""),Ls=m(""),qr=m(null),Ms=m(null),on=m(!1),xe=m(!1),Sn=m(null),rn=m(!1),ln=m(!1),Ds=m(!1),Is=m(!1),Le=m(!1);function Es(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function ns(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function Kr(t){return!t||t.length===0?"none":t.join(", ")}function u_(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Es(t.quiet_start)}-${Es(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${ns(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${ns(t.interval_s)}.`:`Lodge ticks every ${ns(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function Ee(){Ne();try{await Jt()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function No(t){const e=t.trim();mt.value=e,e&&localStorage.setItem(To,e)}function p_(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function uo(){if(Le.value)return;const t=mt.value.trim();if(t){rn.value=!0;try{const e=await $c(t),n=p_(e);n&&No(n),Sn.value=n??t,Le.value=!0,await Ee(),w(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";w(n,"error")}finally{rn.value=!1}}}async function di(){if(!Le.value)return;const t=Sn.value??mt.value.trim();if(t){ln.value=!0;try{await Pi(t),Sn.value=null,Le.value=!1,await Ee(),w(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";w(n,"error")}finally{ln.value=!1}}}async function m_(){const t=Sn.value??mt.value.trim();if(t)try{await Pi(t)}catch{}Sn.value=null,localStorage.removeItem(To),No("dashboard"),Le.value=!1,await uo()}async function v_(){const t=mt.value.trim();if(t){Ds.value=!0;try{await hc(t),await Ee(),w("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";w(n,"error")}finally{Ds.value=!1}}}async function ui(){const t=mt.value.trim(),e=sn.value.trim();if(!(!t||!e)){on.value=!0;try{await Ri(t,e),sn.value="",await Ee(),w("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";w(s,"error")}finally{on.value=!1}}}async function __(){const t=an.value.trim(),e=Ls.value.trim()||"Created from dashboard";if(t){xe.value=!0;try{await gc(t,e,1),an.value="",Ls.value="",await Ee(),w("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";w(s,"error")}finally{xe.value=!1}}}async function pi(){const t=mt.value.trim()||"dashboard";Is.value=!0,Ms.value=null;try{const e=await wn({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=_o(e.result);qr.value=n,await Ee(),n!=null&&n.skipped_reason?w(n.skipped_reason,"warning"):w(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";Ms.value=n,w(n,"error")}finally{Is.value=!1}}function f_({runtime:t}){var a,i;const e=qr.value??(t==null?void 0:t.last_tick_result)??null;if(Ms.value)return o`<div class="control-result-box is-error">${Ms.value}</div>`;if(!e)return o`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((a=e.skipped_rows)==null?void 0:a.slice(0,3))??[],s=((i=e.passed_rows)==null?void 0:i.slice(0,3))??[];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?o`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">Last acted: ${Kr(e.acted_names)}</div>
      ${e.skipped_reason?o`<div class="control-status-copy">${e.skipped_reason}</div>`:null}
      ${e.activity_report?o`<pre class="control-transcript-text">${e.activity_report}</pre>`:null}
      ${n.length>0?o`
            <div class="control-result-list">
              ${n.map(r=>o`<div>${r.name}: ${r.reason??"skipped"}</div>`)}
            </div>
          `:null}
      ${s.length>0?o`
            <div class="control-result-list">
              ${s.map(r=>o`<div>${r.name}: ${r.reason??"passed"}</div>`)}
            </div>
          `:null}
    </div>
  `}function g_(t){return t.find(n=>n.name===Be.value)??t[0]??null}function $_(){var s,a;const t=Qt.value,e=((s=me.value)==null?void 0:s.lodge)??null,n=g_(t);return tt(()=>(uo(),()=>{di()}),[]),tt(()=>{var r;const i=((r=t[0])==null?void 0:r.name)??"";if(!Be.value&&i){Wn(i);return}Be.value&&!t.some(l=>l.name===Be.value)&&Wn(i)},[t.map(i=>i.name).join("|")]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Room Identity</h4>
          <p class="control-help">Broadcasts and operator actions use this agent name.</p>
        </div>

        <label class="control-label" for="dock-agent">Agent</label>
        <input
          id="dock-agent"
          class="control-input"
          type="text"
          value=${mt.value}
          onInput=${i=>No(i.target.value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{uo()}}
            disabled=${rn.value||mt.value.trim()===""}
          >
            ${rn.value?"Joining...":Le.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{di()}}
            disabled=${ln.value||mt.value.trim()===""}
          >
            ${ln.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{m_()}}
            disabled=${rn.value||ln.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{v_()}}
            disabled=${Ds.value||mt.value.trim()===""}
          >
            ${Ds.value?"Pinging...":"Heartbeat"}
          </button>
        </div>
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Room Broadcast</h4>
          <p class="control-help">This is visible to the room and other agents. Use it for announcements, nudges, and @mentions, not private keeper prompts.</p>
        </div>

        <label class="control-label" for="dock-message">Broadcast</label>
        <div class="control-row">
          <input
            id="dock-message"
            class="control-input"
            type="text"
            placeholder="@agent or room-wide update"
            value=${sn.value}
            onInput=${i=>{sn.value=i.target.value}}
            onKeyDown=${i=>{i.key==="Enter"&&ui()}}
            disabled=${on.value}
          />
          <button
            class="control-btn"
            onClick=${()=>{ui()}}
            disabled=${on.value||sn.value.trim()===""||mt.value.trim()===""}
          >
            ${on.value?"Sending...":"Send"}
          </button>
        </div>
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Keeper Direct Message</h4>
          <p class="control-help">This sends a 1:1 message through <code>masc_keeper_msg</code> and keeps the actual reply thread in the dock so you can see whether the keeper answered.</p>
        </div>

        <label class="control-label" for="dock-keeper">Keeper</label>
        <select
          id="dock-keeper"
          class="control-input"
          value=${(n==null?void 0:n.name)??""}
          onInput=${i=>{Wn(i.target.value)}}
          disabled=${t.length===0}
        >
          ${t.length===0?o`<option value="">No keepers available</option>`:t.map(i=>o`<option value=${i.name}>${i.name}</option>`)}
        </select>

        <${Ar} keeper=${n} />
        <${wr}
          actor=${mt.value.trim()||"dashboard"}
          keeper=${n}
          onPokeLodge=${()=>{pi()}}
        />
        <${Cr}
          keeperName=${(n==null?void 0:n.name)??""}
          placeholder=${t.length===0?"No keeper is active yet":"Direct prompt for the selected keeper"}
        />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${u_(e)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${e!=null&&e.enabled?"enabled":"disabled"}</span>
          <span class="pill">every ${ns(e==null?void 0:e.interval_s)}</span>
          <span class="pill">quiet ${Es(e==null?void 0:e.quiet_start)}-${Es(e==null?void 0:e.quiet_end)} KST</span>
          <span class="pill">${e!=null&&e.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${e!=null&&e.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${e!=null&&e.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${Kr((a=e==null?void 0:e.last_tick_result)==null?void 0:a.acted_names)}
        </div>
        ${e!=null&&e.last_skip_reason?o`<div class="control-status-copy">Last skip reason: ${e.last_skip_reason}</div>`:null}

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{pi()}}
            disabled=${Is.value}
          >
            ${Is.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${f_} runtime=${e} />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Quick Task</h4>
          <p class="control-help">Fast backlog injection for local follow-up work.</p>
        </div>

        <input
          id="dock-task"
          class="control-input"
          type="text"
          placeholder="Task title"
          value=${an.value}
          onInput=${i=>{an.value=i.target.value}}
          disabled=${xe.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${Ls.value}
          onInput=${i=>{Ls.value=i.target.value}}
          disabled=${xe.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${()=>{__()}}
          disabled=${xe.value||an.value.trim()===""}
        >
          ${xe.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
  `}const mi=[{id:"observe",label:"Monitor",description:"지금 상태와 우선순위를 먼저 읽는 운영 랜딩"},{id:"coordinate",label:"Workspace",description:"대화, 계획, 에이전트 상태를 보조 작업 공간으로 분리"},{id:"command",label:"Act",description:"개입과 지휘를 실제로 실행하는 표면"}],po=[{id:"mission",label:"상황판",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"intervene",label:"개입",icon:"🎮",group:"command",description:"room/session/keeper 액션을 실제로 실행하는 intervention workspace"},{id:"command",label:"지휘",icon:"🧭",group:"command",description:"command plane, swarm, trace, approvals를 drill-down으로 보는 상세 화면"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals, MDAL loops, and task backlog in one planning surface"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}],An=m(!1);function vi(){An.value=!1}function h_(){An.value=!An.value}const _i="masc_dashboard_quick_actions_open";function y_(){const t=Et.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Os.value} events</span>
    </div>
  `}function b_({currentTab:t,currentSectionLabel:e}){const n=Et.value;return o`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>Snapshot</h3>
        <span class="rail-section-chip ${n?"ok":"bad"}">${n?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agents</span>
          <strong>${Nt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keepers</span>
          <strong>${Qt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Tasks</span>
          <strong>${kt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Events</span>
          <strong>${Os.value}</strong>
        </div>
      </div>
      <div class="rail-snapshot-copy">
        <span>Connection ${n?"healthy":"recovering"}</span>
        <span>${e} workspace active</span>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Jt(),t==="command"&&(de(),Ut(),gt.value==="swarm"&&Dt()),(t==="mission"||t==="overview")&&Ka(),(t==="intervene"||t==="ops")&&(pe(),Yt()),t==="board"&&wt(),t==="trpg"&&Tt(),t==="goals"&&(mn(),Re())}}
        >
          Refresh Now
        </button>
        <button class="rail-secondary-btn" onClick=${()=>nt("intervene")}>
          Open Intervene
        </button>
      </div>
    </section>
  `}function k_(){const t=Z.value.tab,e=po.find(i=>i.id===t),n=mi.find(i=>i.id===(e==null?void 0:e.group)),[s,a]=zs(()=>{const i=localStorage.getItem(_i);return i!=="0"});return tt(()=>{localStorage.setItem(_i,s?"1":"0")},[s]),o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${n?o`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${mi.map(i=>o`
          <div class="rail-nav-group" key=${i.id}>
            <div class="rail-group-label">${i.label}</div>
            <div class="rail-group-copy">${i.description}</div>
            <div class="rail-tab-list">
              ${po.filter(r=>r.group===i.id).map(r=>o`
                  <button
                    class="rail-tab-btn ${t===r.id?"active":""}"
                    onClick=${()=>nt(r.id)}
                  >
                    <span class="rail-tab-icon">${r.icon}</span>
                    <span class="rail-tab-copy">
                      <strong>${r.label}</strong>
                      <span>${r.description}</span>
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

      <${b_} currentTab=${t} currentSectionLabel=${(n==null?void 0:n.label)??"Observe"} />

      <section class="rail-card fold-card">
        <div class="rail-card-head">
          <h3>Quick Actions</h3>
          <span class="rail-section-chip">${s?"Open":"Closed"}</span>
        </div>
        <button class="fold-toggle" onClick=${()=>a(i=>!i)}>
          <span>${s?"Hide inline actions":"Show inline actions"}</span>
          <span class="fold-toggle-meta">Join, broadcast, keeper DM, lodge poke</span>
        </button>
        ${s?o`<div class="rail-fold-body"><${$_} /></div>`:o`<div class="rail-fold-hint">Use inline actions for quick room nudges. Open the Ops tab for structured intervention work.</div>`}
      </section>
    </aside>
  `}function x_(){switch(Z.value.tab){case"mission":return o`<${Qs} />`;case"intervene":return o`<${Vo} />`;case"command":return o`<${Mp} />`;case"overview":return o`<${Qs} />`;case"ops":return o`<${Vo} />`;case"board":return o`<${Am} />`;case"agents":return o`<${Sv} />`;case"goals":return o`<${Dv} />`;case"trpg":return o`<${c_} />`;default:return o`<${Qs} />`}}function S_(){tt(()=>{il(),xi(),Jt();const n=fd();return gd(),()=>{vl(),n(),$d()}},[]),tt(()=>{const n=setInterval(()=>{const s=Z.value.tab;s==="command"?(de(),Ut(),gt.value==="swarm"&&Dt()):s==="mission"||s==="overview"?Ka():s==="intervene"||s==="ops"?(pe(),Yt()):s==="board"?wt():s==="trpg"?Tt():s==="goals"&&(mn(),Re())},15e3);return()=>{clearInterval(n)}},[]),tt(()=>{const n=Z.value.tab;n==="command"&&(de(),Ut(),gt.value==="swarm"&&Dt()),(n==="mission"||n==="overview")&&Ka(),(n==="intervene"||n==="ops")&&(pe(),Yt()),n==="board"&&wt(),n==="trpg"&&Tt(),n==="goals"&&(mn(),Re())},[Z.value.tab]);const t=Z.value.tab,e=po.find(n=>n.id===t);return o`
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
            class="activity-panel-toggle ${An.value?"active":""}"
            onClick=${h_}
            title="Toggle Activity Panel"
          >
            Activity
          </button>
          <${y_} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${k_} />
        <main class="dashboard-main">
          ${za.value&&!Et.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${x_} />`}
        </main>
      </div>

      ${An.value?o`
        <div class="activity-panel-backdrop" onClick=${vi} />
        <aside class="activity-panel">
          <div class="activity-panel-header">
            <h3>Activity Feed</h3>
            <button class="activity-panel-close" onClick=${vi}>Close</button>
          </div>
          <div class="activity-panel-body">
            <${Wm} />
          </div>
        </aside>
      `:null}

      <${lv} />
      <${mv} />
      <${Ep} />
    </div>
  `}const fi=document.getElementById("app");fi&&tl(o`<${S_} />`,fi);export{Md as _};
