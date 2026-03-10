var Ur=Object.defineProperty;var Hr=(t,e,n)=>e in t?Ur(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var ye=(t,e,n)=>Hr(t,typeof e!="symbol"?e+"":e,n);import{e as Wr,_ as Br,c as m,b as se,y as ut,d as mi,A as Gr,G as Jr}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var o=Wr.bind(Br);const Vr=["mission","execution","memory","governance","planning","intervene","command","lab"],vi={tab:"mission",params:{},postId:null};function Io(t){return!!t&&Vr.includes(t)}function Ia(t){try{return decodeURIComponent(t)}catch{return t}}function Na(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Yr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function _i(t,e){if(t[0]==="chains"){const i={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(i.operation=Ia(t[2])),{tab:"command",params:i,postId:null}}if(t[0]==="lab"){const i={...e};return t[1]&&(i.surface=Ia(t[1])),{tab:"lab",params:i,postId:null}}const n=t[0],s=e.tab;return{tab:Io(n)?n:Io(s)?s:"mission",params:e,postId:null}}function as(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return vi;const n=Ia(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=Na(a),r=Yr(s);return _i(r,i)}function Xr(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...vi,params:Na(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Na(e.replace(/^\?/,""));return _i(s,a)}function fi(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const L=m(as(window.location.hash));window.addEventListener("hashchange",()=>{L.value=as(window.location.hash)});function xt(t,e){const n={tab:t,params:e??{}};window.location.hash=fi(n)}function Qr(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function Zr(){if(window.location.hash&&window.location.hash!=="#"){L.value=as(window.location.hash);return}const t=Xr(window.location.pathname,window.location.search);if(t){L.value=t;const e=fi(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",L.value=as(window.location.hash)}const No="masc_dashboard_sse_session_id",tl=1e3,el=15e3,$e=m(!1),io=m(0),gi=m(null),Ra=m([]);function nl(){let t=sessionStorage.getItem(No);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(No,t)),t}const sl=200;function al(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};Ra.value=[a,...Ra.value].slice(0,sl)}function Pa(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Ro(t,e){const n=Pa(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function St(t,e,n,s,a={}){al(t,e,n,{eventType:s,...a})}let It=null,Ne=null,Ma=0;function $i(){Ne&&(clearTimeout(Ne),Ne=null)}function ol(){if(Ne)return;Ma++;const t=Math.min(Ma,5),e=Math.min(el,tl*Math.pow(2,t));Ne=setTimeout(()=>{Ne=null,hi()},e)}function hi(){$i(),It&&(It.close(),It=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",nl());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);It=i,i.onopen=()=>{It===i&&(Ma=0,$e.value=!0)},i.onerror=()=>{It===i&&($e.value=!1,i.close(),It=null,ol())},i.onmessage=r=>{try{const c=JSON.parse(r.data);io.value++,gi.value=c,il(c)}catch{}}}function il(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":St(n,"Joined","system","agent_joined");break;case"agent_left":St(n,"Left","system","agent_left");break;case"broadcast":St(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":St(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":St(n,Ro("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Pa(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":St(n,Ro("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Pa(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":St(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":St(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":St(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":St(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:St(n,e,"system","unknown")}}function rl(){$i(),It&&(It.close(),It=null),$e.value=!1}function yi(){return new URLSearchParams(window.location.search)}function bi(){const t=yi(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function ki(){return{...bi(),"Content-Type":"application/json"}}const ll=15e3,ro=3e4,cl=6e4,Po=new Set([408,425,429,500,502,503,504]);class wn extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);ye(this,"method");ye(this,"path");ye(this,"status");ye(this,"statusText");ye(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function lo(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new wn({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function dl(){var e,n;const t=yi();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function nt(t){const e=await lo(t,{headers:bi()},ll);if(!e.ok)throw new wn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function ul(t){return new Promise(e=>setTimeout(e,t))}function pl(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function ml(t){if(t instanceof wn)return t.timeout||typeof t.status=="number"&&Po.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=pl(t.message);return e!==null&&Po.has(e)}async function xi(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!ml(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${i}ms`,a),await ul(i),s+=1}}async function Et(t,e,n,s=ro){const a=await lo(t,{method:"POST",headers:{...ki(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new wn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function vl(t,e,n,s=ro){const a=await lo(t,{method:"POST",headers:{...ki(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new wn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function _l(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function fl(t){var e,n,s,a,i,r,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((c=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:c.text)??""}async function ae(t,e){const n=await vl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},cl),s=_l(n);return fl(s)}function gl(){return nt("/api/v1/dashboard/shell")}function $l(){return nt("/api/v1/dashboard/execution")}function hl(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),nt(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function yl(){return nt("/api/v1/dashboard/governance")}function bl(){return nt("/api/v1/dashboard/semantics")}function kl(){return nt("/api/v1/dashboard/mission")}function xl(t=!1){return nt(`/api/v1/dashboard/mission/briefing${t?"?force=1":""}`)}function Sl(){return nt("/api/v1/dashboard/planning")}function Al(){return nt("/api/v1/operator")}function Si(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return nt(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Cl(){return nt("/api/v1/command-plane")}function wl(){return nt("/api/v1/command-plane/summary")}function Tl(){return nt("/api/v1/chains/summary")}function Il(t){return nt(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Nl(){return nt("/api/v1/command-plane/help")}function Rl(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return nt(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function Pl(t,e){return Et(t,e)}function Ml(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return ro}}function Es(t){return Et("/api/v1/operator/action",t,void 0,Ml(t))}function Dl(t,e){return Et("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function os(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function Ll(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function El(t){if(!q(t))return null;const e=h(t.id,"").trim(),n=h(t.author,"").trim(),s=h(t.content,"").trim();if(!e||!n)return null;const a=W(t.score,0),i=W(t.votes_up,0),r=W(t.votes_down,0),c=W(t.votes,a||i-r),d=W(t.comment_count,W(t.reply_count,0)),f=(()=>{const x=t.flair;if(typeof x=="string"&&x.trim())return x.trim();if(q(x)){const I=h(x.name,"").trim();if(I)return I}return h(t.flair_name,"").trim()||void 0})(),p=h(t.created_at_iso,"").trim()||os(t.created_at),u=h(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?os(t.updated_at):p),$=h(t.title,"").trim()||Ll(s);return{id:e,author:n,title:$,content:s,tags:[],votes:c,vote_balance:a,comment_count:d,created_at:p,updated_at:u,flair:f,hearth_count:W(t.hearth_count,0)}}function zl(t){if(!q(t))return null;const e=h(t.id,"").trim(),n=h(t.post_id,"").trim(),s=h(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:h(t.content,""),created_at:os(t.created_at)}}async function Ol(t){return xi("fetchBoardPost",async()=>{const e=await nt(`/api/v1/board/${t}?format=flat`),n=q(e.post)?e.post:e,s=El(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(zl).filter(r=>r!==null);return{...s,comments:i}})}function Ai(t,e){return Et("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:dl()})}function jl(t,e,n){return Et("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Fl(t){const e=h(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function lt(...t){for(const e of t){const n=h(e,"");if(n.trim())return n.trim()}return""}function Mo(t){const e=Fl(lt(t.outcome,t.result,t.result_code));if(!e)return;const n=lt(t.reason,t.reason_code,t.description,t.detail),s=lt(t.summary,t.summary_ko,t.summary_en,t.note),a=lt(t.details,t.details_text,t.text,t.note),i=lt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=lt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=lt(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const u=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof u=="string"?[u]:Array.isArray(u)?u.map(g=>{if(typeof g=="string")return g.trim();if(q(g)){const $=h(g.summary,"").trim();if($)return $;const x=h(g.text,"").trim();if(x)return x;const A=h(g.type,"").trim();return A||h(g.event_id,"").trim()}return""}).filter(g=>g.length>0):[]})(),f=(()=>{const u=W(t.turn,Number.NaN);if(Number.isFinite(u))return u;const g=W(t.turn_number,Number.NaN);if(Number.isFinite(g))return g;const $=W(t.current_turn,Number.NaN);if(Number.isFinite($))return $;const x=W(t.round,Number.NaN);return Number.isFinite(x)?x:void 0})(),p=lt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:c||void 0,turn:f,phase:p||void 0}}function ql(t,e){const n=q(t.state)?t.state:{};if(h(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>q(r)?h(r.type,"")==="session.outcome":!1),i=q(n.session_outcome)?n.session_outcome:{};if(q(i)&&Object.keys(i).length>0){const r=Mo(i);if(r)return r}if(q(a))return Mo(q(a.payload)?a.payload:{})}function q(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function W(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Kl(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Da(t,e=!1){return typeof t=="boolean"?t:e}function Ge(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(q(e)){const n=h(e.name,"").trim(),s=h(e.id,"").trim(),a=h(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Ul(t){const e={};if(!q(t)&&!Array.isArray(t))return e;if(q(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=h(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!q(n))continue;const s=lt(n.to,n.target,n.actor_id,n.name,n.id),a=lt(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function Hl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function ht(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const Wl=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Bl(t){const e=q(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const i=s.trim();i&&(Wl.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function Gl(t,e){if(t!=="dice.rolled")return;const n=W(e.raw_d20,0),s=W(e.total,0),a=W(e.bonus,0),i=h(e.action,"roll"),r=W(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Jl(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Vl(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Yl(t,e,n,s){const a=n||e||h(s.actor_id,"")||h(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=h(s.proposed_action,h(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=h(s.reply,h(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return h(s.reply,h(s.content,h(s.text,"Narration")));case"dice.rolled":{const i=h(s.action,"roll"),r=W(s.total,0),c=W(s.dc,0),d=h(s.label,""),f=a||"actor",p=c>0?` vs DC ${c}`:"",u=d?` (${d})`:"";return`${f} ${i}: ${r}${p}${u}`}case"turn.started":return`Turn ${W(s.turn,1)} started`;case"phase.changed":return`Phase: ${h(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(s.name,q(s.actor)?h(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${h(s.keeper_name,h(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${h(s.keeper_name,h(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${W(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${W(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||h(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||h(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${h(s.reason_code,"unknown")}`;case"memory.signal":{const i=q(s.entity_refs)?s.entity_refs:{},r=h(i.requested_tier,""),c=h(i.effective_tier,""),d=Da(i.guardrail_applied,!1),f=h(s.summary_en,h(s.summary_ko,"Memory signal"));if(!r&&!c)return f;const p=r&&c?`${r}->${c}`:c||r;return`${f} [${p}${d?" (guardrail)":""}]`}case"world.event":{if(h(s.event_type,"")==="canon.check"){const r=h(s.status,"unknown"),c=h(s.contract_id,"n/a");return`Canon ${r}: ${c}`}return h(s.description,h(s.summary,"World event"))}case"combat.attack":return h(s.summary,h(s.result,"Attack resolved"));case"combat.defense":return h(s.summary,h(s.result,"Defense resolved"));case"session.outcome":return h(s.summary,h(s.outcome,"Session ended"));default:{const i=Jl(s);return i?`${t}: ${i}`:t}}}function Xl(t,e){const n=q(t)?t:{},s=h(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=h(n.actor_name,"").trim()||e[a]||h(q(n.payload)?n.payload.actor_name:"",""),r=q(n.payload)?n.payload:{},c=h(n.ts,h(n.timestamp,new Date().toISOString())),d=h(n.phase,h(r.phase,"")),f=h(n.category,"");return{type:s,actor:i||a||h(r.actor_name,""),actor_id:a||h(r.actor_id,""),actor_name:i,seq:n.seq,room_id:h(n.room_id,""),phase:d||void 0,category:f||Vl(s),visibility:h(n.visibility,h(r.visibility,"public")),event_id:h(n.event_id,""),content:Yl(s,a,i,r),dice_roll:Gl(s,r),timestamp:c}}function Ql(t,e,n){var K,tt;const s=h(t.room_id,"")||n||"default",a=q(t.state)?t.state:{},i=q(a.party)?a.party:{},r=q(a.actor_control)?a.actor_control:{},c=q(a.join_gate)?a.join_gate:{},d=q(a.contribution_ledger)?a.contribution_ledger:{},f=Object.entries(i).map(([G,st])=>{const b=q(st)?st:{},le=ht(b,"max_hp",void 0,10),Be=ht(b,"hp",void 0,le),Pn=ht(b,"max_mp",void 0,0),Mn=ht(b,"mp",void 0,0),E=ht(b,"level",void 0,1),ce=ht(b,"xp",void 0,0),Dn=Da(b.alive,Be>0),wo=r[G],To=typeof wo=="string"?wo:void 0,Er=Hl(b.role,G,To),zr=Kl(b.generation),Or=lt(b.joined_at,b.joinedAt,b.started_at,b.startedAt),jr=lt(b.claimed_at,b.claimedAt,b.assigned_at,b.assignedAt,b.assigned_time),Fr=lt(b.last_seen,b.lastSeen,b.last_seen_at,b.lastSeenAt,b.last_active,b.lastActive),qr=lt(b.scene,b.current_scene,b.currentScene,b.world_scene,b.scene_name,b.sceneName),Kr=lt(b.location,b.current_location,b.currentLocation,b.position,b.zone,b.area);return{id:G,name:h(b.name,G),role:Er,keeper:To,archetype:h(b.archetype,""),persona:h(b.persona,""),portrait:h(b.portrait,"")||void 0,background:h(b.background,"")||void 0,traits:Ge(b.traits),skills:Ge(b.skills),stats_raw:Bl(b),status:Dn?"active":"dead",generation:zr,joined_at:Or||void 0,claimed_at:jr||void 0,last_seen:Fr||void 0,scene:qr||void 0,location:Kr||void 0,inventory:Ge(b.inventory),notes:Ge(b.notes),relationships:Ul(b.relationships),stats:{hp:Be,max_hp:le,mp:Mn,max_mp:Pn,level:E,xp:ce,strength:ht(b,"strength","str",10),dexterity:ht(b,"dexterity","dex",10),constitution:ht(b,"constitution","con",10),intelligence:ht(b,"intelligence","int",10),wisdom:ht(b,"wisdom","wis",10),charisma:ht(b,"charisma","cha",10)}}}),p=f.filter(G=>G.status!=="dead"),u=ql(t,e),g={phase_open:Da(c.phase_open,!0),min_points:W(c.min_points,3),window:h(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},$=Object.entries(d).map(([G,st])=>{const b=q(st)?st:{};return{actor_id:G,score:W(b.score,0),last_reason:h(b.last_reason,"")||null,reasons:Ge(b.reasons)}}),x=f.reduce((G,st)=>(G[st.id]=st.name,G),{}),A=e.map(G=>Xl(G,x)),I=W(a.turn,1),M=h(a.phase,"round"),U=h(a.map,""),D=q(a.world)?a.world:{},N=U||h(D.ascii_map,h(D.map,"")),R=A.filter((G,st)=>{const b=e[st];if(!q(b))return!1;const le=q(b.payload)?b.payload:{};return W(le.turn,-1)===I}),Y=(R.length>0?R:A).slice(-12),J=h(a.status,"active");return{session:{id:s,room:s,status:J==="ended"?"ended":J==="paused"?"paused":"active",round:I,actors:p,created_at:((K=A[0])==null?void 0:K.timestamp)??new Date().toISOString()},current_round:{round_number:I,phase:M,events:Y,timestamp:((tt=A[A.length-1])==null?void 0:tt.timestamp)??new Date().toISOString()},map:N||void 0,join_gate:g,contribution_ledger:$,outcome:u,party:p,story_log:A,history:[]}}async function Zl(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await nt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function tc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([nt(`/api/v1/trpg/state${e}`),Zl(t)]);return Ql(n,s,t)}function ec(t){return Et("/api/v1/trpg/rounds/run",{room_id:t})}function nc(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function sc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Et("/api/v1/trpg/dice/roll",e)}function ac(t,e){const n=nc();return Et("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function oc(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Et("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function ic(t,e,n){return Et("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function rc(t,e,n){const s=await ae("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function lc(t){const e=await ae("trpg.mid_join.request",t);return JSON.parse(e)}async function cc(t,e){await ae("masc_broadcast",{agent_name:t,message:e})}async function dc(t=40){return(await ae("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function uc(t,e=20){return ae("masc_task_history",{task_id:t,limit:e})}async function pc(t){const e=await ae("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function mc(t){return xi("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await nt(`/api/v1/council/debates/${e}/summary`);if(!q(n))return null;const s=h(n.id,"").trim();return s?{id:s,topic:h(n.topic,""),status:h(n.status,"open"),support_count:W(n.support_count,0),oppose_count:W(n.oppose_count,0),neutral_count:W(n.neutral_count,0),total_arguments:W(n.total_arguments,0),created_at:os(n.created_at_iso??n.created_at),summary_text:h(n.summary_text,"")}:null})}function vc(t,e,n){return ae("masc_keeper_msg",{name:t,message:e})}const _c=m(""),qt=m({}),dt=m({}),La=m({}),Ea=m({}),za=m({}),Oa=m({}),Kt=m({});function rt(t,e,n){t.value={...t.value,[e]:n}}function Wt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function B(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function Ct(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ae(t){return typeof t=="boolean"?t:void 0}function ja(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function Fa(t){return Array.isArray(t)?t.map(e=>B(e)).filter(e=>!!e):[]}function fc(t){var n;const e=(n=B(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function gc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function ta(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!Wt(s))continue;const a=B(s.name);if(!a)continue;const i=B(s[e]);e==="summary"?n.push({name:a,summary:i}):n.push({name:a,reason:i})}return n}function $c(t){if(!Wt(t))return null;const e=B(t.name);return e?{name:e,trigger:B(t.trigger),outcome:B(t.outcome),summary:B(t.summary),reason:B(t.reason)}:null}function hc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function yc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Ci(t,e,n){return B(t)??yc(e,n)}function wi(t,e){return typeof t=="boolean"?t:e==="recover"}function is(t){if(!Wt(t))return null;const e=B(t.health_state),n=B(t.next_action_path),s=B(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:B(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:ja(t.last_reply_at),last_reply_preview:B(t.last_reply_preview)??null,last_error:B(t.last_error)??null,next_eligible_at_s:Ct(t.next_eligible_at_s)??null,recoverable:wi(t.recoverable,n),summary:Ci(t.summary,e,B(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Ti(t){return Wt(t)?{hour:Ct(t.hour),checked:Ct(t.checked)??0,acted:Ct(t.acted)??0,acted_names:Fa(t.acted_names),activity_report:B(t.activity_report),quiet_hours_overridden:Ae(t.quiet_hours_overridden),skipped_reason:B(t.skipped_reason),acted_rows:ta(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:ta(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:ta(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map($c).filter(e=>e!==null):[]}:null}function bc(t){return Wt(t)?{enabled:Ae(t.enabled)??!1,interval_s:Ct(t.interval_s)??0,quiet_start:Ct(t.quiet_start),quiet_end:Ct(t.quiet_end),quiet_active:Ae(t.quiet_active),use_planner:Ae(t.use_planner),delegate_llm:Ae(t.delegate_llm),agent_count:Ct(t.agent_count),agents:Fa(t.agents),last_tick_ago_s:Ct(t.last_tick_ago_s)??null,last_tick_ago:B(t.last_tick_ago),total_ticks:Ct(t.total_ticks),total_checkins:Ct(t.total_checkins),last_skip_reason:B(t.last_skip_reason)??null,last_tick_result:Ti(t.last_tick_result),active_self_heartbeats:Fa(t.active_self_heartbeats)}:null}function kc(t){return Wt(t)?{status:t.status,diagnostic:is(t.diagnostic)}:null}function xc(t){return Wt(t)?{recovered:Ae(t.recovered)??!1,skipped_reason:B(t.skipped_reason)??null,before:is(t.before),after:is(t.after),down:t.down,up:t.up}:null}function Sc(t,e){var U,D;if(!(t!=null&&t.name))return null;const n=B((U=t.agent)==null?void 0:U.status)??B(t.status)??"unknown",s=B((D=t.agent)==null?void 0:D.error)??null,a=t.presence_keepalive??!0,i=t.keepalive_running??!1,r=t.turn_count??0,c=t.last_turn_ago_s??null,d=t.proactive_enabled??!1,f=t.proactive_cooldown_sec??0,p=t.last_proactive_ago_s??null,u=d&&p!=null?Math.max(0,f-p):null,g=r<=0||c==null?"never":c>900?"stale":"fresh",$=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,x=s??(a&&!i?"keeper keepalive is not running":null),A=n==="offline"||n==="inactive"?"offline":x?"degraded":g==="stale"?"stale":g==="never"?"idle":"healthy",I=x?hc(x):e!=null&&e.quiet_active&&g!=="fresh"?"quiet_hours":a&&!i?"disabled":r<=0?"never_started":u!=null&&u>0?"min_gap":g==="fresh"||g==="stale"?"no_recent_activity":"unknown",M=A==="offline"||A==="degraded"||A==="stale"?"recover":I==="quiet_hours"?"manual_lodge_poke":I==="unknown"?"probe":"direct_message";return{health_state:A,quiet_reason:I,next_action_path:M,last_reply_status:g,last_reply_at:$,last_reply_preview:null,last_error:x,next_eligible_at_s:u!=null&&u>0?u:null,recoverable:wi(void 0,M),summary:Ci(void 0,A,I),keepalive_running:i}}function Ac(t,e){if(!Wt(t))return null;const n=fc(t.role),s=B(t.content)??B(t.preview);if(!s)return null;const a=ja(t.ts_unix)??ja(t.timestamp);return{id:`${n}-${a??"entry"}-${e}`,role:n,label:gc(n),text:s,timestamp:a,delivery:"history"}}function Cc(t,e,n){const s=Wt(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((i,r)=>Ac(i,r)).filter(i=>i!==null):[];return{name:t,diagnostic:is(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function Do(t,e){const n=dt.value[t]??[];dt.value={...dt.value,[t]:[...n,e].slice(-50)}}function wc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Tc(t,e){const s=(dt.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(i=>wc(a,i)));dt.value={...dt.value,[t]:[...e,...s].slice(-50)}}function zs(t,e){qt.value={...qt.value,[t]:e},Tc(t,e.history)}function Lo(t,e){const n=qt.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};zs(t,{...n,diagnostic:{...s,...e}})}async function co(){try{await Tn()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Ic(t){_c.value=t.trim()}async function Ii(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&qt.value[n])return qt.value[n];rt(La,n,!0),rt(Kt,n,null);try{const s=await ae("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const i=Cc(n,s,a);return zs(n,i),i}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return rt(Kt,n,a),null}finally{rt(La,n,!1)}}async function Nc(t,e){const n=t.trim(),s=e.trim();if(!n||!s)return;const a=`local-${Date.now()}`;Do(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),rt(Ea,n,!0),rt(Kt,n,null);try{const i=await vc(n,s);dt.value={...dt.value,[n]:(dt.value[n]??[]).map(r=>r.id===a?{...r,delivery:"delivered"}:r)},Do(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Lo(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await co()}catch(i){const r=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw dt.value={...dt.value,[n]:(dt.value[n]??[]).map(c=>c.id===a?{...c,delivery:"error",error:r}:c)},Lo(n,{last_reply_status:"error",last_error:r}),rt(Kt,n,r),i}finally{rt(Ea,n,!1)}}async function Rc(t,e){const n=t.trim();if(!n)return null;rt(za,n,!0),rt(Kt,n,null);try{const s=await Es({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=kc(s.result),i=(a==null?void 0:a.diagnostic)??null;if(i){const r=qt.value[n];zs(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??dt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await co(),i}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw rt(Kt,n,a),s}finally{rt(za,n,!1)}}async function Pc(t,e){const n=t.trim();if(!n)return null;rt(Oa,n,!0),rt(Kt,n,null);try{const s=await Es({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=xc(s.result),i=(a==null?void 0:a.after)??null;if(i){const r=qt.value[n];zs(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??dt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await co(),i}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw rt(Kt,n,a),s}finally{rt(Oa,n,!1)}}function de(t){return(t??"").trim().toLowerCase()}function _t(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Jn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Ln(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Je(t){return t.last_heartbeat??Ln(t.last_turn_ago_s)??Ln(t.last_proactive_ago_s)??Ln(t.last_handoff_ago_s)??Ln(t.last_compaction_ago_s)}function Mc(t){const e=t.title.trim();return e||Jn(t.content)}function Dc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Lc(t,e,n,s,a={}){var D;const i=de(t),r=e.filter(N=>de(N.assignee)===i&&(N.status==="claimed"||N.status==="in_progress")).length,c=n.filter(N=>de(N.from)===i).sort((N,R)=>_t(R.timestamp)-_t(N.timestamp))[0],d=s.filter(N=>de(N.agent)===i||de(N.author)===i).sort((N,R)=>_t(R.timestamp)-_t(N.timestamp))[0],f=(a.boardPosts??[]).filter(N=>de(N.author)===i).sort((N,R)=>_t(R.updated_at||R.created_at)-_t(N.updated_at||N.created_at))[0],p=(a.keepers??[]).filter(N=>de(N.name)===i&&Je(N)!==null).sort((N,R)=>_t(Je(R)??0)-_t(Je(N)??0))[0],u=c?_t(c.timestamp):0,g=d?_t(d.timestamp):0,$=f?_t(f.updated_at||f.created_at):0,x=p?_t(Je(p)??0):0,A=a.lastSeen?_t(a.lastSeen):0,I=((D=a.currentTask)==null?void 0:D.trim())||(r>0?`${r} claimed tasks`:null);if(u===0&&g===0&&$===0&&x===0&&A===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:I};const U=[c?{timestamp:c.timestamp,ts:u,text:Jn(c.content)}:null,f?{timestamp:f.updated_at||f.created_at,ts:$,text:`Post: ${Jn(Mc(f))}`}:null,p?{timestamp:Je(p),ts:x,text:Dc(p)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:g,text:Jn(d.text)}:null].filter(N=>N!==null).sort((N,R)=>R.ts-N.ts)[0];return U&&U.ts>=A?{activeAssignedCount:r,lastActivityAt:U.timestamp,lastActivityText:U.text}:{activeAssignedCount:r,lastActivityAt:a.lastSeen??null,lastActivityText:I??"Presence heartbeat"}}const Bt=m([]),Mt=m([]),Oe=m([]),oe=m([]),Re=m(null),Ec=m(null),qa=m(new Map),Os=m([]),ln=m("hot"),Ce=m(!0),Ni=m(null),Ft=m(""),cn=m([]),we=m(!1),Ri=m(new Map),uo=m("unknown"),rs=m(null),Ka=m(!1),dn=m(!1),Ua=m(!1),Te=m(!1),po=m(null),ls=m(!1),cs=m(null),Pi=m(null),Ha=m(null),Mi=m(null),Di=m(null),zc=m(null);se(()=>Bt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const Oc=se(()=>{const t=Mt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Li=se(()=>{const t=new Map,e=Mt.value,n=Oe.value,s=Ra.value,a=Os.value,i=oe.value;for(const r of Bt.value)t.set(r.name.trim().toLowerCase(),Lc(r.name,e,n,s,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:a,keepers:i}));return t});function jc(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const Fc=se(()=>{const t=new Map;for(const e of oe.value)t.set(e.name,jc(e));return t}),qc=12e4;function Kc(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof a=="number"?Date.now()-a*1e3:null}const Uc=se(()=>{const t=Date.now(),e=new Set,n=qa.value;for(const s of oe.value){const a=Kc(s,n);a!=null&&t-a>qc&&e.add(s.name)}return e});let ea=null;function Hc(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function it(t){return typeof t=="object"&&t!==null}function y(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function C(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Nt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Wa(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Ei(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Wc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Bc(t){if(!it(t))return null;const e=y(t.name);return e?{name:e,agent_type:y(t.agent_type),status:Ei(t.status),current_task:y(t.current_task)??null,joined_at:y(t.joined_at),last_seen:y(t.last_seen),capabilities:Nt(t.capabilities),emoji:y(t.emoji),koreanName:y(t.koreanName)??y(t.korean_name),model:y(t.model),traits:Nt(t.traits),interests:Nt(t.interests),activityLevel:C(t.activityLevel)??C(t.activity_level),primaryValue:y(t.primaryValue)??y(t.primary_value)}:null}function Gc(t){if(!it(t))return null;const e=y(t.id),n=y(t.title);return!e||!n?null:{id:e,title:n,status:Wc(t.status),priority:C(t.priority),assignee:y(t.assignee),description:y(t.description),created_at:y(t.created_at),updated_at:y(t.updated_at)}}function Jc(t){if(!it(t))return null;const e=y(t.from)??y(t.from_agent)??"system",n=y(t.content)??"",s=y(t.timestamp)??new Date().toISOString();return{id:y(t.id),seq:C(t.seq),from:e,content:n,timestamp:s,type:y(t.type)}}function Eo(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function Vc(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>Eo(s)-Eo(a)).slice(-500)}function Yc(t){return Array.isArray(t)?t.map(e=>{if(!it(e))return null;const n=C(e.ts_unix);if(n==null)return null;const s=it(e.handoff)?e.handoff:null;return{ts:n,context_ratio:C(e.context_ratio)??0,context_tokens:C(e.context_tokens)??0,context_max:C(e.context_max)??0,latency_ms:C(e.latency_ms)??0,generation:C(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:C(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:C(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?C(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function zo(t){if(!it(t))return null;const e=y(t.health_state),n=y(t.next_action_path),s=y(t.last_reply_status);if(!e||!n||!s)return null;const a=y(t.quiet_reason)??null,i=y(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:Wa(t.last_reply_at)??y(t.last_reply_at)??null,last_reply_preview:y(t.last_reply_preview)??null,last_error:y(t.last_error)??null,next_eligible_at_s:C(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:i,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Xc(t,e){return(Array.isArray(t)?t:it(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!it(s))return null;const a=it(s.agent)?s.agent:null,i=it(s.context)?s.context:null,r=it(s.metrics_window)?s.metrics_window:void 0,c=y(s.name);if(!c)return null;const d=C(s.context_ratio)??C(i==null?void 0:i.context_ratio),f=y(s.status)??y(a==null?void 0:a.status)??"offline",p=Ei(f),u=y(s.model)??y(s.active_model)??y(s.primary_model),g=Nt(s.skill_secondary),$=i?{source:y(i.source),context_ratio:C(i.context_ratio),context_tokens:C(i.context_tokens),context_max:C(i.context_max),message_count:C(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,x=a?{name:y(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:y(a.error),agent_type:y(a.agent_type),status:y(a.status),current_task:y(a.current_task)??null,joined_at:y(a.joined_at),last_seen:y(a.last_seen),last_seen_ago_s:C(a.last_seen_ago_s),capabilities:Nt(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,A=Yc(s.metrics_series),I={name:c,emoji:y(s.emoji),koreanName:y(s.koreanName)??y(s.korean_name),agent_name:y(s.agent_name),trace_id:y(s.trace_id),model:u,primary_model:y(s.primary_model),active_model:y(s.active_model),next_model_hint:y(s.next_model_hint)??null,status:p,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:C(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:C(s.proactive_idle_sec),proactive_cooldown_sec:C(s.proactive_cooldown_sec),last_heartbeat:y(s.last_heartbeat)??y(a==null?void 0:a.last_seen),generation:C(s.generation),turn_count:C(s.turn_count)??C(s.total_turns),keeper_age_s:C(s.keeper_age_s),last_turn_ago_s:C(s.last_turn_ago_s),last_handoff_ago_s:C(s.last_handoff_ago_s),last_compaction_ago_s:C(s.last_compaction_ago_s),last_proactive_ago_s:C(s.last_proactive_ago_s),last_proactive_preview:y(s.last_proactive_preview)??null,context_ratio:d,context_tokens:C(s.context_tokens)??C(i==null?void 0:i.context_tokens),context_max:C(s.context_max)??C(i==null?void 0:i.context_max),context_source:y(s.context_source)??y(i==null?void 0:i.source),context:$,traits:Nt(s.traits),interests:Nt(s.interests),primaryValue:y(s.primaryValue)??y(s.primary_value),activityLevel:C(s.activityLevel)??C(s.activity_level),memory_recent_note:y(s.memory_recent_note)??null,recent_input_preview:y(s.recent_input_preview)??null,recent_output_preview:y(s.recent_output_preview)??null,recent_tool_names:Nt(s.recent_tool_names)??[],conversation_tail_count:C(s.conversation_tail_count),k2k_count:C(s.k2k_count),handoff_count_total:C(s.handoff_count_total)??C(s.trace_history_count),compaction_count:C(s.compaction_count),last_compaction_saved_tokens:C(s.last_compaction_saved_tokens),diagnostic:zo(s.diagnostic),skill_primary:y(s.skill_primary)??null,skill_secondary:g,skill_reason:y(s.skill_reason)??null,metrics_series:A.length>0?A:void 0,metrics_window:r,agent:x};return I.diagnostic=zo(s.diagnostic)??Sc(I,(e==null?void 0:e.lodge)??null),I}).filter(s=>s!==null)}function zi(t){return it(t)?{...t,lodge:bc(t.lodge)??void 0}:null}function Qc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function Zc(t){if(!it(t))return null;const e=C(t.iteration);if(e==null)return null;const n=C(t.metric_before)??0,s=C(t.metric_after)??n,a=it(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:C(t.delta)??s-n,changes:y(t.changes)??"",failed_attempts:y(t.failed_attempts)??"",next_suggestion:y(t.next_suggestion)??"",elapsed_ms:C(t.elapsed_ms)??0,cost_usd:C(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:y(a.worker_model)??"",tool_call_count:C(a.tool_call_count)??0,tool_names:Nt(a.tool_names)??[],session_id:y(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function td(t){var i,r;if(!it(t))return null;const e=y(t.loop_id);if(!e)return null;const n=C(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(Zc).filter(c=>c!==null):[],a=C(t.current_metric)??((i=s[0])==null?void 0:i.metric_after)??n;return{loop_id:e,profile:y(t.profile)??"unknown",status:Qc(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:y(t.error_message)??y(t.error_reason)??null,stop_reason:y(t.stop_reason)??y(t.reason)??null,current_iteration:C(t.current_iteration)??((r=s[0])==null?void 0:r.iteration)??0,max_iterations:C(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:y(t.target)??"",stagnation_streak:C(t.stagnation_streak)??0,stagnation_limit:C(t.stagnation_limit)??0,elapsed_seconds:C(t.elapsed_seconds)??0,updated_at:Wa(t.updated_at)??null,stopped_at:Wa(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:y(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:C(t.latest_tool_call_count)??0,latest_tool_names:Nt(t.latest_tool_names)??[],session_id:y(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function Tn(){Ka.value=!0;try{await Promise.all([ji(),Ot()]),Pi.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{Ka.value=!1}}async function Oi(){ls.value=!0,cs.value=null;try{const t=await bl();po.value=t,zc.value=new Date().toISOString()}catch(t){cs.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{ls.value=!1}}function ed(t){var e;return((e=po.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function nd(t){var n;const e=((n=po.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(i=>i.id===t);if(a)return a}return null}function sd(t){var s,a;cn.value=(Array.isArray(t.goals)?t.goals:[]).map(i=>{if(!it(i))return null;const r=y(i.id),c=y(i.title),d=y(i.horizon),f=y(i.status),p=y(i.created_at),u=y(i.updated_at);return!r||!c||!d||!f||!p||!u?null:{id:r,horizon:d,title:c,metric:y(i.metric)??null,target_value:y(i.target_value)??null,due_date:y(i.due_date)??null,priority:C(i.priority)??3,status:f,parent_goal_id:y(i.parent_goal_id)??null,last_review_note:y(i.last_review_note)??null,last_review_at:y(i.last_review_at)??null,created_at:p,updated_at:u}}).filter(i=>i!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const i of n){const r=td(i);r&&e.set(r.loop_id,r)}Ri.value=e,rs.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,uo.value=rs.value?"error":e.size===0?"idle":"ready"}async function ji(){try{const t=await gl(),e=zi(t.status);e&&(Re.value=e)}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Ot(){var t;try{const e=await $l(),n=zi(e.status),s=(t=Re.value)==null?void 0:t.room;n&&(Re.value=n);const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;Bt.value=(Array.isArray(e.agents)?e.agents:[]).map(Bc).filter(r=>r!==null),Mt.value=(Array.isArray(e.tasks)?e.tasks:[]).map(Gc).filter(r=>r!==null);const i=(Array.isArray(e.messages)?e.messages:[]).map(Jc).filter(r=>r!==null);Oe.value=a?i:Vc(Oe.value,i),oe.value=Xc(e.keepers,n??Re.value),Ec.value=null,Pi.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function Dt(){dn.value=!0;try{const t=await hl(ln.value,{excludeSystem:Ce.value});Os.value=t.posts??[],Ha.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{dn.value=!1}}async function Lt(){var t;Ua.value=!0;try{const e=Ft.value||((t=Re.value)==null?void 0:t.room)||"default";Ft.value||(Ft.value=e);const n=await tc(e);Ni.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Ua.value=!1}}async function je(){we.value=!0,Te.value=!0;try{const t=await Sl();sd(t),Mi.value=new Date().toISOString(),Di.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),uo.value="error",rs.value=t instanceof Error?t.message:String(t)}finally{we.value=!1,Te.value=!1}}async function Ba(){return je()}let Vn=null;function ad(t){Vn=t}let Yn=null;function od(t){Yn=t}let Xn=null;function id(t){Xn=t}const ve={};function ue(t,e,n=500){ve[t]&&clearTimeout(ve[t]),ve[t]=setTimeout(()=>{e(),delete ve[t]},n)}function rd(){const t=gi.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(qa.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),qa.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&ue("execution",Ot),Hc(e.type)&&(ea||(ea=setTimeout(()=>{Tn(),Yn==null||Yn(),Xn==null||Xn(),ea=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&ue("execution",Ot),e.type==="broadcast"&&ue("execution",Ot),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&ue("execution",Ot),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&ue("board",Dt),e.type.startsWith("decision_")&&ue("council",()=>Vn==null?void 0:Vn()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&ue("mdal",Ba,350)}});return()=>{t();for(const e of Object.keys(ve))clearTimeout(ve[e]),delete ve[e]}}let Ze=null;function ld(){Ze||(Ze=setInterval(()=>{$e.value,Tn()},1e4))}function cd(){Ze&&(clearInterval(Ze),Ze=null)}function dd({metric:t}){return o`
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
  `}function ud({panel:t}){return o`
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
            ${t.metrics.map(e=>o`<${dd} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function z({panelId:t,compact:e=!1,label:n="Why"}){const s=nd(t);return s?o`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${ud} panel=${s} />
    </details>
  `:ls.value?o`<span class="semantic-inline-state">Loading semantics…</span>`:null}function kt({surfaceId:t,compact:e=!1}){const n=ed(t);return n?o`
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
  `:ls.value?o`<div class="semantic-surface-card ${e?"compact":""}">Loading semantics…</div>`:cs.value?o`<div class="semantic-surface-card ${e?"compact":""}">${cs.value}</div>`:null}function T({title:t,class:e,semanticId:n,children:s}){return o`
    <div class="card ${e??""}">
      ${t?o`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?o`<${z} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${s}
    </div>
  `}const js=m(null),Ga=m(!1),ds=m(null),Fi=m(null),Ie=m(!1),me=m(null);function O(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function w(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function j(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Fs(t){return typeof t=="boolean"?t:void 0}function bt(t,e=[]){if(Array.isArray(t))return t;if(!O(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function qs(t){if(!O(t))return null;const e=w(t.kind),n=w(t.summary),s=w(t.target_type);return!e||!n||!s?null:{kind:e,severity:w(t.severity)??"warn",summary:n,target_type:s,target_id:w(t.target_id)??null,actor:w(t.actor)??null,evidence:t.evidence}}function Ks(t){if(!O(t))return null;const e=w(t.action_type),n=w(t.target_type),s=w(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:w(t.target_id)??null,severity:w(t.severity)??"warn",reason:s,confirm_required:Fs(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function pd(t){if(!O(t))return null;const e=w(t.session_id);return e?{session_id:e,goal:w(t.goal),status:w(t.status),health:w(t.health),scale_profile:w(t.scale_profile),control_profile:w(t.control_profile),planned_worker_count:j(t.planned_worker_count),active_agent_count:j(t.active_agent_count),last_turn_age_sec:j(t.last_turn_age_sec)??null,attention_count:j(t.attention_count),recommended_action_count:j(t.recommended_action_count),top_attention:qs(t.top_attention),top_recommendation:Ks(t.top_recommendation)}:null}function md(t){if(!O(t))return null;const e=w(t.session_id);if(!e)return null;const n=O(t.status)?t.status:t,s=O(n.summary)?n.summary:void 0;return{session_id:e,status:w(t.status)??w(s==null?void 0:s.status)??(O(n.session)?w(n.session.status):void 0),progress_pct:j(t.progress_pct)??j(s==null?void 0:s.progress_pct),elapsed_sec:j(t.elapsed_sec)??j(s==null?void 0:s.elapsed_sec),remaining_sec:j(t.remaining_sec)??j(s==null?void 0:s.remaining_sec),done_delta_total:j(t.done_delta_total)??j(s==null?void 0:s.done_delta_total),summary:O(t.summary)?t.summary:s,team_health:O(t.team_health)?t.team_health:O(n.team_health)?n.team_health:void 0,communication_metrics:O(t.communication_metrics)?t.communication_metrics:O(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:O(t.orchestration_state)?t.orchestration_state:O(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:O(t.cascade_metrics)?t.cascade_metrics:O(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:O(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,i])=>{const r=w(i);return r?[a,r]:null}).filter(a=>a!==null)):O(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,i])=>{const r=w(i);return r?[a,r]:null}).filter(a=>a!==null)):void 0,session:O(t.session)?t.session:O(n.session)?n.session:void 0,recent_events:bt(t.recent_events,["events"]).filter(O)}}function vd(t){if(!O(t))return null;const e=w(t.name);return e?{name:e,agent_name:w(t.agent_name),status:w(t.status),autonomy_level:w(t.autonomy_level),context_ratio:j(t.context_ratio),generation:j(t.generation),active_goal_ids:bt(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:w(t.last_autonomous_action_at)??null,last_turn_ago_s:j(t.last_turn_ago_s),model:w(t.model)}:null}function _d(t){if(!O(t))return null;const e=w(t.confirm_token)??w(t.token);return e?{confirm_token:e,actor:w(t.actor),action_type:w(t.action_type),target_type:w(t.target_type),target_id:w(t.target_id)??null,delegated_tool:w(t.delegated_tool),created_at:w(t.created_at),preview:t.preview}:null}function fd(t){if(!O(t))return null;const e=w(t.action_type),n=w(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:w(t.description),confirm_required:Fs(t.confirm_required)}}function gd(t){const e=O(t)?t:{};return{room_health:w(e.room_health),cluster:w(e.cluster),project:w(e.project),current_room:w(e.current_room)??null,paused:Fs(e.paused),tempo_interval_s:j(e.tempo_interval_s),active_agents:j(e.active_agents),keeper_pressure:j(e.keeper_pressure),active_operations:j(e.active_operations),pending_approvals:j(e.pending_approvals),incident_count:j(e.incident_count),recommended_action_count:j(e.recommended_action_count),top_attention:qs(e.top_attention),top_action:Ks(e.top_action)}}function $d(t){const e=O(t)?t:{},n=O(e.swarm_overview)?e.swarm_overview:{};return{health:w(e.health),active_operations:j(e.active_operations),pending_approvals:j(e.pending_approvals),swarm_overview:{active_lanes:j(n.active_lanes),moving_lanes:j(n.moving_lanes),stalled_lanes:j(n.stalled_lanes),projected_lanes:j(n.projected_lanes),last_movement_at:w(n.last_movement_at)??null},top_attention:qs(e.top_attention),top_action:Ks(e.top_action),session_cards:bt(e.session_cards).map(pd).filter(s=>s!==null)}}function hd(t){const e=O(t)?t:{};return{sessions:bt(e.sessions,["items"]).map(md).filter(n=>n!==null),keepers:bt(e.keepers,["items"]).map(vd).filter(n=>n!==null),pending_confirms:bt(e.pending_confirms).map(_d).filter(n=>n!==null),available_actions:bt(e.available_actions).map(fd).filter(n=>n!==null)}}function yd(t){const e=O(t)?t:{};return{generated_at:w(e.generated_at),summary:gd(e.summary),incidents:bt(e.incidents).map(qs).filter(n=>n!==null),recommended_actions:bt(e.recommended_actions).map(Ks).filter(n=>n!==null),command_focus:$d(e.command_focus),operator_targets:hd(e.operator_targets)}}function bd(t){if(!O(t))return null;const e=w(t.id),n=w(t.label),s=w(t.summary);if(!e||!n||!s)return null;const a=w(t.status)??"unclear";return{id:e,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,evidence:bt(t.evidence).map(r=>typeof r=="string"?r.trim():"").filter(Boolean)}}function kd(t){const e=O(t)?t:{},n=O(e.basis)?e.basis:{},s=w(e.status)??"error",a=s==="ok"||s==="unavailable"||s==="error"?s:"error";return{generated_at:w(e.generated_at),cached:Fs(e.cached),status:a,model:w(e.model)??null,ttl_sec:j(e.ttl_sec),criteria:bt(e.criteria).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),basis:{current_room:w(n.current_room)??null,crew_count:j(n.crew_count),agent_count:j(n.agent_count),keeper_count:j(n.keeper_count)},sections:bt(e.sections).map(bd).filter(i=>i!==null),error:w(e.error)??null}}async function Qn(){Ga.value=!0,ds.value=null;try{const t=await kl();js.value=yd(t)}catch(t){ds.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{Ga.value=!1}}async function us(t=!1){Ie.value=!0,me.value=null;try{const e=await xl(t);Fi.value=kd(e)}catch(e){me.value=e instanceof Error?e.message:"Failed to load mission briefing"}finally{Ie.value=!1}}function ie({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function xd(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function at({timestamp:t}){const e=xd(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}let Sd=0;const _e=m([]);function P(t,e="success",n=4e3){const s=++Sd;_e.value=[..._e.value,{id:s,message:t,type:e}],setTimeout(()=>{_e.value=_e.value.filter(a=>a.id!==s)},n)}function Ad(t){_e.value=_e.value.filter(e=>e.id!==t)}function Cd(){const t=_e.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Ad(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const wd="masc_dashboard_agent_name",Ue=m(null),ps=m(!1),un=m(""),ms=m([]),pn=m([]),Pe=m(""),tn=m(!1);function Us(t){Ue.value=t,mo()}function Oo(){Ue.value=null,un.value="",ms.value=[],pn.value=[],Pe.value=""}function Td(){const t=Ue.value;return t?Bt.value.find(e=>e.name===t)??null:null}function qi(t){return t?Mt.value.filter(e=>e.assignee===t):[]}async function mo(){const t=Ue.value;if(t){ps.value=!0,un.value="",ms.value=[],pn.value=[];try{const e=await dc(80);ms.value=e.filter(a=>a.includes(t)).slice(0,20);const n=qi(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await uc(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));pn.value=s}catch(e){un.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{ps.value=!1}}}async function jo(){var s;const t=Ue.value,e=Pe.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(wd))==null?void 0:s.trim())||"dashboard";tn.value=!0;try{await cc(n,`@${t} ${e}`),Pe.value="",P(`Mention sent to ${t}`,"success"),mo()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";P(i,"error")}finally{tn.value=!1}}function Id({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${ie} status=${t.status} />
    </div>
  `}function Nd({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Rd(){var a,i,r,c;const t=Ue.value;if(!t)return null;const e=Td(),n=qi(t),s=ms.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&Oo()}}
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
                        <${ie} status=${e.status} />
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
                ${(c=e==null?void 0:e.interests)==null?void 0:c.map(d=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${at} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{mo()}} disabled=${ps.value}>
              ${ps.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Oo}>Close</button>
          </div>
        </div>

        ${un.value?o`<div class="council-error">${un.value}</div>`:null}

        <div class="agent-detail-grid">
          <${T} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${Id} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${T} title="Recent Activity">
            ${s.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${s.map((d,f)=>o`<div key=${f} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${T} title="Task History">
          ${pn.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${pn.value.map(d=>o`<${Nd} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${T} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Pe.value}
              onInput=${d=>{Pe.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&jo()}}
              disabled=${tn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{jo()}}
              disabled=${tn.value||Pe.value.trim()===""}
            >
              ${tn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function Pd(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Md(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Dd(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Fo(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function Ki(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Ld(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Ui(t){if(!t)return null;const e=qt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function Ed({keeper:t,showRawStatus:e=!1}){if(ut(()=>{t!=null&&t.name&&Ii(t.name)},[t==null?void 0:t.name]),!t)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=qt.value[t.name],s=Ui(t),a=La.value[t.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${Pd(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Md((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?o` · ${Ki(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?o` · next eligible ${Ld(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?o`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function zd({keeperName:t,placeholder:e}){const[n,s]=mi("");ut(()=>{t&&Ii(t)},[t]);const a=dt.value[t]??[],i=Ea.value[t]??!1,r=Kt.value[t],c=async()=>{const d=n.trim();if(!(!t||!d)){s("");try{await Nc(t,d)}catch(f){const p=f instanceof Error?f.message:`Failed to message ${t}`;P(p,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?o`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(d=>o`
              <div class="keeper-conversation-item" key=${d.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Fo(d)}`}>${d.label}</span>
                  <span class=${`keeper-role-chip ${Fo(d)}`}>${Dd(d)}</span>
                  ${d.timestamp?o`<span class="keeper-conversation-time">${Ki(d.timestamp)}</span>`:null}
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
            onClick=${()=>{c()}}
            disabled=${i||n.trim()===""||!t}
          >
            ${i?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${r?o`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function Od({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=Ui(e),a=za.value[e.name]??!1,i=Oa.value[e.name]??!1,r=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??r==="recover";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{Rc(e.name,t).catch(d=>{const f=d instanceof Error?d.message:`Failed to probe ${e.name}`;P(f,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{Pc(e.name,t).catch(d=>{const f=d instanceof Error?d.message:`Failed to recover ${e.name}`;P(f,"error")})}}
        disabled=${i||!c||!t.trim()}
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
  `}const vo=m(null);function _o(t){vo.value=t,Ic(t.name)}function qo(){vo.value=null}const xe=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function jd(t){if(!t)return 0;const e=xe.findIndex(n=>n.level===t);return e>=0?e:0}function Fd({keeper:t}){const e=jd(t.autonomy_level),n=xe[e]??xe[0];if(!n)return null;const s=(e+1)/xe.length*100;return o`
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
          ${xe.map((a,i)=>o`
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
            <strong><${at} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Zn(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function qd({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
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
  `}function Kd({keeper:t}){var p,u;const e=t.metrics_series??[];if(e.length<2){const g=(((p=t.context)==null?void 0:p.context_ratio)??0)*100,$=g>85?"#ef4444":g>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${g.toFixed(1)}%;background:${$}"></div>
        </div>
        <span class="chart-pct">${g.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((g,$)=>{const x=a+$/(i-1)*(n-2*a),A=s-a-(g.context_ratio??0)*(s-2*a);return{x,y:A,p:g}}),c=r.map(({x:g,y:$})=>`${g.toFixed(1)},${$.toFixed(1)}`).join(" "),d=(((u=e[e.length-1])==null?void 0:u.context_ratio)??0)*100,f=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:g})=>g.is_handoff).map(({x:g})=>o`
          <line x1="${g.toFixed(1)}" y1="${a}" x2="${g.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${f}" stroke-width="1.5"/>
        ${r.filter(({p:g})=>g.is_compaction).map(({x:g,y:$})=>o`
          <circle cx="${g.toFixed(1)}" cy="${$.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const na=m("");function Ud({keeper:t}){var a,i,r,c;const e=na.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
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
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Hd({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function Wd({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Bd({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Ko({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function sa(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Gd({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:sa(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:sa(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:sa(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function Hi(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function Jd(){try{const t=await Es({actor:Hi(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Ti(t.result);await Tn(),e!=null&&e.skipped_reason?P(e.skipped_reason,"warning"):P(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";P(e,"error")}}function Vd({keeper:t}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Ed} keeper=${t} />
          <${Od}
            actor=${Hi()}
            keeper=${t}
            onPokeLodge=${()=>{Jd()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${zd}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function Yd(){var e,n,s;const t=vo.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&qo()}}
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
            <${ie} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>qo()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${qd} keeper=${t} />

        ${""}
        <${Kd} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${T} title="Field Dictionary">
            <${Ud} keeper=${t} />
          <//>

          ${""}
          <${T} title="Profile">
            <${Ko} traits=${t.traits??[]} label="Traits" />
            <${Ko} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${at} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${T} title="Autonomy">
                <${Fd} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${T} title="TRPG Stats">
                <${Hd} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${T} title="Equipment (${t.inventory.length})">
                <${Wd} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${T} title="Relationships (${Object.keys(t.relationships).length})">
                <${Bd} rels=${t.relationships} />
              <//>
            `:null}

          <${T} title="Runtime Signals">
            <${Gd} keeper=${t} />
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
        <${Vd} keeper=${t} />
      </div>
    </div>
  `:null}const vs="masc_dashboard_workflow_context",Xd=900*1e3;function fo(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function At(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function Gt(t){const e=At(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function Wi(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function Ja(t){return fo(t)?t:null}function Qd(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function Zd(t){if(!t)return null;try{const e=JSON.parse(t);if(!fo(e))return null;const n=At(e.id),s=At(e.source_surface),a=At(e.source_label),i=At(e.summary),r=At(e.created_at);return!n||s!=="mission"||!a||!i||!r?null:{id:n,source_surface:"mission",source_label:a,action_type:At(e.action_type),target_type:At(e.target_type),target_id:At(e.target_id),focus_kind:At(e.focus_kind),summary:i,payload_preview:At(e.payload_preview),suggested_payload:Ja(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:r}}catch{return null}}function go(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=Xd}function tu(){const t=Wi(),e=Zd((t==null?void 0:t.getItem(vs))??null);return e?go(e)?e:(t==null||t.removeItem(vs),null):null}const Bi=m(tu());function eu(t){const e=t&&go(t)?t:null;Bi.value=e;const n=Wi();if(!n)return;if(!e){n.removeItem(vs);return}const s=Qd(e);s&&n.setItem(vs,s)}function Gi(t){if(!t)return null;const e=Ja(t.suggested_payload);if(e)return e;if(fo(t.preview)){const n=Ja(t.preview.payload);if(n)return n}return null}function Ji(t){if(!t)return null;const e=Gt(t.message);if(e)return e;const n=Gt(t.task_title)??Gt(t.title),s=Gt(t.task_description)??Gt(t.description),a=Gt(t.reason),i=Gt(t.priority)??Gt(t.task_priority);return n&&s?`${n} · ${s}`:n&&i?`${n} · P${i}`:n||s||a||null}function Vi(t,e,n,s,a,i){return["mission",t,e??"action",n??"target",s??"room",a??"focus",i].join(":")}function He(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=Gi(t),i=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,r=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,c=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,d=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:Vi(n,(t==null?void 0:t.action_type)??null,i,r,c,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:i,target_id:r,focus_kind:c,summary:d,payload_preview:Ji(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function nu(t,e){return e.source==="mission"&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)}function In(t){const{params:e}=t;if(e.source!=="mission")return null;const n=Bi.value;if(n&&go(n)&&nu(n,e))return n;const s=new Date().toISOString();return{id:Vi("상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,s),source_surface:"mission",source_label:"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,summary:e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function su(t){return{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function Yi(t){const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.target_type==="room"?"summary":"swarm"}function au(t){return{source:"mission",surface:Yi(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function $o(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function ho(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";default:return(t==null?void 0:t.trim())||"추천 액션"}}function ou(t){switch(t){case"summary":return"요약";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}function $t(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function ct(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function mn(t){return typeof t=="number"&&Number.isFinite(t)?t:null}function aa(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function X(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function pt(t){return t==="bad"||t==="offline"||t==="critical"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"?"warn":"ok"}function te(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:n<86400?`${Math.round(n/3600)}h 전`:`${Math.round(n/86400)}d 전`}function iu(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:t<86400?`${Math.round(t/3600)}h`:`${Math.round(t/86400)}d`}function Uo(t){const e=mn(t.ts);if(e!=null)return e;const n=ct(t.ts_iso);if(!n)return 0;const s=Date.parse(n);return Number.isNaN(s)?0:s}function ru(t){return[...new Set(t.filter(Boolean))]}function lu(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function cu(t){return Ji(Gi(t))}function du(t){return $o(t?He(t,null,"상황판 추천 액션"):null)}function Hs(t,e=He()){eu(e),xt(t,t==="intervene"?su(e):au(e))}function uu(t){Hs("intervene",He(null,t,"상황판 incident"))}function pu(t){Hs("command",He(null,t,"상황판 incident"))}function mu(t,e,n="상황판 추천 액션"){Hs("intervene",He(t,e,n))}function vu(t,e,n="상황판 추천 액션"){Hs("command",He(t,e,n))}function Ho(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),xt(t,n)}function Xi(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>(s.from??"").trim().toLowerCase()===n).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function _u(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>{if((s.from??"").trim().toLowerCase()===n)return!1;const i=(s.content??"").trim().toLowerCase();return i.includes(`@${n}`)||i.includes(n)}).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function fu(t){const e=$t(t.session)?t.session:{},n=$t(t.summary)?t.summary:{};return ru([...aa(e.agent_names),...aa(n.active_agents),...aa(n.planned_participants)])}function gu(t){const e=$t(t.session)?t.session:{};return ct(e.goal)??ct(e.session_id)??t.session_id}function $u(t){const e=$t(t.session)?t.session:{};return ct(e.room_id)}function hu(t){const e=$t(t.session)?t.session:{};return ct(e.created_at_iso)}function yu(t){const e=$t(t.session)?t.session:{};return ct(e.updated_at_iso)}function bu(t){const e=$t(t.communication_metrics)?t.communication_metrics:{};return ct(e.mode)}function ku(t){const e=$t(t.communication_metrics)?t.communication_metrics:{};return mn(e.broadcast_count)??0}function xu(t){const e=$t(t.communication_metrics)?t.communication_metrics:{};return mn(e.portal_count)??0}function Su(t){const e=$t(t.team_health)?t.team_health:{};return{active:mn(e.active_agents_count)??0,required:mn(e.required_agents)??0}}function Au(t){const n=[...t.recent_events??[]].sort((p,u)=>Uo(u)-Uo(p))[0];if(!n)return{at:null,summary:"최근 session event가 없습니다."};const s=$t(n.detail)?n.detail:{},a=ct(n.event_type)??"event",i=ct(s.actor),r=ct(s.task_title)??ct(s.title),c=X(ct(s.result),120),d=X(ct(s.reason),120),f=r?`${i?`${i} · `:""}${r}`:c??d??a.replace(/_/g," ");return{at:ct(n.ts_iso),summary:f}}function Cu(){const t=js.value;return t?t.operator_targets.sessions.map(e=>{var i,r;const n=Su(e),s=Au(e),a=t.command_focus.session_cards.find(c=>c.session_id===e.session_id);return{session:e,goal:gu(e),room:$u(e),status:e.status??"unknown",memberNames:fu(e),startedAt:hu(e),stoppedAt:yu(e),elapsedSec:e.elapsed_sec??null,lastEventAt:s.at,lastEventSummary:s.summary,communicationMode:bu(e),broadcastCount:ku(e),portalCount:xu(e),activeCount:n.active,requiredCount:n.required,attentionSummary:((i=a==null?void 0:a.top_attention)==null?void 0:i.summary)??((r=a==null?void 0:a.top_recommendation)==null?void 0:r.reason)??null}}).sort((e,n)=>{const s=Date.parse(e.lastEventAt??e.startedAt??"")||0;return(Date.parse(n.lastEventAt??n.startedAt??"")||0)-s}):[]}function Qi(t){if(t.recent_tool_names&&t.recent_tool_names.length>0)return t.recent_tool_names;const e=$t(t.metrics_window)?t.metrics_window:{};return(Array.isArray(e.top_tools)?e.top_tools:[]).map(s=>$t(s)?ct(s.tool):null).filter(s=>s!==null)}function wu(t){return oe.value.find(e=>e.agent_name===t||e.name===t)??null}function Zi(t,e){const n=X(t.current_task,100);if(!n)return"명시된 current task 없음";const s=e.find(i=>i.id===n);if(s)return`${s.id} · ${X(s.title,92)}`;const a=e.find(i=>i.title===n);return a?`${a.id} · ${X(a.title,92)}`:n}function Tu(t){const e=new Map;for(const n of t)for(const s of n.memberNames)e.has(s)||e.set(s,n);return[...Bt.value].map(n=>{var g,$;const s=e.get(n.name),a=wu(n.name),i=Xi(n.name,Oe.value),r=_u(n.name,Oe.value),c=Li.value.get(n.name.trim().toLowerCase()),d=s?s.memberNames.filter(x=>x!==n.name):[],f=s?`${s.goal}${s.room?` · ${s.room}`:""}`:((g=js.value)==null?void 0:g.summary.current_room)??"room",p=(a==null?void 0:a.skill_primary)??(n.capabilities&&n.capabilities.length>0?n.capabilities.slice(0,3).join(", "):null)??n.agent_type??null,u=Zi(n,Mt.value);return{agent:n,where:f,withWhom:d,activeSince:(s==null?void 0:s.startedAt)??n.joined_at??n.last_seen??null,currentWork:u,how:p,recentInput:X(r==null?void 0:r.content,120)??X(a==null?void 0:a.recent_input_preview,120)??null,recentOutput:X(i==null?void 0:i.content,120)??X(a==null?void 0:a.recent_output_preview,120)??X(($=a==null?void 0:a.diagnostic)==null?void 0:$.last_reply_preview,120)??null,recentEvent:X(c==null?void 0:c.lastActivityText,120)??(s==null?void 0:s.lastEventSummary)??null,recentTools:a?Qi(a):[]}}).sort((n,s)=>{const a=d=>d==="busy"?4:d==="active"?3:d==="listening"?2:d==="idle"?1:0,i=a(s.agent.status)-a(n.agent.status);if(i!==0)return i;const r=Date.parse(n.agent.last_seen??n.activeSince??"")||0;return(Date.parse(s.agent.last_seen??s.activeSince??"")||0)-r})}function Iu(){return[...oe.value].map(t=>{var e,n,s,a;return{keeper:t,activeSince:((e=t.agent)==null?void 0:e.joined_at)??t.created_at??t.last_heartbeat??null,currentWork:X((n=t.agent)==null?void 0:n.current_task,110)??X(t.skill_primary,110)??X(t.last_proactive_reason,110)??"명시된 keeper focus 없음",recentInput:X(t.recent_input_preview,120)??null,recentOutput:X(t.recent_output_preview,120)??X((s=t.diagnostic)==null?void 0:s.last_reply_preview,120)??X(t.last_proactive_preview,120)??null,recentEvent:X(t.last_proactive_reason,120)??X((a=t.diagnostic)==null?void 0:a.summary,120)??null,recentTools:Qi(t)}}).sort((t,e)=>{const n=Date.parse(t.keeper.last_heartbeat??t.activeSince??"")||0;return(Date.parse(e.keeper.last_heartbeat??e.activeSince??"")||0)-n})}function Nu({cluster:t,project:e,room:n,generatedAt:s}){return o`
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
        <strong>${s?te(s):"fresh"}</strong>
      </div>
    </div>
  `}function be({label:t,value:e,detail:n,tone:s}){return o`
    <article class="mission-stat-card ${pt(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function Ru(){const t=Fi.value;return o`
    <${T} title="LLM 판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>heuristic 대신 별도 판단 계층</h3>
        <p>아래 해석은 LLM이 사실 스냅샷만 읽고 만든 요약입니다. raw thinking은 숨기고, 기준과 근거만 남깁니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${pt((t==null?void 0:t.status)??(me.value?"bad":"warn"))}">
          ${(t==null?void 0:t.status)??(me.value?"error":"loading")}
        </span>
        ${t!=null&&t.model?o`<span class="command-chip">${t.model}</span>`:null}
        ${t!=null&&t.generated_at?o`<span class="command-chip">${te(t.generated_at)}</span>`:null}
        ${t!=null&&t.cached?o`<span class="command-chip">cached</span>`:null}
      </div>

      ${me.value?o`<div class="empty-state error">${me.value}</div>`:null}
      ${t!=null&&t.error?o`<div class="empty-state error">${t.error}</div>`:null}

      ${t&&t.sections.length>0?o`
            <div class="mission-briefing-grid">
              ${t.sections.map(e=>o`
                <article class="mission-briefing-section ${pt(e.status)}">
                  <div class="mission-card-head">
                    <strong>${e.label}</strong>
                    <span class="command-chip ${pt(e.status)}">${e.status}</span>
                  </div>
                  <p>${e.summary}</p>
                  ${e.evidence.length>0?o`
                        <div class="mission-briefing-evidence">
                          ${e.evidence.map(n=>o`<span>${n}</span>`)}
                        </div>
                      `:null}
                </article>
              `)}
            </div>
          `:!Ie.value&&!me.value?o`<div class="empty-state">아직 판단 레이어를 불러오지 못했습니다.</div>`:null}

      ${t!=null&&t.criteria&&t.criteria.length>0?o`
            <details class="mission-briefing-criteria">
              <summary>판단 기준 보기</summary>
              <div class="mission-briefing-evidence">
                ${t.criteria.map(e=>o`<span>${e}</span>`)}
              </div>
            </details>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{us(!1)}} disabled=${Ie.value}>
          ${Ie.value?"판단 불러오는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{us(!0)}} disabled=${Ie.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function Pu({row:t}){const e=t.memberNames.slice(0,4).map(n=>{const s=Bt.value.find(i=>i.name===n),a=Xi(n,Oe.value);return{name:n,currentTask:s?Zi(s,Mt.value):"agent snapshot 없음",output:X(a==null?void 0:a.content,96)}});return o`
    <article class="mission-crew-card ${pt(t.status)}">
      <div class="mission-card-head">
        <div>
          <strong>${t.goal}</strong>
          <div class="mission-card-target">${t.session.session_id}${t.room?` · ${t.room}`:""}</div>
        </div>
        <span class="command-chip ${pt(t.status)}">${t.status}</span>
      </div>

      <div class="mission-fact-grid">
        <div class="mission-fact-tile">
          <span>멤버</span>
          <strong>${t.memberNames.length}</strong>
          <small>${t.memberNames.slice(0,3).join(", ")||"n/a"}</small>
        </div>
        <div class="mission-fact-tile">
          <span>가동 시간</span>
          <strong>${iu(t.elapsedSec)}</strong>
          <small>${t.startedAt?`${te(t.startedAt)} 시작`:"시작 시각 없음"}</small>
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
        <small>${t.lastEventAt?te(t.lastEventAt):"시각 없음"}</small>
      </div>

      ${e.length>0?o`
            <div class="mission-member-stack">
              ${e.map(n=>o`
                <button class="mission-member-row" onClick=${()=>Us(n.name)}>
                  <strong>${n.name}</strong>
                  <span>${n.currentTask}</span>
                  <small>${n.output??"최근 출력 없음"}</small>
                </button>
              `)}
            </div>
          `:null}

      ${t.attentionSummary?o`<div class="mission-inline-note">attention: ${t.attentionSummary}</div>`:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Ho("intervene",t.session.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Ho("command",t.session.session_id)}>세션 원인 보기</button>
      </div>
    </article>
  `}function Mu({row:t}){const e=t.recentTools.length>0?t.recentTools.join(", "):"도구 텔레메트리 없음",n=t.withWhom.length>0?t.withWhom.slice(0,3).join(", "):"단독 또는 room-level";return o`
    <button class="mission-activity-card ${pt(t.agent.status)}" onClick=${()=>Us(t.agent.name)}>
      <div class="mission-activity-head">
        <div class="mission-activity-title">
          <span class="agent-emoji">${t.agent.emoji??""}</span>
          <div>
            <strong>${t.agent.name}</strong>
            ${t.agent.koreanName?o`<span>${t.agent.koreanName}</span>`:null}
          </div>
        </div>
        <span class="command-chip ${pt(t.agent.status)}">${t.agent.status}</span>
      </div>

      <div class="mission-activity-meta">
        <span>어디서 · ${t.where}</span>
        <span>누구와 · ${n}</span>
        <span>언제부터 · ${t.activeSince?te(t.activeSince):"n/a"}</span>
      </div>

      <div class="mission-activity-focus">
        <span>무엇을</span>
        <strong>${t.currentWork}</strong>
        ${t.how?o`<small>어떻게 · ${t.how}</small>`:null}
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
        ${t.recentEvent?o`<span>최근 일 · ${t.recentEvent}</span>`:null}
      </div>
    </button>
  `}function Du({row:t}){const e=[`gen ${t.keeper.generation??0}`,`handoff ${t.keeper.handoff_count_total??0}`,`compact ${t.keeper.compaction_count??0}`,t.keeper.context_ratio!=null?`ctx ${Math.round(t.keeper.context_ratio*100)}%`:null].filter(n=>n!==null).join(" · ");return o`
    <button class="mission-activity-card ${pt(t.keeper.status)}" onClick=${()=>_o(t.keeper)}>
      <div class="mission-activity-head">
        <div class="mission-activity-title">
          <span class="agent-emoji">${t.keeper.emoji??""}</span>
          <div>
            <strong>${t.keeper.name}</strong>
            ${t.keeper.koreanName?o`<span>${t.keeper.koreanName}</span>`:null}
          </div>
        </div>
        <span class="command-chip ${pt(t.keeper.status)}">${t.keeper.status}</span>
      </div>

      <div class="mission-activity-meta">
        <span>언제부터 · ${t.activeSince?te(t.activeSince):"n/a"}</span>
        <span>최근 heartbeat · ${t.keeper.last_heartbeat?te(t.keeper.last_heartbeat):"n/a"}</span>
        <span>${e}</span>
      </div>

      <div class="mission-activity-focus">
        <span>무엇을</span>
        <strong>${t.currentWork}</strong>
        ${t.keeper.skill_reason?o`<small>판단 요약 · ${X(t.keeper.skill_reason,120)}</small>`:null}
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
        ${t.recentEvent?o`<span>최근 일 · ${t.recentEvent}</span>`:null}
      </div>
    </button>
  `}function Lu({item:t}){return o`
    <article class="mission-action-card ${pt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${pt(t.severity)}">${t.kind}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>uu(t)}>이 이슈로 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>pu(t)}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `}function Eu({action:t,incident:e}){const n=cu(t);return o`
    <article class="mission-action-card ${pt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${pt(t.severity)}">${ho(t.action_type)}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.reason}</p>
      <div class="mission-action-detail">
        <span>${lu(t)}</span>
        <span>${du(t)}</span>
      </div>
      ${n?o`<div class="mission-action-preview">${n}</div>`:null}
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>mu(t,e,"상황판 추천 액션")}>이 액션으로 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>vu(t,e,"상황판 추천 액션")}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `}function Wo(){const t=js.value;if(Ga.value&&!t)return o`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(ds.value&&!t)return o`<div class="empty-state error">${ds.value}</div>`;if(!t)return o`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;const e=Cu(),n=Tu(e),s=Iu(),a=n.filter(d=>["active","busy","listening","idle"].includes(d.agent.status)).length,i=n.filter(d=>d.recentOutput).length+s.filter(d=>d.recentOutput).length,r=t.incidents[0]??null,c=t.recommended_actions[0]??null;return o`
    <section class="dashboard-panel mission-view">
      <${kt} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>사람 운영자가 누가 어디서 누구와 무엇을 하고 있는지 바로 보는 관찰면입니다. 내부 메트릭은 아래가 아니라 Command로 내렸습니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${pt(t.summary.room_health)}">${t.summary.room_health??"ok"}</span>
          <span class="command-chip">${t.summary.project??"room"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?te(t.generated_at):"fresh"}</span>
        </div>
      </div>

      <${Nu}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <${Ru} />

      <div class="mission-stat-grid">
        <${be} label="활성 흐름" value=${e.length} detail="지금 보이는 crew / session" tone=${e.length>0?"ok":"warn"} />
        <${be} label="응답 가능 에이전트" value=${a} detail="지금 응답 가능한 actor 수" tone=${a>0?"ok":"warn"} />
        <${be} label="Keeper 수" value=${s.length} detail="연속성 runtime / generation 관찰 대상" tone=${s.length>0?"ok":"warn"} />
        <${be} label="최근 output" value=${i} detail="main 화면에서 바로 볼 수 있는 최근 출력 수" tone=${i>0?"ok":"warn"} />
        <${be} label="내부 incident" value=${t.incidents.length} detail="시스템 진단 신호는 아래 보조 카드로만 유지" tone=${(r==null?void 0:r.severity)??"ok"} />
        <${be} label="추천 액션" value=${t.recommended_actions.length} detail="개입이 필요하면 Intervene로 바로 이동" tone=${(c==null?void 0:c.severity)??"ok"} />
      </div>

      <div class="mission-human-grid">
        <${T} title="같이 움직이는 흐름" class="mission-list-card" semanticId="mission.crews">
          <div class="mission-section-head">
            <h3>누가 누구와 같은 목표를 향하는지</h3>
            <p>team session 단위로 목표, 멤버, 최근 사건, 커뮤니케이션 흔적을 바로 보여줍니다.</p>
          </div>
          <div class="mission-list-stack">
            ${e.length>0?e.map(d=>o`<${Pu} key=${d.session.session_id} row=${d} />`):o`<div class="empty-state">지금 열려 있는 crew / session 이 없습니다.</div>`}
          </div>
        <//>

        <${T} title="에이전트 활동" class="mission-list-card" semanticId="mission.agent_activity">
          <div class="mission-section-head">
            <h3>각 에이전트가 지금 뭘 하는가</h3>
            <p>where / with whom / current task / recent input-output / recent tools 를 preview-first로 보여줍니다.</p>
          </div>
          <div class="mission-activity-list">
            ${n.length>0?n.slice(0,10).map(d=>o`<${Mu} key=${d.agent.name} row=${d} />`):o`<div class="empty-state">지금 보이는 에이전트 활동이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${T} title="Keeper 연속성" class="mission-list-card" semanticId="mission.keeper_activity">
          <div class="mission-section-head">
            <h3>generation / compaction / handoff 를 거치는 장기 실행체</h3>
            <p>keeper 는 별도 continuity lane 으로 보고, raw thinking 대신 최근 입출력과 판단 요약만 노출합니다.</p>
          </div>
          <div class="mission-activity-list">
            ${s.length>0?s.slice(0,8).map(d=>o`<${Du} key=${d.keeper.name} row=${d} />`):o`<div class="empty-state">지금 보이는 keeper 가 없습니다.</div>`}
          </div>
        <//>

        <${T} title="내부 진단은 여기서만" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>internal signal / recommendation</h3>
            <p>artifact_scope_drift 같은 시스템 진단은 메인 판단 근거가 아니라 보조 신호로만 유지합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${t.incidents.slice(0,2).map(d=>o`<${Lu} key=${`${d.kind}:${d.target_id??"room"}`} item=${d} />`)}
            ${t.recommended_actions.slice(0,2).map(d=>o`<${Eu} key=${`${d.action_type}:${d.target_id??"room"}`} action=${d} />`)}
            ${t.incidents.length===0&&t.recommended_actions.length===0?o`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`:null}
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>xt("execution")}>실행 관찰면 보기</button>
            <button class="control-btn ghost" onClick=${()=>xt("command")}>지휘 진단면 보기</button>
          </div>
        <//>
      </div>
    </section>
  `}const zu="modulepreload",Ou=function(t){return"/dashboard/"+t},Bo={},ju=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let r=function(f){return Promise.all(f.map(p=>Promise.resolve(p).then(u=>({status:"fulfilled",value:u}),u=>({status:"rejected",reason:u}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),d=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=r(n.map(f=>{if(f=Ou(f),f in Bo)return;Bo[f]=!0;const p=f.endsWith(".css"),u=p?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${f}"]${u}`))return;const g=document.createElement("link");if(g.rel=p?"stylesheet":zu,p||(g.as="script"),g.crossOrigin="",g.href=f,d&&g.setAttribute("nonce",d),document.head.appendChild(g),p)return new Promise(($,x)=>{g.addEventListener("load",$),g.addEventListener("error",()=>x(new Error(`Unable to preload CSS for ${f}`)))})}))}function i(r){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=r,window.dispatchEvent(c),!c.defaultPrevented)throw r}return a.then(r=>{for(const c of r||[])c.status==="rejected"&&i(c.reason);return e().catch(i)})},yo=m(null),zt=m(null),_s=m(!1),fs=m(!1),gs=m(null),$s=m(null),Va=m(null),hs=m(null),gt=m("operations"),Nn=m(null),Ya=m(!1),ys=m(null),Ws=m(null),Xa=m(!1),bs=m(null),Bs=m(null),Qa=m(!1),ks=m(null),vn=m(null),xs=m(!1),_n=m(null),Me=m(null);let Qe=null;function bo(t){return t!=="summary"&&t!=="swarm"}function S(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function l(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function _(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Q(t){return typeof t=="boolean"?t:void 0}function mt(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function tr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,i)=>{t.has(i)||t.set(i,a)}),t}function Fu(){const e=tr().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function qu(){const e=tr().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Ku(t){if(S(t))return{policy_class:l(t.policy_class),approval_class:l(t.approval_class),tool_allowlist:mt(t.tool_allowlist),model_allowlist:mt(t.model_allowlist),requires_human_for:mt(t.requires_human_for),autonomy_level:l(t.autonomy_level),escalation_timeout_sec:_(t.escalation_timeout_sec),kill_switch:Q(t.kill_switch),frozen:Q(t.frozen)}}function Uu(t){if(S(t))return{headcount_cap:_(t.headcount_cap),active_operation_cap:_(t.active_operation_cap),max_cost_usd:_(t.max_cost_usd),max_tokens:_(t.max_tokens)}}function ko(t){if(!S(t))return null;const e=l(t.unit_id),n=l(t.label),s=l(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:l(t.parent_unit_id)??null,leader_id:l(t.leader_id)??null,roster:mt(t.roster),capability_profile:mt(t.capability_profile),source:l(t.source),created_at:l(t.created_at),updated_at:l(t.updated_at),policy:Ku(t.policy),budget:Uu(t.budget)}}function er(t){if(!S(t))return null;const e=ko(t.unit);return e?{unit:e,leader_status:l(t.leader_status),roster_total:_(t.roster_total),roster_live:_(t.roster_live),active_operation_count:_(t.active_operation_count),health:l(t.health),reasons:mt(t.reasons),children:Array.isArray(t.children)?t.children.map(er).filter(n=>n!==null):[]}:null}function Hu(t){if(S(t))return{total_units:_(t.total_units),company_count:_(t.company_count),platoon_count:_(t.platoon_count),squad_count:_(t.squad_count),leaf_agent_unit_count:_(t.leaf_agent_unit_count),live_agent_count:_(t.live_agent_count),managed_unit_count:_(t.managed_unit_count),active_operation_count:_(t.active_operation_count)}}function nr(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),source:l(e.source),summary:Hu(e.summary),units:Array.isArray(e.units)?e.units.map(er).filter(n=>n!==null):[]}}function Wu(t){if(!S(t))return null;const e=l(t.kind),n=l(t.status);return!e||!n?null:{kind:e,chain_id:l(t.chain_id)??null,goal:l(t.goal)??null,run_id:l(t.run_id)??null,status:n,viewer_path:l(t.viewer_path)??null,last_sync_at:l(t.last_sync_at)??null}}function Gs(t){if(!S(t))return null;const e=l(t.operation_id),n=l(t.objective),s=l(t.assigned_unit_id),a=l(t.trace_id),i=l(t.status);return!e||!n||!s||!a||!i?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:l(t.autonomy_level),policy_class:l(t.policy_class),budget_class:l(t.budget_class),detachment_session_id:l(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:l(t.checkpoint_ref)??null,active_goal_ids:mt(t.active_goal_ids),note:l(t.note)??null,created_by:l(t.created_by),source:l(t.source),status:i,chain:Wu(t.chain),created_at:l(t.created_at),updated_at:l(t.updated_at)}}function Bu(t){if(!S(t))return null;const e=Gs(t.operation);return e?{operation:e,assigned_unit_label:l(t.assigned_unit_label)}:null}function Ve(t){if(S(t))return{tone:l(t.tone),pending_ops:_(t.pending_ops),blocked_ops:_(t.blocked_ops),in_flight_ops:_(t.in_flight_ops),pipeline_stalls:_(t.pipeline_stalls),bus_traffic:_(t.bus_traffic),l1_hit_rate:_(t.l1_hit_rate),invalidation_count:_(t.invalidation_count),current_pending:_(t.current_pending),current_in_flight:_(t.current_in_flight),cdb_wakeups:_(t.cdb_wakeups),total_stolen:_(t.total_stolen),avg_best_score:_(t.avg_best_score),avg_candidate_count:_(t.avg_candidate_count),best_first_operations:_(t.best_first_operations),active_sessions:_(t.active_sessions),commit_rate:_(t.commit_rate),total_speculations:_(t.total_speculations)}}function Gu(t){if(!S(t))return;const e=S(t.pipeline)?t.pipeline:void 0,n=S(t.cache)?t.cache:void 0,s=S(t.ooo)?t.ooo:void 0,a=S(t.speculative)?t.speculative:void 0,i=S(t.search_fabric)?t.search_fabric:void 0,r=S(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:_(e.total_ops),completed_ops:_(e.completed_ops),stalled_cycles:_(e.stalled_cycles),hazards_detected:_(e.hazards_detected),forwarding_used:_(e.forwarding_used),pipeline_flushes:_(e.pipeline_flushes),ipc:_(e.ipc)}:void 0,cache:n?{total_reads:_(n.total_reads),total_writes:_(n.total_writes),l1_hit_rate:_(n.l1_hit_rate),invalidation_count:_(n.invalidation_count),writeback_count:_(n.writeback_count),bus_traffic:_(n.bus_traffic)}:void 0,ooo:s?{agent_count:_(s.agent_count),total_added:_(s.total_added),total_issued:_(s.total_issued),total_completed:_(s.total_completed),total_stolen:_(s.total_stolen),cdb_wakeups:_(s.cdb_wakeups),stall_cycles:_(s.stall_cycles),global_cdb_events:_(s.global_cdb_events),current_pending:_(s.current_pending),current_in_flight:_(s.current_in_flight)}:void 0,speculative:a?{total_speculations:_(a.total_speculations),total_commits:_(a.total_commits),total_aborts:_(a.total_aborts),commit_rate:_(a.commit_rate),total_fast_calls:_(a.total_fast_calls),total_cost_usd:_(a.total_cost_usd),active_sessions:_(a.active_sessions)}:void 0,search_fabric:i?{total_operations:_(i.total_operations),best_first_operations:_(i.best_first_operations),legacy_operations:_(i.legacy_operations),blocked_operations:_(i.blocked_operations),ready_operations:_(i.ready_operations),research_pipeline_operations:_(i.research_pipeline_operations),avg_candidate_count:_(i.avg_candidate_count),avg_best_score:_(i.avg_best_score),top_stage:l(i.top_stage)??null}:void 0,signals:r?{issue_pressure:Ve(r.issue_pressure),cache_contention:Ve(r.cache_contention),scheduler_efficiency:Ve(r.scheduler_efficiency),routing_confidence:Ve(r.routing_confidence),speculative_posture:Ve(r.speculative_posture)}:void 0}}function sr(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:_(n.total),active:_(n.active),paused:_(n.paused),managed:_(n.managed),projected:_(n.projected)}:void 0,microarch:Gu(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(Bu).filter(s=>s!==null):[]}}function ar(t){if(!S(t))return null;const e=l(t.detachment_id),n=l(t.operation_id),s=l(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:l(t.leader_id)??null,roster:mt(t.roster),session_id:l(t.session_id)??null,checkpoint_ref:l(t.checkpoint_ref)??null,runtime_kind:l(t.runtime_kind)??null,runtime_ref:l(t.runtime_ref)??null,source:l(t.source),status:l(t.status),last_event_at:l(t.last_event_at)??null,last_progress_at:l(t.last_progress_at)??null,heartbeat_deadline:l(t.heartbeat_deadline)??null,created_at:l(t.created_at),updated_at:l(t.updated_at)}}function Ju(t){if(!S(t))return null;const e=ar(t.detachment);return e?{detachment:e,assigned_unit_label:l(t.assigned_unit_label),operation:Gs(t.operation)}:null}function or(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:_(n.total),active:_(n.active),projected:_(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(Ju).filter(s=>s!==null):[]}}function Vu(t){if(!S(t))return null;const e=l(t.decision_id),n=l(t.trace_id),s=l(t.requested_action),a=l(t.scope_type),i=l(t.scope_id);return!e||!n||!s||!a||!i?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:i,operation_id:l(t.operation_id)??null,target_unit_id:l(t.target_unit_id)??null,requested_by:l(t.requested_by),status:l(t.status),reason:l(t.reason)??null,source:l(t.source),detail:t.detail,created_at:l(t.created_at),decided_at:l(t.decided_at)??null,expires_at:l(t.expires_at)??null}}function ir(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:_(n.total),pending:_(n.pending),approved:_(n.approved),denied:_(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(Vu).filter(s=>s!==null):[]}}function Yu(t){if(!S(t))return null;const e=ko(t.unit);return e?{unit:e,roster_total:_(t.roster_total),roster_live:_(t.roster_live),headcount_cap:_(t.headcount_cap),active_operations:_(t.active_operations),active_operation_cap:_(t.active_operation_cap),utilization:_(t.utilization)}:null}function Xu(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(Yu).filter(n=>n!==null):[]}}function Qu(t){if(!S(t))return null;const e=l(t.alert_id);return e?{alert_id:e,severity:l(t.severity),kind:l(t.kind),scope_type:l(t.scope_type),scope_id:l(t.scope_id),title:l(t.title),detail:l(t.detail),timestamp:l(t.timestamp)}:null}function rr(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:_(n.total),bad:_(n.bad),warn:_(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(Qu).filter(s=>s!==null):[]}}function lr(t){if(!S(t))return null;const e=l(t.event_id),n=l(t.trace_id),s=l(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:l(t.operation_id)??null,unit_id:l(t.unit_id)??null,actor:l(t.actor)??null,source:l(t.source),timestamp:l(t.timestamp),detail:t.detail}}function Zu(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),events:Array.isArray(e.events)?e.events.map(lr).filter(n=>n!==null):[]}}function tp(t){if(!S(t))return null;const e=l(t.code),n=l(t.severity),s=l(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function ep(t){if(!S(t))return null;const e=l(t.lane_id),n=l(t.label),s=l(t.kind),a=l(t.phase),i=l(t.motion_state),r=l(t.source_of_truth),c=l(t.movement_reason),d=l(t.current_step);if(!e||!n||!s||!a||!i||!r||!c||!d)return null;const f=S(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:Q(t.present)??!1,phase:a,motion_state:i,source_of_truth:r,last_movement_at:l(t.last_movement_at)??null,movement_reason:c,current_step:d,blockers:mt(t.blockers),counts:{operations:_(f.operations),detachments:_(f.detachments),workers:_(f.workers),approvals:_(f.approvals),alerts:_(f.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(tp).filter(p=>p!==null):[]}}function np(t){if(!S(t))return null;const e=l(t.event_id),n=l(t.lane_id),s=l(t.kind),a=l(t.timestamp),i=l(t.title),r=l(t.detail),c=l(t.tone),d=l(t.source);return!e||!n||!s||!a||!i||!r||!c||!d?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:i,detail:r,tone:c,source:d}}function sp(t){if(!S(t))return null;const e=l(t.code),n=l(t.severity),s=l(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,lane_ids:mt(t.lane_ids),count:_(t.count)??0}}function cr(t){if(!S(t))return;const e=S(t.overview)?t.overview:{},n=S(t.gaps)?t.gaps:{},s=S(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:l(t.generated_at),overview:{active_lanes:_(e.active_lanes),moving_lanes:_(e.moving_lanes),stalled_lanes:_(e.stalled_lanes),projected_lanes:_(e.projected_lanes),last_movement_at:l(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(ep).filter(a=>a!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(np).filter(a=>a!==null):[],gaps:{count:_(n.count),items:Array.isArray(n.items)?n.items.map(sp).filter(a=>a!==null):[]},recommended_next_action:s?{tool:l(s.tool)??"masc_operator_snapshot",label:l(s.label)??"Observe operator state",reason:l(s.reason)??"",lane_id:l(s.lane_id)??null}:void 0}}function ap(t){if(!S(t))return;const e=S(t.workers)?t.workers:{},n=Q(t.pass);return{status:l(t.status)??"missing",source:l(t.source)??"none",run_id:l(t.run_id)??null,captured_at:l(t.captured_at)??null,...n!==void 0?{pass:n}:{},..._(t.peak_hot_slots)!=null?{peak_hot_slots:_(t.peak_hot_slots)}:{},..._(t.ctx_per_slot)!=null?{ctx_per_slot:_(t.ctx_per_slot)}:{},workers:{expected:_(e.expected),joined:_(e.joined),current_task_bound:_(e.current_task_bound),fresh_heartbeats:_(e.fresh_heartbeats),done:_(e.done),final:_(e.final)},artifact_ref:l(t.artifact_ref)??null,missing_reason:l(t.missing_reason)??null}}function op(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),topology:nr(e.topology),operations:sr(e.operations),detachments:or(e.detachments),alerts:rr(e.alerts),decisions:ir(e.decisions),capacity:Xu(e.capacity),traces:Zu(e.traces),swarm_status:cr(e.swarm_status)}}function ip(t){const e=S(t)?t:{},n=nr(e.topology),s=sr(e.operations),a=or(e.detachments),i=rr(e.alerts),r=ir(e.decisions);return{version:l(e.version),generated_at:l(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:i.version,generated_at:i.generated_at,summary:i.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:cr(e.swarm_status),swarm_proof:ap(e.swarm_proof)}}function rp(t){return S(t)?{chain_id:l(t.chain_id)??null,started_at:_(t.started_at)??null,progress:_(t.progress)??null,elapsed_sec:_(t.elapsed_sec)??null}:null}function dr(t){if(!S(t))return null;const e=l(t.event);return e?{event:e,chain_id:l(t.chain_id)??null,timestamp:l(t.timestamp)??null,duration_ms:_(t.duration_ms)??null,message:l(t.message)??null,tokens:_(t.tokens)??null}:null}function lp(t){if(!S(t))return null;const e=Gs(t.operation);return e?{operation:e,runtime:rp(t.runtime),history:dr(t.history),mermaid:l(t.mermaid)??null,preview_run:ur(t.preview_run)}:null}function cp(t){const e=S(t)?t:{};return{status:l(e.status)??"disconnected",base_url:l(e.base_url)??null,message:l(e.message)??null}}function dp(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),connection:cp(e.connection),summary:n?{linked_operations:_(n.linked_operations),active_chains:_(n.active_chains),running_operations:_(n.running_operations),recent_failures:_(n.recent_failures),last_history_event_at:l(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(lp).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(dr).filter(s=>s!==null):[]}}function up(t){if(!S(t))return null;const e=l(t.id);return e?{id:e,type:l(t.type),status:l(t.status),duration_ms:_(t.duration_ms)??null,error:l(t.error)??null}:null}function ur(t){if(!S(t))return null;const e=l(t.run_id),n=l(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:_(t.duration_ms),success:Q(t.success),mermaid:l(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(up).filter(s=>s!==null):[]}:null}function pp(t){const e=S(t)?t:{};return{run:ur(e.run)}}function mp(t){if(!S(t))return null;const e=l(t.title),n=l(t.path);return!e||!n?null:{title:e,path:n}}function vp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function _p(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.tool),a=l(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:mt(t.success_signals),pitfalls:mt(t.pitfalls)}}function fp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.summary),a=l(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(_p).filter(i=>i!==null):[]}}function gp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:mt(t.tools)}}function $p(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.symptom),a=l(t.why),i=l(t.fix_tool),r=l(t.fix_summary);return!e||!n||!s||!a||!i||!r?null:{id:e,title:n,symptom:s,why:a,fix_tool:i,fix_summary:r}}function hp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.path_id),a=l(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:mt(t.notes)}}function yp(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(mp).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(vp).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(fp).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(gp).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map($p).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(hp).filter(n=>n!==null):[]}}function bp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.status),a=l(t.detail),i=l(t.next_tool);return!e||!n||!s||!a||!i?null:{id:e,title:n,status:s,detail:a,next_tool:i}}function kp(t){if(!S(t))return null;const e=l(t.code),n=l(t.severity),s=l(t.title),a=l(t.detail),i=l(t.next_tool);return!e||!n||!s||!a||!i?null:{code:e,severity:n,title:s,detail:a,next_tool:i}}function xp(t){if(!S(t))return null;const e=l(t.from),n=l(t.content),s=l(t.timestamp),a=_(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function Sp(t){if(!S(t))return null;const e=l(t.name),n=l(t.role),s=l(t.lane),a=l(t.status),i=l(t.claim_marker),r=l(t.done_marker),c=l(t.final_marker);if(!e||!n||!s||!a||!i||!r||!c)return null;const d=(()=>{if(!S(t.last_message))return null;const f=_(t.last_message.seq),p=l(t.last_message.content),u=l(t.last_message.timestamp);return f==null||!p||!u?null:{seq:f,content:p,timestamp:u}})();return{name:e,role:n,lane:s,joined:Q(t.joined)??!1,live_presence:Q(t.live_presence)??!1,completed:Q(t.completed)??!1,status:a,current_task:l(t.current_task)??null,bound_task_id:l(t.bound_task_id)??null,bound_task_title:l(t.bound_task_title)??null,bound_task_status:l(t.bound_task_status)??null,current_task_matches_run:Q(t.current_task_matches_run)??!1,squad_member:Q(t.squad_member)??!1,detachment_member:Q(t.detachment_member)??!1,last_seen:l(t.last_seen)??null,heartbeat_age_sec:_(t.heartbeat_age_sec)??null,heartbeat_fresh:Q(t.heartbeat_fresh)??!1,claim_marker_seen:Q(t.claim_marker_seen)??!1,done_marker_seen:Q(t.done_marker_seen)??!1,final_marker_seen:Q(t.final_marker_seen)??!1,claim_marker:i,done_marker:r,final_marker:c,last_message:d}}function Ap(t){if(!S(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!S(n))return null;const s=l(n.timestamp),a=_(n.active_slots);if(!s||a==null)return null;const i=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:i}}).filter(n=>n!==null):[];return{slot_url:l(t.slot_url)??null,provider_base_url:l(t.provider_base_url)??null,provider_reachable:Q(t.provider_reachable)??null,provider_status_code:_(t.provider_status_code)??null,provider_model_id:l(t.provider_model_id)??null,actual_model_id:l(t.actual_model_id)??null,expected_slots:_(t.expected_slots),actual_slots:_(t.actual_slots),expected_ctx:_(t.expected_ctx),actual_ctx:_(t.actual_ctx),slot_reachable:Q(t.slot_reachable)??null,slot_status_code:_(t.slot_status_code)??null,runtime_blocker:l(t.runtime_blocker)??null,detail:l(t.detail)??null,checked_at:l(t.checked_at)??null,total_slots:_(t.total_slots),ctx_per_slot:_(t.ctx_per_slot),active_slots_now:_(t.active_slots_now),peak_active_slots:_(t.peak_active_slots),sample_count:_(t.sample_count),last_sample_at:l(t.last_sample_at)??null,timeline:e}}function Cp(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),run_id:l(e.run_id),room_id:l(e.room_id),operation_id:l(e.operation_id)??null,recommended_next_tool:l(e.recommended_next_tool),summary:n?{expected_workers:_(n.expected_workers),joined_workers:_(n.joined_workers),live_workers:_(n.live_workers),squad_roster_size:_(n.squad_roster_size),detachment_roster_size:_(n.detachment_roster_size),current_task_bound:_(n.current_task_bound),fresh_heartbeats:_(n.fresh_heartbeats),claim_markers_seen:_(n.claim_markers_seen),done_markers_seen:_(n.done_markers_seen),final_markers_seen:_(n.final_markers_seen),completed_workers:_(n.completed_workers),peak_hot_slots:_(n.peak_hot_slots),hot_window_ok:Q(n.hot_window_ok),pass_hot_concurrency:Q(n.pass_hot_concurrency),pass_end_to_end:Q(n.pass_end_to_end),pending_decisions:_(n.pending_decisions),pass:Q(n.pass)}:void 0,provider:Ap(e.provider),operation:Gs(e.operation),squad:ko(e.squad),detachment:ar(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Sp).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(bp).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(kp).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(xp).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(lr).filter(s=>s!==null):[],truth_notes:mt(e.truth_notes)}}function De(t){gt.value=t,bo(t)&&wp()}async function pr(){_s.value=!0,gs.value=null;try{const t=await wl();yo.value=ip(t)}catch(t){gs.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{_s.value=!1}}function xo(t){Me.value=t}async function So(){fs.value=!0,$s.value=null;try{const t=await Cl();zt.value=op(t)}catch(t){$s.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{fs.value=!1}}async function wp(){zt.value||fs.value||await So()}async function ge(){await pr(),bo(gt.value)&&await So()}async function Yt(){var t;Qa.value=!0,ks.value=null;try{const e=await Tl(),n=dp(e);Bs.value=n;const s=Me.value;n.operations.length===0?Me.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Me.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){ks.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{Qa.value=!1}}function Tp(){Qe=null,vn.value=null,xs.value=!1,_n.value=null}async function Ip(t){Qe=t,xs.value=!0,_n.value=null;try{const e=await Il(t);if(Qe!==t)return;vn.value=pp(e)}catch(e){if(Qe!==t)return;vn.value=null,_n.value=e instanceof Error?e.message:"Failed to load chain run"}finally{Qe===t&&(xs.value=!1)}}async function Np(){Ya.value=!0,ys.value=null;try{const t=await Nl();Nn.value=yp(t)}catch(t){ys.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Ya.value=!1}}async function jt(t=Fu(),e=qu()){Xa.value=!0,bs.value=null;try{const n=await Rl(t,e);Ws.value=Cp(n)}catch(n){bs.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{Xa.value=!1}}async function re(t,e,n){Va.value=t,hs.value=null;try{await Pl(e,n),await pr(),(zt.value||bo(gt.value))&&await So(),await jt(),await Yt()}catch(s){throw hs.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{Va.value=null}}function Rp(t){return re(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Pp(t){return re(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function Mp(t){return re(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Dp(t={}){return re("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function Lp(t){return re(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Ep(t){return re(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function zp(t,e){return re(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Op(t,e){return re(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}od(()=>{ge(),Yt(),(gt.value==="swarm"||Ws.value!==null)&&jt()});function jp(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function et(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function Fp(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function qp(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function F(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let Go=!1,Kp=0,oa=null;async function Up(){oa||(oa=ju(()=>import("./mermaid.core-3l_DIKA5.js").then(e=>e.bE),[]).then(e=>e.default));const t=await oa;return Go||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),Go=!0),t}function Xt(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Js(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function Hp(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function Rn(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function pe(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:Rn(t/e*100)}function Wp(t,e){const n=Rn(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function mr(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const Bp=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],vr=[{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],Gp=vr.map(t=>t.id),Jp=["chain_start","node_start","node_complete","chain_complete","chain_error"],Vp={operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function Jo(t){return!!t&&Gp.includes(t)}function Yp(){const t=L.value.params;return t.source!=="mission"?{}:{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function Xp(t){const e=Yp();if(t==="operations")return e;if(t==="chains"){const n=Me.value;return n?{...e,surface:t,operation:n}:{...e,surface:t}}return{...e,surface:t}}function Qp(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function Zp(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function ot(t){return Va.value===t}function Vs(){return yo.value}function tm(t){var a,i,r,c,d,f,p;const e=yo.value,n=Ws.value,s=Bs.value;switch(t){case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((r=(i=e==null?void 0:e.swarm_status)==null?void 0:i.recommended_next_action)==null?void 0:r.tool)??"masc_observe_traces",reason:((d=(c=e==null?void 0:e.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:d.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(p=(f=s==null?void 0:s.operations[0])==null?void 0:f.preview_run)!=null&&p.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function em(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function nm(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function sm(){const t=In(L.value);return t?o`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${ho(t.action_type)}</span>
        <span class="command-chip">${$o(t)}</span>
        <span class="command-chip">${ou(L.value.params.surface??"operations")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?o`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function am(){const t=gt.value,e=Vp[t],n=tm(t);return o`
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
  `}function En({label:t,value:e,subtext:n,percent:s,color:a}){return o`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${Wp(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(Rn(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function zn({label:t,value:e,detail:n,percent:s,tone:a}){return o`
    <article class="command-signal-rail ${F(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${F(a)}" style=${`width: ${Math.max(8,Math.round(Rn(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function om(){var K,tt,G,st;const t=Vs(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,i=t==null?void 0:t.alerts.summary,r=(K=t==null?void 0:t.swarm_status)==null?void 0:K.overview,c=t==null?void 0:t.swarm_proof,d=t==null?void 0:t.operations.microarch,f=(e==null?void 0:e.managed_unit_count)??0,p=(e==null?void 0:e.total_units)??0,u=(n==null?void 0:n.active)??0,g=(s==null?void 0:s.active)??0,$=(r==null?void 0:r.moving_lanes)??0,x=(r==null?void 0:r.active_lanes)??0,A=(c==null?void 0:c.workers.done)??0,I=(c==null?void 0:c.workers.expected)??0,M=(i==null?void 0:i.bad)??0,U=(i==null?void 0:i.warn)??0,D=(a==null?void 0:a.pending)??0,N=(a==null?void 0:a.total)??0,R=u+g,Y=((tt=d==null?void 0:d.cache)==null?void 0:tt.l1_hit_rate)??((st=(G=d==null?void 0:d.signals)==null?void 0:G.cache_contention)==null?void 0:st.l1_hit_rate)??0,J=u>0||g>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",v=u>0||$>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return o`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${J}</h3>
        <p>${v}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${F(u>0?"ok":"warn")}">활성 작전 ${u}</span>
          <span class="command-chip ${F($>0?"ok":(x>0,"warn"))}">이동 레인 ${$}/${Math.max(x,$)}</span>
          <span class="command-chip ${F(M>0?"bad":U>0?"warn":"ok")}">치명 알림 ${M}</span>
          <span class="command-chip ${F(D>0?"warn":"ok")}">승인 대기 ${D}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${En}
          label="관리 단위 범위"
          value=${`${f}/${Math.max(p,f)}`}
          subtext=${p>0?`${p-f}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${pe(f,Math.max(p,f))}
          color="#67e8f9"
        />
        <${En}
          label="실행 열도"
          value=${String(R)}
          subtext=${`${u}개 작전 + ${g}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${pe(R,Math.max(f,R||1))}
          color="#4ade80"
        />
        <${En}
          label="스웜 이동감"
          value=${`${$}/${Math.max(x,$)}`}
          subtext=${r!=null&&r.last_movement_at?`마지막 이동 ${et(r.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${pe($,Math.max(x,$||1))}
          color="#fbbf24"
        />
        <${En}
          label="증거 수집률"
          value=${`${A}/${Math.max(I,A)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${pe(A,Math.max(I,A||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${zn}
        label="승인 대기열"
        value=${`${D}건 대기`}
        detail=${`현재 정책 창에서 ${N}개 결정을 추적 중입니다`}
        percent=${pe(D,Math.max(N,D||1))}
        tone=${D>0?"warn":"ok"}
      />
      <${zn}
        label="알림 압력"
        value=${`${M} bad / ${U} warn`}
        detail=${M>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${pe(M*2+U,Math.max((M+U)*2,1))}
        tone=${M>0?"bad":U>0?"warn":"ok"}
      />
      <${zn}
        label="디스패치 점유"
          value=${`${g}개 가동`}
        detail=${f>0?`${f}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${pe(g,Math.max(f,g||1))}
        tone=${g>0?"ok":"warn"}
      />
      <${zn}
        label="캐시 신뢰도"
        value=${Y?Js(Y):"n/a"}
        detail=${Y?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Rn((Y??0)*100)}
        tone=${Y>=.75?"ok":Y>=.4?"warn":"bad"}
      />
    </div>
  `}function im(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function _r(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,i)=>{t.has(i)||t.set(i,a)}),t}function rm(){const e=_r().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function lm(){const e=_r().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function cm(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function dm(t){return t.status==="claimed"||t.status==="in_progress"}function um(t){const e=Nn.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function ia(t){var e;return((e=Nn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function pm(t){const e=Nn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function Qt(t){try{await t()}catch{}}function mm(){var g,$,x,A,I;const t=Vs(),e=Bs.value,n=In(L.value),s=em(n),a=t==null?void 0:t.topology.summary,i=t==null?void 0:t.operations.summary,r=(g=t==null?void 0:t.swarm_status)==null?void 0:g.overview,c=t==null?void 0:t.operations.microarch,d=t==null?void 0:t.decisions.summary,f=t==null?void 0:t.alerts.summary,p=($=c==null?void 0:c.signals)==null?void 0:$.issue_pressure,u=c==null?void 0:c.cache;return o`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(i==null?void 0:i.active)??0}</strong><small>${((x=t==null?void 0:t.detachments.summary)==null?void 0:x.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(d==null?void 0:d.pending)??0}</strong><small>${(d==null?void 0:d.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(f==null?void 0:f.bad)??0}</strong><small>${(f==null?void 0:f.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((A=e==null?void 0:e.summary)==null?void 0:A.active_chains)??0}</strong><small>${((I=e==null?void 0:e.summary)==null?void 0:I.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(r==null?void 0:r.active_lanes)??0}</strong><small>${r?`${r.stalled_lanes??0}개 정체 · ${et(r.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(p==null?void 0:p.pending_ops)??0}</strong><small>${(u==null?void 0:u.l1_hit_rate)!=null?`${Js(u.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(p==null?void 0:p.tone)??"n/a"}</small></div>
    </div>
  `}function fr(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function vm({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const i=a.motion_state;i in e?e[i]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return o`
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
  `}function _m({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return o`
    <div class="swarm-worker-grid">
      ${a.map(()=>o`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?o`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function fm({lane:t}){const e=t.counts??{},n=fr(t),s=e.workers??0,a=e.operations??0,i=e.detachments??0,r=a+i,c=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return o`
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
          <span class="command-chip">${et(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${F(n)}" style=${`width:${c}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${s>0?o`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${_m} total=${s} />
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
  `}function gm({lanes:t}){const e=t.slice(0,4);return e.length===0?null:o`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=fr(n),a=n.counts.workers??0,i=n.counts.operations??0,r=n.counts.detachments??0;return o`
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
  `}function $m({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return o`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${F(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?o`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function hm({gap:t}){return o`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${F(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function ym({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return o`
    <div class="command-guide-card ${F(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${F(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?o`
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${et(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.artifact_ref?o`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?o`<p>${t.missing_reason}</p>`:null}
          `:o`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function bm(){const t=Vs(),e=In(L.value),n=nm(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,i=(s==null?void 0:s.lanes.filter(u=>u.present))??[],r=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],d=s==null?void 0:s.overview,f=s==null?void 0:s.recommended_next_action,p=i.length<=1;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${z} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?o`
            <${gm} lanes=${i} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(d==null?void 0:d.active_lanes)??0}</strong><small>${(d==null?void 0:d.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(d==null?void 0:d.stalled_lanes)??0}</strong><small>${(d==null?void 0:d.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${et(d==null?void 0:d.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${et(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(f==null?void 0:f.label)??"운영자 상태 확인"}</strong><small>${(f==null?void 0:f.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${i.length>0?o`<${vm} lanes=${i} />`:null}

            <div class="command-swarm-layout ${p?"compact":""}">
              <div class="command-card-stack">
                ${i.length>0?i.map(u=>o`<${fm} lane=${u} />`):o`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight ${n==="recommendation"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>${(f==null?void 0:f.label)??"운영자 상태 확인"}</strong>
                    <span class="command-chip">${(f==null?void 0:f.lane_id)??"전체"}</span>
                  </div>
                  <p>${(f==null?void 0:f.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="command-card-foot">${(f==null?void 0:f.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${ym} proof=${a} />

                <div class="command-guide-card ${r.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${F(r.some(u=>u.severity==="bad")?"bad":r.length>0?"warn":"ok")}">${r.length}</span>
                  </div>
                  ${r.length>0?o`<div class="swarm-event-rail">${r.slice(0,4).map(u=>o`<${hm} gap=${u} />`)}</div>`:o`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?o`<div class="swarm-event-rail">${c.map(u=>o`<${$m} event=${u} />`)}</div>`:o`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:o`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function km(){return o`
    <div class="command-surface-tabs grouped">
      ${Bp.map(t=>o`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${vr.filter(e=>e.group===t.id).map(e=>o`
                <button
                  class="command-surface-tab ${gt.value===e.id?"active":""}"
                  onClick=${()=>{De(e.id),xt("command",Xp(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function xm(){var K,tt,G,st,b,le,Be,Pn,Mn;const t=Vs(),e=zt.value,n=Re.value,s=im(),a=s?Bt.value.find(E=>E.name===s)??null:null,i=s?Mt.value.filter(E=>E.assignee===s&&dm(E)):[],r=((K=t==null?void 0:t.operations.summary)==null?void 0:K.active)??0,c=((tt=t==null?void 0:t.detachments.summary)==null?void 0:tt.total)??0,d=((G=t==null?void 0:t.decisions.summary)==null?void 0:G.pending)??0,f=e==null?void 0:e.detachments.detachments.find(E=>{const ce=E.detachment.heartbeat_deadline,Dn=ce?Date.parse(ce):Number.NaN;return E.detachment.status==="stalled"||!Number.isNaN(Dn)&&Dn<=Date.now()}),p=e==null?void 0:e.alerts.alerts.find(E=>E.severity==="bad"),u=!!(n!=null&&n.room||n!=null&&n.project),g=(a==null?void 0:a.current_task)??null,$=cm(a==null?void 0:a.last_seen),x=$!=null?$<=120:null,A=[u?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?i.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:Mt.value.length>0?"masc_claim":"masc_add_task"}:g?x===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${g} 이지만 heartbeat가 stale 합니다 (${$}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${g}${$!=null?` · 마지막 활동 ${$}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((st=t.topology.summary)==null?void 0:st.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:r===0?{title:"작전 준비도",tone:"warn",detail:`${((b=t.topology.summary)==null?void 0:b.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((le=t.topology.summary)==null?void 0:le.managed_unit_count)??0}개 관리 단위 위에서 ${r}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},d>0?{title:"디스패치 준비도",tone:"warn",detail:`${d}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:r>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:f||p?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${f?` · detachment ${f.detachment.detachment_id} 가 stalled 상태입니다`:""}${p?` · alert ${p.title??p.alert_id}`:""}${!e&&!f&&!p?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:d>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],I=u?!s||!a?"masc_join":i.length===0?Mt.value.length>0?"masc_claim":"masc_add_task":g?x===!1?"masc_heartbeat":!t||(((Be=t.topology.summary)==null?void 0:Be.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":d>0?"masc_policy_approve":r>0&&c===0||f||p?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",M=um(I),D=pm(I==="masc_set_room"?["repo-root-room"]:I==="masc_plan_set_task"?["claimed-not-current"]:I==="masc_heartbeat"?["heartbeat-stale"]:I==="masc_dispatch_tick"?["no-detachments"]:I==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),N=ia("room_task_hygiene"),R=ia("cpv2_benchmark"),Y=ia("supervisor_session"),J=((Pn=Nn.value)==null?void 0:Pn.docs)??[],v=[N,R,Y].filter(E=>E!==null);return o`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${z} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(M==null?void 0:M.title)??I}</strong>
            <span class="command-chip ok">${I}</span>
          </div>
          <p>${(M==null?void 0:M.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(Mn=M==null?void 0:M.success_signals)!=null&&Mn.length?o`<div class="command-tag-row">
                ${M.success_signals.map(E=>o`<span class="command-tag ok">${E}</span>`)}
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
                  ${v.map(E=>o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${E.title}</strong>
                        <span class="command-chip">${E.id}</span>
                      </div>
                      <p>${E.summary}</p>
                      <div class="command-card-sub">${E.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${E.steps.slice(0,4).map(ce=>o`
                          <div class="command-step-row">
                            <span class="command-step-tool">${ce.tool}</span>
                            <span>${ce.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${J.length>0?o`<div class="command-doc-links">
                      ${J.map(E=>o`<span class="command-tag">${E.title}: ${E.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Sm(){return o`
    <${om} />
    <${mm} />
    <${xm} />
  `}function Am(){return fs.value?o`<div class="empty-state">command-plane detail 불러오는 중…</div>`:$s.value?o`<div class="empty-state error">${$s.value}</div>`:o`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function gr({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,i=t.unit.policy;return o`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${Zp(t.unit.kind)}</span>
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
            ${t.children.map(r=>o`<${gr} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function Cm({source:t}){const e=Gr(null),[n,s]=mi(null);return ut(()=>{let a=!1;const i=e.current;return i?(i.innerHTML="",s(null),(async()=>{try{const c=await Up(),{svg:d}=await c.render(`command-chain-${++Kp}`,t);if(a||!e.current)return;e.current.innerHTML=d}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid render failed")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),o`
    <div class="command-chain-graph-shell">
      ${n?o`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function wm({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return o`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${Xt(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?o`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?o`<span class="command-tag ${Xt(s==null?void 0:s.status)}">${Js(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${mr(t.history)}</div>
    </button>
  `}function Tm({item:t}){return o`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${Xt(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${et(t.timestamp)}</div>
      <div class="command-card-sub">${mr(t)}</div>
    </article>
  `}function Im({node:t}){return o`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${Xt(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?o`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function Nm({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,i=e.chain,r=(i==null?void 0:i.run_id)??null;return o`
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
        <span>Updated</span><span>${et(e.updated_at)}</span>
      </div>
      ${i?o`
            <div class="command-tag-row">
              <span class="command-tag">${i.kind}</span>
              <span class="command-tag ${Xt(i.status)}">${i.status}</span>
              ${i.chain_id?o`<span class="command-tag">${i.chain_id}</span>`:null}
              ${i.run_id?o`<span class="command-tag">run ${i.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?o`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{De("swarm"),xt("command",{surface:"swarm",operation_id:e.operation_id,...r?{run_id:r}:{}})}}
        >
          Swarm Live
        </button>
        ${i?o`
              <button
                class="control-btn ghost"
                onClick=${()=>{xo(e.operation_id),De("chains"),xt("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?o`
              <button class="control-btn ghost" disabled=${ot(n)} onClick=${()=>Qt(()=>Rp(e.operation_id))}>
                ${ot(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${ot(a)} onClick=${()=>Qt(()=>Mp(e.operation_id))}>
                ${ot(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?o`
              <button class="control-btn ghost" disabled=${ot(s)} onClick=${()=>Qt(()=>Pp(e.operation_id))}>
                ${ot(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Rm({card:t}){var n;const e=t.detachment;return o`
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
        <span>Progress</span><span>${et(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${qp(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${et(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?o`<span class="command-tag ${Fp(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Pm({alert:t}){return o`
    <article class="command-alert ${F(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${F(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${et(t.timestamp)}</span>
      </div>
      ${t.detail?o`<p>${t.detail}</p>`:null}
    </article>
  `}function $r({event:t}){return o`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${et(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${jp(t.detail)}</pre>
    </article>
  `}function Mm({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return o`
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
        <span>Created</span><span>${et(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!s?o`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${ot(e)} onClick=${()=>Qt(()=>Lp(t.decision_id))}>
                ${ot(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${ot(n)} onClick=${()=>Qt(()=>Ep(t.decision_id))}>
                ${ot(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?o`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function Dm({row:t}){var c,d,f;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((c=e.policy)!=null&&c.frozen),i=!!((d=e.policy)!=null&&d.kill_switch),r=Math.round((t.utilization??0)*100);return o`
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
        <span>Autonomy</span><span>${((f=e.policy)==null?void 0:f.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${a?"yes":"no"}</span>
        <span>Kill Switch</span><span>${i?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${ot(n)} onClick=${()=>Qt(()=>zp(e.unit_id,!a))}>
          ${ot(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${ot(s)} onClick=${()=>Qt(()=>Op(e.unit_id,!i))}>
          ${ot(s)?"Applying…":i?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function Lm({item:t}){return o`
    <article class="command-guide-card ${F(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${F(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Em({blocker:t}){return o`
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
  `}function zm({worker:t}){return o`
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
      ${t.last_message?o`<div class="command-card-foot">${et(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function Om(){var d,f,p,u,g,$,x,A,I,M,U,D,N,R,Y,J,v,K,tt,G,st;const t=Ws.value,e=rm(),n=lm(),s=(d=t==null?void 0:t.provider)!=null&&d.runtime_blocker?"blocked":(f=t==null?void 0:t.provider)!=null&&f.provider_reachable?"ready":"check",a=((p=t==null?void 0:t.provider)==null?void 0:p.actual_slots)??((u=t==null?void 0:t.provider)==null?void 0:u.total_slots)??0,i=((g=t==null?void 0:t.provider)==null?void 0:g.expected_slots)??"n/a",r=(($=t==null?void 0:t.provider)==null?void 0:$.actual_ctx)??((x=t==null?void 0:t.provider)==null?void 0:x.ctx_per_slot)??0,c=((A=t==null?void 0:t.provider)==null?void 0:A.expected_ctx)??"n/a";return o`
    <div class="command-section-stack">
      <${bm} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${Xa.value?o`<div class="empty-state">Loading swarm live state…</div>`:bs.value?o`<div class="empty-state error">${bs.value}</div>`:t?o`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((I=t.summary)==null?void 0:I.joined_workers)??0}/${((M=t.summary)==null?void 0:M.expected_workers)??0}</strong><small>${((U=t.summary)==null?void 0:U.live_workers)??0}개 가동 · ${((D=t.summary)==null?void 0:D.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${i} · ctx ${r}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(N=t.summary)!=null&&N.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((R=t.provider)==null?void 0:R.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(Y=t.summary)!=null&&Y.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((J=t.operation)==null?void 0:J.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((v=t.squad)==null?void 0:v.label)??"없음"}</span>
                      <span>실행체</span><span>${((K=t.detachment)==null?void 0:K.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((tt=t.summary)==null?void 0:tt.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((G=t.summary)==null?void 0:G.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((st=t.provider)==null?void 0:st.runtime_blocker)??"없음"}</span>
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
                ${t.checklist.map(b=>o`<${Lm} item=${b} />`)}
              </div>`:o`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?o`<div class="command-card-stack">
                ${t.workers.map(b=>o`<${zm} worker=${b} />`)}
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
                  <span>Last Sample</span><span>${t.provider.last_sample_at?et(t.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${t.provider.checked_at?et(t.provider.checked_at):"n/a"}</span>
                </div>
                ${t.provider.detail?o`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?o`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(b=>o`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${b.active_slots} active</strong>
                              <span class="command-chip">${et(b.timestamp)}</span>
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
                ${t.blockers.map(b=>o`<${Em} blocker=${b} />`)}
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
                        <span class="command-chip">${et(b.timestamp)}</span>
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
                ${t.recent_trace_events.map(b=>o`<${$r} event=${b} />`)}
              </div>`:o`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function jm(){const t=zt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${z} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?o`<div class="command-card-stack">
              ${t.operations.operations.map(e=>o`<${Nm} card=${e} />`)}
            </div>`:o`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${z} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?o`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>o`<${Rm} card=${e} />`)}
            </div>`:o`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function Fm(){var c,d,f,p,u,g,$,x,A,I,M,U,D,N,R,Y;const t=Bs.value,e=(t==null?void 0:t.operations)??[],n=Me.value,s=e.find(J=>J.operation.operation_id===n)??e[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,i=((d=vn.value)==null?void 0:d.run)??(s==null?void 0:s.preview_run)??null,r=!((f=vn.value)!=null&&f.run)&&!!(s!=null&&s.preview_run);return ut(()=>{a?Ip(a):Tp()},[a]),o`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${z} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${Xt(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${Xt(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(t==null?void 0:t.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((p=t==null?void 0:t.summary)==null?void 0:p.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((u=t==null?void 0:t.summary)==null?void 0:u.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((g=t==null?void 0:t.summary)==null?void 0:g.recent_failures)??0}</span>
            <span>Last Event</span><span>${et(($=t==null?void 0:t.summary)==null?void 0:$.last_history_event_at)}</span>
          </div>
        </article>

        ${ks.value?o`<div class="empty-state error">${ks.value}</div>`:null}

        ${Qa.value&&!t?o`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?o`
                <div class="command-chain-list">
                  ${e.map(J=>o`
                    <${wm}
                      overlay=${J}
                      selected=${(s==null?void 0:s.operation.operation_id)===J.operation.operation_id}
                      onSelect=${()=>xo(J.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(J=>o`<${Tm} item=${J} />`)}
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
                  <span class="command-chip ${Xt((x=s.operation.chain)==null?void 0:x.status)}">
                    ${((A=s.operation.chain)==null?void 0:A.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((I=s.operation.chain)==null?void 0:I.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((M=s.operation.chain)==null?void 0:M.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${Js((U=s.runtime)==null?void 0:U.progress)}</span>
                  <span>Elapsed</span><span>${Hp((D=s.runtime)==null?void 0:D.elapsed_sec)}</span>
                  <span>Updated</span><span>${et(((N=s.operation.chain)==null?void 0:N.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(R=s.operation.chain)!=null&&R.goal?o`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?o`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((Y=s.operation.chain)==null?void 0:Y.chain_id)??"graph"}</span>
                      </div>
                      <${Cm} source=${s.mermaid} />
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
                            ${i.nodes.map(J=>o`<${Im} node=${J} />`)}
                          </div>
                        `:o`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:o`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function qm(){const t=zt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${z} panelId="command.topology" compact=${!0} />
      </div>
      ${t&&t.topology.units.length>0?o`${t.topology.units.map(e=>o`<${gr} node=${e} />`)}`:o`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function Km(){const t=zt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${z} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?o`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>o`<${Pm} alert=${e} />`)}
          </div>`:o`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function Um(){const t=zt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${z} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?o`<div class="command-trace-stack">
            ${t.traces.events.map(e=>o`<${$r} event=${e} />`)}
          </div>`:o`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function Hm(){const t=zt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${z} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?o`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>o`<${Mm} decision=${e} />`)}
            </div>`:o`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${z} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?o`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>o`<${Dm} row=${e} />`)}
            </div>`:o`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function Wm(){if(gt.value==="summary")return o`<${Sm} />`;if(gt.value==="swarm")return o`<${Om} />`;if(!zt.value)return o`<${Am} />`;switch(gt.value){case"chains":return o`<${Fm} />`;case"topology":return o`<${qm} />`;case"alerts":return o`<${Km} />`;case"trace":return o`<${Um} />`;case"control":return o`<${Hm} />`;case"operations":default:return o`<${jm} />`}}function Bm(){return ut(()=>{ge(),Yt(),Np(),jt()},[]),ut(()=>{if(L.value.tab!=="command")return;const t=L.value.params.surface,e=L.value.params.operation,n=In(L.value);if(Jo(t))De(t);else if(n){const s=Yi(n);Jo(s)&&De(s)}else t||De("operations");e&&xo(e),t==="swarm"&&jt()},[L.value.tab,L.value.params.surface,L.value.params.operation,L.value.params.operation_id,L.value.params.run_id,L.value.params.source,L.value.params.action_type,L.value.params.target_type,L.value.params.target_id,L.value.params.focus_kind]),ut(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,ge(),Yt(),gt.value==="swarm"&&jt()},250))},n=new EventSource(Qp()),s=Jp.map(a=>{const i=()=>e();return n.addEventListener(a,i),{type:a,handler:i}});return n.onerror=()=>{e()},()=>{s.forEach(({type:a,handler:i})=>{n.removeEventListener(a,i)}),n.close(),t&&window.clearTimeout(t)}},[]),o`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 현재 작전입니다. 여기서는 지금 무엇이 움직이고 막히는지 확인한 뒤, 필요한 surface로만 더 깊게 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Qt(()=>Dp())}}
            disabled=${ot("dispatch:tick")}
          >
            ${ot("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{ge(),Yt(),jt()}}
            disabled=${_s.value}
          >
            ${_s.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${gs.value?o`<div class="empty-state error">${gs.value}</div>`:null}
      ${hs.value?o`<div class="empty-state error">${hs.value}</div>`:null}
      <${kt} surfaceId="command" />
      <${sm} />
      <${am} />
      <${km} />
      <${Wm} />
    </section>
  `}const We=m(null),hr=m(null),Ut=m(null),Ss=m(!1),ee=m(null),fn=m(!1),Fe=m(null),V=m(!1),As=m([]);let Gm=1;function H(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function k(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function Z(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ys(t){return typeof t=="boolean"?t:void 0}function Jm(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Rt(t,e=[]){if(Array.isArray(t))return t;if(!H(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Vm(t){return H(t)?{id:k(t.id),seq:Z(t.seq),from:k(t.from)??k(t.from_agent)??"system",content:k(t.content)??"",timestamp:k(t.timestamp)??new Date().toISOString(),type:k(t.type)}:null}function Ym(t){return H(t)?{room_id:k(t.room_id),current_room:k(t.current_room)??k(t.room),project:k(t.project),cluster:k(t.cluster),paused:Ys(t.paused),pause_reason:k(t.pause_reason)??null,paused_by:k(t.paused_by)??null,paused_at:k(t.paused_at)??null}:{}}function Vo(t){if(!H(t))return;const e=Object.entries(t).map(([n,s])=>{const a=k(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function yr(t){if(!H(t))return null;const e=k(t.kind),n=k(t.summary),s=k(t.target_type);return!e||!n||!s?null:{kind:e,severity:k(t.severity)??"warn",summary:n,target_type:s,target_id:k(t.target_id)??null,actor:k(t.actor)??null,evidence:t.evidence}}function br(t){if(!H(t))return null;const e=k(t.action_type),n=k(t.target_type),s=k(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:k(t.target_id)??null,severity:k(t.severity)??"warn",reason:s,confirm_required:Ys(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Xm(t){return H(t)?{actor:k(t.actor)??null,spawn_agent:k(t.spawn_agent)??null,spawn_role:k(t.spawn_role)??null,spawn_model:k(t.spawn_model)??null,worker_class:k(t.worker_class)??null,parent_actor:k(t.parent_actor)??null,capsule_mode:k(t.capsule_mode)??null,runtime_pool:k(t.runtime_pool)??null,lane_id:k(t.lane_id)??null,controller_level:k(t.controller_level)??null,control_domain:k(t.control_domain)??null,supervisor_actor:k(t.supervisor_actor)??null,model_tier:k(t.model_tier)??null,task_profile:k(t.task_profile)??null,risk_level:k(t.risk_level)??null,routing_confidence:Z(t.routing_confidence)??null,routing_reason:k(t.routing_reason)??null,status:k(t.status)??"unknown",turn_count:Z(t.turn_count)??0,empty_note_turn_count:Z(t.empty_note_turn_count)??0,has_turn:Ys(t.has_turn)??!1,last_turn_ts_iso:k(t.last_turn_ts_iso)??null}:null}function Qm(t){if(!H(t))return null;const e=k(t.session_id);return e?{session_id:e,goal:k(t.goal),status:k(t.status),health:k(t.health),scale_profile:k(t.scale_profile),control_profile:k(t.control_profile),planned_worker_count:Z(t.planned_worker_count),active_agent_count:Z(t.active_agent_count),last_turn_age_sec:Z(t.last_turn_age_sec)??null,attention_count:Z(t.attention_count),recommended_action_count:Z(t.recommended_action_count),top_attention:yr(t.top_attention),top_recommendation:br(t.top_recommendation)}:null}function kr(t){const e=H(t)?t:{};return{trace_id:k(e.trace_id),target_type:k(e.target_type)??"room",target_id:k(e.target_id)??null,health:k(e.health),swarm_status:H(e.swarm_status)?e.swarm_status:void 0,attention_items:Rt(e.attention_items).map(yr).filter(n=>n!==null),recommended_actions:Rt(e.recommended_actions).map(br).filter(n=>n!==null),session_cards:Rt(e.session_cards).map(Qm).filter(n=>n!==null),worker_cards:Rt(e.worker_cards).map(Xm).filter(n=>n!==null)}}function Zm(t){if(!H(t))return null;const e=H(t.status)?t.status:void 0,n=H(t.summary)?t.summary:H(e==null?void 0:e.summary)?e.summary:void 0,s=H(t.session)?t.session:H(e==null?void 0:e.session)?e.session:void 0,a=k(t.session_id)??k(n==null?void 0:n.session_id)??k(s==null?void 0:s.session_id);if(!a)return null;const i=Vo(t.report_paths)??Vo(e==null?void 0:e.report_paths),r=Rt(t.recent_events,["events"]).filter(H);return{session_id:a,status:k(t.status)??k(n==null?void 0:n.status)??k(s==null?void 0:s.status),progress_pct:Z(t.progress_pct)??Z(n==null?void 0:n.progress_pct),elapsed_sec:Z(t.elapsed_sec)??Z(n==null?void 0:n.elapsed_sec),remaining_sec:Z(t.remaining_sec)??Z(n==null?void 0:n.remaining_sec),done_delta_total:Z(t.done_delta_total)??Z(n==null?void 0:n.done_delta_total),summary:n,team_health:H(t.team_health)?t.team_health:H(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:H(t.communication_metrics)?t.communication_metrics:H(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:H(t.orchestration_state)?t.orchestration_state:H(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:H(t.cascade_metrics)?t.cascade_metrics:H(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:s,recent_events:r}}function tv(t){if(!H(t))return null;const e=k(t.name);if(!e)return null;const n=H(t.context)?t.context:void 0;return{name:e,agent_name:k(t.agent_name),status:k(t.status),autonomy_level:k(t.autonomy_level),context_ratio:Z(t.context_ratio)??Z(n==null?void 0:n.context_ratio),generation:Z(t.generation),active_goal_ids:Jm(t.active_goal_ids),last_autonomous_action_at:k(t.last_autonomous_action_at)??null,last_turn_ago_s:Z(t.last_turn_ago_s),model:k(t.model)??k(t.active_model)??k(t.primary_model)}}function ev(t){if(!H(t))return null;const e=k(t.confirm_token)??k(t.token);return e?{confirm_token:e,actor:k(t.actor),action_type:k(t.action_type),target_type:k(t.target_type),target_id:k(t.target_id)??null,delegated_tool:k(t.delegated_tool),created_at:k(t.created_at),preview:t.preview}:null}function nv(t){const e=H(t)?t:{};return{room:Ym(e.room),sessions:Rt(e.sessions,["items","sessions"]).map(Zm).filter(n=>n!==null),keepers:Rt(e.keepers,["items","keepers"]).map(tv).filter(n=>n!==null),recent_messages:Rt(e.recent_messages,["messages"]).map(Vm).filter(n=>n!==null),pending_confirms:Rt(e.pending_confirms,["items","confirms"]).map(ev).filter(n=>n!==null),available_actions:Rt(e.available_actions,["actions"]).filter(H).map(n=>({action_type:k(n.action_type)??"unknown",target_type:k(n.target_type)??"unknown",description:k(n.description),confirm_required:Ys(n.confirm_required)}))}}function On(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Yo(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Cs(t){As.value=[{...t,id:Gm++,at:new Date().toISOString()},...As.value].slice(0,20)}function xr(t){return t.confirm_required?On(t.preview)||"Confirmation required":On(t.result)||On(t.executed_action)||On(t.delegated_tool_result)||t.status}async function ne(){Ss.value=!0,ee.value=null;try{const t=await Al();We.value=nv(t)}catch(t){ee.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Ss.value=!1}}async function Ht(){fn.value=!0,Fe.value=null;try{const t=await Si({targetType:"room"});hr.value=kr(t)}catch(t){Fe.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{fn.value=!1}}async function gn(t){if(!t){Ut.value=null;return}fn.value=!0,Fe.value=null;try{const e=await Si({targetType:"team_session",targetId:t,includeWorkers:!0});Ut.value=kr(e)}catch(e){Fe.value=e instanceof Error?e.message:"Failed to load session digest"}finally{fn.value=!1}}async function sv(t){var e;V.value=!0,ee.value=null;try{const n=await Es(t);return Cs({actor:t.actor,action_type:t.action_type,target_label:Yo(t),outcome:n.confirm_required?"preview":"executed",message:xr(n),delegated_tool:n.delegated_tool}),await ne(),await Ht(),(e=Ut.value)!=null&&e.target_id&&await gn(Ut.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw ee.value=s,Cs({actor:t.actor,action_type:t.action_type,target_label:Yo(t),outcome:"error",message:s}),n}finally{V.value=!1}}async function av(t,e){var n;V.value=!0,ee.value=null;try{const s=await Dl(t,e);return Cs({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:xr(s),delegated_tool:s.delegated_tool}),await ne(),await Ht(),(n=Ut.value)!=null&&n.target_id&&await gn(Ut.value.target_id),s}catch(s){const a=s instanceof Error?s.message:"Operator confirmation failed";throw ee.value=a,Cs({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),s}finally{V.value=!1}}id(()=>{var t;ne(),Ht(),(t=Ut.value)!=null&&t.target_id&&gn(Ut.value.target_id)});const Sr="masc_dashboard_agent_name";function ov(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Sr))==null?void 0:s.trim())||"dashboard"}const Xs=m(ov()),Le=m(""),Za=m("운영 점검"),Ee=m(""),$n=m(""),hn=m("2"),yn=m(""),Pt=m("note"),bn=m(""),kn=m(""),xn=m(""),Sn=m("2"),ws=m("운영자 중지 요청"),Ts=m(""),ze=m(""),jn=m(null);function iv(t){const e=t.trim()||"dashboard";Xs.value=e,localStorage.setItem(Sr,e)}function Xo(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function rv(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function qe(t){return typeof t=="string"?t.trim().toLowerCase():""}function lv(t){var s;const e=qe(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=qe((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function ra(t){const e=qe(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function Qo(t){return t.some(e=>qe(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function cv(t){return t.target_type==="team_session"}function dv(t){return t.target_type==="keeper"}function Fn(t){switch(t){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";case"keeper_msg":return"keeper 메시지";default:return(t==null?void 0:t.trim())||"액션"}}function qn(t){switch(t){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";default:return(t==null?void 0:t.trim())||"target"}}function Ye(t){switch(qe(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Zo(t){return t?"확인 후 실행":"즉시 실행"}function uv(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";default:return t}}function vt(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function pv(t){if(t.action_type==="team_task_inject")return"task";if(t.action_type==="team_broadcast")return"broadcast";if(t.action_type==="team_note")return"note";if(t.action_type==="team_turn"){const e=vt(t.suggested_payload,"turn_kind");if(e==="broadcast"||e==="task")return e}return"note"}function mv(t){const e=t.suggested_payload;if(t.target_type==="room"){if(t.action_type==="broadcast"){Le.value=vt(e,"message")??t.summary;return}t.action_type==="task_inject"&&(Ee.value=vt(e,"title")??"운영자 주입 작업",$n.value=vt(e,"description")??t.summary,hn.value=vt(e,"priority")??hn.value);return}if(t.target_type==="team_session"){if(t.target_id&&(yn.value=t.target_id),t.action_type==="team_stop"){ws.value=vt(e,"reason")??t.summary;return}Pt.value=pv(t);const n=vt(e,"message");n&&(bn.value=n),Pt.value==="task"&&(kn.value=vt(e,"task_title")??vt(e,"title")??"운영자 주입 작업",xn.value=vt(e,"task_description")??vt(e,"description")??t.summary,Sn.value=vt(e,"task_priority")??vt(e,"priority")??Sn.value);return}t.target_type==="keeper"&&(t.target_id&&(Ts.value=t.target_id),ze.value=vt(e,"message")??t.summary)}function vv(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function he(t){const e=Xs.value.trim()||"dashboard";try{const n=await sv({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?P("확인 대기열에 올렸습니다","warning"):P(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return P(s,"error"),null}}async function ti(){const t=Le.value.trim();if(!t)return;await he({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(Le.value="")}async function _v(){await he({action_type:"room_pause",target_type:"room",payload:{reason:Za.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function ei(){await he({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function fv(){const t=Ee.value.trim();if(!t)return;await he({action_type:"task_inject",target_type:"room",payload:{title:t,description:$n.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(hn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(Ee.value="",$n.value="")}async function gv(){var r;const t=We.value,e=yn.value||((r=t==null?void 0:t.sessions[0])==null?void 0:r.session_id)||"";if(!e){P("먼저 세션을 고르세요","warning");return}const n={},s=bn.value.trim();s&&(n.message=s);let a="team_note";Pt.value==="broadcast"?a="team_broadcast":Pt.value==="task"&&(a="team_task_inject"),Pt.value==="task"&&(n.task_title=kn.value.trim()||"운영자 주입 작업",n.task_description=xn.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(Sn.value,10)||2),await he({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(bn.value="",Pt.value==="task"&&(kn.value="",xn.value=""))}async function $v(){var n;const t=We.value,e=yn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){P("먼저 세션을 고르세요","warning");return}await he({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:ws.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function hv(){var a;const t=We.value,e=Ts.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=ze.value.trim();if(!e){P("먼저 keeper를 고르세요","warning");return}if(!n)return;await he({action_type:"keeper_message",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`${e}에게 메시지를 보냈습니다`})&&(ze.value="")}async function yv(t){const e=Xs.value.trim()||"dashboard";try{await av(e,t),P("확인 실행을 완료했습니다","success")}catch(n){const s=n instanceof Error?n.message:"확인 실행에 실패했습니다";P(s,"error")}}function bv(){var R,Y,J;const t=We.value,e=L.value.tab==="intervene"?In(L.value):null,n=hr.value,s=Ut.value,a=(t==null?void 0:t.room)??{},i=(t==null?void 0:t.sessions)??[],r=(t==null?void 0:t.keepers)??[],c=(t==null?void 0:t.pending_confirms)??[],d=(t==null?void 0:t.recent_messages)??[],f=(n==null?void 0:n.recommended_actions)??[],p=(t==null?void 0:t.available_actions)??[],u=i.find(v=>v.session_id===yn.value)??i[0]??null,g=r.find(v=>v.name===Ts.value)??r[0]??null,$=(n==null?void 0:n.attention_items)??[],x=$.filter(cv),A=$.filter(dv),I=i.filter(v=>lv(v)!=="ok"),M=r.filter(v=>ra(v)!=="ok"),U=d.slice(0,5),D=vv(e,i,r);ut(()=>{Ht()},[]),ut(()=>{if(L.value.tab!=="intervene"){jn.value=null;return}if(!e){jn.value=null;return}jn.value!==e.id&&(jn.value=e.id,mv(e))},[L.value.tab,L.value.params.source,L.value.params.action_type,L.value.params.target_type,L.value.params.target_id,L.value.params.focus_kind,e==null?void 0:e.id]),ut(()=>{const v=(u==null?void 0:u.session_id)??null;gn(v)},[u==null?void 0:u.session_id]);const N=[{key:"room",label:"Room 게이트",value:a.paused?"일시정지":"열림",detail:a.paused?`재개 전환 대기 중${a.pause_reason?` · ${a.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:a.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:c.length,detail:c.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:c.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:x.length>0?x.length:i.length,detail:x.length>0?((R=x[0])==null?void 0:R.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":i.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:x.length>0?Qo(x):i.length===0?"warn":I.some(v=>qe(v.status)==="paused")?"bad":I.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:A.length>0?A.length:M.length,detail:A.length>0?((Y=A[0])==null?void 0:Y.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":M.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:A.length>0?Qo(A):M.some(v=>ra(v)==="bad")?"bad":M.length>0?"warn":"ok"}];return o`
    <section class="ops-view">
      <${kt} surfaceId="intervene" />
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
            value=${Xs.value}
            onInput=${v=>iv(v.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{ne(),Ht(),gn((u==null?void 0:u.session_id)??null)}}
            disabled=${Ss.value||V.value}
          >
            ${Ss.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${ee.value?o`<section class="ops-banner error">${ee.value}</section>`:null}
      ${Fe.value?o`<section class="ops-banner error">${Fe.value}</section>`:null}
      ${e?o`
        <section class="ops-banner ${D?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${ho(e.action_type)}</span>
            <span>${$o(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?o`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${D?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const v=[];if(c.length>0&&v.push({label:`확인 대기 ${c.length}건 처리`,desc:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:"bad",onClick:()=>{const K=document.querySelector(".ops-pending-section");K==null||K.scrollIntoView({behavior:"smooth"})}}),a.paused&&v.push({label:"Room 재개",desc:`현재 일시정지 상태${a.pause_reason?` (${a.pause_reason})`:""}`,tone:"warn",onClick:()=>void ei()}),M.length>0){const K=M.filter(tt=>ra(tt)==="bad");v.push({label:K.length>0?`Keeper ${K.length}개 오프라인`:`Keeper ${M.length}개 점검 필요`,desc:K.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:K.length>0?"bad":"warn",onClick:()=>{const tt=document.querySelector(".ops-keeper-section");tt==null||tt.scrollIntoView({behavior:"smooth"})}})}return v.length===0?null:o`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${v.slice(0,3).map(K=>o`
                <button class="ops-action-guide-item ${K.tone}" onClick=${K.onClick}>
                  <strong>${K.label}</strong>
                  <span>${K.desc}</span>
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
          ${N.map(v=>o`
            <div key=${v.key} class="ops-priority-card ${v.tone}">
              <span class="ops-priority-label">${v.label}</span>
              <strong>${v.value}</strong>
              <div class="ops-priority-detail">${v.detail}</div>
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
                value=${Le.value}
                onInput=${v=>{Le.value=v.target.value}}
                onKeyDown=${v=>{v.key==="Enter"&&ti()}}
                disabled=${V.value}
              />
              <button class="control-btn" onClick=${()=>{ti()}} disabled=${V.value||Le.value.trim()===""}>
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
                onInput=${v=>{Za.value=v.target.value}}
                disabled=${V.value}
              />
              <button class="control-btn ghost" onClick=${()=>{_v()}} disabled=${V.value}>
                일시정지
              </button>
              <button class="control-btn ghost" onClick=${()=>{ei()}} disabled=${V.value}>
                재개
              </button>
            </div>

            <div class="ops-section-head">작업 주입</div>
            <input
              class="control-input"
              type="text"
              placeholder="작업 제목"
              value=${Ee.value}
              onInput=${v=>{Ee.value=v.target.value}}
              disabled=${V.value}
            />
            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="작업 설명"
              value=${$n.value}
              onInput=${v=>{$n.value=v.target.value}}
              disabled=${V.value}
            ></textarea>
            <div class="control-row ops-split-row">
              <select
                class="control-input ops-select"
                value=${hn.value}
                onChange=${v=>{hn.value=v.target.value}}
                disabled=${V.value}
              >
                <option value="1">P1</option>
                <option value="2">P2</option>
                <option value="3">P3</option>
                <option value="4">P4</option>
                <option value="5">P5</option>
              </select>
              <button class="control-btn" onClick=${()=>{fv()}} disabled=${V.value||Ee.value.trim()===""}>
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
            `:f.length>0?o`
              <div class="ops-log-list">
                ${f.map(v=>o`
                  <article key=${`${v.action_type}:${v.target_type}:${v.target_id??"room"}`} class="ops-log-entry ${v.severity}">
                    <div class="ops-log-head">
                      <strong>${Fn(v.action_type)}</strong>
                      <span>${qn(v.target_type)}${v.target_id?` · ${v.target_id}`:""}</span>
                      <span>${Zo(v.confirm_required)}</span>
                    </div>
                    <div class="ops-log-body">${v.reason}</div>
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
              <${z} panelId="intervene.pending_confirmations" compact=${!0} />
            </div>
            <p class="ops-context-note">미리보기만 끝났고 아직 사람이 눌러줘야 하는 액션만 남깁니다.</p>
            ${c.length>0?o`
              <div class="ops-confirmation-list">
                ${c.map(v=>o`
                  <article key=${v.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${Fn(v.action_type)}</strong>
                      <span>${qn(v.target_type)}${v.target_id?` · ${v.target_id}`:""}</span>
                      <span>${v.delegated_tool??"위임 도구 확인 필요"}</span>
                    </div>
                    ${v.preview?o`<pre class="ops-code-block compact">${Xo(v.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{yv(v.confirm_token)}} disabled=${V.value}>
                        실행
                      </button>
                      <span class="ops-token">${v.confirm_token}</span>
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
            ${U.length>0?o`
              <div class="ops-feed-list">
                ${U.map(v=>o`
                  <article key=${v.seq??v.id??v.timestamp} class="ops-feed-item">
                    <div class="ops-feed-meta">
                      <strong>${v.from}</strong>
                      <span>${v.timestamp}</span>
                    </div>
                    <div class="ops-feed-content">${v.content}</div>
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
              ${i.length===0?o`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:i.map(v=>{var K;return o`
                <button
                  key=${v.session_id}
                  class="ops-entity-card ${(u==null?void 0:u.session_id)===v.session_id?"active":""}"
                  onClick=${()=>{yn.value=v.session_id}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${v.session_id}</strong>
                    <span class="status-badge ${v.status??"idle"}">${Ye(v.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round(v.progress_pct??0)}%</span>
                    <span>${v.done_delta_total??0}건 완료</span>
                    <span>${(K=v.team_health)!=null&&K.status?Ye(String(v.team_health.status)):"상태 확인 필요"}</span>
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
                ${s.attention_items.length>0?s.attention_items.map(v=>o`
                  <article key=${`${v.kind}:${v.target_id??"session"}`} class="ops-log-entry ${v.severity}">
                    <div class="ops-log-head">
                      <strong>${v.kind}</strong>
                      <span>${qn(v.target_type)}${v.target_id?` · ${v.target_id}`:""}</span>
                    </div>
                    <div class="ops-log-body">${v.summary}</div>
                  </article>
                `):o`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
                ${s.worker_cards.length>0?s.worker_cards.map(v=>o`
                  <article key=${`${v.actor??v.spawn_role??"worker"}:${v.spawn_agent??v.runtime_pool??"runtime"}`} class="ops-log-entry">
                    <div class="ops-log-head">
                      <strong>${v.actor??v.spawn_role??"worker"}</strong>
                      <span>${Ye(v.status)}</span>
                      <span>${v.spawn_agent??v.runtime_pool??"runtime 확인 필요"}</span>
                    </div>
                    <div class="ops-log-body">
                      ${v.worker_class??"worker"}${v.lane_id?` · ${v.lane_id}`:""}${v.routing_reason?` · ${v.routing_reason}`:""}
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
                  <span>상태: ${Ye(u.status)}</span>
                  <span>경과: ${u.elapsed_sec??0}초</span>
                  <span>남은 시간: ${u.remaining_sec??0}초</span>
                </div>
                ${u.recent_events&&u.recent_events.length>0?o`
                  <pre class="ops-code-block compact">${Xo(u.recent_events.slice(-3))}</pre>
                `:null}
              </div>
            `:o`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

            <label class="control-label" for="ops-turn-kind">세션 액션</label>
            <div class="control-row ops-split-row">
              <select
                id="ops-turn-kind"
                class="control-input ops-select"
                value=${Pt.value}
                onChange=${v=>{Pt.value=v.target.value}}
                disabled=${V.value||!u}
              >
                <option value="note">노트</option>
                <option value="broadcast">방송</option>
                <option value="task">작업</option>
              </select>
              <button class="control-btn" onClick=${()=>{gv()}} disabled=${V.value||!u}>
                적용
              </button>
            </div>
            <div class="ops-context-note">현재 선택: ${uv(Pt.value)}</div>

            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="세션에 남길 메시지"
              value=${bn.value}
              onInput=${v=>{bn.value=v.target.value}}
              disabled=${V.value||!u}
            ></textarea>

            ${Pt.value==="task"?o`
              <input
                class="control-input"
                type="text"
                placeholder="주입할 작업 제목"
                value=${kn.value}
                onInput=${v=>{kn.value=v.target.value}}
                disabled=${V.value||!u}
              />
              <textarea
                class="control-textarea"
                rows=${2}
                placeholder="주입할 작업 설명"
                value=${xn.value}
                onInput=${v=>{xn.value=v.target.value}}
                disabled=${V.value||!u}
              ></textarea>
              <select
                class="control-input ops-select"
                value=${Sn.value}
                onChange=${v=>{Sn.value=v.target.value}}
                disabled=${V.value||!u}
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
                value=${ws.value}
                onInput=${v=>{ws.value=v.target.value}}
                disabled=${V.value||!u}
              />
              <button class="control-btn ghost" onClick=${()=>{$v()}} disabled=${V.value||!u}>
                세션 중지
              </button>
            </div>
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel ops-keeper-section">
            <div class="card-title-row">
              <div class="card-title">Keeper 개입</div>
              <${z} panelId="intervene.keeper_queue" compact=${!0} />
            </div>
            <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

            <div class="ops-entity-list">
              ${r.length===0?o`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:r.map(v=>o`
                <button
                  key=${v.name}
                  class="ops-entity-card ${(g==null?void 0:g.name)===v.name?"active":""}"
                  onClick=${()=>{Ts.value=v.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${v.name}</strong>
                    <span class="status-badge ${v.status??"idle"}">${Ye(v.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${v.model??"model 확인 필요"}</span>
                    <span>${typeof v.context_ratio=="number"?`${Math.round(v.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                    <span>${rv(v.last_turn_ago_s)}</span>
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
                  <span>활성 목표: ${((J=g.active_goal_ids)==null?void 0:J.length)??0}</span>
                </div>
              </div>
            `:o`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

            <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
            <textarea
              id="ops-keeper-message"
              class="control-textarea"
              rows=${6}
              placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
              value=${ze.value}
              onInput=${v=>{ze.value=v.target.value}}
              disabled=${V.value||!g}
            ></textarea>
            <div class="control-row">
              <button class="control-btn" onClick=${()=>{hv()}} disabled=${V.value||!g||ze.value.trim()===""}>
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
              ${p.length?p.map(v=>o`
                    <article key=${`${v.action_type}:${v.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${Fn(v.action_type)}</strong>
                        <span>${qn(v.target_type)}</span>
                        <span>${Zo(v.confirm_required)}</span>
                      </div>
                      <div class="ops-log-body">${v.description??"설명이 아직 없습니다."}</div>
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
              `:As.value.map(v=>o`
                <article key=${v.id} class="ops-log-entry ${v.outcome}">
                  <div class="ops-log-head">
                    <strong>${Fn(v.action_type)}</strong>
                    <span>${v.target_label}</span>
                    <span>${v.at}</span>
                  </div>
                  <div class="ops-log-body">${v.message}</div>
                </article>
              `)}
            </div>
          </section>
        </div>
      </div>
    </section>
  `}function kv({text:t}){if(!t)return null;const e=xv(t);return o`<div class="markdown-content">${e}</div>`}function xv(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(o`<pre><code class=${c?`language-${c}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&r.push(c),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const f=e[s].replace("</think>","").trim();f&&r.push(f),s++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${la(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${la(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${la(i.join(`
`))}</p>`)}return n}function la(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Ar=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],ts=m(null),es=m([]),Ke=m(!1),fe=m(null),en=m(""),nn=m(!1);function Sv(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Av=m(Sv());function Cv(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function ni(t){return t.updated_at!==t.created_at}async function Ao(t){fe.value=t,ts.value=null,es.value=[],Ke.value=!0;try{const e=await Ol(t);if(fe.value!==t)return;ts.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},es.value=e.comments??[]}catch{fe.value===t&&(ts.value=null,es.value=[])}finally{fe.value===t&&(Ke.value=!1)}}async function si(t){const e=en.value.trim();if(e){nn.value=!0;try{await jl(t,Av.value,e),en.value="",P("Comment posted","success"),await Ao(t),Dt()}catch{P("Failed to post comment","error")}finally{nn.value=!1}}}function wv(){const t=ln.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Ar.map(e=>o`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{ln.value=e.id,Dt()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Ce.value?"is-active":""}"
          onClick=${()=>{Ce.value=!Ce.value,Dt()}}
        >
          ${Ce.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${Dt} disabled=${dn.value}>
          ${dn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function ca(){var e;const t=((e=Ar.find(n=>n.id===ln.value))==null?void 0:e.label)??ln.value;return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Visible posts</span>
        <strong>${Os.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Sort</span>
        <strong>${t}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${Ce.value?"Auto reports hidden":"Full memory feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Ha.value?o`<${at} timestamp=${Ha.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Tv({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Ai(t.id,n),Dt()}catch{P("Failed to vote","error")}};return o`
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
              ${ni(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${at} timestamp=${t.created_at} /></span>
            ${ni(t)?o`<span>Updated <${at} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${Cv(t.content)}</div>
      </div>
    </div>
  `}function Iv({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${at} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Nv({postId:t}){return o`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${en.value}
        onInput=${e=>{en.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&si(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${nn.value}
      />
      <button
        onClick=${()=>si(t)}
        disabled=${nn.value||en.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${nn.value?"...":"Post"}
      </button>
    </div>
  `}function Rv({post:t}){fe.value!==t.id&&!Ke.value&&Ao(t.id);const e=async n=>{try{await Ai(t.id,n),Dt()}catch{P("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>xt("memory")}>← Back to Memory</button>
      <${T} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${kv} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${t.author}</span>
            <${at} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
          </div>
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${T} title="Comments" semanticId="memory.feed">
        ${Ke.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Iv} comments=${es.value} />`}
        <${Nv} postId=${t.id} />
      <//>
    </div>
  `}function Pv(){const t=Os.value,e=L.value.params.post??null,n=e?t.find(s=>s.id===e)??(fe.value===e?ts.value:null):null;return e&&!n&&fe.value!==e&&!Ke.value&&Ao(e),e?n?o`
          <${kt} surfaceId="memory" />
          <${ca} />
          <${Rv} post=${n} />
        `:o`
          <div>
            <${kt} surfaceId="memory" />
            <${ca} />
            <button class="back-btn" onClick=${()=>xt("memory")}>← Back to Memory</button>
            ${Ke.value?o`<div class="loading-indicator">Loading post...</div>`:o`<div class="empty-state">Post not found</div>`}
          </div>
        `:o`
    <div>
      <${kt} surfaceId="memory" />
      <${ca} />
      <${wv} />
      ${dn.value?o`<div class="loading-indicator">Loading memory feed...</div>`:t.length===0?o`<div class="empty-state">No posts in durable memory right now</div>`:o`
              <${T} title="Posts / Comments" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.map(s=>o`<${Tv} key=${s.id} post=${s} />`)}
                </div>
              <//>
            `}
    </div>
  `}function Cr({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${c}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${c}">${Math.round(t*100)}%</span>
    </div>
  `}const da=600*1e3,Mv=1200*1e3,ai=.8;function Jt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ke(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Dv(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function Lv(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Ev(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function zv(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function Ov(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function jv(t){var d,f;const e=Li.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,s=n?Math.max(0,Date.now()-Jt(n)):Number.POSITIVE_INFINITY,a=!!((d=t.current_task)!=null&&d.trim())||e.activeAssignedCount>0;let i="watching",r="ok",c="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",c=n?"Offline or inactive":"No recent presence"):s>Mv?(i="quiet",r="bad",c=a?"Working without a fresh signal":"No fresh agent signal"):a?(i="working",r=s>da?"warn":"ok",c=s>da?"Execution looks quiet for too long":"Task and live signal aligned"):s>da?(i="quiet",r="warn",c="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",c="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((f=t.current_task)==null?void 0:f.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:c}}function Fv(t){const e=Fc.value.get(t.name)??"idle",n=Uc.value.has(t.name),s=t.context_ratio??0;let a="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(a="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||s>=ai)&&(a="warning",i="warn",r=s>=ai?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:a,tone:i,focus:zv(t),note:r}}function Xe({label:t,value:e,color:n,caption:s}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?o`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function qv({item:t}){const e=t.kind==="agent"?()=>Us(t.agent.name):()=>_o(t.keeper);return o`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?o`<span><${at} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </button>
  `}function oi({row:t}){const{agent:e,motion:n}=t;return o`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Us(e.name)}>
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
        <${ie} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${Dv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${at} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
        ${e.last_seen?o`<span>Seen <${at} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?o`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function Kv({row:t}){const{keeper:e}=t;return o`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>_o(e)}>
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
        <${ie} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Lv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?o`<span>Heartbeat <${at} timestamp=${e.last_heartbeat} /></span>`:o`<span>No heartbeat</span>`}
        <span>${Ov(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${Ev(e.context_ratio)}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?o`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function Uv(){const t=[...Bt.value].map(jv).sort((p,u)=>{const g=ke(u.tone)-ke(p.tone);if(g!==0)return g;const $=u.activeTaskCount-p.activeTaskCount;return $!==0?$:Jt(u.lastSignalAt)-Jt(p.lastSignalAt)}),e=[...oe.value].map(Fv).sort((p,u)=>{const g=ke(u.tone)-ke(p.tone);if(g!==0)return g;const $=(u.keeper.context_ratio??0)-(p.keeper.context_ratio??0);return $!==0?$:Jt(u.keeper.last_heartbeat)-Jt(p.keeper.last_heartbeat)}),n=t.filter(p=>p.state!=="offline"),s=t.filter(p=>p.state==="offline"),a=n.length,i=t.filter(p=>p.state==="working").length,r=t.filter(p=>p.lastSignalAt&&Date.now()-Jt(p.lastSignalAt)<=12e4).length,c=t.filter(p=>p.tone!=="ok"),d=e.filter(p=>p.tone!=="ok"),f=[...d.map(p=>({kind:"keeper",key:`keeper-${p.keeper.name}`,tone:p.tone,title:p.keeper.name,subtitle:`${p.note} · ${p.focus}`,timestamp:p.keeper.last_heartbeat??null,keeper:p.keeper})),...c.map(p=>({kind:"agent",key:`agent-${p.agent.name}`,tone:p.tone,title:p.agent.name,subtitle:`${p.note} · ${p.focus}`,timestamp:p.lastSignalAt,agent:p.agent}))].sort((p,u)=>{const g=ke(u.tone)-ke(p.tone);return g!==0?g:Jt(u.timestamp)-Jt(p.timestamp)}).slice(0,8);return o`
    <div class="agents-monitor">
      <${kt} surfaceId="execution" />
      <div class="stats-grid">
        <${Xe} label="Workers online" value=${a} color="#4ade80" caption="활성 + 대기 실행 actor" />
        <${Xe} label="Working now" value=${i} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${Xe} label="Fresh signals" value=${r} color="#22d3ee" caption="최근 2분 이내 신호" />
        <${Xe} label="Worker alerts" value=${c.length} color=${c.length>0?"#fb7185":"#4ade80"} caption="실행 actor 경고" />
        <${Xe} label="Continuity alerts" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="keeper 연속성 경고" />
      </div>

      <${T} title="Execution Priorities" class="section" semanticId="execution.priority_queue">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs execution attention right now</h2>
          <p class="monitor-subheadline">Worker drift and keeper continuity risk are ranked together here, but diagnosed in separate sections below.</p>
        </div>
        <div class="monitor-alert-list">
          ${f.length===0?o`<div class="empty-state">No execution alerts right now</div>`:f.map(p=>o`<${qv} key=${p.key} item=${p} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${T} title="Workers" class="section" semanticId="execution.workers">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Live workers stay grouped here so owner drift is visible before you scan offline history.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?o`<div class="empty-state">No active workers visible</div>`:n.map(p=>o`<${oi} key=${p.agent.name} row=${p} />`)}
          </div>
        <//>

        <${T} title="Continuity" class="section" semanticId="execution.continuity">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper continuity</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and handoff state are isolated from worker execution drift.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?o`<div class="empty-state">No keepers active</div>`:e.map(p=>o`<${Kv} key=${p.keeper.name} row=${p} />`)}
          </div>
        <//>

        <${T} title="Offline Workers" class="section" semanticId="execution.offline">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who dropped out of the live loop</h2>
            <p class="monitor-subheadline">Offline rows stay separate so they do not drown the active execution monitor.</p>
          </div>
          <div class="monitor-list">
            ${s.length===0?o`<div class="empty-state">No offline workers right now</div>`:s.map(p=>o`<${oi} key=${p.agent.name} row=${p} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Is=m("all"),Ns=m("all"),to=se(()=>{let t=cn.value;return Is.value!=="all"&&(t=t.filter(e=>e.horizon===Is.value)),Ns.value!=="all"&&(t=t.filter(e=>e.status===Ns.value)),t}),Hv=se(()=>{const t={short:[],mid:[],long:[]};for(const e of to.value){const n=t[e.horizon];n&&n.push(e)}return t}),Wv=se(()=>{const t=Array.from(Ri.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function Bv(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Co(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function ns(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Gv(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function ii(t){return t.toFixed(4)}function ri(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function Jv({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ns(t.horizon)}">
            ${Co(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${Bv(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${at} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${ie} status=${t.status} />
        <div class="goal-updated">
          <${at} timestamp=${t.updated_at} />
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
        ${e?o`<${at} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function ua({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${T} title="${Co(t)} Goals (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>o`<${Jv} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function Vv(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Is.value===t?"active":""}"
            onClick=${()=>{Is.value=t}}
          >
            ${t==="all"?"All":Co(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Ns.value===t?"active":""}"
            onClick=${()=>{Ns.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function Yv(){const t=cn.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${ns("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ns("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ns("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function Xv({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${ie} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${ii(t.baseline_metric)}</span>
          <span>Current ${ii(t.current_metric)}</span>
          <span class=${ri(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${ri(t)}
          </span>
          <span>Elapsed ${Gv(t.elapsed_seconds)}</span>
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
  `}function pa({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${at} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Qv(){const{todo:t,inProgress:e,done:n}=Oc.value;return o`
    <${T} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>o`<${pa} key=${s.id} task=${s} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>o`<${pa} key=${s.id} task=${s} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>o`<${pa} key=${s.id} task=${s} />`)}
          ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function Zv(){const t=Hv.value,e=Wv.value,n=e.filter(c=>c.status==="running").length,s=e.filter(c=>c.recoverable).length,a=cn.value.filter(c=>c.status==="active").length,i=uo.value,r=i==="idle"?"No loop running":i==="error"?rs.value??"MDAL snapshot unavailable":"Current loop snapshot";return o`
    <div>
      <${kt} surfaceId="planning" />
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${a}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${to.value.length}</div>
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

      <${T} title="Planning Surface" class="section" semanticId="planning.surface">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Planning refresh reads a dedicated projection so goals, loops, and backlog pressure stay in one surface.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${je} disabled=${we.value}>
              ${we.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${Ba} disabled=${Te.value}>
              ${Te.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{je(),Ba()}}
              disabled=${we.value||Te.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${li} label="Goals" timestamp=${Mi.value} source="/api/v1/dashboard/planning" />
          <${li}
            label="MDAL loops"
            timestamp=${Di.value}
            source="/api/v1/dashboard/planning"
            note=${r}
          />
        </div>
      <//>

      <${T} title="Goal Pipeline" class="section" semanticId="planning.goal_pipeline">
        <${Yv} />
        <${Vv} />
      <//>

      ${we.value&&cn.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:to.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${ua} horizon="short" items=${t.short??[]} />
              <${ua} horizon="mid" items=${t.mid??[]} />
              <${ua} horizon="long" items=${t.long??[]} />
            `}

      <${T} title="MDAL Loops" class="section" semanticId="planning.mdal_loops">
        ${Te.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&i==="error"?o`
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
                  ${e.map(c=>o`<${Xv} key=${c.loop_id} loop=${c} />`)}
                </div>
              `}
      <//>

      <${Qv} />
    </div>
  `}const sn=m("debates"),Rs=m([]),Ps=m([]),Ms=m(!1),an=m(!1),An=m(""),on=m(""),Ds=m(null),wt=m(null),eo=m(!1);async function Qs(){Ms.value=!0,An.value="";try{const t=await yl();Rs.value=Array.isArray(t.debates)?t.debates:[],Ps.value=Array.isArray(t.sessions)?t.sessions:[]}catch(t){An.value=t instanceof Error?t.message:"Failed to load governance state"}finally{Ms.value=!1}}ad(Qs);async function ci(){const t=on.value.trim();if(t){an.value=!0;try{const e=await pc(t);on.value="",P(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Qs()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";P(n,"error")}finally{an.value=!1}}}async function t_(t){Ds.value=t,wt.value=null,eo.value=!0;try{wt.value=await mc(t)}catch(e){An.value=e instanceof Error?e.message:"Failed to load debate detail"}finally{eo.value=!1}}function e_(){return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${Rs.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Voting sessions</span>
        <strong>${Ps.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Active view</span>
        <strong>${sn.value==="debates"?"Debates":"Voting"}</strong>
      </div>
    </div>
  `}function n_({debate:t}){const e=Ds.value===t.id;return o`
    <button class="council-row ${e?"selected":""}" onClick=${()=>t_(t.id)}>
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Arguments: ${t.argument_count}</span>
          ${t.created_at?o`<span><${at} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </button>
  `}function s_({session:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.created_at?o`<span><${at} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function a_(){const t=sn.value;return o`
    <div class="overview-sub-tabs" style="margin-bottom:12px;">
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{sn.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{sn.value="voting"}}>Voting</button>
    </div>
  `}function o_(){return o`
    <div>
      <${T} title="Start Debate" class="section" semanticId="governance.debates">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${on.value}
            onInput=${t=>{on.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&ci()}}
            disabled=${an.value}
          />
          <button
            class="control-btn secondary"
            onClick=${ci}
            disabled=${an.value||on.value.trim()===""}
          >
            ${an.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Qs} disabled=${Ms.value}>
            ${Ms.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${An.value?o`<div class="council-error">${An.value}</div>`:null}
      <//>

      <${T} title="Debates" class="section" semanticId="governance.debates">
        <div class="council-list">
          ${Rs.value.length===0?o`<div class="empty-state">No debates yet</div>`:Rs.value.map(t=>o`<${n_} key=${t.id} debate=${t} />`)}
        </div>
      <//>

      <${T} title=${Ds.value?`Debate Detail (${Ds.value})`:"Debate Detail"} class="section" semanticId="governance.debates">
        ${eo.value?o`<div class="loading-indicator">Loading debate detail...</div>`:wt.value?o`
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Status: ${wt.value.status}</span>
                  <span>Total arguments: ${wt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Support: ${wt.value.support_count}</span>
                  <span>Oppose: ${wt.value.oppose_count}</span>
                  <span>Neutral: ${wt.value.neutral_count}</span>
                </div>
                ${wt.value.summary_text?o`<pre class="council-detail">${wt.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function i_(){return o`
    <${T} title="Voting Sessions" class="section" semanticId="governance.voting">
      <div class="council-list">
        ${Ps.value.length===0?o`<div class="empty-state">No active sessions</div>`:Ps.value.map(t=>o`<${s_} key=${t.id} session=${t} />`)}
      </div>
    <//>
  `}function r_(){return ut(()=>{Qs()},[]),o`
    <div>
      <${kt} surfaceId="governance" />
      <${e_} />
      <${a_} />
      ${sn.value==="debates"?o`<${o_} />`:o`<${i_} />`}
    </div>
  `}const Se=m(""),ma=m("ability_check"),va=m("10"),_a=m("12"),Kn=m(""),Un=m("idle"),Vt=m(""),Hn=m("keeper-late"),fa=m("player"),ga=m(""),yt=m("idle"),$a=m(null),Wn=m(""),ha=m(""),ya=m("player"),ba=m(""),ka=m(""),xa=m(""),rn=m("20"),Sa=m("20"),Aa=m(""),Bn=m("idle"),no=m(null),wr=m("overview"),Ca=m("all"),wa=m("all"),Ta=m("all"),l_=12e4,Zs=m(null),di=m(Date.now());function c_(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function d_(t,e){return e>0?Math.round(t/e*100):0}const u_={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},p_={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Gn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function m_(t){const e=t.trim().toLowerCase();return u_[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function v_(t){const e=t.trim().toLowerCase();return p_[e]??"상황에 따라 선택되는 전술 액션입니다."}function Zt(t){return typeof t=="object"&&t!==null}function ft(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function Tt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function Cn(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const __=new Set(["str","dex","con","int","wis","cha"]);function f_(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!Zt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const r=a.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){s[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const c=Number.parseFloat(i.trim());if(Number.isFinite(c)){s[r]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),s}function g_(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(rn.value.trim(),10);Number.isFinite(s)&&s>n&&(rn.value=String(n))}function so(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function $_(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function h_(t){wr.value=t}function Tr(t){const e=Zs.value;return e==null||e<=t}function y_(t){const e=Zs.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Ls(){Zs.value=null}function Ir(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function b_(t,e){Ir(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Zs.value=Date.now()+l_,P("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function ss(t){return Tr(t)?(P("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function ao(t,e,n){return Ir([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function k_({hp:t,max:e}){const n=d_(t,e),s=c_(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function x_({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function S_({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Nr({actor:t}){var d,f,p,u;const e=(d=t.archetype)==null?void 0:d.trim(),n=(f=t.persona)==null?void 0:f.trim(),s=(p=t.portrait)==null?void 0:p.trim(),a=(u=t.background)==null?void 0:u.trim(),i=t.traits??[],r=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([g,$])=>Number.isFinite($)).filter(([g])=>!__.has(g.toLowerCase()));return o`
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
        <${ie} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${S_} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${k_} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${x_} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${Gn(e)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([g,$])=>o`
                <span class="trpg-custom-stat-chip">${Gn(g)} ${$}</span>
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
                  <span class="trpg-annot-name">${Gn(g)}</span>
                  <span class="trpg-annot-desc">${m_(g)}</span>
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
                  <span class="trpg-annot-name">${Gn(g)}</span>
                  <span class="trpg-annot-desc">${v_(g)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function A_({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Rr({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${$_(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${so(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${at} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function C_({events:t}){const e="__none__",n=Ca.value,s=wa.value,a=Ta.value,i=Array.from(new Set(t.map(so).map(u=>u.trim()).filter(u=>u!==""))).sort((u,g)=>u.localeCompare(g)),r=Array.from(new Set(t.map(u=>(u.type??"").trim()).filter(u=>u!==""))).sort((u,g)=>u.localeCompare(g)),c=t.some(u=>(u.type??"").trim()===""),d=Array.from(new Set(t.map(u=>(u.phase??"").trim()).filter(u=>u!==""))).sort((u,g)=>u.localeCompare(g)),f=t.some(u=>(u.phase??"").trim()===""),p=t.filter(u=>{if(n!=="all"&&so(u)!==n)return!1;const g=(u.type??"").trim(),$=(u.phase??"").trim();if(s===e){if(g!=="")return!1}else if(s!=="all"&&g!==s)return!1;if(a===e){if($!=="")return!1}else if(a!=="all"&&$!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${u=>{Ca.value=u.target.value}}>
          <option value="all">all</option>
          ${i.map(u=>o`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${u=>{wa.value=u.target.value}}>
          <option value="all">all</option>
          ${c?o`<option value=${e}>(none)</option>`:null}
          ${r.map(u=>o`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${u=>{Ta.value=u.target.value}}>
          <option value="all">all</option>
          ${f?o`<option value=${e}>(none)</option>`:null}
          ${d.map(u=>o`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Ca.value="all",wa.value="all",Ta.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${p.length} / 전체 ${t.length}
      </span>
    </div>
    <${Rr} events=${p.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function w_({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function Pr({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function T_({state:t,nowMs:e}){var f;const n=Ft.value||((f=t.session)==null?void 0:f.room)||"",s=Un.value,a=t.party??[];if(!a.find(p=>p.id===Se.value)&&a.length>0){const p=a[0];p&&(Se.value=p.id)}const r=async()=>{var u,g;if(!n){P("Room ID가 비어 있습니다.","error");return}if(!ss(e))return;const p=((u=t.current_round)==null?void 0:u.phase)??((g=t.session)==null?void 0:g.status)??"unknown";if(ao("라운드 실행",n,p)){Un.value="running";try{const $=await ec(n);no.value=$,Un.value="ok";const x=Zt($.summary)?$.summary:null,A=x?Cn(x,"advanced",!1):!1,I=x?ft(x,"progress_reason",""):"";P(A?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${I?`: ${I}`:""}`,A?"success":"warning"),Lt()}catch($){no.value=null,Un.value="error";const x=$ instanceof Error?$.message:"라운드 실행에 실패했습니다.";P(x,"error")}finally{Ls()}}},c=async()=>{var u,g;if(!n||!ss(e))return;const p=((u=t.current_round)==null?void 0:u.phase)??((g=t.session)==null?void 0:g.status)??"unknown";if(ao("턴 강제 진행",n,p))try{await ac(n),P("턴을 다음 단계로 이동했습니다.","success"),Lt()}catch{P("턴 이동에 실패했습니다.","error")}finally{Ls()}},d=async()=>{if(!n||!ss(e))return;const p=Se.value.trim();if(!p){P("먼저 Actor를 선택하세요.","warning");return}const u=Number.parseInt(va.value,10),g=Number.parseInt(_a.value,10);if(Number.isNaN(u)||Number.isNaN(g)){P("stat/dc는 숫자여야 합니다.","warning");return}const $=Number.parseInt(Kn.value,10),x=Kn.value.trim()===""||Number.isNaN($)?void 0:$;try{await sc({roomId:n,actorId:p,action:ma.value.trim()||"ability_check",statValue:u,dc:g,rawD20:x}),P("주사위 판정을 기록했습니다.","success"),Lt()}catch{P("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${p=>{Ft.value=p.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Se.value}
            onChange=${p=>{Se.value=p.target.value}}
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
              value=${ma.value}
              onInput=${p=>{ma.value=p.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${va.value}
              onInput=${p=>{va.value=p.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${_a.value}
              onInput=${p=>{_a.value=p.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Kn.value}
              onInput=${p=>{Kn.value=p.target.value}}
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
            <button class="trpg-run-btn secondary" onClick=${c}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${s!=="idle"?o`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function I_({state:t}){var a;const e=Ft.value||((a=t.session)==null?void 0:a.room)||"",n=Bn.value,s=async()=>{if(!e){P("Room ID가 비어 있습니다.","warning");return}const i=Wn.value.trim(),r=ha.value.trim();if(!r&&!i){P("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(rn.value.trim(),10),d=Number.parseInt(Sa.value.trim(),10),f=Number.isFinite(d)?Math.max(1,d):20,p=Number.isFinite(c)?Math.max(0,Math.min(f,c)):f;let u={};try{u=f_(Aa.value)}catch(g){P(g instanceof Error?g.message:"능력치 JSON 오류","error");return}Bn.value="spawning";try{const g=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,$=await oc(e,{actor_id:i||void 0,name:r||void 0,role:ya.value,idempotencyKey:g,portrait:ka.value.trim()||void 0,background:xa.value.trim()||void 0,hp:p,max_hp:f,alive:p>0,stats:Object.keys(u).length>0?u:void 0}),x=typeof $.actor_id=="string"?$.actor_id.trim():"";if(!x)throw new Error("생성 응답에 actor_id가 없습니다.");const A=ba.value.trim();A&&await ic(e,x,A),Se.value=x,Vt.value=x,i||(Wn.value=""),Bn.value="ok",P(`Actor 생성 완료: ${x}`,"success"),await Lt()}catch(g){Bn.value="error",P(g instanceof Error?g.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${ha.value}
            onInput=${i=>{ha.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${ya.value}
            onChange=${i=>{ya.value=i.target.value}}
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
            value=${ba.value}
            onInput=${i=>{ba.value=i.target.value}}
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
              value=${Wn.value}
              onInput=${i=>{Wn.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${ka.value}
              onInput=${i=>{ka.value=i.target.value}}
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
              value=${Sa.value}
              onInput=${i=>{const r=i.target.value;Sa.value=r,g_(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${xa.value}
              onInput=${i=>{xa.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Aa.value}
              onInput=${i=>{Aa.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function N_({state:t,nowMs:e}){var g;const n=Ft.value||((g=t.session)==null?void 0:g.room)||"",s=t.join_gate,a=$a.value,i=Zt(a)?a:null,r=(t.party??[]).filter($=>$.role!=="dm"),c=Vt.value.trim(),d=r.some($=>$.id===c),f=d?c:c?"__manual__":"",p=async()=>{const $=Vt.value.trim(),x=Hn.value.trim();if(!n||!$){P("Room/Actor가 필요합니다.","warning");return}yt.value="checking";try{const A=await rc(n,$,x||void 0);$a.value=A,yt.value="ok",P("참가 가능 여부를 갱신했습니다.","success")}catch(A){yt.value="error";const I=A instanceof Error?A.message:"참가 가능 여부 확인에 실패했습니다.";P(I,"error")}},u=async()=>{var M,U;const $=Vt.value.trim(),x=Hn.value.trim(),A=ga.value.trim();if(!n||!$||!x){P("Room/Actor/Keeper가 필요합니다.","warning");return}if(!ss(e))return;const I=((M=t.current_round)==null?void 0:M.phase)??((U=t.session)==null?void 0:U.status)??"unknown";if(ao("Mid-Join 승인 요청",n,I)){yt.value="requesting";try{const D=await lc({room_id:n,actor_id:$,keeper_name:x,role:fa.value,...A?{name:A}:{}});$a.value=D;const N=Zt(D)?Cn(D,"granted",!1):!1,R=Zt(D)?ft(D,"reason_code",""):"";N?P("Mid-Join이 승인되었습니다.","success"):P(`Mid-Join이 거절되었습니다${R?`: ${R}`:""}`,"warning"),yt.value=N?"ok":"error",Lt()}catch(D){yt.value="error";const N=D instanceof Error?D.message:"Mid-Join 요청에 실패했습니다.";P(N,"error")}finally{Ls()}}};return o`
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
            value=${f}
            onChange=${$=>{const x=$.target.value;if(x==="__manual__"){(d||!c)&&(Vt.value="");return}Vt.value=x}}
          >
            <option value="">Actor 선택</option>
            ${r.map($=>o`
              <option value=${$.id}>${$.name} (${$.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${f==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${Vt.value}
                onInput=${$=>{Vt.value=$.target.value}}
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
            value=${Hn.value}
            onInput=${$=>{Hn.value=$.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${fa.value}
            onChange=${$=>{fa.value=$.target.value}}
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
            value=${ga.value}
            onInput=${$=>{ga.value=$.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${p} disabled=${yt.value==="checking"||yt.value==="requesting"}>
              ${yt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${u} disabled=${yt.value==="checking"||yt.value==="requesting"}>
              ${yt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Cn(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Tt(i,"effective_score",0)}/${Tt(i,"required_points",0)}</span>
            ${ft(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${ft(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Mr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Dr({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Lr(){const t=no.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=Zt(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(Zt).slice(-8),i=t.canon_check,r=Zt(i)?i:null,c=r&&Array.isArray(r.warnings)?r.warnings.filter(R=>typeof R=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(R=>typeof R=="string").slice(0,3):[],f=n?Cn(n,"advanced",!1):!1,p=n?ft(n,"progress_reason",""):"",u=n?ft(n,"progress_detail",""):"",g=n?Tt(n,"player_successes",0):0,$=n?Tt(n,"player_required_successes",0):0,x=n?Cn(n,"dm_success",!1):!1,A=n?Tt(n,"timeouts",0):0,I=n?Tt(n,"unavailable",0):0,M=n?Tt(n,"reprompts",0):0,U=n?Tt(n,"npc_attacks",0):0,D=n?Tt(n,"keeper_timeout_sec",0):0,N=n?Tt(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${f?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${f?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${x?"DM ok":"DM stalled"} / players ${g}/${$}
          </span>
        </div>
        ${p?o`<div style="margin-top:4px; font-size:12px;">${p}</div>`:null}
        ${u?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${u}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${I}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${M}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${U}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${D||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${N}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(R=>{const Y=ft(R,"status","unknown"),J=ft(R,"actor_id","-"),v=ft(R,"role","-"),K=ft(R,"reason",""),tt=ft(R,"action_type",""),G=ft(R,"reply","");return o`
                <div class="trpg-round-item ${Y.includes("fallback")||Y.includes("timeout")?"failed":"active"}">
                  <span>${J} (${v})</span>
                  <span style="margin-left:auto; font-size:11px;">${Y}</span>
                  ${tt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${tt}</div>`:null}
                  ${K?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${K}</div>`:null}
                  ${G?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${G.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${ft(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(R=>o`<div>violation: ${R}</div>`)}
                </div>`:null}
            ${c.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(R=>o`<div>warning: ${R}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function R_({state:t,nowMs:e}){var r,c,d;const n=Ft.value||((r=t.session)==null?void 0:r.room)||"",s=((c=t.current_round)==null?void 0:c.phase)??((d=t.session)==null?void 0:d.status)??"unknown",a=Tr(e),i=y_(e);return o`
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
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>b_(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Ls(),P("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function P_({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>h_(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function M_({state:t}){const e=t.party??[],n=t.story_log??[];return o`
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
          <${Rr} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${T} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${A_} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${T} title="현재 라운드" semanticId="lab.trpg">
          <${Dr} state=${t} />
        <//>

        <${T} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${Mr} state=${t} />
        <//>

        <${T} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>o`<${Nr} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${Pr} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function D_({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${T} title=${`이벤트 타임라인 (${e.length})`}>
          <${C_} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${T} title="최근 라운드 결과" semanticId="lab.trpg">
          <${Lr} />
        <//>

        <${T} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${Dr} state=${t} />
        <//>
      </div>
    </div>
  `}function L_({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${R_} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${T} title="조작 패널" semanticId="lab.trpg">
            <${T_} state=${t} nowMs=${e} />
          <//>

          <${T} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${I_} state=${t} />
          <//>

          <${T} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${N_} state=${t} nowMs=${e} />
          <//>

          <${T} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${Lr} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${T} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${Mr} state=${t} />
          <//>

          <${T} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${Nr} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${Pr} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function E_(){var c,d,f,p,u;const t=Ni.value,e=Ua.value;if(ut(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const g=window.setInterval(()=>{di.value=Date.now()},1e3);return()=>{window.clearInterval(g)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Lt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,i=wr.value,r=di.value;return o`
    <div>
      <${kt} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Ft.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((f=t.session)==null?void 0:f.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Lt()}>새로고침</button>
      </div>

      <${w_} outcome=${a} />

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

      <${P_} active=${i} />

      ${i==="overview"?o`<${M_} state=${t} />`:i==="timeline"?o`<${D_} state=${t} />`:o`<${L_} state=${t} nowMs=${r} />`}
    </div>
  `}function z_(){return o`
    <div>
      <${kt} surfaceId="lab" />
      <${T} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${T} title="TRPG" class="section" semanticId="lab.trpg">
        <${E_} />
      <//>
    </div>
  `}const ui=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],oo=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}];function O_(){const t=$e.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${io.value} events</span>
    </div>
  `}function j_({currentTab:t,currentSectionLabel:e}){const n=$e.value;return o`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>Snapshot</h3>
        <${z} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${n?"ok":"bad"}">${n?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agents</span>
          <strong>${Bt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keepers</span>
          <strong>${oe.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Tasks</span>
          <strong>${Mt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Events</span>
          <strong>${io.value}</strong>
        </div>
      </div>
      <div class="rail-snapshot-copy">
        <span>Connection ${n?"healthy":"recovering"}</span>
        <span>${e} workspace active</span>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Tn(),Oi(),t==="command"&&(ge(),Yt(),gt.value==="swarm"&&jt()),t==="mission"&&(Qn(),us()),t==="execution"&&Ot(),t==="intervene"&&(ne(),Ht()),t==="memory"&&Dt(),t==="planning"&&je(),t==="lab"&&Lt()}}
        >
          Refresh Now
        </button>
        <button class="rail-secondary-btn" onClick=${()=>xt("intervene")}>
          Open Intervene
        </button>
      </div>
    </section>
  `}function F_(){const t=We.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return o`
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
          onClick=${()=>{ne(),Ht()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>xt("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function q_(){const t=L.value.tab,e=oo.find(s=>s.id===t),n=ui.find(s=>s.id===(e==null?void 0:e.group));return o`
    <aside class="dashboard-rail">
      <${kt} surfaceId="side_rail" compact=${!0} />
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
              ${oo.filter(a=>a.group===s.id).map(a=>o`
                  <button
                    class="rail-tab-btn ${t===a.id?"active":""}"
                    onClick=${()=>xt(a.id)}
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

      <${j_} currentTab=${t} currentSectionLabel=${(n==null?void 0:n.label)??"Observe"} />
      <${F_} />
    </aside>
  `}function K_(){switch(L.value.tab){case"mission":return o`<${Wo} />`;case"execution":return o`<${Uv} />`;case"memory":return o`<${Pv} />`;case"governance":return o`<${r_} />`;case"planning":return o`<${Zv} />`;case"intervene":return o`<${bv} />`;case"command":return o`<${Bm} />`;case"lab":return o`<${z_} />`;default:return o`<${Wo} />`}}function U_(){ut(()=>{Zr(),hi(),ji(),Ot(),Oi(),Qn();const n=rd();return ld(),()=>{rl(),n(),cd()}},[]),ut(()=>{const n=setInterval(()=>{const s=L.value.tab;s==="command"?(ge(),Yt(),gt.value==="swarm"&&jt()):s==="mission"?Qn():s==="execution"?Ot():s==="intervene"?(ne(),Ht()):s==="memory"?Dt():s==="planning"?je():s==="lab"&&Lt()},15e3);return()=>{clearInterval(n)}},[]),ut(()=>{const n=L.value.tab;n==="command"&&(ge(),Yt(),gt.value==="swarm"&&jt()),n==="mission"&&(Qn(),us()),n==="execution"&&Ot(),n==="intervene"&&(ne(),Ht()),n==="memory"&&Dt(),n==="planning"&&je(),n==="lab"&&Lt()},[L.value.tab]);const t=L.value.tab,e=oo.find(n=>n.id===t);return o`
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
          <${O_} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${q_} />
        <main class="dashboard-main">
          ${Ka.value&&!$e.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${K_} />`}
        </main>
      </div>

      <${Yd} />
      <${Rd} />
      <${Cd} />
    </div>
  `}const pi=document.getElementById("app");pi&&Jr(o`<${U_} />`,pi);export{ju as _};
