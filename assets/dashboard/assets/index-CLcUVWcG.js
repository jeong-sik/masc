var Pr=Object.defineProperty;var Dr=(t,e,n)=>e in t?Pr(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var me=(t,e,n)=>Dr(t,typeof e!="symbol"?e+"":e,n);import{e as Lr,_ as Mr,c as f,b as Qt,y as ct,A as Er,d as Zo,G as zr}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const o of document.querySelectorAll('link[rel="modulepreload"]'))s(o);new MutationObserver(o=>{for(const i of o)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(o){const i={};return o.integrity&&(i.integrity=o.integrity),o.referrerPolicy&&(i.referrerPolicy=o.referrerPolicy),o.crossOrigin==="use-credentials"?i.credentials="include":o.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(o){if(o.ep)return;o.ep=!0;const i=n(o);fetch(o.href,i)}})();var a=Lr.bind(Mr);const Or=["mission","execution","memory","governance","planning","intervene","command","lab"],ti={tab:"mission",params:{},postId:null};function $o(t){return!!t&&Or.includes(t)}function ga(t){try{return decodeURIComponent(t)}catch{return t}}function $a(t){const e={};return t&&new URLSearchParams(t).forEach((s,o)=>{e[o]=s}),e}function jr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function ei(t,e){if(t[0]==="chains"){const i={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(i.operation=ga(t[2])),{tab:"command",params:i,postId:null}}if(t[0]==="lab"){const i={...e};return t[1]&&(i.surface=ga(t[1])),{tab:"lab",params:i,postId:null}}const n=t[0],s=e.tab;return{tab:$o(n)?n:$o(s)?s:"mission",params:e,postId:null}}function Yn(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return ti;const n=ga(e);let s=n,o;if(n.startsWith("?"))s="",o=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),o=n.slice(c+1))}!o&&s.includes("=")&&!s.includes("/")&&(o=s,s="");const i=$a(o),r=jr(s);return ei(r,i)}function Fr(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...ti,params:$a(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const o=$a(e.replace(/^\?/,""));return ei(s,o)}function ni(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([o])=>!(o==="tab"||t.tab==="lab"&&o==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const M=f(Yn(window.location.hash));window.addEventListener("hashchange",()=>{M.value=Yn(window.location.hash)});function $t(t,e){const n={tab:t,params:e??{}};window.location.hash=ni(n)}function qr(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function Kr(){if(window.location.hash&&window.location.hash!=="#"){M.value=Yn(window.location.hash);return}const t=Fr(window.location.pathname,window.location.search);if(t){M.value=t;const e=ni(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",M.value=Yn(window.location.hash)}const ho="masc_dashboard_sse_session_id",Ur=1e3,Hr=15e3,ue=f(!1),Ya=f(0),si=f(null),ha=f([]);function Wr(){let t=sessionStorage.getItem(ho);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(ho,t)),t}const Br=200;function Gr(t,e,n="system",s={}){const o={agent:t,text:e,timestamp:Date.now(),kind:n,...s};ha.value=[o,...ha.value].slice(0,Br)}function ya(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function yo(t,e){const n=ya(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function yt(t,e,n,s,o={}){Gr(t,e,n,{eventType:s,...o})}let At=null,ke=null,ba=0;function ai(){ke&&(clearTimeout(ke),ke=null)}function Jr(){if(ke)return;ba++;const t=Math.min(ba,5),e=Math.min(Hr,Ur*Math.pow(2,t));ke=setTimeout(()=>{ke=null,oi()},e)}function oi(){ai(),At&&(At.close(),At=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Wr());const o=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(o);At=i,i.onopen=()=>{At===i&&(ba=0,ue.value=!0)},i.onerror=()=>{At===i&&(ue.value=!1,i.close(),At=null,Jr())},i.onmessage=r=>{try{const c=JSON.parse(r.data);Ya.value++,si.value=c,Vr(c)}catch{}}}function Vr(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":yt(n,"Joined","system","agent_joined");break;case"agent_left":yt(n,"Left","system","agent_left");break;case"broadcast":yt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":yt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":yt(n,yo("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:ya(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":yt(n,yo("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:ya(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":yt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":yt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":yt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":yt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:yt(n,e,"system","unknown")}}function Yr(){ai(),At&&(At.close(),At=null),ue.value=!1}function ii(){return new URLSearchParams(window.location.search)}function ri(){const t=ii(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function li(){return{...ri(),"Content-Type":"application/json"}}const Xr=15e3,Xa=3e4,Qr=6e4,bo=new Set([408,425,429,500,502,503,504]);class hn extends Error{constructor(n){const s=n.method.toUpperCase(),o=n.timeout===!0,i=o?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);me(this,"method");me(this,"path");me(this,"status");me(this,"statusText");me(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=o}}async function Qa(t,e,n){const s=new AbortController,o=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new hn({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(o)}}function Zr(){var e,n;const t=ii();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function st(t){const e=await Qa(t,{headers:ri()},Xr);if(!e.ok)throw new hn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function tl(t){return new Promise(e=>setTimeout(e,t))}function el(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function nl(t){if(t instanceof hn)return t.timeout||typeof t.status=="number"&&bo.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=el(t.message);return e!==null&&bo.has(e)}async function ci(t,e,n=2){let s=0;for(;;)try{return await e()}catch(o){if(!nl(o)||s>=n)throw o;const i=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${i}ms`,o),await tl(i),s+=1}}async function Rt(t,e,n,s=Xa){const o=await Qa(t,{method:"POST",headers:{...li(),...n??{}},body:JSON.stringify(e)},s);if(!o.ok)throw new hn({method:"POST",path:t,status:o.status,statusText:o.statusText});return o.json()}async function sl(t,e,n,s=Xa){const o=await Qa(t,{method:"POST",headers:{...li(),...n??{}},body:JSON.stringify(e)},s);if(!o.ok)throw new hn({method:"POST",path:t,status:o.status,statusText:o.statusText});return o.text()}function al(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function ol(t){var e,n,s,o,i,r,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((o=(s=t.result.content)==null?void 0:s[0])==null?void 0:o.text)??"MCP tool call failed";throw new Error(d)}return((c=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:c.text)??""}async function Ft(t,e){const n=await sl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Qr),s=al(n);return ol(s)}function il(){return st("/api/v1/dashboard/shell")}function rl(){return st("/api/v1/dashboard/execution")}function ll(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),st(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function cl(){return st("/api/v1/dashboard/governance")}function dl(){return st("/api/v1/dashboard/semantics")}function ul(){return st("/api/v1/dashboard/mission")}function pl(){return st("/api/v1/dashboard/planning")}function ml(){return st("/api/v1/operator")}function di(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return st(`/api/v1/operator/digest${n?`?${n}`:""}`)}function vl(){return st("/api/v1/command-plane")}function _l(){return st("/api/v1/command-plane/summary")}function fl(){return st("/api/v1/chains/summary")}function gl(t){return st(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function $l(){return st("/api/v1/command-plane/help")}function hl(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return st(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function yl(t,e){return Rt(t,e)}function bl(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return Xa}}function ws(t){return Rt("/api/v1/operator/action",t,void 0,bl(t))}function kl(t,e){return Rt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function Xn(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function xl(t){var o;const e=t.trim(),s=((o=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:o.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Sl(t){if(!j(t))return null;const e=h(t.id,"").trim(),n=h(t.author,"").trim(),s=h(t.content,"").trim();if(!e||!n)return null;const o=U(t.score,0),i=U(t.votes_up,0),r=U(t.votes_down,0),c=U(t.votes,o||i-r),d=U(t.comment_count,U(t.reply_count,0)),m=(()=>{const x=t.flair;if(typeof x=="string"&&x.trim())return x.trim();if(j(x)){const I=h(x.name,"").trim();if(I)return I}return h(t.flair_name,"").trim()||void 0})(),p=h(t.created_at_iso,"").trim()||Xn(t.created_at),u=h(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Xn(t.updated_at):p),$=h(t.title,"").trim()||xl(s);return{id:e,author:n,title:$,content:s,tags:[],votes:c,vote_balance:o,comment_count:d,created_at:p,updated_at:u,flair:m,hearth_count:U(t.hearth_count,0)}}function Al(t){if(!j(t))return null;const e=h(t.id,"").trim(),n=h(t.post_id,"").trim(),s=h(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:h(t.content,""),created_at:Xn(t.created_at)}}async function Cl(t){return ci("fetchBoardPost",async()=>{const e=await st(`/api/v1/board/${t}?format=flat`),n=j(e.post)?e.post:e,s=Sl(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(Al).filter(r=>r!==null);return{...s,comments:i}})}function ui(t,e){return Rt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Zr()})}function wl(t,e,n){return Rt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Il(t){const e=h(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function rt(...t){for(const e of t){const n=h(e,"");if(n.trim())return n.trim()}return""}function ko(t){const e=Il(rt(t.outcome,t.result,t.result_code));if(!e)return;const n=rt(t.reason,t.reason_code,t.description,t.detail),s=rt(t.summary,t.summary_ko,t.summary_en,t.note),o=rt(t.details,t.details_text,t.text,t.note),i=rt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=rt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=rt(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const u=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof u=="string"?[u]:Array.isArray(u)?u.map(g=>{if(typeof g=="string")return g.trim();if(j(g)){const $=h(g.summary,"").trim();if($)return $;const x=h(g.text,"").trim();if(x)return x;const A=h(g.type,"").trim();return A||h(g.event_id,"").trim()}return""}).filter(g=>g.length>0):[]})(),m=(()=>{const u=U(t.turn,Number.NaN);if(Number.isFinite(u))return u;const g=U(t.turn_number,Number.NaN);if(Number.isFinite(g))return g;const $=U(t.current_turn,Number.NaN);if(Number.isFinite($))return $;const x=U(t.round,Number.NaN);return Number.isFinite(x)?x:void 0})(),p=rt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:o||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:c||void 0,turn:m,phase:p||void 0}}function Tl(t,e){const n=j(t.state)?t.state:{};if(h(n.status,"active").toLowerCase()!=="ended")return;const o=[...e].reverse().find(r=>j(r)?h(r.type,"")==="session.outcome":!1),i=j(n.session_outcome)?n.session_outcome:{};if(j(i)&&Object.keys(i).length>0){const r=ko(i);if(r)return r}if(j(o))return ko(j(o.payload)?o.payload:{})}function j(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function U(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Rl(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function ka(t,e=!1){return typeof t=="boolean"?t:e}function je(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(j(e)){const n=h(e.name,"").trim(),s=h(e.id,"").trim(),o=h(e.skill,"").trim();return n||s||o}return""}).filter(e=>e.length>0):[]}function Nl(t){const e={};if(!j(t)&&!Array.isArray(t))return e;if(j(t))return Object.entries(t).forEach(([n,s])=>{const o=n.trim(),i=h(s,"").trim();!o||!i||(e[o]=i)}),e;for(const n of t){if(!j(n))continue;const s=rt(n.to,n.target,n.actor_id,n.name,n.id),o=rt(n.relationship,n.relation,n.type,n.kind);!s||!o||(e[s]=o)}return e}function Pl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function ft(t,e,n,s=0){const o=t[e];if(typeof o=="number"&&Number.isFinite(o))return o;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const Dl=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Ll(t){const e=j(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,o])=>{const i=s.trim();i&&(Dl.has(i.toLowerCase())||typeof o=="number"&&Number.isFinite(o)&&(n[i]=o))}),n}function Ml(t,e){if(t!=="dice.rolled")return;const n=U(e.raw_d20,0),s=U(e.total,0),o=U(e.bonus,0),i=h(e.action,"roll"),r=U(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:o}}function El(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function zl(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Ol(t,e,n,s){const o=n||e||h(s.actor_id,"")||h(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=h(s.proposed_action,h(s.reply,""));return i?`${o||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=h(s.reply,h(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return h(s.reply,h(s.content,h(s.text,"Narration")));case"dice.rolled":{const i=h(s.action,"roll"),r=U(s.total,0),c=U(s.dc,0),d=h(s.label,""),m=o||"actor",p=c>0?` vs DC ${c}`:"",u=d?` (${d})`:"";return`${m} ${i}: ${r}${p}${u}`}case"turn.started":return`Turn ${U(s.turn,1)} started`;case"phase.changed":return`Phase: ${h(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(s.name,j(s.actor)?h(s.actor.name,o||"unknown"):o||"unknown")}`;case"actor.claimed":return`${h(s.keeper_name,h(s.keeper,"keeper"))} claimed ${o||"actor"}`;case"actor.released":return`${h(s.keeper_name,h(s.keeper,"keeper"))} released ${o||"actor"}`;case"join.window.opened":return`Join window opened (turn ${U(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${U(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${o||h(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${o||h(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${h(s.reason_code,"unknown")}`;case"memory.signal":{const i=j(s.entity_refs)?s.entity_refs:{},r=h(i.requested_tier,""),c=h(i.effective_tier,""),d=ka(i.guardrail_applied,!1),m=h(s.summary_en,h(s.summary_ko,"Memory signal"));if(!r&&!c)return m;const p=r&&c?`${r}->${c}`:c||r;return`${m} [${p}${d?" (guardrail)":""}]`}case"world.event":{if(h(s.event_type,"")==="canon.check"){const r=h(s.status,"unknown"),c=h(s.contract_id,"n/a");return`Canon ${r}: ${c}`}return h(s.description,h(s.summary,"World event"))}case"combat.attack":return h(s.summary,h(s.result,"Attack resolved"));case"combat.defense":return h(s.summary,h(s.result,"Defense resolved"));case"session.outcome":return h(s.summary,h(s.outcome,"Session ended"));default:{const i=El(s);return i?`${t}: ${i}`:t}}}function jl(t,e){const n=j(t)?t:{},s=h(n.type,"event"),o=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=h(n.actor_name,"").trim()||e[o]||h(j(n.payload)?n.payload.actor_name:"",""),r=j(n.payload)?n.payload:{},c=h(n.ts,h(n.timestamp,new Date().toISOString())),d=h(n.phase,h(r.phase,"")),m=h(n.category,"");return{type:s,actor:i||o||h(r.actor_name,""),actor_id:o||h(r.actor_id,""),actor_name:i,seq:n.seq,room_id:h(n.room_id,""),phase:d||void 0,category:m||zl(s),visibility:h(n.visibility,h(r.visibility,"public")),event_id:h(n.event_id,""),content:Ol(s,o,i,r),dice_roll:Ml(s,r),timestamp:c}}function Fl(t,e,n){var F,Z;const s=h(t.room_id,"")||n||"default",o=j(t.state)?t.state:{},i=j(o.party)?o.party:{},r=j(o.actor_control)?o.actor_control:{},c=j(o.join_gate)?o.join_gate:{},d=j(o.contribution_ledger)?o.contribution_ledger:{},m=Object.entries(i).map(([W,et])=>{const b=j(et)?et:{},ee=ft(b,"max_hp",void 0,10),Oe=ft(b,"hp",void 0,ee),Sn=ft(b,"max_mp",void 0,0),An=ft(b,"mp",void 0,0),E=ft(b,"level",void 0,1),ne=ft(b,"xp",void 0,0),Cn=ka(b.alive,Oe>0),fo=r[W],go=typeof fo=="string"?fo:void 0,Ar=Pl(b.role,W,go),Cr=Rl(b.generation),wr=rt(b.joined_at,b.joinedAt,b.started_at,b.startedAt),Ir=rt(b.claimed_at,b.claimedAt,b.assigned_at,b.assignedAt,b.assigned_time),Tr=rt(b.last_seen,b.lastSeen,b.last_seen_at,b.lastSeenAt,b.last_active,b.lastActive),Rr=rt(b.scene,b.current_scene,b.currentScene,b.world_scene,b.scene_name,b.sceneName),Nr=rt(b.location,b.current_location,b.currentLocation,b.position,b.zone,b.area);return{id:W,name:h(b.name,W),role:Ar,keeper:go,archetype:h(b.archetype,""),persona:h(b.persona,""),portrait:h(b.portrait,"")||void 0,background:h(b.background,"")||void 0,traits:je(b.traits),skills:je(b.skills),stats_raw:Ll(b),status:Cn?"active":"dead",generation:Cr,joined_at:wr||void 0,claimed_at:Ir||void 0,last_seen:Tr||void 0,scene:Rr||void 0,location:Nr||void 0,inventory:je(b.inventory),notes:je(b.notes),relationships:Nl(b.relationships),stats:{hp:Oe,max_hp:ee,mp:An,max_mp:Sn,level:E,xp:ne,strength:ft(b,"strength","str",10),dexterity:ft(b,"dexterity","dex",10),constitution:ft(b,"constitution","con",10),intelligence:ft(b,"intelligence","int",10),wisdom:ft(b,"wisdom","wis",10),charisma:ft(b,"charisma","cha",10)}}}),p=m.filter(W=>W.status!=="dead"),u=Tl(t,e),g={phase_open:ka(c.phase_open,!0),min_points:U(c.min_points,3),window:h(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},$=Object.entries(d).map(([W,et])=>{const b=j(et)?et:{};return{actor_id:W,score:U(b.score,0),last_reason:h(b.last_reason,"")||null,reasons:je(b.reasons)}}),x=m.reduce((W,et)=>(W[et.id]=et.name,W),{}),A=e.map(W=>jl(W,x)),I=U(o.turn,1),D=h(o.phase,"round"),q=h(o.map,""),L=j(o.world)?o.world:{},T=q||h(L.ascii_map,h(L.map,"")),N=A.filter((W,et)=>{const b=e[et];if(!j(b))return!1;const ee=j(b.payload)?b.payload:{};return U(ee.turn,-1)===I}),V=(N.length>0?N:A).slice(-12),B=h(o.status,"active");return{session:{id:s,room:s,status:B==="ended"?"ended":B==="paused"?"paused":"active",round:I,actors:p,created_at:((F=A[0])==null?void 0:F.timestamp)??new Date().toISOString()},current_round:{round_number:I,phase:D,events:V,timestamp:((Z=A[A.length-1])==null?void 0:Z.timestamp)??new Date().toISOString()},map:T||void 0,join_gate:g,contribution_ledger:$,outcome:u,party:p,story_log:A,history:[]}}async function ql(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await st(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Kl(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([st(`/api/v1/trpg/state${e}`),ql(t)]);return Fl(n,s,t)}function Ul(t){return Rt("/api/v1/trpg/rounds/run",{room_id:t})}function Hl(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Wl(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Rt("/api/v1/trpg/dice/roll",e)}function Bl(t,e){const n=Hl();return Rt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function Gl(t,e){var o;const n=(o=e.idempotencyKey)==null?void 0:o.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Rt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function Jl(t,e,n){return Rt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Vl(t,e,n){const s=await Ft("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Yl(t){const e=await Ft("trpg.mid_join.request",t);return JSON.parse(e)}async function Xl(t,e){await Ft("masc_broadcast",{agent_name:t,message:e})}async function Ql(t,e,n=1){await Ft("masc_add_task",{title:t,description:e,priority:n})}async function Zl(t=40){return(await Ft("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function tc(t,e=20){return Ft("masc_task_history",{task_id:t,limit:e})}async function ec(t){const e=await Ft("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function nc(t){return ci("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await st(`/api/v1/council/debates/${e}/summary`);if(!j(n))return null;const s=h(n.id,"").trim();return s?{id:s,topic:h(n.topic,""),status:h(n.status,"open"),support_count:U(n.support_count,0),oppose_count:U(n.oppose_count,0),neutral_count:U(n.neutral_count,0),total_arguments:U(n.total_arguments,0),created_at:Xn(n.created_at_iso??n.created_at),summary_text:h(n.summary_text,"")}:null})}function sc(t,e,n){return Ft("masc_keeper_msg",{name:t,message:e})}const ac=f(""),Et=f({}),lt=f({}),xa=f({}),Sa=f({}),Aa=f({}),Ca=f({}),zt=f({});function it(t,e,n){t.value={...t.value,[e]:n}}function qt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function H(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function kt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function $e(t){return typeof t=="boolean"?t:void 0}function wa(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function Ia(t){return Array.isArray(t)?t.map(e=>H(e)).filter(e=>!!e):[]}function oc(t){var n;const e=(n=H(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function ic(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Us(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!qt(s))continue;const o=H(s.name);if(!o)continue;const i=H(s[e]);e==="summary"?n.push({name:o,summary:i}):n.push({name:o,reason:i})}return n}function rc(t){if(!qt(t))return null;const e=H(t.name);return e?{name:e,trigger:H(t.trigger),outcome:H(t.outcome),summary:H(t.summary),reason:H(t.reason)}:null}function lc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function cc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function pi(t,e,n){return H(t)??cc(e,n)}function mi(t,e){return typeof t=="boolean"?t:e==="recover"}function Qn(t){if(!qt(t))return null;const e=H(t.health_state),n=H(t.next_action_path),s=H(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:H(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:wa(t.last_reply_at),last_reply_preview:H(t.last_reply_preview)??null,last_error:H(t.last_error)??null,next_eligible_at_s:kt(t.next_eligible_at_s)??null,recoverable:mi(t.recoverable,n),summary:pi(t.summary,e,H(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function vi(t){return qt(t)?{hour:kt(t.hour),checked:kt(t.checked)??0,acted:kt(t.acted)??0,acted_names:Ia(t.acted_names),activity_report:H(t.activity_report),quiet_hours_overridden:$e(t.quiet_hours_overridden),skipped_reason:H(t.skipped_reason),acted_rows:Us(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:Us(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:Us(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(rc).filter(e=>e!==null):[]}:null}function dc(t){return qt(t)?{enabled:$e(t.enabled)??!1,interval_s:kt(t.interval_s)??0,quiet_start:kt(t.quiet_start),quiet_end:kt(t.quiet_end),quiet_active:$e(t.quiet_active),use_planner:$e(t.use_planner),delegate_llm:$e(t.delegate_llm),agent_count:kt(t.agent_count),agents:Ia(t.agents),last_tick_ago_s:kt(t.last_tick_ago_s)??null,last_tick_ago:H(t.last_tick_ago),total_ticks:kt(t.total_ticks),total_checkins:kt(t.total_checkins),last_skip_reason:H(t.last_skip_reason)??null,last_tick_result:vi(t.last_tick_result),active_self_heartbeats:Ia(t.active_self_heartbeats)}:null}function uc(t){return qt(t)?{status:t.status,diagnostic:Qn(t.diagnostic)}:null}function pc(t){return qt(t)?{recovered:$e(t.recovered)??!1,skipped_reason:H(t.skipped_reason)??null,before:Qn(t.before),after:Qn(t.after),down:t.down,up:t.up}:null}function mc(t,e){var q,L;if(!(t!=null&&t.name))return null;const n=H((q=t.agent)==null?void 0:q.status)??H(t.status)??"unknown",s=H((L=t.agent)==null?void 0:L.error)??null,o=t.presence_keepalive??!0,i=t.keepalive_running??!1,r=t.turn_count??0,c=t.last_turn_ago_s??null,d=t.proactive_enabled??!1,m=t.proactive_cooldown_sec??0,p=t.last_proactive_ago_s??null,u=d&&p!=null?Math.max(0,m-p):null,g=r<=0||c==null?"never":c>900?"stale":"fresh",$=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,x=s??(o&&!i?"keeper keepalive is not running":null),A=n==="offline"||n==="inactive"?"offline":x?"degraded":g==="stale"?"stale":g==="never"?"idle":"healthy",I=x?lc(x):e!=null&&e.quiet_active&&g!=="fresh"?"quiet_hours":o&&!i?"disabled":r<=0?"never_started":u!=null&&u>0?"min_gap":g==="fresh"||g==="stale"?"no_recent_activity":"unknown",D=A==="offline"||A==="degraded"||A==="stale"?"recover":I==="quiet_hours"?"manual_lodge_poke":I==="unknown"?"probe":"direct_message";return{health_state:A,quiet_reason:I,next_action_path:D,last_reply_status:g,last_reply_at:$,last_reply_preview:null,last_error:x,next_eligible_at_s:u!=null&&u>0?u:null,recoverable:mi(void 0,D),summary:pi(void 0,A,I),keepalive_running:i}}function vc(t,e){if(!qt(t))return null;const n=oc(t.role),s=H(t.content)??H(t.preview);if(!s)return null;const o=wa(t.ts_unix)??wa(t.timestamp);return{id:`${n}-${o??"entry"}-${e}`,role:n,label:ic(n),text:s,timestamp:o,delivery:"history"}}function _c(t,e,n){const s=qt(n)?n:null,o=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((i,r)=>vc(i,r)).filter(i=>i!==null):[];return{name:t,diagnostic:Qn(s==null?void 0:s.diagnostic),history:o,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function xo(t,e){const n=lt.value[t]??[];lt.value={...lt.value,[t]:[...n,e].slice(-50)}}function fc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function gc(t,e){const s=(lt.value[t]??[]).filter(o=>o.delivery!=="history"&&!e.some(i=>fc(o,i)));lt.value={...lt.value,[t]:[...e,...s].slice(-50)}}function Is(t,e){Et.value={...Et.value,[t]:e},gc(t,e.history)}function So(t,e){const n=Et.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Is(t,{...n,diagnostic:{...s,...e}})}async function Za(){try{await yn()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function $c(t){ac.value=t.trim()}async function _i(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Et.value[n])return Et.value[n];it(xa,n,!0),it(zt,n,null);try{const s=await Ft("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let o=null;try{o=JSON.parse(s)}catch{o=null}const i=_c(n,s,o);return Is(n,i),i}catch(s){const o=s instanceof Error?s.message:`Failed to inspect ${n}`;return it(zt,n,o),null}finally{it(xa,n,!1)}}async function hc(t,e){const n=t.trim(),s=e.trim();if(!n||!s)return;const o=`local-${Date.now()}`;xo(n,{id:o,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),it(Sa,n,!0),it(zt,n,null);try{const i=await sc(n,s);lt.value={...lt.value,[n]:(lt.value[n]??[]).map(r=>r.id===o?{...r,delivery:"delivered"}:r)},xo(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),So(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await Za()}catch(i){const r=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw lt.value={...lt.value,[n]:(lt.value[n]??[]).map(c=>c.id===o?{...c,delivery:"error",error:r}:c)},So(n,{last_reply_status:"error",last_error:r}),it(zt,n,r),i}finally{it(Sa,n,!1)}}async function yc(t,e){const n=t.trim();if(!n)return null;it(Aa,n,!0),it(zt,n,null);try{const s=await ws({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),o=uc(s.result),i=(o==null?void 0:o.diagnostic)??null;if(i){const r=Et.value[n];Is(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??lt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Za(),i}catch(s){const o=s instanceof Error?s.message:`Failed to probe ${n}`;throw it(zt,n,o),s}finally{it(Aa,n,!1)}}async function bc(t,e){const n=t.trim();if(!n)return null;it(Ca,n,!0),it(zt,n,null);try{const s=await ws({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),o=pc(s.result),i=(o==null?void 0:o.after)??null;if(i){const r=Et.value[n];Is(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??lt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Za(),i}catch(s){const o=s instanceof Error?s.message:`Failed to recover ${n}`;throw it(zt,n,o),s}finally{it(Ca,n,!1)}}function se(t){return(t??"").trim().toLowerCase()}function pt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Fn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function wn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Fe(t){return t.last_heartbeat??wn(t.last_turn_ago_s)??wn(t.last_proactive_ago_s)??wn(t.last_handoff_ago_s)??wn(t.last_compaction_ago_s)}function kc(t){const e=t.title.trim();return e||Fn(t.content)}function xc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Sc(t,e,n,s,o={}){var L;const i=se(t),r=e.filter(T=>se(T.assignee)===i&&(T.status==="claimed"||T.status==="in_progress")).length,c=n.filter(T=>se(T.from)===i).sort((T,N)=>pt(N.timestamp)-pt(T.timestamp))[0],d=s.filter(T=>se(T.agent)===i||se(T.author)===i).sort((T,N)=>pt(N.timestamp)-pt(T.timestamp))[0],m=(o.boardPosts??[]).filter(T=>se(T.author)===i).sort((T,N)=>pt(N.updated_at||N.created_at)-pt(T.updated_at||T.created_at))[0],p=(o.keepers??[]).filter(T=>se(T.name)===i&&Fe(T)!==null).sort((T,N)=>pt(Fe(N)??0)-pt(Fe(T)??0))[0],u=c?pt(c.timestamp):0,g=d?pt(d.timestamp):0,$=m?pt(m.updated_at||m.created_at):0,x=p?pt(Fe(p)??0):0,A=o.lastSeen?pt(o.lastSeen):0,I=((L=o.currentTask)==null?void 0:L.trim())||(r>0?`${r} claimed tasks`:null);if(u===0&&g===0&&$===0&&x===0&&A===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:I};const q=[c?{timestamp:c.timestamp,ts:u,text:Fn(c.content)}:null,m?{timestamp:m.updated_at||m.created_at,ts:$,text:`Post: ${Fn(kc(m))}`}:null,p?{timestamp:Fe(p),ts:x,text:xc(p)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:g,text:Fn(d.text)}:null].filter(T=>T!==null).sort((T,N)=>N.ts-T.ts)[0];return q&&q.ts>=A?{activeAssignedCount:r,lastActivityAt:q.timestamp,lastActivityText:q.text}:{activeAssignedCount:r,lastActivityAt:o.lastSeen??null,lastActivityText:I??"Presence heartbeat"}}const pe=f([]),Wt=f([]),fi=f([]),De=f([]),Ze=f(null),Ac=f(null),Ta=f(new Map),Ts=f([]),tn=f("hot"),he=f(!0),gi=f(null),Mt=f(""),en=f([]),ye=f(!1),$i=f(new Map),to=f("unknown"),Zn=f(null),Ra=f(!1),nn=f(!1),Na=f(!1),be=f(!1),eo=f(null),ts=f(!1),es=f(null),hi=f(null),Pa=f(null),yi=f(null),bi=f(null),Cc=f(null);Qt(()=>pe.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const wc=Qt(()=>{const t=Wt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Ic=Qt(()=>{const t=new Map,e=Wt.value,n=fi.value,s=ha.value,o=Ts.value,i=De.value;for(const r of pe.value)t.set(r.name.trim().toLowerCase(),Sc(r.name,e,n,s,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:o,keepers:i}));return t});function Tc(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const o=s.context_ratio;return o>.85?"handoff-imminent":o>.7?"preparing":o>.5?"compacting":"active"}const Rc=Qt(()=>{const t=new Map;for(const e of De.value)t.set(e.name,Tc(e));return t}),Nc=12e4;function Pc(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const o=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof o=="number"?Date.now()-o*1e3:null}const Dc=Qt(()=>{const t=Date.now(),e=new Set,n=Ta.value;for(const s of De.value){const o=Pc(s,n);o!=null&&t-o>Nc&&e.add(s.name)}return e});let Hs=null;function Lc(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function ot(t){return typeof t=="object"&&t!==null}function y(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function C(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function ce(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Da(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function ki(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Mc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Ec(t){if(!ot(t))return null;const e=y(t.name);return e?{name:e,status:ki(t.status),current_task:y(t.current_task)??null,last_seen:y(t.last_seen),emoji:y(t.emoji),koreanName:y(t.koreanName)??y(t.korean_name),model:y(t.model),traits:ce(t.traits),interests:ce(t.interests),activityLevel:C(t.activityLevel)??C(t.activity_level),primaryValue:y(t.primaryValue)??y(t.primary_value)}:null}function zc(t){if(!ot(t))return null;const e=y(t.id),n=y(t.title);return!e||!n?null:{id:e,title:n,status:Mc(t.status),priority:C(t.priority),assignee:y(t.assignee),description:y(t.description),created_at:y(t.created_at),updated_at:y(t.updated_at)}}function Oc(t){if(!ot(t))return null;const e=y(t.from)??y(t.from_agent)??"system",n=y(t.content)??"",s=y(t.timestamp)??new Date().toISOString();return{id:y(t.id),seq:C(t.seq),from:e,content:n,timestamp:s,type:y(t.type)}}function jc(t){return Array.isArray(t)?t.map(e=>{if(!ot(e))return null;const n=C(e.ts_unix);if(n==null)return null;const s=ot(e.handoff)?e.handoff:null;return{ts:n,context_ratio:C(e.context_ratio)??0,context_tokens:C(e.context_tokens)??0,context_max:C(e.context_max)??0,latency_ms:C(e.latency_ms)??0,generation:C(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:C(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:C(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?C(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Ao(t){if(!ot(t))return null;const e=y(t.health_state),n=y(t.next_action_path),s=y(t.last_reply_status);if(!e||!n||!s)return null;const o=y(t.quiet_reason)??null,i=y(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":o==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":o==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":o==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:o,next_action_path:n,last_reply_status:s,last_reply_at:Da(t.last_reply_at)??y(t.last_reply_at)??null,last_reply_preview:y(t.last_reply_preview)??null,last_error:y(t.last_error)??null,next_eligible_at_s:C(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:i,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Fc(t,e){return(Array.isArray(t)?t:ot(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!ot(s))return null;const o=ot(s.agent)?s.agent:null,i=ot(s.context)?s.context:null,r=ot(s.metrics_window)?s.metrics_window:void 0,c=y(s.name);if(!c)return null;const d=C(s.context_ratio)??C(i==null?void 0:i.context_ratio),m=y(s.status)??y(o==null?void 0:o.status)??"offline",p=ki(m),u=y(s.model)??y(s.active_model)??y(s.primary_model),g=ce(s.skill_secondary),$=i?{source:y(i.source),context_ratio:C(i.context_ratio),context_tokens:C(i.context_tokens),context_max:C(i.context_max),message_count:C(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,x=o?{name:y(o.name),exists:typeof o.exists=="boolean"?o.exists:void 0,error:y(o.error),status:y(o.status),current_task:y(o.current_task)??null,last_seen:y(o.last_seen),last_seen_ago_s:C(o.last_seen_ago_s),is_zombie:typeof o.is_zombie=="boolean"?o.is_zombie:void 0}:void 0,A=jc(s.metrics_series),I={name:c,emoji:y(s.emoji),koreanName:y(s.koreanName)??y(s.korean_name),agent_name:y(s.agent_name),trace_id:y(s.trace_id),model:u,primary_model:y(s.primary_model),active_model:y(s.active_model),next_model_hint:y(s.next_model_hint)??null,status:p,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:C(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:C(s.proactive_idle_sec),proactive_cooldown_sec:C(s.proactive_cooldown_sec),last_heartbeat:y(s.last_heartbeat)??y(o==null?void 0:o.last_seen),generation:C(s.generation),turn_count:C(s.turn_count)??C(s.total_turns),keeper_age_s:C(s.keeper_age_s),last_turn_ago_s:C(s.last_turn_ago_s),last_handoff_ago_s:C(s.last_handoff_ago_s),last_compaction_ago_s:C(s.last_compaction_ago_s),last_proactive_ago_s:C(s.last_proactive_ago_s),context_ratio:d,context_tokens:C(s.context_tokens)??C(i==null?void 0:i.context_tokens),context_max:C(s.context_max)??C(i==null?void 0:i.context_max),context_source:y(s.context_source)??y(i==null?void 0:i.source),context:$,traits:ce(s.traits),interests:ce(s.interests),primaryValue:y(s.primaryValue)??y(s.primary_value),activityLevel:C(s.activityLevel)??C(s.activity_level),memory_recent_note:y(s.memory_recent_note)??null,conversation_tail_count:C(s.conversation_tail_count),k2k_count:C(s.k2k_count),handoff_count_total:C(s.handoff_count_total)??C(s.trace_history_count),compaction_count:C(s.compaction_count),last_compaction_saved_tokens:C(s.last_compaction_saved_tokens),diagnostic:Ao(s.diagnostic),skill_primary:y(s.skill_primary)??null,skill_secondary:g,skill_reason:y(s.skill_reason)??null,metrics_series:A.length>0?A:void 0,metrics_window:r,agent:x};return I.diagnostic=Ao(s.diagnostic)??mc(I,(e==null?void 0:e.lodge)??null),I}).filter(s=>s!==null)}function xi(t){return ot(t)?{...t,lodge:dc(t.lodge)??void 0}:null}function qc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function Kc(t){if(!ot(t))return null;const e=C(t.iteration);if(e==null)return null;const n=C(t.metric_before)??0,s=C(t.metric_after)??n,o=ot(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:C(t.delta)??s-n,changes:y(t.changes)??"",failed_attempts:y(t.failed_attempts)??"",next_suggestion:y(t.next_suggestion)??"",elapsed_ms:C(t.elapsed_ms)??0,cost_usd:C(t.cost_usd)??null,evidence:o?{worker_engine:(o.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:y(o.worker_model)??"",tool_call_count:C(o.tool_call_count)??0,tool_names:ce(o.tool_names)??[],session_id:y(o.session_id)??"",evidence_status:o.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function Uc(t){var i,r;if(!ot(t))return null;const e=y(t.loop_id);if(!e)return null;const n=C(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(Kc).filter(c=>c!==null):[],o=C(t.current_metric)??((i=s[0])==null?void 0:i.metric_after)??n;return{loop_id:e,profile:y(t.profile)??"unknown",status:qc(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:y(t.error_message)??y(t.error_reason)??null,stop_reason:y(t.stop_reason)??y(t.reason)??null,current_iteration:C(t.current_iteration)??((r=s[0])==null?void 0:r.iteration)??0,max_iterations:C(t.max_iterations)??0,baseline_metric:n,current_metric:o,target:y(t.target)??"",stagnation_streak:C(t.stagnation_streak)??0,stagnation_limit:C(t.stagnation_limit)??0,elapsed_seconds:C(t.elapsed_seconds)??0,updated_at:Da(t.updated_at)??null,stopped_at:Da(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:y(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:C(t.latest_tool_call_count)??0,latest_tool_names:ce(t.latest_tool_names)??[],session_id:y(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function yn(){Ra.value=!0;try{await Promise.all([Ai(),Pt()]),hi.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{Ra.value=!1}}async function Si(){ts.value=!0,es.value=null;try{const t=await dl();eo.value=t,Cc.value=new Date().toISOString()}catch(t){es.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{ts.value=!1}}function Hc(t){var e;return((e=eo.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function Wc(t){var n;const e=((n=eo.value)==null?void 0:n.surfaces)??[];for(const s of e){const o=s.panels.find(i=>i.id===t);if(o)return o}return null}function Bc(t){var s,o;en.value=(Array.isArray(t.goals)?t.goals:[]).map(i=>{if(!ot(i))return null;const r=y(i.id),c=y(i.title),d=y(i.horizon),m=y(i.status),p=y(i.created_at),u=y(i.updated_at);return!r||!c||!d||!m||!p||!u?null:{id:r,horizon:d,title:c,metric:y(i.metric)??null,target_value:y(i.target_value)??null,due_date:y(i.due_date)??null,priority:C(i.priority)??3,status:m,parent_goal_id:y(i.parent_goal_id)??null,last_review_note:y(i.last_review_note)??null,last_review_at:y(i.last_review_at)??null,created_at:p,updated_at:u}}).filter(i=>i!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const i of n){const r=Uc(i);r&&e.set(r.loop_id,r)}$i.value=e,Zn.value=typeof((o=t.mdal)==null?void 0:o.error)=="string"?t.mdal.error:null,to.value=Zn.value?"error":e.size===0?"idle":"ready"}async function Ai(){try{const t=await il(),e=xi(t.status);e&&(Ze.value=e)}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Pt(){try{const t=await rl(),e=xi(t.status);e&&(Ze.value=e),pe.value=(Array.isArray(t.agents)?t.agents:[]).map(Ec).filter(n=>n!==null),Wt.value=(Array.isArray(t.tasks)?t.tasks:[]).map(zc).filter(n=>n!==null),fi.value=(Array.isArray(t.messages)?t.messages:[]).map(Oc).filter(n=>n!==null),De.value=Fc(t.keepers,e??Ze.value),Ac.value=null,hi.value=new Date().toISOString()}catch(t){console.error("Dashboard execution fetch error:",t)}}async function It(){nn.value=!0;try{const t=await ll(tn.value,{excludeSystem:he.value});Ts.value=t.posts??[],Pa.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{nn.value=!1}}async function Tt(){var t;Na.value=!0;try{const e=Mt.value||((t=Ze.value)==null?void 0:t.room)||"default";Mt.value||(Mt.value=e);const n=await Kl(e);gi.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Na.value=!1}}async function Te(){ye.value=!0,be.value=!0;try{const t=await pl();Bc(t),yi.value=new Date().toISOString(),bi.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),to.value="error",Zn.value=t instanceof Error?t.message:String(t)}finally{ye.value=!1,be.value=!1}}async function La(){return Te()}let qn=null;function Gc(t){qn=t}let Kn=null;function Jc(t){Kn=t}let Un=null;function Vc(t){Un=t}const ie={};function ae(t,e,n=500){ie[t]&&clearTimeout(ie[t]),ie[t]=setTimeout(()=>{e(),delete ie[t]},n)}function Yc(){const t=si.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Ta.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Ta.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&ae("execution",Pt),Lc(e.type)&&(Hs||(Hs=setTimeout(()=>{yn(),Kn==null||Kn(),Un==null||Un(),Hs=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&ae("execution",Pt),e.type==="broadcast"&&ae("execution",Pt),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&ae("execution",Pt),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&ae("board",It),e.type.startsWith("decision_")&&ae("council",()=>qn==null?void 0:qn()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&ae("mdal",La,350)}});return()=>{t();for(const e of Object.keys(ie))clearTimeout(ie[e]),delete ie[e]}}let We=null;function Xc(){We||(We=setInterval(()=>{ue.value,yn()},1e4))}function Qc(){We&&(clearInterval(We),We=null)}function Zc({metric:t}){return a`
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
  `}function td({panel:t}){return a`
    <div class="semantic-body">
      <div class="semantic-grid">
        <span>Purpose</span><span>${t.purpose}</span>
        <span>Solves</span><span>${t.problem_solved}</span>
        <span>When</span><span>${t.when_active}</span>
        <span>Agent Role</span><span>${t.agent_role}</span>
        <span>Ecosystem</span><span>${t.ecosystem_function}</span>
      </div>
      ${t.related_tools.length>0?a`<div class="semantic-tag-row">
            ${t.related_tools.map(e=>a`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
      ${t.metrics.length>0?a`<div class="semantic-metric-list">
            ${t.metrics.map(e=>a`<${Zc} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function z({panelId:t,compact:e=!1,label:n="Why"}){const s=Wc(t);return s?a`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${td} panel=${s} />
    </details>
  `:ts.value?a`<span class="semantic-inline-state">Loading semantics…</span>`:null}function ht({surfaceId:t,compact:e=!1}){const n=Hc(t);return n?a`
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
      ${n.panels.length>0?a`<div class="semantic-tag-row">
            ${n.panels.map(s=>a`<span class="semantic-tag">${s.title}</span>`)}
          </div>`:null}
    </section>
  `:ts.value?a`<div class="semantic-surface-card ${e?"compact":""}">Loading semantics…</div>`:es.value?a`<div class="semantic-surface-card ${e?"compact":""}">${es.value}</div>`:null}function w({title:t,class:e,semanticId:n,children:s}){return a`
    <div class="card ${e??""}">
      ${t?a`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?a`<${z} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${s}
    </div>
  `}const Ci=f(null),Ma=f(!1),ns=f(null);function X(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function P(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function J(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function no(t){return typeof t=="boolean"?t:void 0}function Dt(t,e=[]){if(Array.isArray(t))return t;if(!X(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Rs(t){if(!X(t))return null;const e=P(t.kind),n=P(t.summary),s=P(t.target_type);return!e||!n||!s?null:{kind:e,severity:P(t.severity)??"warn",summary:n,target_type:s,target_id:P(t.target_id)??null,actor:P(t.actor)??null,evidence:t.evidence}}function Ns(t){if(!X(t))return null;const e=P(t.action_type),n=P(t.target_type),s=P(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:P(t.target_id)??null,severity:P(t.severity)??"warn",reason:s,confirm_required:no(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function ed(t){if(!X(t))return null;const e=P(t.session_id);return e?{session_id:e,goal:P(t.goal),status:P(t.status),health:P(t.health),scale_profile:P(t.scale_profile),control_profile:P(t.control_profile),planned_worker_count:J(t.planned_worker_count),active_agent_count:J(t.active_agent_count),last_turn_age_sec:J(t.last_turn_age_sec)??null,attention_count:J(t.attention_count),recommended_action_count:J(t.recommended_action_count),top_attention:Rs(t.top_attention),top_recommendation:Ns(t.top_recommendation)}:null}function nd(t){if(!X(t))return null;const e=P(t.session_id);return e?{session_id:e,status:P(t.status),progress_pct:J(t.progress_pct),elapsed_sec:J(t.elapsed_sec),remaining_sec:J(t.remaining_sec),done_delta_total:J(t.done_delta_total),summary:X(t.summary)?t.summary:void 0,team_health:X(t.team_health)?t.team_health:void 0,communication_metrics:X(t.communication_metrics)?t.communication_metrics:void 0,orchestration_state:X(t.orchestration_state)?t.orchestration_state:void 0,cascade_metrics:X(t.cascade_metrics)?t.cascade_metrics:void 0,report_paths:X(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([n,s])=>{const o=P(s);return o?[n,o]:null}).filter(n=>n!==null)):void 0,session:X(t.session)?t.session:void 0,recent_events:Dt(t.recent_events,["events"]).filter(X)}:null}function sd(t){if(!X(t))return null;const e=P(t.name);return e?{name:e,agent_name:P(t.agent_name),status:P(t.status),autonomy_level:P(t.autonomy_level),context_ratio:J(t.context_ratio),generation:J(t.generation),active_goal_ids:Dt(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:P(t.last_autonomous_action_at)??null,last_turn_ago_s:J(t.last_turn_ago_s),model:P(t.model)}:null}function ad(t){if(!X(t))return null;const e=P(t.confirm_token)??P(t.token);return e?{confirm_token:e,actor:P(t.actor),action_type:P(t.action_type),target_type:P(t.target_type),target_id:P(t.target_id)??null,delegated_tool:P(t.delegated_tool),created_at:P(t.created_at),preview:t.preview}:null}function od(t){if(!X(t))return null;const e=P(t.action_type),n=P(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:P(t.description),confirm_required:no(t.confirm_required)}}function id(t){const e=X(t)?t:{};return{room_health:P(e.room_health),cluster:P(e.cluster),project:P(e.project),current_room:P(e.current_room)??null,paused:no(e.paused),tempo_interval_s:J(e.tempo_interval_s),active_agents:J(e.active_agents),keeper_pressure:J(e.keeper_pressure),active_operations:J(e.active_operations),pending_approvals:J(e.pending_approvals),incident_count:J(e.incident_count),recommended_action_count:J(e.recommended_action_count),top_attention:Rs(e.top_attention),top_action:Ns(e.top_action)}}function rd(t){const e=X(t)?t:{},n=X(e.swarm_overview)?e.swarm_overview:{};return{health:P(e.health),active_operations:J(e.active_operations),pending_approvals:J(e.pending_approvals),swarm_overview:{active_lanes:J(n.active_lanes),moving_lanes:J(n.moving_lanes),stalled_lanes:J(n.stalled_lanes),projected_lanes:J(n.projected_lanes),last_movement_at:P(n.last_movement_at)??null},top_attention:Rs(e.top_attention),top_action:Ns(e.top_action),session_cards:Dt(e.session_cards).map(ed).filter(s=>s!==null)}}function ld(t){const e=X(t)?t:{};return{sessions:Dt(e.sessions,["items"]).map(nd).filter(n=>n!==null),keepers:Dt(e.keepers,["items"]).map(sd).filter(n=>n!==null),pending_confirms:Dt(e.pending_confirms).map(ad).filter(n=>n!==null),available_actions:Dt(e.available_actions).map(od).filter(n=>n!==null)}}function cd(t){const e=X(t)?t:{};return{generated_at:P(e.generated_at),summary:id(e.summary),incidents:Dt(e.incidents).map(Rs).filter(n=>n!==null),recommended_actions:Dt(e.recommended_actions).map(Ns).filter(n=>n!==null),command_focus:rd(e.command_focus),operator_targets:ld(e.operator_targets)}}async function Hn(){Ma.value=!0,ns.value=null;try{const t=await ul();Ci.value=cd(t)}catch(t){ns.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{Ma.value=!1}}const ss="masc_dashboard_workflow_context",dd=900*1e3;function so(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function bt(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function Kt(t){const e=bt(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function wi(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function Ea(t){return so(t)?t:null}function ud(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function pd(t){if(!t)return null;try{const e=JSON.parse(t);if(!so(e))return null;const n=bt(e.id),s=bt(e.source_surface),o=bt(e.source_label),i=bt(e.summary),r=bt(e.created_at);return!n||s!=="mission"||!o||!i||!r?null:{id:n,source_surface:"mission",source_label:o,action_type:bt(e.action_type),target_type:bt(e.target_type),target_id:bt(e.target_id),focus_kind:bt(e.focus_kind),summary:i,payload_preview:bt(e.payload_preview),suggested_payload:Ea(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:r}}catch{return null}}function ao(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=dd}function md(){const t=wi(),e=pd((t==null?void 0:t.getItem(ss))??null);return e?ao(e)?e:(t==null||t.removeItem(ss),null):null}const Ii=f(md());function vd(t){const e=t&&ao(t)?t:null;Ii.value=e;const n=wi();if(!n)return;if(!e){n.removeItem(ss);return}const s=ud(e);s&&n.setItem(ss,s)}function Ti(t){if(!t)return null;const e=Ea(t.suggested_payload);if(e)return e;if(so(t.preview)){const n=Ea(t.preview.payload);if(n)return n}return null}function Ri(t){if(!t)return null;const e=Kt(t.message);if(e)return e;const n=Kt(t.task_title)??Kt(t.title),s=Kt(t.task_description)??Kt(t.description),o=Kt(t.reason),i=Kt(t.priority)??Kt(t.task_priority);return n&&s?`${n} · ${s}`:n&&i?`${n} · P${i}`:n||s||o||null}function Ni(t,e,n,s,o,i){return["mission",t,e??"action",n??"target",s??"room",o??"focus",i].join(":")}function Le(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),o=Ti(t),i=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,r=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,c=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,d=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:Ni(n,(t==null?void 0:t.action_type)??null,i,r,c,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:i,target_id:r,focus_kind:c,summary:d,payload_preview:Ri(o),suggested_payload:o,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function _d(t,e){return e.source==="mission"&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)}function bn(t){const{params:e}=t;if(e.source!=="mission")return null;const n=Ii.value;if(n&&ao(n)&&_d(n,e))return n;const s=new Date().toISOString();return{id:Ni("상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,s),source_surface:"mission",source_label:"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,summary:e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function fd(t){return{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function Pi(t){const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.target_type==="room"?"summary":"swarm"}function gd(t){return{source:"mission",surface:Pi(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function oo(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function Ps(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";default:return(t==null?void 0:t.trim())||"추천 액션"}}function $d(t){switch(t){case"summary":return"요약";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}function vt(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}function za(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:`${Math.round(n/3600)}h 전`}function Di(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function Oa(t){return Ri(Ti(t))}function Li(t){return oo(t?Le(t,null,"상황판 추천 액션"):null)}function Ds(t,e=Le()){vd(e),$t(t,t==="intervene"?fd(e):gd(e))}function hd(t){Ds("intervene",Le(null,t,"상황판 incident"))}function yd(t){Ds("command",Le(null,t,"상황판 incident"))}function Mi(t,e,n="상황판 추천 액션"){Ds("intervene",Le(t,e,n))}function Ei(t,e,n="상황판 추천 액션"){Ds("command",Le(t,e,n))}function bd({cluster:t,project:e,room:n,generatedAt:s}){return a`
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
        <strong>${s?za(s):"fresh"}</strong>
      </div>
    </div>
  `}function ve({label:t,value:e,detail:n,tone:s}){return a`
    <article class="mission-stat-card ${vt(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function kd({item:t}){return a`
    <article class="mission-incident-card ${vt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${vt(t.severity)}">${t.severity}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <strong>${t.summary}</strong>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>hd(t)}>이 이슈로 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>yd(t)}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `}function xd({action:t,incident:e}){const n=Oa(t);return a`
    <article class="mission-action-card ${vt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${vt(t.severity)}">${Ps(t.action_type)}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.reason}</p>
      <div class="mission-action-detail">
        <span>${Di(t)}</span>
        <span>${Li(t)}</span>
      </div>
      ${n?a`<div class="mission-action-preview">${n}</div>`:null}
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Mi(t,e,"상황판 추천 액션")}>이 액션으로 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Ei(t,e,"상황판 추천 액션")}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `}function Sd({session:t}){return a`
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
  `}function Co(){var r,c,d;const t=Ci.value;if(Ma.value&&!t)return a`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(ns.value&&!t)return a`<div class="empty-state error">${ns.value}</div>`;if(!t)return a`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;const e=t.summary,n=t.incidents[0]??e.top_attention??null,s=t.recommended_actions[0]??e.top_action??null,o=t.command_focus.session_cards.slice(0,3),i=t.operator_targets.keepers.slice(0,4);return a`
    <section class="dashboard-panel mission-view">
      <${ht} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 문제, 다음 액션, 운영 포커스를 한 번에 보는 운영 랜딩입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${vt(e.room_health)}">${e.room_health??"ok"}</span>
          <span class="command-chip">${e.project??"room"}${e.current_room?` · ${e.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?za(t.generated_at):"fresh"}</span>
        </div>
      </div>

      <${bd}
        cluster=${e.cluster}
        project=${e.project}
        room=${e.current_room}
        generatedAt=${t.generated_at}
      />

      <div class="mission-stat-grid">
        <${ve} label="활성 에이전트" value=${e.active_agents??0} detail="실시간 응답 가능한 agent 수" tone=${e.active_agents&&e.active_agents>0?"ok":"warn"} />
        <${ve} label="Keeper 압력" value=${e.keeper_pressure??0} detail="stale / hot keeper 수" tone=${(e.keeper_pressure??0)>0?"warn":"ok"} />
        <${ve} label="활성 작전" value=${e.active_operations??0} detail="command plane active operation" tone=${(e.active_operations??0)>0?"ok":"warn"} />
        <${ve} label="승인 대기" value=${e.pending_approvals??0} detail="사람 확인이 필요한 decision" tone=${(e.pending_approvals??0)>0?"warn":"ok"} />
        <${ve} label="우선 Incident" value=${e.incident_count??t.incidents.length} detail="지금 우선순위로 볼 attention item" tone=${(n==null?void 0:n.severity)??"ok"} />
        <${ve} label="다음 액션" value=${e.recommended_action_count??t.recommended_actions.length} detail="digest 기준 추천 액션 수" tone=${(s==null?void 0:s.severity)??"ok"} />
      </div>

      <div class="mission-primary-grid">
        <${w} title="지금 가장 먼저 볼 것" class="mission-hero-card" semanticId="mission.hero">
          ${n?a`
                <div class="mission-priority-block ${vt(n.severity)}">
                  <div class="mission-card-head">
                    <span class="command-chip ${vt(n.severity)}">${n.kind}</span>
                    <span class="mission-card-target">${n.target_type}${n.target_id?` · ${n.target_id}`:""}</span>
                  </div>
                  <strong>${n.summary}</strong>
                </div>
              `:a`<div class="empty-state">우선 incident가 없습니다.</div>`}
          ${s?a`
                <div class="mission-action-highlight">
                  <div class="mission-card-head">
                    <span class="command-chip ${vt(s.severity)}">${Ps(s.action_type)}</span>
                    <span class="mission-card-target">${s.target_type}${s.target_id?` · ${s.target_id}`:""}</span>
                  </div>
                  <p>${s.reason}</p>
                  <div class="mission-action-detail">
                    <span>${Di(s)}</span>
                    <span>${Li(s)}</span>
                  </div>
                  ${Oa(s)?a`<div class="mission-action-preview">${Oa(s)}</div>`:null}
                  <div class="mission-card-actions">
                    <button class="control-btn ghost" onClick=${()=>Mi(s,n,"상황판 hero 액션")}>이 액션으로 개입 열기</button>
                    <button class="control-btn ghost" onClick=${()=>Ei(s,n,"상황판 hero 액션")}>이 이슈의 원인 보기</button>
                  </div>
                </div>
              `:null}
        <//>

        <${w} title="운영 포커스" class="mission-focus-card" semanticId="mission.focus">
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
              <strong>${((c=t.command_focus.swarm_overview)==null?void 0:c.moving_lanes)??0}</strong>
            </div>
            <div class="mission-focus-item">
              <span>마지막 이동</span>
              <strong>${za((d=t.command_focus.swarm_overview)==null?void 0:d.last_movement_at)}</strong>
            </div>
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>$t("command")}>지휘면 열기</button>
            <button class="control-btn ghost" onClick=${()=>$t("command",{surface:"swarm"})}>스웜 상세</button>
          </div>
        <//>
      </div>

      <div class="mission-content-grid">
        <${w} title="우선 Incident" class="mission-list-card" semanticId="mission.incidents">
          <div class="mission-list-stack">
            ${t.incidents.length>0?t.incidents.slice(0,5).map(m=>a`<${kd} item=${m} />`):a`<div class="empty-state">attention item이 없습니다.</div>`}
          </div>
        <//>

        <${w} title="추천 액션" class="mission-list-card" semanticId="mission.actions">
          <div class="mission-list-stack">
            ${t.recommended_actions.length>0?t.recommended_actions.slice(0,4).map(m=>a`<${xd} action=${m} />`):a`<div class="empty-state">추천 액션이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-content-grid">
        <${w} title="집중 세션" class="mission-list-card" semanticId="mission.sessions">
          <div class="mission-list-stack">
            ${o.length>0?o.map(m=>a`<${Sd} session=${m} />`):a`<div class="empty-state">지금 강조할 session이 없습니다.</div>`}
          </div>
        <//>

        <${w} title="바로 개입할 대상" class="mission-list-card" semanticId="mission.targets">
          <div class="mission-target-grid">
            <div class="mission-target-block">
              <span class="mission-target-title">Keepers</span>
              ${i.length>0?i.map(m=>a`<div class="mission-target-row"><strong>${m.name}</strong><span class="command-chip ${vt(m.status)}">${m.status??"unknown"}</span></div>`):a`<div class="mission-target-empty">keeper 대상이 없습니다.</div>`}
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
  `}const Ad="modulepreload",Cd=function(t){return"/dashboard/"+t},wo={},wd=function(e,n,s){let o=Promise.resolve();if(n&&n.length>0){let r=function(m){return Promise.all(m.map(p=>Promise.resolve(p).then(u=>({status:"fulfilled",value:u}),u=>({status:"rejected",reason:u}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),d=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));o=r(n.map(m=>{if(m=Cd(m),m in wo)return;wo[m]=!0;const p=m.endsWith(".css"),u=p?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${m}"]${u}`))return;const g=document.createElement("link");if(g.rel=p?"stylesheet":Ad,p||(g.as="script"),g.crossOrigin="",g.href=m,d&&g.setAttribute("nonce",d),document.head.appendChild(g),p)return new Promise(($,x)=>{g.addEventListener("load",$),g.addEventListener("error",()=>x(new Error(`Unable to preload CSS for ${m}`)))})}))}function i(r){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=r,window.dispatchEvent(c),!c.defaultPrevented)throw r}return o.then(r=>{for(const c of r||[])c.status==="rejected"&&i(c.reason);return e().catch(i)})},io=f(null),Nt=f(null),as=f(!1),os=f(!1),is=f(null),rs=f(null),ja=f(null),ls=f(null),_t=f("operations"),kn=f(null),Fa=f(!1),cs=f(null),Ls=f(null),qa=f(!1),ds=f(null),Ms=f(null),Ka=f(!1),us=f(null),sn=f(null),ps=f(!1),an=f(null),xe=f(null);let He=null;function ro(t){return t!=="summary"&&t!=="swarm"}function S(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function l(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function _(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Y(t){return typeof t=="boolean"?t:void 0}function dt(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function zi(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((o,i)=>{t.has(i)||t.set(i,o)}),t}function Id(){const e=zi().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Td(){const e=zi().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Rd(t){if(S(t))return{policy_class:l(t.policy_class),approval_class:l(t.approval_class),tool_allowlist:dt(t.tool_allowlist),model_allowlist:dt(t.model_allowlist),requires_human_for:dt(t.requires_human_for),autonomy_level:l(t.autonomy_level),escalation_timeout_sec:_(t.escalation_timeout_sec),kill_switch:Y(t.kill_switch),frozen:Y(t.frozen)}}function Nd(t){if(S(t))return{headcount_cap:_(t.headcount_cap),active_operation_cap:_(t.active_operation_cap),max_cost_usd:_(t.max_cost_usd),max_tokens:_(t.max_tokens)}}function lo(t){if(!S(t))return null;const e=l(t.unit_id),n=l(t.label),s=l(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:l(t.parent_unit_id)??null,leader_id:l(t.leader_id)??null,roster:dt(t.roster),capability_profile:dt(t.capability_profile),source:l(t.source),created_at:l(t.created_at),updated_at:l(t.updated_at),policy:Rd(t.policy),budget:Nd(t.budget)}}function Oi(t){if(!S(t))return null;const e=lo(t.unit);return e?{unit:e,leader_status:l(t.leader_status),roster_total:_(t.roster_total),roster_live:_(t.roster_live),active_operation_count:_(t.active_operation_count),health:l(t.health),reasons:dt(t.reasons),children:Array.isArray(t.children)?t.children.map(Oi).filter(n=>n!==null):[]}:null}function Pd(t){if(S(t))return{total_units:_(t.total_units),company_count:_(t.company_count),platoon_count:_(t.platoon_count),squad_count:_(t.squad_count),leaf_agent_unit_count:_(t.leaf_agent_unit_count),live_agent_count:_(t.live_agent_count),managed_unit_count:_(t.managed_unit_count),active_operation_count:_(t.active_operation_count)}}function ji(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),source:l(e.source),summary:Pd(e.summary),units:Array.isArray(e.units)?e.units.map(Oi).filter(n=>n!==null):[]}}function Dd(t){if(!S(t))return null;const e=l(t.kind),n=l(t.status);return!e||!n?null:{kind:e,chain_id:l(t.chain_id)??null,goal:l(t.goal)??null,run_id:l(t.run_id)??null,status:n,viewer_path:l(t.viewer_path)??null,last_sync_at:l(t.last_sync_at)??null}}function Es(t){if(!S(t))return null;const e=l(t.operation_id),n=l(t.objective),s=l(t.assigned_unit_id),o=l(t.trace_id),i=l(t.status);return!e||!n||!s||!o||!i?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:l(t.autonomy_level),policy_class:l(t.policy_class),budget_class:l(t.budget_class),detachment_session_id:l(t.detachment_session_id)??null,trace_id:o,checkpoint_ref:l(t.checkpoint_ref)??null,active_goal_ids:dt(t.active_goal_ids),note:l(t.note)??null,created_by:l(t.created_by),source:l(t.source),status:i,chain:Dd(t.chain),created_at:l(t.created_at),updated_at:l(t.updated_at)}}function Ld(t){if(!S(t))return null;const e=Es(t.operation);return e?{operation:e,assigned_unit_label:l(t.assigned_unit_label)}:null}function qe(t){if(S(t))return{tone:l(t.tone),pending_ops:_(t.pending_ops),blocked_ops:_(t.blocked_ops),in_flight_ops:_(t.in_flight_ops),pipeline_stalls:_(t.pipeline_stalls),bus_traffic:_(t.bus_traffic),l1_hit_rate:_(t.l1_hit_rate),invalidation_count:_(t.invalidation_count),current_pending:_(t.current_pending),current_in_flight:_(t.current_in_flight),cdb_wakeups:_(t.cdb_wakeups),total_stolen:_(t.total_stolen),avg_best_score:_(t.avg_best_score),avg_candidate_count:_(t.avg_candidate_count),best_first_operations:_(t.best_first_operations),active_sessions:_(t.active_sessions),commit_rate:_(t.commit_rate),total_speculations:_(t.total_speculations)}}function Md(t){if(!S(t))return;const e=S(t.pipeline)?t.pipeline:void 0,n=S(t.cache)?t.cache:void 0,s=S(t.ooo)?t.ooo:void 0,o=S(t.speculative)?t.speculative:void 0,i=S(t.search_fabric)?t.search_fabric:void 0,r=S(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:_(e.total_ops),completed_ops:_(e.completed_ops),stalled_cycles:_(e.stalled_cycles),hazards_detected:_(e.hazards_detected),forwarding_used:_(e.forwarding_used),pipeline_flushes:_(e.pipeline_flushes),ipc:_(e.ipc)}:void 0,cache:n?{total_reads:_(n.total_reads),total_writes:_(n.total_writes),l1_hit_rate:_(n.l1_hit_rate),invalidation_count:_(n.invalidation_count),writeback_count:_(n.writeback_count),bus_traffic:_(n.bus_traffic)}:void 0,ooo:s?{agent_count:_(s.agent_count),total_added:_(s.total_added),total_issued:_(s.total_issued),total_completed:_(s.total_completed),total_stolen:_(s.total_stolen),cdb_wakeups:_(s.cdb_wakeups),stall_cycles:_(s.stall_cycles),global_cdb_events:_(s.global_cdb_events),current_pending:_(s.current_pending),current_in_flight:_(s.current_in_flight)}:void 0,speculative:o?{total_speculations:_(o.total_speculations),total_commits:_(o.total_commits),total_aborts:_(o.total_aborts),commit_rate:_(o.commit_rate),total_fast_calls:_(o.total_fast_calls),total_cost_usd:_(o.total_cost_usd),active_sessions:_(o.active_sessions)}:void 0,search_fabric:i?{total_operations:_(i.total_operations),best_first_operations:_(i.best_first_operations),legacy_operations:_(i.legacy_operations),blocked_operations:_(i.blocked_operations),ready_operations:_(i.ready_operations),research_pipeline_operations:_(i.research_pipeline_operations),avg_candidate_count:_(i.avg_candidate_count),avg_best_score:_(i.avg_best_score),top_stage:l(i.top_stage)??null}:void 0,signals:r?{issue_pressure:qe(r.issue_pressure),cache_contention:qe(r.cache_contention),scheduler_efficiency:qe(r.scheduler_efficiency),routing_confidence:qe(r.routing_confidence),speculative_posture:qe(r.speculative_posture)}:void 0}}function Fi(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:_(n.total),active:_(n.active),paused:_(n.paused),managed:_(n.managed),projected:_(n.projected)}:void 0,microarch:Md(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(Ld).filter(s=>s!==null):[]}}function qi(t){if(!S(t))return null;const e=l(t.detachment_id),n=l(t.operation_id),s=l(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:l(t.leader_id)??null,roster:dt(t.roster),session_id:l(t.session_id)??null,checkpoint_ref:l(t.checkpoint_ref)??null,runtime_kind:l(t.runtime_kind)??null,runtime_ref:l(t.runtime_ref)??null,source:l(t.source),status:l(t.status),last_event_at:l(t.last_event_at)??null,last_progress_at:l(t.last_progress_at)??null,heartbeat_deadline:l(t.heartbeat_deadline)??null,created_at:l(t.created_at),updated_at:l(t.updated_at)}}function Ed(t){if(!S(t))return null;const e=qi(t.detachment);return e?{detachment:e,assigned_unit_label:l(t.assigned_unit_label),operation:Es(t.operation)}:null}function Ki(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:_(n.total),active:_(n.active),projected:_(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(Ed).filter(s=>s!==null):[]}}function zd(t){if(!S(t))return null;const e=l(t.decision_id),n=l(t.trace_id),s=l(t.requested_action),o=l(t.scope_type),i=l(t.scope_id);return!e||!n||!s||!o||!i?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:o,scope_id:i,operation_id:l(t.operation_id)??null,target_unit_id:l(t.target_unit_id)??null,requested_by:l(t.requested_by),status:l(t.status),reason:l(t.reason)??null,source:l(t.source),detail:t.detail,created_at:l(t.created_at),decided_at:l(t.decided_at)??null,expires_at:l(t.expires_at)??null}}function Ui(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:_(n.total),pending:_(n.pending),approved:_(n.approved),denied:_(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(zd).filter(s=>s!==null):[]}}function Od(t){if(!S(t))return null;const e=lo(t.unit);return e?{unit:e,roster_total:_(t.roster_total),roster_live:_(t.roster_live),headcount_cap:_(t.headcount_cap),active_operations:_(t.active_operations),active_operation_cap:_(t.active_operation_cap),utilization:_(t.utilization)}:null}function jd(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(Od).filter(n=>n!==null):[]}}function Fd(t){if(!S(t))return null;const e=l(t.alert_id);return e?{alert_id:e,severity:l(t.severity),kind:l(t.kind),scope_type:l(t.scope_type),scope_id:l(t.scope_id),title:l(t.title),detail:l(t.detail),timestamp:l(t.timestamp)}:null}function Hi(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:_(n.total),bad:_(n.bad),warn:_(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(Fd).filter(s=>s!==null):[]}}function Wi(t){if(!S(t))return null;const e=l(t.event_id),n=l(t.trace_id),s=l(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:l(t.operation_id)??null,unit_id:l(t.unit_id)??null,actor:l(t.actor)??null,source:l(t.source),timestamp:l(t.timestamp),detail:t.detail}}function qd(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),events:Array.isArray(e.events)?e.events.map(Wi).filter(n=>n!==null):[]}}function Kd(t){if(!S(t))return null;const e=l(t.code),n=l(t.severity),s=l(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function Ud(t){if(!S(t))return null;const e=l(t.lane_id),n=l(t.label),s=l(t.kind),o=l(t.phase),i=l(t.motion_state),r=l(t.source_of_truth),c=l(t.movement_reason),d=l(t.current_step);if(!e||!n||!s||!o||!i||!r||!c||!d)return null;const m=S(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:Y(t.present)??!1,phase:o,motion_state:i,source_of_truth:r,last_movement_at:l(t.last_movement_at)??null,movement_reason:c,current_step:d,blockers:dt(t.blockers),counts:{operations:_(m.operations),detachments:_(m.detachments),workers:_(m.workers),approvals:_(m.approvals),alerts:_(m.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(Kd).filter(p=>p!==null):[]}}function Hd(t){if(!S(t))return null;const e=l(t.event_id),n=l(t.lane_id),s=l(t.kind),o=l(t.timestamp),i=l(t.title),r=l(t.detail),c=l(t.tone),d=l(t.source);return!e||!n||!s||!o||!i||!r||!c||!d?null:{event_id:e,lane_id:n,kind:s,timestamp:o,title:i,detail:r,tone:c,source:d}}function Wd(t){if(!S(t))return null;const e=l(t.code),n=l(t.severity),s=l(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,lane_ids:dt(t.lane_ids),count:_(t.count)??0}}function Bi(t){if(!S(t))return;const e=S(t.overview)?t.overview:{},n=S(t.gaps)?t.gaps:{},s=S(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:l(t.generated_at),overview:{active_lanes:_(e.active_lanes),moving_lanes:_(e.moving_lanes),stalled_lanes:_(e.stalled_lanes),projected_lanes:_(e.projected_lanes),last_movement_at:l(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(Ud).filter(o=>o!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(Hd).filter(o=>o!==null):[],gaps:{count:_(n.count),items:Array.isArray(n.items)?n.items.map(Wd).filter(o=>o!==null):[]},recommended_next_action:s?{tool:l(s.tool)??"masc_operator_snapshot",label:l(s.label)??"Observe operator state",reason:l(s.reason)??"",lane_id:l(s.lane_id)??null}:void 0}}function Bd(t){if(!S(t))return;const e=S(t.workers)?t.workers:{},n=Y(t.pass);return{status:l(t.status)??"missing",source:l(t.source)??"none",run_id:l(t.run_id)??null,captured_at:l(t.captured_at)??null,...n!==void 0?{pass:n}:{},..._(t.peak_hot_slots)!=null?{peak_hot_slots:_(t.peak_hot_slots)}:{},..._(t.ctx_per_slot)!=null?{ctx_per_slot:_(t.ctx_per_slot)}:{},workers:{expected:_(e.expected),joined:_(e.joined),current_task_bound:_(e.current_task_bound),fresh_heartbeats:_(e.fresh_heartbeats),done:_(e.done),final:_(e.final)},artifact_ref:l(t.artifact_ref)??null,missing_reason:l(t.missing_reason)??null}}function Gd(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),topology:ji(e.topology),operations:Fi(e.operations),detachments:Ki(e.detachments),alerts:Hi(e.alerts),decisions:Ui(e.decisions),capacity:jd(e.capacity),traces:qd(e.traces),swarm_status:Bi(e.swarm_status)}}function Jd(t){const e=S(t)?t:{},n=ji(e.topology),s=Fi(e.operations),o=Ki(e.detachments),i=Hi(e.alerts),r=Ui(e.decisions);return{version:l(e.version),generated_at:l(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:o.version,generated_at:o.generated_at,summary:o.summary},alerts:{version:i.version,generated_at:i.generated_at,summary:i.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:Bi(e.swarm_status),swarm_proof:Bd(e.swarm_proof)}}function Vd(t){return S(t)?{chain_id:l(t.chain_id)??null,started_at:_(t.started_at)??null,progress:_(t.progress)??null,elapsed_sec:_(t.elapsed_sec)??null}:null}function Gi(t){if(!S(t))return null;const e=l(t.event);return e?{event:e,chain_id:l(t.chain_id)??null,timestamp:l(t.timestamp)??null,duration_ms:_(t.duration_ms)??null,message:l(t.message)??null,tokens:_(t.tokens)??null}:null}function Yd(t){if(!S(t))return null;const e=Es(t.operation);return e?{operation:e,runtime:Vd(t.runtime),history:Gi(t.history),mermaid:l(t.mermaid)??null,preview_run:Ji(t.preview_run)}:null}function Xd(t){const e=S(t)?t:{};return{status:l(e.status)??"disconnected",base_url:l(e.base_url)??null,message:l(e.message)??null}}function Qd(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),connection:Xd(e.connection),summary:n?{linked_operations:_(n.linked_operations),active_chains:_(n.active_chains),running_operations:_(n.running_operations),recent_failures:_(n.recent_failures),last_history_event_at:l(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(Yd).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(Gi).filter(s=>s!==null):[]}}function Zd(t){if(!S(t))return null;const e=l(t.id);return e?{id:e,type:l(t.type),status:l(t.status),duration_ms:_(t.duration_ms)??null,error:l(t.error)??null}:null}function Ji(t){if(!S(t))return null;const e=l(t.run_id),n=l(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:_(t.duration_ms),success:Y(t.success),mermaid:l(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(Zd).filter(s=>s!==null):[]}:null}function tu(t){const e=S(t)?t:{};return{run:Ji(e.run)}}function eu(t){if(!S(t))return null;const e=l(t.title),n=l(t.path);return!e||!n?null:{title:e,path:n}}function nu(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function su(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.tool),o=l(t.summary);return!e||!n||!s||!o?null:{id:e,title:n,tool:s,summary:o,success_signals:dt(t.success_signals),pitfalls:dt(t.pitfalls)}}function au(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.summary),o=l(t.when_to_use);return!e||!n||!s||!o?null:{id:e,title:n,summary:s,when_to_use:o,steps:Array.isArray(t.steps)?t.steps.map(su).filter(i=>i!==null):[]}}function ou(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:dt(t.tools)}}function iu(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.symptom),o=l(t.why),i=l(t.fix_tool),r=l(t.fix_summary);return!e||!n||!s||!o||!i||!r?null:{id:e,title:n,symptom:s,why:o,fix_tool:i,fix_summary:r}}function ru(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.path_id),o=l(t.transport);return!e||!n||!s||!o?null:{id:e,title:n,path_id:s,transport:o,request:t.request,response:t.response,notes:dt(t.notes)}}function lu(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(eu).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(nu).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(au).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(ou).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(iu).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(ru).filter(n=>n!==null):[]}}function cu(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.status),o=l(t.detail),i=l(t.next_tool);return!e||!n||!s||!o||!i?null:{id:e,title:n,status:s,detail:o,next_tool:i}}function du(t){if(!S(t))return null;const e=l(t.code),n=l(t.severity),s=l(t.title),o=l(t.detail),i=l(t.next_tool);return!e||!n||!s||!o||!i?null:{code:e,severity:n,title:s,detail:o,next_tool:i}}function uu(t){if(!S(t))return null;const e=l(t.from),n=l(t.content),s=l(t.timestamp),o=_(t.seq);return!e||!n||!s||o==null?null:{seq:o,from:e,content:n,timestamp:s}}function pu(t){if(!S(t))return null;const e=l(t.name),n=l(t.role),s=l(t.lane),o=l(t.status),i=l(t.claim_marker),r=l(t.done_marker),c=l(t.final_marker);if(!e||!n||!s||!o||!i||!r||!c)return null;const d=(()=>{if(!S(t.last_message))return null;const m=_(t.last_message.seq),p=l(t.last_message.content),u=l(t.last_message.timestamp);return m==null||!p||!u?null:{seq:m,content:p,timestamp:u}})();return{name:e,role:n,lane:s,joined:Y(t.joined)??!1,live_presence:Y(t.live_presence)??!1,completed:Y(t.completed)??!1,status:o,current_task:l(t.current_task)??null,bound_task_id:l(t.bound_task_id)??null,bound_task_title:l(t.bound_task_title)??null,bound_task_status:l(t.bound_task_status)??null,current_task_matches_run:Y(t.current_task_matches_run)??!1,squad_member:Y(t.squad_member)??!1,detachment_member:Y(t.detachment_member)??!1,last_seen:l(t.last_seen)??null,heartbeat_age_sec:_(t.heartbeat_age_sec)??null,heartbeat_fresh:Y(t.heartbeat_fresh)??!1,claim_marker_seen:Y(t.claim_marker_seen)??!1,done_marker_seen:Y(t.done_marker_seen)??!1,final_marker_seen:Y(t.final_marker_seen)??!1,claim_marker:i,done_marker:r,final_marker:c,last_message:d}}function mu(t){if(!S(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!S(n))return null;const s=l(n.timestamp),o=_(n.active_slots);if(!s||o==null)return null;const i=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:s,active_slots:o,active_slot_ids:i}}).filter(n=>n!==null):[];return{slot_url:l(t.slot_url)??null,provider_base_url:l(t.provider_base_url)??null,provider_reachable:Y(t.provider_reachable)??null,provider_status_code:_(t.provider_status_code)??null,provider_model_id:l(t.provider_model_id)??null,actual_model_id:l(t.actual_model_id)??null,expected_slots:_(t.expected_slots),actual_slots:_(t.actual_slots),expected_ctx:_(t.expected_ctx),actual_ctx:_(t.actual_ctx),slot_reachable:Y(t.slot_reachable)??null,slot_status_code:_(t.slot_status_code)??null,runtime_blocker:l(t.runtime_blocker)??null,detail:l(t.detail)??null,checked_at:l(t.checked_at)??null,total_slots:_(t.total_slots),ctx_per_slot:_(t.ctx_per_slot),active_slots_now:_(t.active_slots_now),peak_active_slots:_(t.peak_active_slots),sample_count:_(t.sample_count),last_sample_at:l(t.last_sample_at)??null,timeline:e}}function vu(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),run_id:l(e.run_id),room_id:l(e.room_id),operation_id:l(e.operation_id)??null,recommended_next_tool:l(e.recommended_next_tool),summary:n?{expected_workers:_(n.expected_workers),joined_workers:_(n.joined_workers),live_workers:_(n.live_workers),squad_roster_size:_(n.squad_roster_size),detachment_roster_size:_(n.detachment_roster_size),current_task_bound:_(n.current_task_bound),fresh_heartbeats:_(n.fresh_heartbeats),claim_markers_seen:_(n.claim_markers_seen),done_markers_seen:_(n.done_markers_seen),final_markers_seen:_(n.final_markers_seen),completed_workers:_(n.completed_workers),peak_hot_slots:_(n.peak_hot_slots),hot_window_ok:Y(n.hot_window_ok),pass_hot_concurrency:Y(n.pass_hot_concurrency),pass_end_to_end:Y(n.pass_end_to_end),pending_decisions:_(n.pending_decisions),pass:Y(n.pass)}:void 0,provider:mu(e.provider),operation:Es(e.operation),squad:lo(e.squad),detachment:qi(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(pu).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(cu).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(du).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(uu).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(Wi).filter(s=>s!==null):[],truth_notes:dt(e.truth_notes)}}function Se(t){_t.value=t,ro(t)&&_u()}async function Vi(){as.value=!0,is.value=null;try{const t=await _l();io.value=Jd(t)}catch(t){is.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{as.value=!1}}function co(t){xe.value=t}async function uo(){os.value=!0,rs.value=null;try{const t=await vl();Nt.value=Gd(t)}catch(t){rs.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{os.value=!1}}async function _u(){Nt.value||os.value||await uo()}async function de(){await Vi(),ro(_t.value)&&await uo()}async function Bt(){var t;Ka.value=!0,us.value=null;try{const e=await fl(),n=Qd(e);Ms.value=n;const s=xe.value;n.operations.length===0?xe.value=null:(!s||!n.operations.some(o=>o.operation.operation_id===s))&&(xe.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){us.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{Ka.value=!1}}function fu(){He=null,sn.value=null,ps.value=!1,an.value=null}async function gu(t){He=t,ps.value=!0,an.value=null;try{const e=await gl(t);if(He!==t)return;sn.value=tu(e)}catch(e){if(He!==t)return;sn.value=null,an.value=e instanceof Error?e.message:"Failed to load chain run"}finally{He===t&&(ps.value=!1)}}async function $u(){Fa.value=!0,cs.value=null;try{const t=await $l();kn.value=lu(t)}catch(t){cs.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Fa.value=!1}}async function Lt(t=Id(),e=Td()){qa.value=!0,ds.value=null;try{const n=await hl(t,e);Ls.value=vu(n)}catch(n){ds.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{qa.value=!1}}async function Zt(t,e,n){ja.value=t,ls.value=null;try{await yl(e,n),await Vi(),(Nt.value||ro(_t.value))&&await uo(),await Lt(),await Bt()}catch(s){throw ls.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{ja.value=null}}function hu(t){return Zt(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function yu(t){return Zt(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function bu(t){return Zt(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function ku(t={}){return Zt("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function xu(t){return Zt(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Su(t){return Zt(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Au(t,e){return Zt(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Cu(t,e){return Zt(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}Jc(()=>{de(),Bt(),(_t.value==="swarm"||Ls.value!==null)&&Lt()});function wu(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function tt(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function Iu(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Tu(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function O(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let Io=!1,Ru=0,Ws=null;async function Nu(){Ws||(Ws=wd(()=>import("./mermaid.core-C5GjEMwI.js").then(e=>e.bE),[]).then(e=>e.default));const t=await Ws;return Io||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),Io=!0),t}function Gt(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function zs(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function Pu(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function xn(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function oe(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:xn(t/e*100)}function Du(t,e){const n=xn(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function Yi(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const Lu=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],Xi=[{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],Mu=Xi.map(t=>t.id),Eu=["chain_start","node_start","node_complete","chain_complete","chain_error"],zu={operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function To(t){return!!t&&Mu.includes(t)}function Ou(){const t=M.value.params;return t.source!=="mission"?{}:{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function ju(t){const e=Ou();if(t==="operations")return e;if(t==="chains"){const n=xe.value;return n?{...e,surface:t,operation:n}:{...e,surface:t}}return{...e,surface:t}}function Fu(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function qu(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function at(t){return ja.value===t}function Os(){return io.value}function Ku(t){var o,i,r,c,d,m,p;const e=io.value,n=Ls.value,s=Ms.value;switch(t){case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((o=e==null?void 0:e.operations.summary)==null?void 0:o.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((r=(i=e==null?void 0:e.swarm_status)==null?void 0:i.recommended_next_action)==null?void 0:r.tool)??"masc_observe_traces",reason:((d=(c=e==null?void 0:e.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:d.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(p=(m=s==null?void 0:s.operations[0])==null?void 0:m.preview_run)!=null&&p.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function Uu(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function Hu(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function Wu(){const t=bn(M.value);return t?a`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${Ps(t.action_type)}</span>
        <span class="command-chip">${oo(t)}</span>
        <span class="command-chip">${$d(M.value.params.surface??"operations")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?a`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function Bu(){const t=_t.value,e=zu[t],n=Ku(t);return a`
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
  `}function In({label:t,value:e,subtext:n,percent:s,color:o}){return a`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${Du(s,o)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(xn(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function Tn({label:t,value:e,detail:n,percent:s,tone:o}){return a`
    <article class="command-signal-rail ${O(o)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${O(o)}" style=${`width: ${Math.max(8,Math.round(xn(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function Gu(){var F,Z,W,et;const t=Os(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,o=t==null?void 0:t.decisions.summary,i=t==null?void 0:t.alerts.summary,r=(F=t==null?void 0:t.swarm_status)==null?void 0:F.overview,c=t==null?void 0:t.swarm_proof,d=t==null?void 0:t.operations.microarch,m=(e==null?void 0:e.managed_unit_count)??0,p=(e==null?void 0:e.total_units)??0,u=(n==null?void 0:n.active)??0,g=(s==null?void 0:s.active)??0,$=(r==null?void 0:r.moving_lanes)??0,x=(r==null?void 0:r.active_lanes)??0,A=(c==null?void 0:c.workers.done)??0,I=(c==null?void 0:c.workers.expected)??0,D=(i==null?void 0:i.bad)??0,q=(i==null?void 0:i.warn)??0,L=(o==null?void 0:o.pending)??0,T=(o==null?void 0:o.total)??0,N=u+g,V=((Z=d==null?void 0:d.cache)==null?void 0:Z.l1_hit_rate)??((et=(W=d==null?void 0:d.signals)==null?void 0:W.cache_contention)==null?void 0:et.l1_hit_rate)??0,B=u>0||g>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",v=u>0||$>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return a`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${B}</h3>
        <p>${v}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${O(u>0?"ok":"warn")}">활성 작전 ${u}</span>
          <span class="command-chip ${O($>0?"ok":(x>0,"warn"))}">이동 레인 ${$}/${Math.max(x,$)}</span>
          <span class="command-chip ${O(D>0?"bad":q>0?"warn":"ok")}">치명 알림 ${D}</span>
          <span class="command-chip ${O(L>0?"warn":"ok")}">승인 대기 ${L}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${In}
          label="관리 단위 범위"
          value=${`${m}/${Math.max(p,m)}`}
          subtext=${p>0?`${p-m}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${oe(m,Math.max(p,m))}
          color="#67e8f9"
        />
        <${In}
          label="실행 열도"
          value=${String(N)}
          subtext=${`${u}개 작전 + ${g}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${oe(N,Math.max(m,N||1))}
          color="#4ade80"
        />
        <${In}
          label="스웜 이동감"
          value=${`${$}/${Math.max(x,$)}`}
          subtext=${r!=null&&r.last_movement_at?`마지막 이동 ${tt(r.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${oe($,Math.max(x,$||1))}
          color="#fbbf24"
        />
        <${In}
          label="증거 수집률"
          value=${`${A}/${Math.max(I,A)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${oe(A,Math.max(I,A||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${Tn}
        label="승인 대기열"
        value=${`${L}건 대기`}
        detail=${`현재 정책 창에서 ${T}개 결정을 추적 중입니다`}
        percent=${oe(L,Math.max(T,L||1))}
        tone=${L>0?"warn":"ok"}
      />
      <${Tn}
        label="알림 압력"
        value=${`${D} bad / ${q} warn`}
        detail=${D>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${oe(D*2+q,Math.max((D+q)*2,1))}
        tone=${D>0?"bad":q>0?"warn":"ok"}
      />
      <${Tn}
        label="디스패치 점유"
          value=${`${g}개 가동`}
        detail=${m>0?`${m}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${oe(g,Math.max(m,g||1))}
        tone=${g>0?"ok":"warn"}
      />
      <${Tn}
        label="캐시 신뢰도"
        value=${V?zs(V):"n/a"}
        detail=${V?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${xn((V??0)*100)}
        tone=${V>=.75?"ok":V>=.4?"warn":"bad"}
      />
    </div>
  `}function Ju(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Qi(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((o,i)=>{t.has(i)||t.set(i,o)}),t}function Vu(){const e=Qi().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Yu(){const e=Qi().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Xu(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function Qu(t){return t.status==="claimed"||t.status==="in_progress"}function Zu(t){const e=kn.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(o=>o.tool===t);if(s)return s}return null}function Bs(t){var e;return((e=kn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function tp(t){const e=kn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function Jt(t){try{await t()}catch{}}function ep(){var g,$,x,A,I;const t=Os(),e=Ms.value,n=bn(M.value),s=Uu(n),o=t==null?void 0:t.topology.summary,i=t==null?void 0:t.operations.summary,r=(g=t==null?void 0:t.swarm_status)==null?void 0:g.overview,c=t==null?void 0:t.operations.microarch,d=t==null?void 0:t.decisions.summary,m=t==null?void 0:t.alerts.summary,p=($=c==null?void 0:c.signals)==null?void 0:$.issue_pressure,u=c==null?void 0:c.cache;return a`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(o==null?void 0:o.total_units)??0}</strong><small>${(o==null?void 0:o.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(i==null?void 0:i.active)??0}</strong><small>${((x=t==null?void 0:t.detachments.summary)==null?void 0:x.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(d==null?void 0:d.pending)??0}</strong><small>${(d==null?void 0:d.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(m==null?void 0:m.bad)??0}</strong><small>${(m==null?void 0:m.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((A=e==null?void 0:e.summary)==null?void 0:A.active_chains)??0}</strong><small>${((I=e==null?void 0:e.summary)==null?void 0:I.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(r==null?void 0:r.active_lanes)??0}</strong><small>${r?`${r.stalled_lanes??0}개 정체 · ${tt(r.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(p==null?void 0:p.pending_ops)??0}</strong><small>${(u==null?void 0:u.l1_hit_rate)!=null?`${zs(u.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(p==null?void 0:p.tone)??"n/a"}</small></div>
    </div>
  `}function Zi(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function np({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const o of t){const i=o.motion_state;i in e?e[i]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return a`
    <div>
      <div class="swarm-health-bar">
        ${s.filter(o=>o.count>0).map(o=>a`
          <div class="swarm-health-seg ${o.key}" style="flex: ${o.count}"></div>
        `)}
      </div>
      <div class="swarm-health-labels">
        ${s.filter(o=>o.count>0).map(o=>a`
          <span class="swarm-health-label">
            <span class="swarm-health-swatch" style="background: ${o.color}"></span>
            ${o.count} ${o.key}
          </span>
        `)}
      </div>
    </div>
  `}function sp({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,o=Array.from({length:n});return a`
    <div class="swarm-worker-grid">
      ${o.map(()=>a`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?a`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function ap({lane:t}){const e=t.counts??{},n=Zi(t),s=e.workers??0,o=e.operations??0,i=e.detachments??0,r=o+i,c=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return a`
    <article class="swarm-lane-strip ${O(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${O(n)}">${t.phase}</span>
          <span class="command-chip ${O(n)}">${t.motion_state}</span>
          <span class="command-chip">${tt(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${O(n)}" style=${`width:${c}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${s>0?a`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${sp} total=${s} />
              </div>
            `:null}
        ${r>0?a`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">흐름</span>
                <div class="swarm-mini-bar">
                  <div class="swarm-mini-bar-fill" style="width: ${r>0?Math.round(o/r*100):0}%; background: var(--${n==="bad"?"bad":n==="warn"?"warn":"ok"})"></div>
                </div>
                <span class="swarm-worker-count">작전 ${o} · 실행체 ${i}</span>
              </div>
            `:null}
      </div>
      ${t.blockers.length>0?a`<div class="swarm-lane-blockers">막힘: ${t.blockers.join(" · ")}</div>`:null}
      ${t.hard_flags.length>0?a`
            <div class="swarm-lane-flags">
              ${t.hard_flags.map(d=>a`<span class="command-chip ${O(d.severity)}">${d.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function op({lanes:t}){const e=t.slice(0,4);return e.length===0?null:a`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=Zi(n),o=n.counts.workers??0,i=n.counts.operations??0,r=n.counts.detachments??0;return a`
          <article class="swarm-story-card ${O(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${O(s)}">${n.motion_state}</span>
              <span class="command-chip">${n.phase}</span>
            </div>
            <strong>${n.label}</strong>
            <p>${n.current_step}</p>
            <div class="swarm-story-strip">
              <span>워커 ${o}</span>
              <span>작전 ${i}</span>
              <span>실행체 ${r}</span>
            </div>
            <small>${n.movement_reason}</small>
          </article>
        `})}
    </div>
  `}function ip({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return a`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${O(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?a`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function rp({gap:t}){return a`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${O(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function lp({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return a`
    <div class="command-guide-card ${O(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${O(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?a`
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${tt(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.artifact_ref?a`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?a`<p>${t.missing_reason}</p>`:null}
          `:a`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function cp(){const t=Os(),e=bn(M.value),n=Hu(e),s=t==null?void 0:t.swarm_status,o=t==null?void 0:t.swarm_proof,i=(s==null?void 0:s.lanes.filter(u=>u.present))??[],r=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],d=s==null?void 0:s.overview,m=s==null?void 0:s.recommended_next_action,p=i.length<=1;return a`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${z} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?a`
            <${op} lanes=${i} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(d==null?void 0:d.active_lanes)??0}</strong><small>${(d==null?void 0:d.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(d==null?void 0:d.stalled_lanes)??0}</strong><small>${(d==null?void 0:d.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${tt(d==null?void 0:d.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${tt(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong><small>${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${i.length>0?a`<${np} lanes=${i} />`:null}

            <div class="command-swarm-layout ${p?"compact":""}">
              <div class="command-card-stack">
                ${i.length>0?i.map(u=>a`<${ap} lane=${u} />`):a`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${lp} proof=${o} />

                <div class="command-guide-card ${r.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${O(r.some(u=>u.severity==="bad")?"bad":r.length>0?"warn":"ok")}">${r.length}</span>
                  </div>
                  ${r.length>0?a`<div class="swarm-event-rail">${r.slice(0,4).map(u=>a`<${rp} gap=${u} />`)}</div>`:a`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?a`<div class="swarm-event-rail">${c.map(u=>a`<${ip} event=${u} />`)}</div>`:a`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:a`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function dp(){return a`
    <div class="command-surface-tabs grouped">
      ${Lu.map(t=>a`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${Xi.filter(e=>e.group===t.id).map(e=>a`
                <button
                  class="command-surface-tab ${_t.value===e.id?"active":""}"
                  onClick=${()=>{Se(e.id),$t("command",ju(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function up(){var F,Z,W,et,b,ee,Oe,Sn,An;const t=Os(),e=Nt.value,n=Ze.value,s=Ju(),o=s?pe.value.find(E=>E.name===s)??null:null,i=s?Wt.value.filter(E=>E.assignee===s&&Qu(E)):[],r=((F=t==null?void 0:t.operations.summary)==null?void 0:F.active)??0,c=((Z=t==null?void 0:t.detachments.summary)==null?void 0:Z.total)??0,d=((W=t==null?void 0:t.decisions.summary)==null?void 0:W.pending)??0,m=e==null?void 0:e.detachments.detachments.find(E=>{const ne=E.detachment.heartbeat_deadline,Cn=ne?Date.parse(ne):Number.NaN;return E.detachment.status==="stalled"||!Number.isNaN(Cn)&&Cn<=Date.now()}),p=e==null?void 0:e.alerts.alerts.find(E=>E.severity==="bad"),u=!!(n!=null&&n.room||n!=null&&n.project),g=(o==null?void 0:o.current_task)??null,$=Xu(o==null?void 0:o.last_seen),x=$!=null?$<=120:null,A=[u?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?o?i.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:Wt.value.length>0?"masc_claim":"masc_add_task"}:g?x===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${g} 이지만 heartbeat가 stale 합니다 (${$}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${g}${$!=null?` · 마지막 활동 ${$}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((et=t.topology.summary)==null?void 0:et.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:r===0?{title:"작전 준비도",tone:"warn",detail:`${((b=t.topology.summary)==null?void 0:b.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((ee=t.topology.summary)==null?void 0:ee.managed_unit_count)??0}개 관리 단위 위에서 ${r}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},d>0?{title:"디스패치 준비도",tone:"warn",detail:`${d}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:r>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:m||p?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${m?` · detachment ${m.detachment.detachment_id} 가 stalled 상태입니다`:""}${p?` · alert ${p.title??p.alert_id}`:""}${!e&&!m&&!p?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:d>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],I=u?!s||!o?"masc_join":i.length===0?Wt.value.length>0?"masc_claim":"masc_add_task":g?x===!1?"masc_heartbeat":!t||(((Oe=t.topology.summary)==null?void 0:Oe.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":d>0?"masc_policy_approve":r>0&&c===0||m||p?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",D=Zu(I),L=tp(I==="masc_set_room"?["repo-root-room"]:I==="masc_plan_set_task"?["claimed-not-current"]:I==="masc_heartbeat"?["heartbeat-stale"]:I==="masc_dispatch_tick"?["no-detachments"]:I==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),T=Bs("room_task_hygiene"),N=Bs("cpv2_benchmark"),V=Bs("supervisor_session"),B=((Sn=kn.value)==null?void 0:Sn.docs)??[],v=[T,N,V].filter(E=>E!==null);return a`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${z} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(D==null?void 0:D.title)??I}</strong>
            <span class="command-chip ok">${I}</span>
          </div>
          <p>${(D==null?void 0:D.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(An=D==null?void 0:D.success_signals)!=null&&An.length?a`<div class="command-tag-row">
                ${D.success_signals.map(E=>a`<span class="command-tag ok">${E}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${A.map(E=>a`
            <article class="command-readiness-row ${O(E.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${E.title}</strong>
                  <span class="command-chip ${O(E.tone)}">${E.tone}</span>
                </div>
                <p>${E.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${E.tool}</div>
            </article>
          `)}
        </div>

        ${L.length>0?a`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${L.length}</span>
                </div>
                <div class="command-guide-list">
                  ${L.map(E=>a`
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
        ${Fa.value?a`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:cs.value?a`<div class="empty-state error">${cs.value}</div>`:a`
                <div class="command-path-grid">
                  ${v.map(E=>a`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${E.title}</strong>
                        <span class="command-chip">${E.id}</span>
                      </div>
                      <p>${E.summary}</p>
                      <div class="command-card-sub">${E.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${E.steps.slice(0,4).map(ne=>a`
                          <div class="command-step-row">
                            <span class="command-step-tool">${ne.tool}</span>
                            <span>${ne.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${B.length>0?a`<div class="command-doc-links">
                      ${B.map(E=>a`<span class="command-tag">${E.title}: ${E.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function pp(){return a`
    <${Gu} />
    <${ep} />
    <${up} />
  `}function mp(){return os.value?a`<div class="empty-state">command-plane detail 불러오는 중…</div>`:rs.value?a`<div class="empty-state error">${rs.value}</div>`:a`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function tr({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,o=t.active_operation_count??0,i=t.unit.policy;return a`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${qu(t.unit.kind)}</span>
            <span class="command-chip ${O(t.health)}">${t.health??"ok"}</span>
            ${i!=null&&i.frozen?a`<span class="command-chip warn">frozen</span>`:null}
            ${i!=null&&i.kill_switch?a`<span class="command-chip bad">kill-switch</span>`:null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${t.unit.unit_id}</span>
            <span>Leader ${t.unit.leader_id??"unassigned"} / ${t.leader_status??"unknown"}</span>
            <span>Roster ${n}/${s}</span>
            <span>Ops ${o}</span>
            <span>Autonomy ${(i==null?void 0:i.autonomy_level)??"n/a"}</span>
          </div>
          ${t.reasons&&t.reasons.length>0?a`<div class="command-tag-row">
                ${t.reasons.map(r=>a`<span class="command-tag warn">${r}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?a`<div class="command-tree-children">
            ${t.children.map(r=>a`<${tr} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function vp({source:t}){const e=Er(null),[n,s]=Zo(null);return ct(()=>{let o=!1;const i=e.current;return i?(i.innerHTML="",s(null),(async()=>{try{const c=await Nu(),{svg:d}=await c.render(`command-chain-${++Ru}`,t);if(o||!e.current)return;e.current.innerHTML=d}catch(c){if(o)return;s(c instanceof Error?c.message:"Mermaid render failed")}})(),()=>{o=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),a`
    <div class="command-chain-graph-shell">
      ${n?a`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function _p({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,o=t.runtime;return a`
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
        ${s!=null&&s.chain_id?a`<span class="command-tag">${s.chain_id}</span>`:null}
        ${o?a`<span class="command-tag ${Gt(s==null?void 0:s.status)}">${zs(o.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${Yi(t.history)}</div>
    </button>
  `}function fp({item:t}){return a`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${Gt(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${tt(t.timestamp)}</div>
      <div class="command-card-sub">${Yi(t)}</div>
    </article>
  `}function gp({node:t}){return a`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${Gt(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?a`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function $p({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,o=`recall:${e.operation_id}`,i=e.chain,r=(i==null?void 0:i.run_id)??null;return a`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${O(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Autonomy</span><span>${e.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${e.budget_class??"standard"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Updated</span><span>${tt(e.updated_at)}</span>
      </div>
      ${i?a`
            <div class="command-tag-row">
              <span class="command-tag">${i.kind}</span>
              <span class="command-tag ${Gt(i.status)}">${i.status}</span>
              ${i.chain_id?a`<span class="command-tag">${i.chain_id}</span>`:null}
              ${i.run_id?a`<span class="command-tag">run ${i.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?a`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Se("swarm"),$t("command",{surface:"swarm",operation_id:e.operation_id,...r?{run_id:r}:{}})}}
        >
          Swarm Live
        </button>
        ${i?a`
              <button
                class="control-btn ghost"
                onClick=${()=>{co(e.operation_id),Se("chains"),$t("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?a`
              <button class="control-btn ghost" disabled=${at(n)} onClick=${()=>Jt(()=>hu(e.operation_id))}>
                ${at(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${at(o)} onClick=${()=>Jt(()=>bu(e.operation_id))}>
                ${at(o)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?a`
              <button class="control-btn ghost" disabled=${at(s)} onClick=${()=>Jt(()=>yu(e.operation_id))}>
                ${at(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function hp({card:t}){var n;const e=t.detachment;return a`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${O(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${tt(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Tu(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${tt(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?a`<span class="command-tag ${Iu(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function yp({alert:t}){return a`
    <article class="command-alert ${O(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${O(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${tt(t.timestamp)}</span>
      </div>
      ${t.detail?a`<p>${t.detail}</p>`:null}
    </article>
  `}function er({event:t}){return a`
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
      <pre class="command-trace-detail">${wu(t.detail)}</pre>
    </article>
  `}function bp({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return a`
    <article class="command-card ${O(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${O(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${tt(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!s?a`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${at(e)} onClick=${()=>Jt(()=>xu(t.decision_id))}>
                ${at(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${at(n)} onClick=${()=>Jt(()=>Su(t.decision_id))}>
                ${at(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?a`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function kp({row:t}){var c,d,m;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,o=!!((c=e.policy)!=null&&c.frozen),i=!!((d=e.policy)!=null&&d.kill_switch),r=Math.round((t.utilization??0)*100);return a`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${O(r>100?"bad":r>70?"warn":"ok")}">${r}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>Headcount Cap</span><span>${t.headcount_cap??0}</span>
        <span>Ops</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${((m=e.policy)==null?void 0:m.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${o?"yes":"no"}</span>
        <span>Kill Switch</span><span>${i?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${at(n)} onClick=${()=>Jt(()=>Au(e.unit_id,!o))}>
          ${at(n)?"Applying…":o?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${at(s)} onClick=${()=>Jt(()=>Cu(e.unit_id,!i))}>
          ${at(s)?"Applying…":i?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function xp({item:t}){return a`
    <article class="command-guide-card ${O(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${O(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Sp({blocker:t}){return a`
    <article class="command-alert ${O(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${O(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function Ap({worker:t}){return a`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${O(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${t.last_message?a`<div class="command-card-foot">${tt(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function Cp(){var d,m,p,u,g,$,x,A,I,D,q,L,T,N,V,B,v,F,Z,W,et;const t=Ls.value,e=Vu(),n=Yu(),s=(d=t==null?void 0:t.provider)!=null&&d.runtime_blocker?"blocked":(m=t==null?void 0:t.provider)!=null&&m.provider_reachable?"ready":"check",o=((p=t==null?void 0:t.provider)==null?void 0:p.actual_slots)??((u=t==null?void 0:t.provider)==null?void 0:u.total_slots)??0,i=((g=t==null?void 0:t.provider)==null?void 0:g.expected_slots)??"n/a",r=(($=t==null?void 0:t.provider)==null?void 0:$.actual_ctx)??((x=t==null?void 0:t.provider)==null?void 0:x.ctx_per_slot)??0,c=((A=t==null?void 0:t.provider)==null?void 0:A.expected_ctx)??"n/a";return a`
    <div class="command-section-stack">
      <${cp} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${qa.value?a`<div class="empty-state">Loading swarm live state…</div>`:ds.value?a`<div class="empty-state error">${ds.value}</div>`:t?a`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((I=t.summary)==null?void 0:I.joined_workers)??0}/${((D=t.summary)==null?void 0:D.expected_workers)??0}</strong><small>${((q=t.summary)==null?void 0:q.live_workers)??0}개 가동 · ${((L=t.summary)==null?void 0:L.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${o}/${i} · ctx ${r}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(T=t.summary)!=null&&T.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((N=t.provider)==null?void 0:N.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(V=t.summary)!=null&&V.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((B=t.operation)==null?void 0:B.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((v=t.squad)==null?void 0:v.label)??"없음"}</span>
                      <span>실행체</span><span>${((F=t.detachment)==null?void 0:F.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((Z=t.summary)==null?void 0:Z.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((W=t.summary)==null?void 0:W.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((et=t.provider)==null?void 0:et.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?a`<div class="command-tag-row">
                          ${t.truth_notes.map(b=>a`<span class="command-tag">${b}</span>`)}
                        </div>`:null}
                  `:a`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?a`<div class="command-card-stack">
                ${t.checklist.map(b=>a`<${xp} item=${b} />`)}
              </div>`:a`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?a`<div class="command-card-stack">
                ${t.workers.map(b=>a`<${Ap} worker=${b} />`)}
              </div>`:a`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t!=null&&t.provider?a`
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
                ${t.provider.detail?a`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?a`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(b=>a`
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
                    </div>`:a`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:a`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?a`<div class="command-card-stack">
                ${t.blockers.map(b=>a`<${Sp} blocker=${b} />`)}
              </div>`:a`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?a`<div class="command-trace-stack">
                ${t.recent_messages.map(b=>a`
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
              </div>`:a`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${z} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?a`<div class="command-trace-stack">
                ${t.recent_trace_events.map(b=>a`<${er} event=${b} />`)}
              </div>`:a`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function wp(){const t=Nt.value;return a`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${z} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?a`<div class="command-card-stack">
              ${t.operations.operations.map(e=>a`<${$p} card=${e} />`)}
            </div>`:a`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${z} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?a`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>a`<${hp} card=${e} />`)}
            </div>`:a`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function Ip(){var c,d,m,p,u,g,$,x,A,I,D,q,L,T,N,V;const t=Ms.value,e=(t==null?void 0:t.operations)??[],n=xe.value,s=e.find(B=>B.operation.operation_id===n)??e[0]??null,o=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,i=((d=sn.value)==null?void 0:d.run)??(s==null?void 0:s.preview_run)??null,r=!((m=sn.value)!=null&&m.run)&&!!(s!=null&&s.preview_run);return ct(()=>{o?gu(o):fu()},[o]),a`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${z} panelId="command.chains" compact=${!0} />
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
            <span>Active Chains</span><span>${((u=t==null?void 0:t.summary)==null?void 0:u.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((g=t==null?void 0:t.summary)==null?void 0:g.recent_failures)??0}</span>
            <span>Last Event</span><span>${tt(($=t==null?void 0:t.summary)==null?void 0:$.last_history_event_at)}</span>
          </div>
        </article>

        ${us.value?a`<div class="empty-state error">${us.value}</div>`:null}

        ${Ka.value&&!t?a`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?a`
                <div class="command-chain-list">
                  ${e.map(B=>a`
                    <${_p}
                      overlay=${B}
                      selected=${(s==null?void 0:s.operation.operation_id)===B.operation.operation_id}
                      onSelect=${()=>co(B.operation.operation_id)}
                    />
                  `)}
                </div>
              `:a`<div class="empty-state">No chain-backed operations yet.</div>`}

        <div class="command-chain-history">
          <div class="command-guide-head">
            <strong>Recent history</strong>
            <span class="command-chip">${(t==null?void 0:t.recent_history.length)??0}</span>
          </div>
          ${t&&t.recent_history.length>0?a`
                <div class="command-card-stack">
                  ${t.recent_history.slice(0,6).map(B=>a`<${fp} item=${B} />`)}
                </div>
              `:a`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chain Detail</div>
          <${z} panelId="command.chains" compact=${!0} />
        </div>
        ${s?a`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${Gt((x=s.operation.chain)==null?void 0:x.status)}">
                    ${((A=s.operation.chain)==null?void 0:A.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((I=s.operation.chain)==null?void 0:I.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((D=s.operation.chain)==null?void 0:D.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${o??"not materialized"}</span>
                  <span>Progress</span><span>${zs((q=s.runtime)==null?void 0:q.progress)}</span>
                  <span>Elapsed</span><span>${Pu((L=s.runtime)==null?void 0:L.elapsed_sec)}</span>
                  <span>Updated</span><span>${tt(((T=s.operation.chain)==null?void 0:T.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(N=s.operation.chain)!=null&&N.goal?a`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?a`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((V=s.operation.chain)==null?void 0:V.chain_id)??"graph"}</span>
                      </div>
                      <${vp} source=${s.mermaid} />
                    </div>
                  `:a`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(i==null?void 0:i.success)===!1?"bad":"ok"}">
                    ${i?i.success===!1?"failed":r?"preview":"captured":"pending"}
                  </span>
                </div>
                ${ps.value?a`<div class="empty-state">Loading run detail…</div>`:an.value?a`<div class="empty-state error">${an.value}</div>`:i&&i.nodes.length>0?a`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${i.chain_id}</span>
                            <span>Run</span><span>${i.run_id??"preview only"}</span>
                            <span>Duration</span><span>${i.duration_ms!=null?`${i.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${i.nodes.length}</span>
                          </div>
                          ${r?a`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${i.nodes.map(B=>a`<${gp} node=${B} />`)}
                          </div>
                        `:a`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:a`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function Tp(){const t=Nt.value;return a`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${z} panelId="command.topology" compact=${!0} />
      </div>
      ${t&&t.topology.units.length>0?a`${t.topology.units.map(e=>a`<${tr} node=${e} />`)}`:a`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function Rp(){const t=Nt.value;return a`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${z} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?a`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>a`<${yp} alert=${e} />`)}
          </div>`:a`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function Np(){const t=Nt.value;return a`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${z} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?a`<div class="command-trace-stack">
            ${t.traces.events.map(e=>a`<${er} event=${e} />`)}
          </div>`:a`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function Pp(){const t=Nt.value;return a`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${z} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?a`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>a`<${bp} decision=${e} />`)}
            </div>`:a`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${z} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?a`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>a`<${kp} row=${e} />`)}
            </div>`:a`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function Dp(){if(_t.value==="summary")return a`<${pp} />`;if(_t.value==="swarm")return a`<${Cp} />`;if(!Nt.value)return a`<${mp} />`;switch(_t.value){case"chains":return a`<${Ip} />`;case"topology":return a`<${Tp} />`;case"alerts":return a`<${Rp} />`;case"trace":return a`<${Np} />`;case"control":return a`<${Pp} />`;case"operations":default:return a`<${wp} />`}}function Lp(){return ct(()=>{de(),Bt(),$u(),Lt()},[]),ct(()=>{if(M.value.tab!=="command")return;const t=M.value.params.surface,e=M.value.params.operation,n=bn(M.value);if(To(t))Se(t);else if(n){const s=Pi(n);To(s)&&Se(s)}else t||Se("operations");e&&co(e),t==="swarm"&&Lt()},[M.value.tab,M.value.params.surface,M.value.params.operation,M.value.params.operation_id,M.value.params.run_id,M.value.params.source,M.value.params.action_type,M.value.params.target_type,M.value.params.target_id,M.value.params.focus_kind]),ct(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,de(),Bt(),_t.value==="swarm"&&Lt()},250))},n=new EventSource(Fu()),s=Eu.map(o=>{const i=()=>e();return n.addEventListener(o,i),{type:o,handler:i}});return n.onerror=()=>{e()},()=>{s.forEach(({type:o,handler:i})=>{n.removeEventListener(o,i)}),n.close(),t&&window.clearTimeout(t)}},[]),a`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 현재 작전입니다. 여기서는 지금 무엇이 움직이고 막히는지 확인한 뒤, 필요한 surface로만 더 깊게 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Jt(()=>ku())}}
            disabled=${at("dispatch:tick")}
          >
            ${at("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{de(),Bt(),Lt()}}
            disabled=${as.value}
          >
            ${as.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${is.value?a`<div class="empty-state error">${is.value}</div>`:null}
      ${ls.value?a`<div class="empty-state error">${ls.value}</div>`:null}
      <${ht} surfaceId="command" />
      <${Wu} />
      <${Bu} />
      <${dp} />
      <${Dp} />
    </section>
  `}let Mp=0;const re=f([]);function R(t,e="success",n=4e3){const s=++Mp;re.value=[...re.value,{id:s,message:t,type:e}],setTimeout(()=>{re.value=re.value.filter(o=>o.id!==s)},n)}function Ep(t){re.value=re.value.filter(e=>e.id!==t)}function zp(){const t=re.value;return t.length===0?null:a`
    <div class="toast-container">
      ${t.map(e=>a`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Ep(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Me=f(null),nr=f(null),Ot=f(null),ms=f(!1),Yt=f(null),on=f(!1),Re=f(null),G=f(!1),vs=f([]);let Op=1;function K(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function k(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function Q(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function js(t){return typeof t=="boolean"?t:void 0}function jp(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Ct(t,e=[]){if(Array.isArray(t))return t;if(!K(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Fp(t){return K(t)?{id:k(t.id),seq:Q(t.seq),from:k(t.from)??k(t.from_agent)??"system",content:k(t.content)??"",timestamp:k(t.timestamp)??new Date().toISOString(),type:k(t.type)}:null}function qp(t){return K(t)?{room_id:k(t.room_id),current_room:k(t.current_room)??k(t.room),project:k(t.project),cluster:k(t.cluster),paused:js(t.paused),pause_reason:k(t.pause_reason)??null,paused_by:k(t.paused_by)??null,paused_at:k(t.paused_at)??null}:{}}function Ro(t){if(!K(t))return;const e=Object.entries(t).map(([n,s])=>{const o=k(s);return o?[n,o]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function sr(t){if(!K(t))return null;const e=k(t.kind),n=k(t.summary),s=k(t.target_type);return!e||!n||!s?null:{kind:e,severity:k(t.severity)??"warn",summary:n,target_type:s,target_id:k(t.target_id)??null,actor:k(t.actor)??null,evidence:t.evidence}}function ar(t){if(!K(t))return null;const e=k(t.action_type),n=k(t.target_type),s=k(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:k(t.target_id)??null,severity:k(t.severity)??"warn",reason:s,confirm_required:js(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Kp(t){return K(t)?{actor:k(t.actor)??null,spawn_agent:k(t.spawn_agent)??null,spawn_role:k(t.spawn_role)??null,spawn_model:k(t.spawn_model)??null,worker_class:k(t.worker_class)??null,parent_actor:k(t.parent_actor)??null,capsule_mode:k(t.capsule_mode)??null,runtime_pool:k(t.runtime_pool)??null,lane_id:k(t.lane_id)??null,controller_level:k(t.controller_level)??null,control_domain:k(t.control_domain)??null,supervisor_actor:k(t.supervisor_actor)??null,model_tier:k(t.model_tier)??null,task_profile:k(t.task_profile)??null,risk_level:k(t.risk_level)??null,routing_confidence:Q(t.routing_confidence)??null,routing_reason:k(t.routing_reason)??null,status:k(t.status)??"unknown",turn_count:Q(t.turn_count)??0,empty_note_turn_count:Q(t.empty_note_turn_count)??0,has_turn:js(t.has_turn)??!1,last_turn_ts_iso:k(t.last_turn_ts_iso)??null}:null}function Up(t){if(!K(t))return null;const e=k(t.session_id);return e?{session_id:e,goal:k(t.goal),status:k(t.status),health:k(t.health),scale_profile:k(t.scale_profile),control_profile:k(t.control_profile),planned_worker_count:Q(t.planned_worker_count),active_agent_count:Q(t.active_agent_count),last_turn_age_sec:Q(t.last_turn_age_sec)??null,attention_count:Q(t.attention_count),recommended_action_count:Q(t.recommended_action_count),top_attention:sr(t.top_attention),top_recommendation:ar(t.top_recommendation)}:null}function or(t){const e=K(t)?t:{};return{trace_id:k(e.trace_id),target_type:k(e.target_type)??"room",target_id:k(e.target_id)??null,health:k(e.health),swarm_status:K(e.swarm_status)?e.swarm_status:void 0,attention_items:Ct(e.attention_items).map(sr).filter(n=>n!==null),recommended_actions:Ct(e.recommended_actions).map(ar).filter(n=>n!==null),session_cards:Ct(e.session_cards).map(Up).filter(n=>n!==null),worker_cards:Ct(e.worker_cards).map(Kp).filter(n=>n!==null)}}function Hp(t){if(!K(t))return null;const e=K(t.status)?t.status:void 0,n=K(t.summary)?t.summary:K(e==null?void 0:e.summary)?e.summary:void 0,s=K(t.session)?t.session:K(e==null?void 0:e.session)?e.session:void 0,o=k(t.session_id)??k(n==null?void 0:n.session_id)??k(s==null?void 0:s.session_id);if(!o)return null;const i=Ro(t.report_paths)??Ro(e==null?void 0:e.report_paths),r=Ct(t.recent_events,["events"]).filter(K);return{session_id:o,status:k(t.status)??k(n==null?void 0:n.status)??k(s==null?void 0:s.status),progress_pct:Q(t.progress_pct)??Q(n==null?void 0:n.progress_pct),elapsed_sec:Q(t.elapsed_sec)??Q(n==null?void 0:n.elapsed_sec),remaining_sec:Q(t.remaining_sec)??Q(n==null?void 0:n.remaining_sec),done_delta_total:Q(t.done_delta_total)??Q(n==null?void 0:n.done_delta_total),summary:n,team_health:K(t.team_health)?t.team_health:K(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:K(t.communication_metrics)?t.communication_metrics:K(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:K(t.orchestration_state)?t.orchestration_state:K(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:K(t.cascade_metrics)?t.cascade_metrics:K(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:s,recent_events:r}}function Wp(t){if(!K(t))return null;const e=k(t.name);if(!e)return null;const n=K(t.context)?t.context:void 0;return{name:e,agent_name:k(t.agent_name),status:k(t.status),autonomy_level:k(t.autonomy_level),context_ratio:Q(t.context_ratio)??Q(n==null?void 0:n.context_ratio),generation:Q(t.generation),active_goal_ids:jp(t.active_goal_ids),last_autonomous_action_at:k(t.last_autonomous_action_at)??null,last_turn_ago_s:Q(t.last_turn_ago_s),model:k(t.model)??k(t.active_model)??k(t.primary_model)}}function Bp(t){if(!K(t))return null;const e=k(t.confirm_token)??k(t.token);return e?{confirm_token:e,actor:k(t.actor),action_type:k(t.action_type),target_type:k(t.target_type),target_id:k(t.target_id)??null,delegated_tool:k(t.delegated_tool),created_at:k(t.created_at),preview:t.preview}:null}function Gp(t){const e=K(t)?t:{};return{room:qp(e.room),sessions:Ct(e.sessions,["items","sessions"]).map(Hp).filter(n=>n!==null),keepers:Ct(e.keepers,["items","keepers"]).map(Wp).filter(n=>n!==null),recent_messages:Ct(e.recent_messages,["messages"]).map(Fp).filter(n=>n!==null),pending_confirms:Ct(e.pending_confirms,["items","confirms"]).map(Bp).filter(n=>n!==null),available_actions:Ct(e.available_actions,["actions"]).filter(K).map(n=>({action_type:k(n.action_type)??"unknown",target_type:k(n.target_type)??"unknown",description:k(n.description),confirm_required:js(n.confirm_required)}))}}function Rn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function No(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function _s(t){vs.value=[{...t,id:Op++,at:new Date().toISOString()},...vs.value].slice(0,20)}function ir(t){return t.confirm_required?Rn(t.preview)||"Confirmation required":Rn(t.result)||Rn(t.executed_action)||Rn(t.delegated_tool_result)||t.status}async function Xt(){ms.value=!0,Yt.value=null;try{const t=await ml();Me.value=Gp(t)}catch(t){Yt.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{ms.value=!1}}async function jt(){on.value=!0,Re.value=null;try{const t=await di({targetType:"room"});nr.value=or(t)}catch(t){Re.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{on.value=!1}}async function rn(t){if(!t){Ot.value=null;return}on.value=!0,Re.value=null;try{const e=await di({targetType:"team_session",targetId:t,includeWorkers:!0});Ot.value=or(e)}catch(e){Re.value=e instanceof Error?e.message:"Failed to load session digest"}finally{on.value=!1}}async function Jp(t){var e;G.value=!0,Yt.value=null;try{const n=await ws(t);return _s({actor:t.actor,action_type:t.action_type,target_label:No(t),outcome:n.confirm_required?"preview":"executed",message:ir(n),delegated_tool:n.delegated_tool}),await Xt(),await jt(),(e=Ot.value)!=null&&e.target_id&&await rn(Ot.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw Yt.value=s,_s({actor:t.actor,action_type:t.action_type,target_label:No(t),outcome:"error",message:s}),n}finally{G.value=!1}}async function Vp(t,e){var n;G.value=!0,Yt.value=null;try{const s=await kl(t,e);return _s({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:ir(s),delegated_tool:s.delegated_tool}),await Xt(),await jt(),(n=Ot.value)!=null&&n.target_id&&await rn(Ot.value.target_id),s}catch(s){const o=s instanceof Error?s.message:"Operator confirmation failed";throw Yt.value=o,_s({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:o}),s}finally{G.value=!1}}Vc(()=>{var t;Xt(),jt(),(t=Ot.value)!=null&&t.target_id&&rn(Ot.value.target_id)});const rr="masc_dashboard_agent_name";function Yp(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(rr))==null?void 0:s.trim())||"dashboard"}const Fs=f(Yp()),Ae=f(""),Ua=f("운영 점검"),Ce=f(""),ln=f(""),cn=f("2"),dn=f(""),wt=f("note"),un=f(""),pn=f(""),mn=f(""),vn=f("2"),fs=f("운영자 중지 요청"),gs=f(""),we=f(""),Nn=f(null);function Xp(t){const e=t.trim()||"dashboard";Fs.value=e,localStorage.setItem(rr,e)}function Po(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Qp(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function Ne(t){return typeof t=="string"?t.trim().toLowerCase():""}function Zp(t){var s;const e=Ne(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=Ne((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function Gs(t){const e=Ne(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function Do(t){return t.some(e=>Ne(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function tm(t){return t.target_type==="team_session"}function em(t){return t.target_type==="keeper"}function Pn(t){switch(t){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";case"keeper_msg":return"keeper 메시지";default:return(t==null?void 0:t.trim())||"액션"}}function Dn(t){switch(t){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";default:return(t==null?void 0:t.trim())||"target"}}function Ke(t){switch(Ne(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Lo(t){return t?"확인 후 실행":"즉시 실행"}function nm(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";default:return t}}function ut(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function sm(t){if(t.action_type==="team_task_inject")return"task";if(t.action_type==="team_broadcast")return"broadcast";if(t.action_type==="team_note")return"note";if(t.action_type==="team_turn"){const e=ut(t.suggested_payload,"turn_kind");if(e==="broadcast"||e==="task")return e}return"note"}function am(t){const e=t.suggested_payload;if(t.target_type==="room"){if(t.action_type==="broadcast"){Ae.value=ut(e,"message")??t.summary;return}t.action_type==="task_inject"&&(Ce.value=ut(e,"title")??"운영자 주입 작업",ln.value=ut(e,"description")??t.summary,cn.value=ut(e,"priority")??cn.value);return}if(t.target_type==="team_session"){if(t.target_id&&(dn.value=t.target_id),t.action_type==="team_stop"){fs.value=ut(e,"reason")??t.summary;return}wt.value=sm(t);const n=ut(e,"message");n&&(un.value=n),wt.value==="task"&&(pn.value=ut(e,"task_title")??ut(e,"title")??"운영자 주입 작업",mn.value=ut(e,"task_description")??ut(e,"description")??t.summary,vn.value=ut(e,"task_priority")??ut(e,"priority")??vn.value);return}t.target_type==="keeper"&&(t.target_id&&(gs.value=t.target_id),we.value=ut(e,"message")??t.summary)}function om(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function Ee(t){const e=Fs.value.trim()||"dashboard";try{const n=await Jp({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?R("확인 대기열에 올렸습니다","warning"):R(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return R(s,"error"),null}}async function Mo(){const t=Ae.value.trim();if(!t)return;await Ee({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(Ae.value="")}async function im(){await Ee({action_type:"room_pause",target_type:"room",payload:{reason:Ua.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function Eo(){await Ee({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function rm(){const t=Ce.value.trim();if(t)try{await Ql(t,ln.value.trim()||"Intervene 화면에서 주입",Number.parseInt(cn.value,10)||2),R("작업을 backlog에 추가했습니다","success"),Ce.value="",ln.value=""}catch(e){const n=e instanceof Error?e.message:"작업 추가에 실패했습니다";R(n,"error")}}async function lm(){var r;const t=Me.value,e=dn.value||((r=t==null?void 0:t.sessions[0])==null?void 0:r.session_id)||"";if(!e){R("먼저 세션을 고르세요","warning");return}const n={},s=un.value.trim();s&&(n.message=s);let o="team_note";wt.value==="broadcast"?o="team_broadcast":wt.value==="task"&&(o="team_task_inject"),wt.value==="task"&&(n.task_title=pn.value.trim()||"운영자 주입 작업",n.task_description=mn.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(vn.value,10)||2),await Ee({action_type:o,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(un.value="",wt.value==="task"&&(pn.value="",mn.value=""))}async function cm(){var n;const t=Me.value,e=dn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){R("먼저 세션을 고르세요","warning");return}await Ee({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:fs.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function dm(){var o;const t=Me.value,e=gs.value||((o=t==null?void 0:t.keepers[0])==null?void 0:o.name)||"",n=we.value.trim();if(!e){R("먼저 keeper를 고르세요","warning");return}if(!n)return;await Ee({action_type:"keeper_message",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`${e}에게 메시지를 보냈습니다`})&&(we.value="")}async function um(t){const e=Fs.value.trim()||"dashboard";try{await Vp(e,t),R("확인 실행을 완료했습니다","success")}catch(n){const s=n instanceof Error?n.message:"확인 실행에 실패했습니다";R(s,"error")}}function pm(){var N,V,B;const t=Me.value,e=M.value.tab==="intervene"?bn(M.value):null,n=nr.value,s=Ot.value,o=(t==null?void 0:t.room)??{},i=(t==null?void 0:t.sessions)??[],r=(t==null?void 0:t.keepers)??[],c=(t==null?void 0:t.pending_confirms)??[],d=(t==null?void 0:t.recent_messages)??[],m=(n==null?void 0:n.recommended_actions)??[],p=(t==null?void 0:t.available_actions)??[],u=i.find(v=>v.session_id===dn.value)??i[0]??null,g=r.find(v=>v.name===gs.value)??r[0]??null,$=(n==null?void 0:n.attention_items)??[],x=$.filter(tm),A=$.filter(em),I=i.filter(v=>Zp(v)!=="ok"),D=r.filter(v=>Gs(v)!=="ok"),q=d.slice(0,5),L=om(e,i,r);ct(()=>{jt()},[]),ct(()=>{if(M.value.tab!=="intervene"){Nn.value=null;return}if(!e){Nn.value=null;return}Nn.value!==e.id&&(Nn.value=e.id,am(e))},[M.value.tab,M.value.params.source,M.value.params.action_type,M.value.params.target_type,M.value.params.target_id,M.value.params.focus_kind,e==null?void 0:e.id]),ct(()=>{const v=(u==null?void 0:u.session_id)??null;rn(v)},[u==null?void 0:u.session_id]);const T=[{key:"room",label:"Room 게이트",value:o.paused?"일시정지":"열림",detail:o.paused?`재개 전환 대기 중${o.pause_reason?` · ${o.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:o.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:c.length,detail:c.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:c.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:x.length>0?x.length:i.length,detail:x.length>0?((N=x[0])==null?void 0:N.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":i.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:x.length>0?Do(x):i.length===0?"warn":I.some(v=>Ne(v.status)==="paused")?"bad":I.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:A.length>0?A.length:D.length,detail:A.length>0?((V=A[0])==null?void 0:V.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":D.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:A.length>0?Do(A):D.some(v=>Gs(v)==="bad")?"bad":D.length>0?"warn":"ok"}];return a`
    <section class="ops-view">
      <${ht} surfaceId="intervene" />
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
            value=${Fs.value}
            onInput=${v=>Xp(v.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{Xt(),jt(),rn((u==null?void 0:u.session_id)??null)}}
            disabled=${ms.value||G.value}
          >
            ${ms.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Yt.value?a`<section class="ops-banner error">${Yt.value}</section>`:null}
      ${Re.value?a`<section class="ops-banner error">${Re.value}</section>`:null}
      ${e?a`
        <section class="ops-banner ${L?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${Ps(e.action_type)}</span>
            <span>${oo(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?a`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${L?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const v=[];if(c.length>0&&v.push({label:`확인 대기 ${c.length}건 처리`,desc:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:"bad",onClick:()=>{const F=document.querySelector(".ops-pending-section");F==null||F.scrollIntoView({behavior:"smooth"})}}),o.paused&&v.push({label:"Room 재개",desc:`현재 일시정지 상태${o.pause_reason?` (${o.pause_reason})`:""}`,tone:"warn",onClick:()=>void Eo()}),D.length>0){const F=D.filter(Z=>Gs(Z)==="bad");v.push({label:F.length>0?`Keeper ${F.length}개 오프라인`:`Keeper ${D.length}개 점검 필요`,desc:F.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:F.length>0?"bad":"warn",onClick:()=>{const Z=document.querySelector(".ops-keeper-section");Z==null||Z.scrollIntoView({behavior:"smooth"})}})}return v.length===0?null:a`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${v.slice(0,3).map(F=>a`
                <button class="ops-action-guide-item ${F.tone}" onClick=${F.onClick}>
                  <strong>${F.label}</strong>
                  <span>${F.desc}</span>
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
          ${T.map(v=>a`
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
                <strong>${o.current_room??o.room_id??"default"}</strong>
              </div>
              <div class="ops-stat">
                <span>프로젝트</span>
                <strong>${o.project??"확인 없음"}</strong>
              </div>
              <div class="ops-stat">
                <span>클러스터</span>
                <strong>${o.cluster??"확인 없음"}</strong>
              </div>
              <div class="ops-stat ${o.paused?"warn":"ok"}">
                <span>상태</span>
                <strong>${o.paused?"일시정지":"진행 중"}</strong>
              </div>
            </div>

            <label class="control-label" for="ops-broadcast">Room 방송</label>
            <div class="control-row">
              <input
                id="ops-broadcast"
                class="control-input"
                type="text"
                placeholder="@agent 또는 room 전체 공지"
                value=${Ae.value}
                onInput=${v=>{Ae.value=v.target.value}}
                onKeyDown=${v=>{v.key==="Enter"&&Mo()}}
                disabled=${G.value}
              />
              <button class="control-btn" onClick=${()=>{Mo()}} disabled=${G.value||Ae.value.trim()===""}>
                보내기
              </button>
            </div>

            <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
            <div class="control-row ops-split-row">
              <input
                id="ops-pause-reason"
                class="control-input"
                type="text"
                value=${Ua.value}
                onInput=${v=>{Ua.value=v.target.value}}
                disabled=${G.value}
              />
              <button class="control-btn ghost" onClick=${()=>{im()}} disabled=${G.value}>
                일시정지
              </button>
              <button class="control-btn ghost" onClick=${()=>{Eo()}} disabled=${G.value}>
                재개
              </button>
            </div>

            <div class="ops-section-head">작업 주입</div>
            <input
              class="control-input"
              type="text"
              placeholder="작업 제목"
              value=${Ce.value}
              onInput=${v=>{Ce.value=v.target.value}}
              disabled=${G.value}
            />
            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="작업 설명"
              value=${ln.value}
              onInput=${v=>{ln.value=v.target.value}}
              disabled=${G.value}
            ></textarea>
            <div class="control-row ops-split-row">
              <select
                class="control-input ops-select"
                value=${cn.value}
                onChange=${v=>{cn.value=v.target.value}}
                disabled=${G.value}
              >
                <option value="1">P1</option>
                <option value="2">P2</option>
                <option value="3">P3</option>
                <option value="4">P4</option>
                <option value="5">P5</option>
              </select>
              <button class="control-btn" onClick=${()=>{rm()}} disabled=${G.value||Ce.value.trim()===""}>
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
            ${on.value&&!n?a`
              <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
            `:m.length>0?a`
              <div class="ops-log-list">
                ${m.map(v=>a`
                  <article key=${`${v.action_type}:${v.target_type}:${v.target_id??"room"}`} class="ops-log-entry ${v.severity}">
                    <div class="ops-log-head">
                      <strong>${Pn(v.action_type)}</strong>
                      <span>${Dn(v.target_type)}${v.target_id?` · ${v.target_id}`:""}</span>
                      <span>${Lo(v.confirm_required)}</span>
                    </div>
                    <div class="ops-log-body">${v.reason}</div>
                  </article>
                `)}
              </div>
            `:a`
              <div class="ops-empty">지금 떠 있는 추천 개입은 없습니다.</div>
            `}
          </section>

          <section class="card ops-panel ops-pending-section">
            <div class="card-title-row">
              <div class="card-title">승인 대기</div>
              <${z} panelId="intervene.pending_confirmations" compact=${!0} />
            </div>
            <p class="ops-context-note">미리보기만 끝났고 아직 사람이 눌러줘야 하는 액션만 남깁니다.</p>
            ${c.length>0?a`
              <div class="ops-confirmation-list">
                ${c.map(v=>a`
                  <article key=${v.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${Pn(v.action_type)}</strong>
                      <span>${Dn(v.target_type)}${v.target_id?` · ${v.target_id}`:""}</span>
                      <span>${v.delegated_tool??"위임 도구 확인 필요"}</span>
                    </div>
                    ${v.preview?a`<pre class="ops-code-block compact">${Po(v.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{um(v.confirm_token)}} disabled=${G.value}>
                        실행
                      </button>
                      <span class="ops-token">${v.confirm_token}</span>
                    </div>
                  </article>
                `)}
              </div>
            `:a`<div class="ops-empty">지금 승인 대기는 없습니다.</div>`}
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 Room 메시지</div>
              <${z} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
            ${q.length>0?a`
              <div class="ops-feed-list">
                ${q.map(v=>a`
                  <article key=${v.seq??v.id??v.timestamp} class="ops-feed-item">
                    <div class="ops-feed-meta">
                      <strong>${v.from}</strong>
                      <span>${v.timestamp}</span>
                    </div>
                    <div class="ops-feed-content">${v.content}</div>
                  </article>
                `)}
              </div>
            `:a`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
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
              ${i.length===0?a`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:i.map(v=>{var F;return a`
                <button
                  key=${v.session_id}
                  class="ops-entity-card ${(u==null?void 0:u.session_id)===v.session_id?"active":""}"
                  onClick=${()=>{dn.value=v.session_id}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${v.session_id}</strong>
                    <span class="status-badge ${v.status??"idle"}">${Ke(v.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round(v.progress_pct??0)}%</span>
                    <span>${v.done_delta_total??0}건 완료</span>
                    <span>${(F=v.team_health)!=null&&F.status?Ke(String(v.team_health.status)):"상태 확인 필요"}</span>
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
            ${u&&s?a`
              <div class="ops-log-list">
                ${s.attention_items.length>0?s.attention_items.map(v=>a`
                  <article key=${`${v.kind}:${v.target_id??"session"}`} class="ops-log-entry ${v.severity}">
                    <div class="ops-log-head">
                      <strong>${v.kind}</strong>
                      <span>${Dn(v.target_type)}${v.target_id?` · ${v.target_id}`:""}</span>
                    </div>
                    <div class="ops-log-body">${v.summary}</div>
                  </article>
                `):a`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
                ${s.worker_cards.length>0?s.worker_cards.map(v=>a`
                  <article key=${`${v.actor??v.spawn_role??"worker"}:${v.spawn_agent??v.runtime_pool??"runtime"}`} class="ops-log-entry">
                    <div class="ops-log-head">
                      <strong>${v.actor??v.spawn_role??"worker"}</strong>
                      <span>${Ke(v.status)}</span>
                      <span>${v.spawn_agent??v.runtime_pool??"runtime 확인 필요"}</span>
                    </div>
                    <div class="ops-log-body">
                      ${v.worker_class??"worker"}${v.lane_id?` · ${v.lane_id}`:""}${v.routing_reason?` · ${v.routing_reason}`:""}
                    </div>
                  </article>
                `):null}
              </div>
            `:a`
              <div class="ops-empty">세션을 고르면 세부 요약을 불러옵니다.</div>
            `}
          </section>

          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">선택한 Session 액션</div>
              <${z} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>

            ${u?a`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${u.session_id}</div>
                <div class="ops-detail-meta">
                  <span>상태: ${Ke(u.status)}</span>
                  <span>경과: ${u.elapsed_sec??0}초</span>
                  <span>남은 시간: ${u.remaining_sec??0}초</span>
                </div>
                ${u.recent_events&&u.recent_events.length>0?a`
                  <pre class="ops-code-block compact">${Po(u.recent_events.slice(-3))}</pre>
                `:null}
              </div>
            `:a`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

            <label class="control-label" for="ops-turn-kind">세션 액션</label>
            <div class="control-row ops-split-row">
              <select
                id="ops-turn-kind"
                class="control-input ops-select"
                value=${wt.value}
                onChange=${v=>{wt.value=v.target.value}}
                disabled=${G.value||!u}
              >
                <option value="note">노트</option>
                <option value="broadcast">방송</option>
                <option value="task">작업</option>
              </select>
              <button class="control-btn" onClick=${()=>{lm()}} disabled=${G.value||!u}>
                적용
              </button>
            </div>
            <div class="ops-context-note">현재 선택: ${nm(wt.value)}</div>

            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="세션에 남길 메시지"
              value=${un.value}
              onInput=${v=>{un.value=v.target.value}}
              disabled=${G.value||!u}
            ></textarea>

            ${wt.value==="task"?a`
              <input
                class="control-input"
                type="text"
                placeholder="주입할 작업 제목"
                value=${pn.value}
                onInput=${v=>{pn.value=v.target.value}}
                disabled=${G.value||!u}
              />
              <textarea
                class="control-textarea"
                rows=${2}
                placeholder="주입할 작업 설명"
                value=${mn.value}
                onInput=${v=>{mn.value=v.target.value}}
                disabled=${G.value||!u}
              ></textarea>
              <select
                class="control-input ops-select"
                value=${vn.value}
                onChange=${v=>{vn.value=v.target.value}}
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
                value=${fs.value}
                onInput=${v=>{fs.value=v.target.value}}
                disabled=${G.value||!u}
              />
              <button class="control-btn ghost" onClick=${()=>{cm()}} disabled=${G.value||!u}>
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
              ${r.length===0?a`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:r.map(v=>a`
                <button
                  key=${v.name}
                  class="ops-entity-card ${(g==null?void 0:g.name)===v.name?"active":""}"
                  onClick=${()=>{gs.value=v.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${v.name}</strong>
                    <span class="status-badge ${v.status??"idle"}">${Ke(v.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${v.model??"model 확인 필요"}</span>
                    <span>${typeof v.context_ratio=="number"?`${Math.round(v.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                    <span>${Qp(v.last_turn_ago_s)}</span>
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

            ${g?a`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${g.name}</div>
                <div class="ops-detail-meta">
                  <span>자율성: ${g.autonomy_level??"확인 없음"}</span>
                  <span>세대: ${g.generation??0}</span>
                  <span>활성 목표: ${((B=g.active_goal_ids)==null?void 0:B.length)??0}</span>
                </div>
              </div>
            `:a`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

            <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
            <textarea
              id="ops-keeper-message"
              class="control-textarea"
              rows=${6}
              placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
              value=${we.value}
              onInput=${v=>{we.value=v.target.value}}
              disabled=${G.value||!g}
            ></textarea>
            <div class="control-row">
              <button class="control-btn" onClick=${()=>{dm()}} disabled=${G.value||!g||we.value.trim()===""}>
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
              ${p.length?p.map(v=>a`
                    <article key=${`${v.action_type}:${v.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${Pn(v.action_type)}</strong>
                        <span>${Dn(v.target_type)}</span>
                        <span>${Lo(v.confirm_required)}</span>
                      </div>
                      <div class="ops-log-body">${v.description??"설명이 아직 없습니다."}</div>
                    </article>
                  `):a`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 개입 로그</div>
              <${z} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <div class="ops-log-list">
              ${vs.value.length===0?a`
                <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
              `:vs.value.map(v=>a`
                <article key=${v.id} class="ops-log-entry ${v.outcome}">
                  <div class="ops-log-head">
                    <strong>${Pn(v.action_type)}</strong>
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
  `}function mm(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const o=Math.floor(s/60);if(o<60)return`${o}m ago`;const i=Math.floor(o/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function nt({timestamp:t}){const e=mm(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return a`<span class="time-ago" title=${n}>${e}</span>`}function vm({text:t}){if(!t)return null;const e=_m(t);return a`<div class="markdown-content">${e}</div>`}function _m(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const o=e[s];if(/^(`{3,}|~{3,})/.test(o)){const r=o.match(/^(`{3,}|~{3,})/)[0],c=o.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(a`<pre><code class=${c?`language-${c}`:""}>${d.join(`
`)}</code></pre>`);continue}if(o.trim()==="<think>"||o.trim().startsWith("<think>")){const r=[],c=o.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&r.push(c),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const m=e[s].replace("</think>","").trim();m&&r.push(m),s++}const d=r.join(`
`).trim();n.push(a`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Js(d)}</div>
        </details>
      `);continue}if(o.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(a`<blockquote>${Js(r.join(`
`))}</blockquote>`);continue}if(o.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(a`<p>${Js(i.join(`
`))}</p>`)}return n}function Js(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,o;for(;(o=n.exec(t))!==null;){if(o.index>s&&e.push(t.slice(s,o.index)),o[1]){const i=o[1].slice(1,-1);e.push(a`<code>${i}</code>`)}else if(o[2]){const i=o[2].slice(2,-2);e.push(a`<strong>${i}</strong>`)}else if(o[3]){const i=o[3].slice(1,-1);e.push(a`<em>${i}</em>`)}else o[4]&&o[5]&&e.push(a`<a href=${o[5]} target="_blank" rel="noopener">${o[4]}</a>`);s=o.index+o[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const lr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Wn=f(null),Bn=f([]),Pe=f(!1),le=f(null),Be=f(""),Ge=f(!1);function fm(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const gm=f(fm());function $m(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function zo(t){return t.updated_at!==t.created_at}async function po(t){le.value=t,Wn.value=null,Bn.value=[],Pe.value=!0;try{const e=await Cl(t);if(le.value!==t)return;Wn.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},Bn.value=e.comments??[]}catch{le.value===t&&(Wn.value=null,Bn.value=[])}finally{le.value===t&&(Pe.value=!1)}}async function Oo(t){const e=Be.value.trim();if(e){Ge.value=!0;try{await wl(t,gm.value,e),Be.value="",R("Comment posted","success"),await po(t),It()}catch{R("Failed to post comment","error")}finally{Ge.value=!1}}}function hm(){const t=tn.value;return a`
    <div class="board-toolbar">
      <div class="board-controls">
        ${lr.map(e=>a`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{tn.value=e.id,It()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${he.value?"is-active":""}"
          onClick=${()=>{he.value=!he.value,It()}}
        >
          ${he.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${It} disabled=${nn.value}>
          ${nn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function Vs(){var e;const t=((e=lr.find(n=>n.id===tn.value))==null?void 0:e.label)??tn.value;return a`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Visible posts</span>
        <strong>${Ts.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Sort</span>
        <strong>${t}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${he.value?"Auto reports hidden":"Full memory feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Pa.value?a`<${nt} timestamp=${Pa.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function ym({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await ui(t.id,n),It()}catch{R("Failed to vote","error")}};return a`
    <div class="board-post" onClick=${()=>qr(t.id)}>
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
              ${zo(t)?a`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${nt} timestamp=${t.created_at} /></span>
            ${zo(t)?a`<span>Updated <${nt} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${$m(t.content)}</div>
      </div>
    </div>
  `}function bm({comments:t}){return t.length===0?a`<div class="empty-state" style="font-size:13px">No comments yet</div>`:a`
    <div class="comment-thread">
      ${t.map(e=>a`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${nt} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function km({postId:t}){return a`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Be.value}
        onInput=${e=>{Be.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Oo(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Ge.value}
      />
      <button
        onClick=${()=>Oo(t)}
        disabled=${Ge.value||Be.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Ge.value?"...":"Post"}
      </button>
    </div>
  `}function xm({post:t}){le.value!==t.id&&!Pe.value&&po(t.id);const e=async n=>{try{await ui(t.id,n),It()}catch{R("Failed to vote","error")}};return a`
    <div>
      <button class="back-btn" onClick=${()=>$t("memory")}>← Back to Memory</button>
      <${w} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${vm} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${t.author}</span>
            <${nt} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
          </div>
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${w} title="Comments" semanticId="memory.feed">
        ${Pe.value?a`<div class="loading-indicator">Loading comments...</div>`:a`<${bm} comments=${Bn.value} />`}
        <${km} postId=${t.id} />
      <//>
    </div>
  `}function Sm(){const t=Ts.value,e=M.value.params.post??null,n=e?t.find(s=>s.id===e)??(le.value===e?Wn.value:null):null;return e&&!n&&le.value!==e&&!Pe.value&&po(e),e?n?a`
          <${ht} surfaceId="memory" />
          <${Vs} />
          <${xm} post=${n} />
        `:a`
          <div>
            <${ht} surfaceId="memory" />
            <${Vs} />
            <button class="back-btn" onClick=${()=>$t("memory")}>← Back to Memory</button>
            ${Pe.value?a`<div class="loading-indicator">Loading post...</div>`:a`<div class="empty-state">Post not found</div>`}
          </div>
        `:a`
    <div>
      <${ht} surfaceId="memory" />
      <${Vs} />
      <${hm} />
      ${nn.value?a`<div class="loading-indicator">Loading memory feed...</div>`:t.length===0?a`<div class="empty-state">No posts in durable memory right now</div>`:a`
              <${w} title="Posts / Comments" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.map(s=>a`<${ym} key=${s.id} post=${s} />`)}
                </div>
              <//>
            `}
    </div>
  `}function te({status:t,label:e}){return a`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function cr({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,o=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),a`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${o}" cy="${o}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${c}" 
          cx="${o}" cy="${o}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${c}">${Math.round(t*100)}%</span>
    </div>
  `}function Am(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Cm(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function wm(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function jo(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function dr(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Im(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function ur(t){if(!t)return null;const e=Et.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function Tm({keeper:t,showRawStatus:e=!1}){if(ct(()=>{t!=null&&t.name&&_i(t.name)},[t==null?void 0:t.name]),!t)return a`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Et.value[t.name],s=ur(t),o=xa.value[t.name];return a`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${Am(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Cm((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${o?a`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?a` · ${dr(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?a` · next eligible ${Im(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?a`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?a`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Rm({keeperName:t,placeholder:e}){const[n,s]=Zo("");ct(()=>{t&&_i(t)},[t]);const o=lt.value[t]??[],i=Sa.value[t]??!1,r=zt.value[t],c=async()=>{const d=n.trim();if(!(!t||!d)){s("");try{await hc(t,d)}catch(m){const p=m instanceof Error?m.message:`Failed to message ${t}`;R(p,"error")}}};return a`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${o.length===0?a`<div class="control-status-copy">No direct keeper conversation yet.</div>`:o.map(d=>a`
              <div class="keeper-conversation-item" key=${d.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${jo(d)}`}>${d.label}</span>
                  <span class=${`keeper-role-chip ${jo(d)}`}>${wm(d)}</span>
                  ${d.timestamp?a`<span class="keeper-conversation-time">${dr(d.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${d.text}</div>
                ${d.error?a`<div class="keeper-conversation-error">${d.error}</div>`:null}
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
        ${r?a`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function Nm({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=ur(e),o=Aa.value[e.name]??!1,i=Ca.value[e.name]??!1,r=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??r==="recover";return a`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{yc(e.name,t).catch(d=>{const m=d instanceof Error?d.message:`Failed to probe ${e.name}`;R(m,"error")})}}
        disabled=${o||!t.trim()}
      >
        ${o?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{bc(e.name,t).catch(d=>{const m=d instanceof Error?d.message:`Failed to recover ${e.name}`;R(m,"error")})}}
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
  `}const mo=f(null);function pr(t){mo.value=t,$c(t.name)}function Fo(){mo.value=null}const fe=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Pm(t){if(!t)return 0;const e=fe.findIndex(n=>n.level===t);return e>=0?e:0}function Dm({keeper:t}){const e=Pm(t.autonomy_level),n=fe[e]??fe[0];if(!n)return null;const s=(e+1)/fe.length*100;return a`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${fe.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${fe.map((o,i)=>a`
            <span style="width:8px; height:8px; border-radius:50%; background:${i<=e?o.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${t.autonomous_action_count??0}</strong>
      </div>
      ${t.last_autonomous_action_at?a`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${nt} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?a`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Gn(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Lm({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",o=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return a`
    <div class="keeper-kpis">
      ${o.map(i=>a`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?a`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Gn(t.context_tokens)}</div>
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
  `}function Mm({keeper:t}){var p,u;const e=t.metrics_series??[];if(e.length<2){const g=(((p=t.context)==null?void 0:p.context_ratio)??0)*100,$=g>85?"#ef4444":g>70?"#f59e0b":"#22c55e";return a`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${g.toFixed(1)}%;background:${$}"></div>
        </div>
        <span class="chart-pct">${g.toFixed(1)}%</span>
      </div>`}const n=200,s=60,o=2,i=e.length,r=e.map((g,$)=>{const x=o+$/(i-1)*(n-2*o),A=s-o-(g.context_ratio??0)*(s-2*o);return{x,y:A,p:g}}),c=r.map(({x:g,y:$})=>`${g.toFixed(1)},${$.toFixed(1)}`).join(" "),d=(((u=e[e.length-1])==null?void 0:u.context_ratio)??0)*100,m=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return a`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${o}" y1="${(s-o-.5*(s-2*o)).toFixed(1)}" x2="${n-o}" y2="${(s-o-.5*(s-2*o)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${o}" y1="${(s-o-.7*(s-2*o)).toFixed(1)}" x2="${n-o}" y2="${(s-o-.7*(s-2*o)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${o}" y1="${(s-o-.85*(s-2*o)).toFixed(1)}" x2="${n-o}" y2="${(s-o-.85*(s-2*o)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:g})=>g.is_handoff).map(({x:g})=>a`
          <line x1="${g.toFixed(1)}" y1="${o}" x2="${g.toFixed(1)}" y2="${s-o}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${m}" stroke-width="1.5"/>
        ${r.filter(({p:g})=>g.is_compaction).map(({x:g,y:$})=>a`
          <circle cx="${g.toFixed(1)}" cy="${$.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const Ys=f("");function Em({keeper:t}){var o,i,r,c;const e=Ys.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((o=t.traits)==null?void 0:o.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return a`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Ys.value}
        onInput=${d=>{Ys.value=d.target.value}}
      />
      ${s.map(d=>a`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${d.title}</span>
          <span class="keeper-field-key">${d.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${d.value}</span>
        </div>
      `)}
      ${t.trace_id?a`<div class="keeper-field-row"><span class="keeper-field-title">Trace ID</span><span class="keeper-field-key mono">${t.trace_id}</span></div>`:""}
      ${t.agent_name?a`<div class="keeper-field-row"><span class="keeper-field-title">Agent</span><span style="flex:1; text-align:right; color:#ccc;">${t.agent_name}</span></div>`:""}
      ${t.primary_model?a`<div class="keeper-field-row"><span class="keeper-field-title">Primary Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.primary_model}</span></div>`:""}
      ${t.active_model?a`<div class="keeper-field-row"><span class="keeper-field-title">Active Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.active_model}</span></div>`:""}
      ${t.next_model_hint?a`<div class="keeper-field-row"><span class="keeper-field-title">Next Model Hint</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.next_model_hint}</span></div>`:""}
      ${t.skill_primary?a`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Primary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_primary}</span></div>`:""}
      ${t.skill_secondary?a`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Secondary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_secondary}</span></div>`:""}
      ${t.skill_reason?a`<div class="keeper-field-row"><span class="keeper-field-title">Skill Reason</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_reason}</span></div>`:""}
      ${t.context_source?a`<div class="keeper-field-row"><span class="keeper-field-title">Context Source</span><span style="flex:1; text-align:right; color:#ccc;">${t.context_source}</span></div>`:""}
      ${t.context_tokens!=null?a`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Gn(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?a`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Gn(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?a`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?a`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?a`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?a`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?a`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?a`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Gn(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?a`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?a`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function zm({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return a`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(s=>a`
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
  `}function Om({items:t}){return t.length===0?a`<div class="empty-state" style="font-size:13px">No equipment</div>`:a`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>a`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function jm({rels:t}){const e=Object.entries(t);return e.length===0?a`<div class="empty-state" style="font-size:13px">No relationships</div>`:a`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>a`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function qo({traits:t,label:e}){return t.length===0?null:a`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>a`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Xs(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Fm({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Xs(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Xs(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Xs(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return a`
    <div class="keeper-signal-list">
      ${n.map(s=>a`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function mr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function qm(){try{const t=await ws({actor:mr(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=vi(t.result);await yn(),e!=null&&e.skipped_reason?R(e.skipped_reason,"warning"):R(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";R(e,"error")}}function Km({keeper:t}){return a`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Tm} keeper=${t} />
          <${Nm}
            actor=${mr()}
            keeper=${t}
            onPokeLodge=${()=>{qm()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Rm}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function Um(){var e,n,s;const t=mo.value;return t?a`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${o=>{o.target.classList.contains("keeper-detail-overlay")&&Fo()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${""}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${t.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${t.name}</h2>
              ${t.koreanName?a`<div style="font-size:13px; color:#888;">${t.koreanName}</div>`:null}
            </div>
            <${te} status=${t.status} />
            ${t.model?a`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Fo()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Lm} keeper=${t} />

        ${""}
        <${Mm} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${w} title="Field Dictionary">
            <${Em} keeper=${t} />
          <//>

          ${""}
          <${w} title="Profile">
            <${qo} traits=${t.traits??[]} label="Traits" />
            <${qo} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?a`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?a`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?a`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?a`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${nt} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?a`
              <${w} title="Autonomy">
                <${Dm} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?a`
              <${w} title="TRPG Stats">
                <${zm} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?a`
              <${w} title="Equipment (${t.inventory.length})">
                <${Om} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?a`
              <${w} title="Relationships (${Object.keys(t.relationships).length})">
                <${jm} rels=${t.relationships} />
              <//>
            `:null}

          <${w} title="Runtime Signals">
            <${Fm} keeper=${t} />
          <//>

          <${w} title="Memory & Context">
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
              ${t.memory_recent_note?a`
                  <div class="keeper-memory-note">
                    ${t.memory_recent_note}
                  </div>
                `:a`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${Km} keeper=${t} />
      </div>
    </div>
  `:null}const Hm="masc_dashboard_agent_name",ze=f(null),$s=f(!1),_n=f(""),hs=f([]),fn=f([]),Ie=f(""),Je=f(!1);function vr(t){ze.value=t,vo()}function Ko(){ze.value=null,_n.value="",hs.value=[],fn.value=[],Ie.value=""}function Wm(){const t=ze.value;return t?pe.value.find(e=>e.name===t)??null:null}function _r(t){return t?Wt.value.filter(e=>e.assignee===t):[]}async function vo(){const t=ze.value;if(t){$s.value=!0,_n.value="",hs.value=[],fn.value=[];try{const e=await Zl(80);hs.value=e.filter(o=>o.includes(t)).slice(0,20);const n=_r(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async o=>{try{const i=await tc(o.id,25);return{taskId:o.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:o.id,text:`Failed to load history: ${r}`}}}));fn.value=s}catch(e){_n.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{$s.value=!1}}}async function Uo(){var s;const t=ze.value,e=Ie.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Hm))==null?void 0:s.trim())||"dashboard";Je.value=!0;try{await Xl(n,`@${t} ${e}`),Ie.value="",R(`Mention sent to ${t}`,"success"),vo()}catch(o){const i=o instanceof Error?o.message:"Failed to send mention";R(i,"error")}finally{Je.value=!1}}function Bm({task:t}){return a`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${te} status=${t.status} />
    </div>
  `}function Gm({row:t}){return a`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Jm(){var o,i,r,c;const t=ze.value;if(!t)return null;const e=Wm(),n=_r(t),s=hs.value;return a`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&Ko()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${e!=null&&e.emoji?a`<span style="font-size:2rem">${e.emoji}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${t}
                  ${e!=null&&e.koreanName?a`<span style="font-size:0.75em;color:#888">(${e.koreanName})</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  ${e?a`
                        <${te} status=${e.status} />
                        ${e.model?a`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                        ${e.primaryValue?a`<span style="font-size:0.75rem;color:#a78bfa">${e.primaryValue}</span>`:""}
                      `:a`<span>Agent snapshot not found in current state</span>`}
                </div>
              </div>
            </div>
            ${(e==null?void 0:e.activityLevel)!=null?a`
              <div style="display:flex;align-items:center;gap:8px;font-size:0.8rem">
                <span style="color:#888">Activity</span>
                <div style="flex:1;max-width:120px;height:6px;background:#1a1a2e;border-radius:3px;overflow:hidden">
                  <div style="width:${Math.min(e.activityLevel*10,100)}%;height:100%;background:${e.activityLevel>=8?"#22c55e":e.activityLevel>=5?"#f59e0b":"#666"};border-radius:3px"></div>
                </div>
                <span style="color:#888">${e.activityLevel}/10</span>
              </div>
            `:""}
            ${(((o=e==null?void 0:e.traits)==null?void 0:o.length)??0)>0?a`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(i=e==null?void 0:e.traits)==null?void 0:i.map(d=>a`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?a`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(c=e==null?void 0:e.interests)==null?void 0:c.map(d=>a`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?a`
                    ${e.current_task?a`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?a`<span>Last seen: <${nt} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{vo()}} disabled=${$s.value}>
              ${$s.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Ko}>Close</button>
          </div>
        </div>

        ${_n.value?a`<div class="council-error">${_n.value}</div>`:null}

        <div class="agent-detail-grid">
          <${w} title="Assigned Tasks">
            ${n.length===0?a`<div class="empty-state">No assigned tasks</div>`:a`<div class="agent-detail-task-list">${n.map(d=>a`<${Bm} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${w} title="Recent Activity">
            ${s.length===0?a`<div class="empty-state">No recent room activity match</div>`:a`<div class="agent-activity-list">${s.map((d,m)=>a`<div key=${m} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${w} title="Task History">
          ${fn.value.length===0?a`<div class="empty-state">No task history loaded</div>`:a`<div class="agent-history-list">${fn.value.map(d=>a`<${Gm} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${w} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Ie.value}
              onInput=${d=>{Ie.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&Uo()}}
              disabled=${Je.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Uo()}}
              disabled=${Je.value||Ie.value.trim()===""}
            >
              ${Je.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const Qs=600*1e3,Vm=1200*1e3,Ho=.8;function Ut(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function _e(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Ym(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function Xm(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Qm(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Zm(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function tv(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function ev(t){var d,m;const e=Ic.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,s=n?Math.max(0,Date.now()-Ut(n)):Number.POSITIVE_INFINITY,o=!!((d=t.current_task)!=null&&d.trim())||e.activeAssignedCount>0;let i="watching",r="ok",c="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",c=n?"Offline or inactive":"No recent presence"):s>Vm?(i="quiet",r="bad",c=o?"Working without a fresh signal":"No fresh agent signal"):o?(i="working",r=s>Qs?"warn":"ok",c=s>Qs?"Execution looks quiet for too long":"Task and live signal aligned"):s>Qs?(i="quiet",r="warn",c="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",c="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((m=t.current_task)==null?void 0:m.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:c}}function nv(t){const e=Rc.value.get(t.name)??"idle",n=Dc.value.has(t.name),s=t.context_ratio??0;let o="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(o="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||s>=Ho)&&(o="warning",i="warn",r=s>=Ho?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:o,tone:i,focus:Zm(t),note:r}}function Ue({label:t,value:e,color:n,caption:s}){return a`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?a`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function sv({item:t}){const e=t.kind==="agent"?()=>vr(t.agent.name):()=>pr(t.keeper);return a`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?a`<span><${nt} timestamp=${t.timestamp} /></span>`:a`<span>No signal</span>`}
      </div>
    </button>
  `}function Wo({row:t}){const{agent:e,motion:n}=t;return a`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>vr(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?a`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${cr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${te} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${Ym(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?a`<span>Signal <${nt} timestamp=${t.lastSignalAt} /></span>`:a`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?a`<span>${e.model}</span>`:null}
        ${e.last_seen?a`<span>Seen <${nt} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?a`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function av({row:t}){const{keeper:e}=t;return a`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>pr(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?a`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${cr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${te} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Xm(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?a`<span>Heartbeat <${nt} timestamp=${e.last_heartbeat} /></span>`:a`<span>No heartbeat</span>`}
        <span>${tv(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${Qm(e.context_ratio)}</span>
        ${e.model?a`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?a`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function ov(){const t=[...pe.value].map(ev).sort((p,u)=>{const g=_e(u.tone)-_e(p.tone);if(g!==0)return g;const $=u.activeTaskCount-p.activeTaskCount;return $!==0?$:Ut(u.lastSignalAt)-Ut(p.lastSignalAt)}),e=[...De.value].map(nv).sort((p,u)=>{const g=_e(u.tone)-_e(p.tone);if(g!==0)return g;const $=(u.keeper.context_ratio??0)-(p.keeper.context_ratio??0);return $!==0?$:Ut(u.keeper.last_heartbeat)-Ut(p.keeper.last_heartbeat)}),n=t.filter(p=>p.state!=="offline"),s=t.filter(p=>p.state==="offline"),o=n.length,i=t.filter(p=>p.state==="working").length,r=t.filter(p=>p.lastSignalAt&&Date.now()-Ut(p.lastSignalAt)<=12e4).length,c=t.filter(p=>p.tone!=="ok"),d=e.filter(p=>p.tone!=="ok"),m=[...d.map(p=>({kind:"keeper",key:`keeper-${p.keeper.name}`,tone:p.tone,title:p.keeper.name,subtitle:`${p.note} · ${p.focus}`,timestamp:p.keeper.last_heartbeat??null,keeper:p.keeper})),...c.map(p=>({kind:"agent",key:`agent-${p.agent.name}`,tone:p.tone,title:p.agent.name,subtitle:`${p.note} · ${p.focus}`,timestamp:p.lastSignalAt,agent:p.agent}))].sort((p,u)=>{const g=_e(u.tone)-_e(p.tone);return g!==0?g:Ut(u.timestamp)-Ut(p.timestamp)}).slice(0,8);return a`
    <div class="agents-monitor">
      <${ht} surfaceId="execution" />
      <div class="stats-grid">
        <${Ue} label="Workers online" value=${o} color="#4ade80" caption="활성 + 대기 실행 actor" />
        <${Ue} label="Working now" value=${i} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${Ue} label="Fresh signals" value=${r} color="#22d3ee" caption="최근 2분 이내 신호" />
        <${Ue} label="Worker alerts" value=${c.length} color=${c.length>0?"#fb7185":"#4ade80"} caption="실행 actor 경고" />
        <${Ue} label="Continuity alerts" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="keeper 연속성 경고" />
      </div>

      <${w} title="Execution Priorities" class="section" semanticId="execution.priority_queue">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs execution attention right now</h2>
          <p class="monitor-subheadline">Worker drift and keeper continuity risk are ranked together here, but diagnosed in separate sections below.</p>
        </div>
        <div class="monitor-alert-list">
          ${m.length===0?a`<div class="empty-state">No execution alerts right now</div>`:m.map(p=>a`<${sv} key=${p.key} item=${p} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${w} title="Workers" class="section" semanticId="execution.workers">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Live workers stay grouped here so owner drift is visible before you scan offline history.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?a`<div class="empty-state">No active workers visible</div>`:n.map(p=>a`<${Wo} key=${p.agent.name} row=${p} />`)}
          </div>
        <//>

        <${w} title="Continuity" class="section" semanticId="execution.continuity">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper continuity</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and handoff state are isolated from worker execution drift.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?a`<div class="empty-state">No keepers active</div>`:e.map(p=>a`<${av} key=${p.keeper.name} row=${p} />`)}
          </div>
        <//>

        <${w} title="Offline Workers" class="section" semanticId="execution.offline">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who dropped out of the live loop</h2>
            <p class="monitor-subheadline">Offline rows stay separate so they do not drown the active execution monitor.</p>
          </div>
          <div class="monitor-list">
            ${s.length===0?a`<div class="empty-state">No offline workers right now</div>`:s.map(p=>a`<${Wo} key=${p.agent.name} row=${p} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const ys=f("all"),bs=f("all"),Ha=Qt(()=>{let t=en.value;return ys.value!=="all"&&(t=t.filter(e=>e.horizon===ys.value)),bs.value!=="all"&&(t=t.filter(e=>e.status===bs.value)),t}),iv=Qt(()=>{const t={short:[],mid:[],long:[]};for(const e of Ha.value){const n=t[e.horizon];n&&n.push(e)}return t}),rv=Qt(()=>{const t=Array.from($i.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function lv(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function _o(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function Jn(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function cv(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Bo(t){return t.toFixed(4)}function Go(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function dv({goal:t}){return a`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${Jn(t.horizon)}">
            ${_o(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${lv(t.priority)}</span>
          ${t.metric?a`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?a`<span class="goal-due">Due: <${nt} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?a`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${te} status=${t.status} />
        <div class="goal-updated">
          <${nt} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Jo({label:t,timestamp:e,source:n,note:s}){return a`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${s?a`<div class="planning-freshness-source">${s}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?a`<${nt} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function Zs({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,o)=>o.priority-s.priority);return a`
    <${w} title="${_o(t)} Goals (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>a`<${dv} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function uv(){return a`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>a`
          <button
            class="goal-filter-btn ${ys.value===t?"active":""}"
            onClick=${()=>{ys.value=t}}
          >
            ${t==="all"?"All":_o(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>a`
          <button
            class="goal-filter-btn ${bs.value===t?"active":""}"
            onClick=${()=>{bs.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function pv(){const t=en.value,e=t.filter(o=>o.status==="active").length,n=t.filter(o=>o.status==="completed").length,s={short:0,mid:0,long:0};for(const o of t)o.horizon in s&&s[o.horizon]++;return a`
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
        <div class="goal-summary-value" style="color:${Jn("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Jn("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Jn("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function mv({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return a`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${te} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Bo(t.baseline_metric)}</span>
          <span>Current ${Bo(t.current_metric)}</span>
          <span class=${Go(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Go(t)}
          </span>
          <span>Elapsed ${cv(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"No explicit target provided"}</div>
        ${t.stop_reason||t.error_message?a`
              <div class="planning-loop-footnote">
                ${t.error_message??t.stop_reason}
              </div>
            `:null}
        <div class="planning-loop-footnote">
          ${t.strict_mode?"Strict hard evidence":"Legacy"} · ${t.worker_engine??"unknown engine"} · ${n}
        </div>
        ${e?a`
              <div class="planning-loop-footnote">
                Latest iteration #${e.iteration}: ${e.changes||e.next_suggestion||"No narrative"}
              </div>
            `:a`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function ta({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return a`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?a`<${nt} timestamp=${t.created_at} />`:a`<span>-</span>`}
        ${t.assignee?a`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function vv(){const{todo:t,inProgress:e,done:n}=wc.value;return a`
    <${w} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?a`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>a`<${ta} key=${s.id} task=${s} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?a`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>a`<${ta} key=${s.id} task=${s} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?a`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>a`<${ta} key=${s.id} task=${s} />`)}
          ${n.length>20?a`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function _v(){const t=iv.value,e=rv.value,n=e.filter(c=>c.status==="running").length,s=e.filter(c=>c.recoverable).length,o=en.value.filter(c=>c.status==="active").length,i=to.value,r=i==="idle"?"No loop running":i==="error"?Zn.value??"MDAL snapshot unavailable":"Current loop snapshot";return a`
    <div>
      <${ht} surfaceId="planning" />
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${o}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${Ha.value.length}</div>
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

      <${w} title="Planning Surface" class="section" semanticId="planning.surface">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Planning refresh reads a dedicated projection so goals, loops, and backlog pressure stay in one surface.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${Te} disabled=${ye.value}>
              ${ye.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${La} disabled=${be.value}>
              ${be.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{Te(),La()}}
              disabled=${ye.value||be.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${Jo} label="Goals" timestamp=${yi.value} source="/api/v1/dashboard/planning" />
          <${Jo}
            label="MDAL loops"
            timestamp=${bi.value}
            source="/api/v1/dashboard/planning"
            note=${r}
          />
        </div>
      <//>

      <${w} title="Goal Pipeline" class="section" semanticId="planning.goal_pipeline">
        <${pv} />
        <${uv} />
      <//>

      ${ye.value&&en.value.length===0?a`<div class="loading-indicator">Loading goals...</div>`:Ha.value.length===0?a`<div class="empty-state">No goals match the current filters</div>`:a`
              <${Zs} horizon="short" items=${t.short??[]} />
              <${Zs} horizon="mid" items=${t.mid??[]} />
              <${Zs} horizon="long" items=${t.long??[]} />
            `}

      <${w} title="MDAL Loops" class="section" semanticId="planning.mdal_loops">
        ${be.value&&e.length===0?a`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&i==="error"?a`
                <div class="empty-state">
                  MDAL snapshot could not be loaded right now. Check the backend tool contract or runtime health.
                </div>
              `:e.length===0&&i==="idle"?a`
                <div class="empty-state">
                  No loop is running right now. This section wakes up when <code>masc_mdal_start</code> exposes a live loop.
                </div>
              `:e.length===0?a`
                  <div class="empty-state">
                    No loop snapshot is visible yet. Refresh once the backend has reported a planning loop.
                  </div>
                `:a`
                <div class="planning-loop-list">
                  ${e.map(c=>a`<${mv} key=${c.loop_id} loop=${c} />`)}
                </div>
              `}
      <//>

      <${vv} />
    </div>
  `}const Ve=f("debates"),ks=f([]),xs=f([]),Ss=f(!1),Ye=f(!1),gn=f(""),Xe=f(""),As=f(null),xt=f(null),Wa=f(!1);async function qs(){Ss.value=!0,gn.value="";try{const t=await cl();ks.value=Array.isArray(t.debates)?t.debates:[],xs.value=Array.isArray(t.sessions)?t.sessions:[]}catch(t){gn.value=t instanceof Error?t.message:"Failed to load governance state"}finally{Ss.value=!1}}Gc(qs);async function Vo(){const t=Xe.value.trim();if(t){Ye.value=!0;try{const e=await ec(t);Xe.value="",R(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await qs()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";R(n,"error")}finally{Ye.value=!1}}}async function fv(t){As.value=t,xt.value=null,Wa.value=!0;try{xt.value=await nc(t)}catch(e){gn.value=e instanceof Error?e.message:"Failed to load debate detail"}finally{Wa.value=!1}}function gv(){return a`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${ks.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Voting sessions</span>
        <strong>${xs.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Active view</span>
        <strong>${Ve.value==="debates"?"Debates":"Voting"}</strong>
      </div>
    </div>
  `}function $v({debate:t}){const e=As.value===t.id;return a`
    <button class="council-row ${e?"selected":""}" onClick=${()=>fv(t.id)}>
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Arguments: ${t.argument_count}</span>
          ${t.created_at?a`<span><${nt} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </button>
  `}function hv({session:t}){return a`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.created_at?a`<span><${nt} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function yv(){const t=Ve.value;return a`
    <div class="overview-sub-tabs" style="margin-bottom:12px;">
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{Ve.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{Ve.value="voting"}}>Voting</button>
    </div>
  `}function bv(){return a`
    <div>
      <${w} title="Start Debate" class="section" semanticId="governance.debates">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Xe.value}
            onInput=${t=>{Xe.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&Vo()}}
            disabled=${Ye.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Vo}
            disabled=${Ye.value||Xe.value.trim()===""}
          >
            ${Ye.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${qs} disabled=${Ss.value}>
            ${Ss.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${gn.value?a`<div class="council-error">${gn.value}</div>`:null}
      <//>

      <${w} title="Debates" class="section" semanticId="governance.debates">
        <div class="council-list">
          ${ks.value.length===0?a`<div class="empty-state">No debates yet</div>`:ks.value.map(t=>a`<${$v} key=${t.id} debate=${t} />`)}
        </div>
      <//>

      <${w} title=${As.value?`Debate Detail (${As.value})`:"Debate Detail"} class="section" semanticId="governance.debates">
        ${Wa.value?a`<div class="loading-indicator">Loading debate detail...</div>`:xt.value?a`
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Status: ${xt.value.status}</span>
                  <span>Total arguments: ${xt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Support: ${xt.value.support_count}</span>
                  <span>Oppose: ${xt.value.oppose_count}</span>
                  <span>Neutral: ${xt.value.neutral_count}</span>
                </div>
                ${xt.value.summary_text?a`<pre class="council-detail">${xt.value.summary_text}</pre>`:null}
              `:a`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function kv(){return a`
    <${w} title="Voting Sessions" class="section" semanticId="governance.voting">
      <div class="council-list">
        ${xs.value.length===0?a`<div class="empty-state">No active sessions</div>`:xs.value.map(t=>a`<${hv} key=${t.id} session=${t} />`)}
      </div>
    <//>
  `}function xv(){return ct(()=>{qs()},[]),a`
    <div>
      <${ht} surfaceId="governance" />
      <${gv} />
      <${yv} />
      ${Ve.value==="debates"?a`<${bv} />`:a`<${kv} />`}
    </div>
  `}const ge=f(""),ea=f("ability_check"),na=f("10"),sa=f("12"),Ln=f(""),Mn=f("idle"),Ht=f(""),En=f("keeper-late"),aa=f("player"),oa=f(""),gt=f("idle"),ia=f(null),zn=f(""),ra=f(""),la=f("player"),ca=f(""),da=f(""),ua=f(""),Qe=f("20"),pa=f("20"),ma=f(""),On=f("idle"),Ba=f(null),fr=f("overview"),va=f("all"),_a=f("all"),fa=f("all"),Sv=12e4,Ks=f(null),Yo=f(Date.now());function Av(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Cv(t,e){return e>0?Math.round(t/e*100):0}const wv={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Iv={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function jn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Tv(t){const e=t.trim().toLowerCase();return wv[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Rv(t){const e=t.trim().toLowerCase();return Iv[e]??"상황에 따라 선택되는 전술 액션입니다."}function Vt(t){return typeof t=="object"&&t!==null}function mt(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function St(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function $n(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const Nv=new Set(["str","dex","con","int","wis","cha"]);function Pv(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(o){throw new Error(`능력치 JSON 파싱 실패: ${o instanceof Error?o.message:"invalid json"}`)}if(!Vt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([o,i])=>{const r=o.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){s[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const c=Number.parseFloat(i.trim());if(Number.isFinite(c)){s[r]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),s}function Dv(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(Qe.value.trim(),10);Number.isFinite(s)&&s>n&&(Qe.value=String(n))}function Ga(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Lv(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Mv(t){fr.value=t}function gr(t){const e=Ks.value;return e==null||e<=t}function Ev(t){const e=Ks.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Cs(){Ks.value=null}function $r(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function zv(t,e){$r(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Ks.value=Date.now()+Sv,R("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function Vn(t){return gr(t)?(R("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Ja(t,e,n){return $r([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Ov({hp:t,max:e}){const n=Cv(t,e),s=Av(t,e);return a`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function jv({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return a`
    <div class="trpg-actor-stats">
      ${e.map(n=>a`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Fv({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return a`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function hr({actor:t}){var d,m,p,u;const e=(d=t.archetype)==null?void 0:d.trim(),n=(m=t.persona)==null?void 0:m.trim(),s=(p=t.portrait)==null?void 0:p.trim(),o=(u=t.background)==null?void 0:u.trim(),i=t.traits??[],r=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([g,$])=>Number.isFinite($)).filter(([g])=>!Nv.has(g.toLowerCase()));return a`
    <div class="trpg-actor">
      ${s?a`
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
        <${te} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Fv} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?a`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?a`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Ov} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${jv} stats=${t.stats} />
          </div>
        `:null}
      ${e?a`<div class="trpg-actor-meta">Archetype: ${jn(e)}</div>`:null}
      ${o?a`<div class="trpg-actor-meta">Background: ${o}</div>`:null}
      ${n?a`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?a`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([g,$])=>a`
                <span class="trpg-custom-stat-chip">${jn(g)} ${$}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?a`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(g=>a`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${jn(g)}</span>
                  <span class="trpg-annot-desc">${Tv(g)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?a`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(g=>a`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${jn(g)}</span>
                  <span class="trpg-annot-desc">${Rv(g)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function qv({mapStr:t}){return a`<pre class="trpg-map">${t}</pre>`}function yr({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?a`<div class="empty-state" style="font-size:13px">${e}</div>`:a`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var o;return a`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Lv(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Ga(n)}</strong>
            ${" "}
          ${n.dice_roll?a`<span class="trpg-dice">[${n.dice_roll.notation}: ${(o=n.dice_roll.rolls)==null?void 0:o.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${nt} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Kv({events:t}){const e="__none__",n=va.value,s=_a.value,o=fa.value,i=Array.from(new Set(t.map(Ga).map(u=>u.trim()).filter(u=>u!==""))).sort((u,g)=>u.localeCompare(g)),r=Array.from(new Set(t.map(u=>(u.type??"").trim()).filter(u=>u!==""))).sort((u,g)=>u.localeCompare(g)),c=t.some(u=>(u.type??"").trim()===""),d=Array.from(new Set(t.map(u=>(u.phase??"").trim()).filter(u=>u!==""))).sort((u,g)=>u.localeCompare(g)),m=t.some(u=>(u.phase??"").trim()===""),p=t.filter(u=>{if(n!=="all"&&Ga(u)!==n)return!1;const g=(u.type??"").trim(),$=(u.phase??"").trim();if(s===e){if(g!=="")return!1}else if(s!=="all"&&g!==s)return!1;if(o===e){if($!=="")return!1}else if(o!=="all"&&$!==o)return!1;return!0});return a`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${u=>{va.value=u.target.value}}>
          <option value="all">all</option>
          ${i.map(u=>a`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${u=>{_a.value=u.target.value}}>
          <option value="all">all</option>
          ${c?a`<option value=${e}>(none)</option>`:null}
          ${r.map(u=>a`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${o} onChange=${u=>{fa.value=u.target.value}}>
          <option value="all">all</option>
          ${m?a`<option value=${e}>(none)</option>`:null}
          ${d.map(u=>a`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{va.value="all",_a.value="all",fa.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${p.length} / 전체 ${t.length}
      </span>
    </div>
    <${yr} events=${p.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Uv({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",o=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return a`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?a`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${o?a`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${o}</div>`:null}
    </div>
  `}function br({state:t}){const e=t.history??[];return e.length===0?null:a`
    <div class="trpg-round-list">
      ${e.slice(-10).map(n=>a`
        <div class="trpg-round-item ${n.status}">
          <span>Session ${n.id.slice(0,8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${n.round} — ${n.status}
          </span>
        </div>
      `)}
    </div>
  `}function Hv({state:t,nowMs:e}){var m;const n=Mt.value||((m=t.session)==null?void 0:m.room)||"",s=Mn.value,o=t.party??[];if(!o.find(p=>p.id===ge.value)&&o.length>0){const p=o[0];p&&(ge.value=p.id)}const r=async()=>{var u,g;if(!n){R("Room ID가 비어 있습니다.","error");return}if(!Vn(e))return;const p=((u=t.current_round)==null?void 0:u.phase)??((g=t.session)==null?void 0:g.status)??"unknown";if(Ja("라운드 실행",n,p)){Mn.value="running";try{const $=await Ul(n);Ba.value=$,Mn.value="ok";const x=Vt($.summary)?$.summary:null,A=x?$n(x,"advanced",!1):!1,I=x?mt(x,"progress_reason",""):"";R(A?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${I?`: ${I}`:""}`,A?"success":"warning"),Tt()}catch($){Ba.value=null,Mn.value="error";const x=$ instanceof Error?$.message:"라운드 실행에 실패했습니다.";R(x,"error")}finally{Cs()}}},c=async()=>{var u,g;if(!n||!Vn(e))return;const p=((u=t.current_round)==null?void 0:u.phase)??((g=t.session)==null?void 0:g.status)??"unknown";if(Ja("턴 강제 진행",n,p))try{await Bl(n),R("턴을 다음 단계로 이동했습니다.","success"),Tt()}catch{R("턴 이동에 실패했습니다.","error")}finally{Cs()}},d=async()=>{if(!n||!Vn(e))return;const p=ge.value.trim();if(!p){R("먼저 Actor를 선택하세요.","warning");return}const u=Number.parseInt(na.value,10),g=Number.parseInt(sa.value,10);if(Number.isNaN(u)||Number.isNaN(g)){R("stat/dc는 숫자여야 합니다.","warning");return}const $=Number.parseInt(Ln.value,10),x=Ln.value.trim()===""||Number.isNaN($)?void 0:$;try{await Wl({roomId:n,actorId:p,action:ea.value.trim()||"ability_check",statValue:u,dc:g,rawD20:x}),R("주사위 판정을 기록했습니다.","success"),Tt()}catch{R("주사위 판정 기록에 실패했습니다.","error")}};return a`
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
            value=${ge.value}
            onChange=${p=>{ge.value=p.target.value}}
          >
            <option value="">Actor 선택</option>
            ${o.map(p=>a`<option value=${p.id}>${p.name} (${p.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${ea.value}
              onInput=${p=>{ea.value=p.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${na.value}
              onInput=${p=>{na.value=p.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${sa.value}
              onInput=${p=>{sa.value=p.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Ln.value}
              onInput=${p=>{Ln.value=p.target.value}}
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

      ${s!=="idle"?a`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function Wv({state:t}){var o;const e=Mt.value||((o=t.session)==null?void 0:o.room)||"",n=On.value,s=async()=>{if(!e){R("Room ID가 비어 있습니다.","warning");return}const i=zn.value.trim(),r=ra.value.trim();if(!r&&!i){R("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(Qe.value.trim(),10),d=Number.parseInt(pa.value.trim(),10),m=Number.isFinite(d)?Math.max(1,d):20,p=Number.isFinite(c)?Math.max(0,Math.min(m,c)):m;let u={};try{u=Pv(ma.value)}catch(g){R(g instanceof Error?g.message:"능력치 JSON 오류","error");return}On.value="spawning";try{const g=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,$=await Gl(e,{actor_id:i||void 0,name:r||void 0,role:la.value,idempotencyKey:g,portrait:da.value.trim()||void 0,background:ua.value.trim()||void 0,hp:p,max_hp:m,alive:p>0,stats:Object.keys(u).length>0?u:void 0}),x=typeof $.actor_id=="string"?$.actor_id.trim():"";if(!x)throw new Error("생성 응답에 actor_id가 없습니다.");const A=ca.value.trim();A&&await Jl(e,x,A),ge.value=x,Ht.value=x,i||(zn.value=""),On.value="ok",R(`Actor 생성 완료: ${x}`,"success"),await Tt()}catch(g){On.value="error",R(g instanceof Error?g.message:"Actor 생성에 실패했습니다.","error")}};return a`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${ra.value}
            onInput=${i=>{ra.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${la.value}
            onChange=${i=>{la.value=i.target.value}}
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
            value=${ca.value}
            onInput=${i=>{ca.value=i.target.value}}
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
              value=${zn.value}
              onInput=${i=>{zn.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${da.value}
              onInput=${i=>{da.value=i.target.value}}
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
              value=${Qe.value}
              onInput=${i=>{Qe.value=i.target.value}}
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
              value=${pa.value}
              onInput=${i=>{const r=i.target.value;pa.value=r,Dv(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${ua.value}
              onInput=${i=>{ua.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${ma.value}
              onInput=${i=>{ma.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?a`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Bv({state:t,nowMs:e}){var g;const n=Mt.value||((g=t.session)==null?void 0:g.room)||"",s=t.join_gate,o=ia.value,i=Vt(o)?o:null,r=(t.party??[]).filter($=>$.role!=="dm"),c=Ht.value.trim(),d=r.some($=>$.id===c),m=d?c:c?"__manual__":"",p=async()=>{const $=Ht.value.trim(),x=En.value.trim();if(!n||!$){R("Room/Actor가 필요합니다.","warning");return}gt.value="checking";try{const A=await Vl(n,$,x||void 0);ia.value=A,gt.value="ok",R("참가 가능 여부를 갱신했습니다.","success")}catch(A){gt.value="error";const I=A instanceof Error?A.message:"참가 가능 여부 확인에 실패했습니다.";R(I,"error")}},u=async()=>{var D,q;const $=Ht.value.trim(),x=En.value.trim(),A=oa.value.trim();if(!n||!$||!x){R("Room/Actor/Keeper가 필요합니다.","warning");return}if(!Vn(e))return;const I=((D=t.current_round)==null?void 0:D.phase)??((q=t.session)==null?void 0:q.status)??"unknown";if(Ja("Mid-Join 승인 요청",n,I)){gt.value="requesting";try{const L=await Yl({room_id:n,actor_id:$,keeper_name:x,role:aa.value,...A?{name:A}:{}});ia.value=L;const T=Vt(L)?$n(L,"granted",!1):!1,N=Vt(L)?mt(L,"reason_code",""):"";T?R("Mid-Join이 승인되었습니다.","success"):R(`Mid-Join이 거절되었습니다${N?`: ${N}`:""}`,"warning"),gt.value=T?"ok":"error",Tt()}catch(L){gt.value="error";const T=L instanceof Error?L.message:"Mid-Join 요청에 실패했습니다.";R(T,"error")}finally{Cs()}}};return a`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${s!=null&&s.phase_open?"OPEN":"CLOSED"}</strong>
        ${s!=null&&s.window?a`<span style="margin-left:8px;">(${s.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(s==null?void 0:s.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <select
            value=${m}
            onChange=${$=>{const x=$.target.value;if(x==="__manual__"){(d||!c)&&(Ht.value="");return}Ht.value=x}}
          >
            <option value="">Actor 선택</option>
            ${r.map($=>a`
              <option value=${$.id}>${$.name} (${$.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${m==="__manual__"?a`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${Ht.value}
                onInput=${$=>{Ht.value=$.target.value}}
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
            value=${En.value}
            onInput=${$=>{En.value=$.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${aa.value}
            onChange=${$=>{aa.value=$.target.value}}
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
            value=${oa.value}
            onInput=${$=>{oa.value=$.target.value}}
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
      ${i?a`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${$n(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${St(i,"effective_score",0)}/${St(i,"required_points",0)}</span>
            ${mt(i,"reason_code","")?a`<span style="margin-left:8px;">Reason: ${mt(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function kr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?a`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:a`
    <div class="trpg-round-list">
      ${e.map(n=>a`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?a`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function xr({state:t}){var n;const e=t.current_round;return e?a`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?a`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Sr(){const t=Ba.value;if(!t)return a`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=Vt(e)?e:null,o=(Array.isArray(t.statuses)?t.statuses:[]).filter(Vt).slice(-8),i=t.canon_check,r=Vt(i)?i:null,c=r&&Array.isArray(r.warnings)?r.warnings.filter(N=>typeof N=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(N=>typeof N=="string").slice(0,3):[],m=n?$n(n,"advanced",!1):!1,p=n?mt(n,"progress_reason",""):"",u=n?mt(n,"progress_detail",""):"",g=n?St(n,"player_successes",0):0,$=n?St(n,"player_required_successes",0):0,x=n?$n(n,"dm_success",!1):!1,A=n?St(n,"timeouts",0):0,I=n?St(n,"unavailable",0):0,D=n?St(n,"reprompts",0):0,q=n?St(n,"npc_attacks",0):0,L=n?St(n,"keeper_timeout_sec",0):0,T=n?St(n,"roll_audit_count",0):0;return a`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${m?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${m?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${x?"DM ok":"DM stalled"} / players ${g}/${$}
          </span>
        </div>
        ${p?a`<div style="margin-top:4px; font-size:12px;">${p}</div>`:null}
        ${u?a`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${u}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${I}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${D}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${q}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${L||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${T}</div></div>
      </div>

      ${o.length>0?a`
          <div class="trpg-round-list">
            ${o.map(N=>{const V=mt(N,"status","unknown"),B=mt(N,"actor_id","-"),v=mt(N,"role","-"),F=mt(N,"reason",""),Z=mt(N,"action_type",""),W=mt(N,"reply","");return a`
                <div class="trpg-round-item ${V.includes("fallback")||V.includes("timeout")?"failed":"active"}">
                  <span>${B} (${v})</span>
                  <span style="margin-left:auto; font-size:11px;">${V}</span>
                  ${Z?a`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${Z}</div>`:null}
                  ${F?a`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${F}</div>`:null}
                  ${W?a`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${W.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?a`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${mt(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?a`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(N=>a`<div>violation: ${N}</div>`)}
                </div>`:null}
            ${c.length>0?a`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(N=>a`<div>warning: ${N}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Gv({state:t,nowMs:e}){var r,c,d;const n=Mt.value||((r=t.session)==null?void 0:r.room)||"",s=((c=t.current_round)==null?void 0:c.phase)??((d=t.session)==null?void 0:d.status)??"unknown",o=gr(e),i=Ev(e);return a`
    <${w} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="lab.trpg">
      <div class="trpg-control-lock ${o?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${o?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${o?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${o?a`<button class="trpg-run-btn recommend" onClick=${()=>zv(n,s)}>잠금 해제 (120초)</button>`:a`<button class="trpg-run-btn secondary" onClick=${()=>{Cs(),R("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Jv({active:t}){return a`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>a`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Mv(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Vv({state:t}){const e=t.party??[],n=t.story_log??[];return a`
    <div class="trpg-layout">
      <div>
        <${w} title="관전 가이드" semanticId="lab.trpg">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${w} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${yr} events=${n.slice(-20)} />
        <//>

        ${t.map?a`
            <${w} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${qv} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${w} title="현재 라운드" semanticId="lab.trpg">
          <${xr} state=${t} />
        <//>

        <${w} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${kr} state=${t} />
        <//>

        <${w} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>a`<${hr} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?a`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?a`
            <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${br} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Yv({state:t}){const e=t.story_log??[];return a`
    <div class="trpg-layout">
      <div>
        <${w} title=${`이벤트 타임라인 (${e.length})`}>
          <${Kv} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${w} title="최근 라운드 결과" semanticId="lab.trpg">
          <${Sr} />
        <//>

        <${w} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${xr} state=${t} />
        <//>
      </div>
    </div>
  `}function Xv({state:t,nowMs:e}){const n=t.party??[];return a`
    <div>
      <${Gv} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${w} title="조작 패널" semanticId="lab.trpg">
            <${Hv} state=${t} nowMs=${e} />
          <//>

          <${w} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${Wv} state=${t} />
          <//>

          <${w} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${Bv} state=${t} nowMs=${e} />
          <//>

          <${w} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${Sr} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${w} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${kr} state=${t} />
          <//>

          <${w} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>a`<${hr} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?a`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?a`
              <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${br} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Qv(){var c,d,m,p,u;const t=gi.value,e=Na.value;if(ct(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const g=window.setInterval(()=>{Yo.value=Date.now()},1e3);return()=>{window.clearInterval(g)}},[]),e&&!t)return a`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return a`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Tt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],o=t.outcome,i=fr.value,r=Yo.value;return a`
    <div>
      <${ht} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Mt.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((m=t.session)==null?void 0:m.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Tt()}>새로고침</button>
      </div>

      <${Uv} outcome=${o} />

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

      <${Jv} active=${i} />

      ${i==="overview"?a`<${Vv} state=${t} />`:i==="timeline"?a`<${Yv} state=${t} />`:a`<${Xv} state=${t} nowMs=${r} />`}
    </div>
  `}function Zv(){return a`
    <div>
      <${ht} surfaceId="lab" />
      <${w} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${w} title="TRPG" class="section" semanticId="lab.trpg">
        <${Qv} />
      <//>
    </div>
  `}const Xo=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],Va=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}];function t_(){const t=ue.value;return a`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Ya.value} events</span>
    </div>
  `}function e_({currentTab:t,currentSectionLabel:e}){const n=ue.value;return a`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>Snapshot</h3>
        <${z} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${n?"ok":"bad"}">${n?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agents</span>
          <strong>${pe.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keepers</span>
          <strong>${De.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Tasks</span>
          <strong>${Wt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Events</span>
          <strong>${Ya.value}</strong>
        </div>
      </div>
      <div class="rail-snapshot-copy">
        <span>Connection ${n?"healthy":"recovering"}</span>
        <span>${e} workspace active</span>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{yn(),Si(),t==="command"&&(de(),Bt(),_t.value==="swarm"&&Lt()),t==="mission"&&Hn(),t==="execution"&&Pt(),t==="intervene"&&(Xt(),jt()),t==="memory"&&It(),t==="planning"&&Te(),t==="lab"&&Tt()}}
        >
          Refresh Now
        </button>
        <button class="rail-secondary-btn" onClick=${()=>$t("intervene")}>
          Open Intervene
        </button>
      </div>
    </section>
  `}function n_(){const t=Me.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return a`
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
          onClick=${()=>{Xt(),jt()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>$t("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function s_(){const t=M.value.tab,e=Va.find(s=>s.id===t),n=Xo.find(s=>s.id===(e==null?void 0:e.group));return a`
    <aside class="dashboard-rail">
      <${ht} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          <${z} panelId="side_rail.navigate" compact=${!0} />
          ${n?a`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${Xo.map(s=>a`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${Va.filter(o=>o.group===s.id).map(o=>a`
                  <button
                    class="rail-tab-btn ${t===o.id?"active":""}"
                    onClick=${()=>$t(o.id)}
                  >
                    <span class="rail-tab-icon">${o.icon}</span>
                    <span class="rail-tab-copy">
                      <strong>${o.label}</strong>
                      <span>${o.description}</span>
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

      <${e_} currentTab=${t} currentSectionLabel=${(n==null?void 0:n.label)??"Observe"} />
      <${n_} />
    </aside>
  `}function a_(){switch(M.value.tab){case"mission":return a`<${Co} />`;case"execution":return a`<${ov} />`;case"memory":return a`<${Sm} />`;case"governance":return a`<${xv} />`;case"planning":return a`<${_v} />`;case"intervene":return a`<${pm} />`;case"command":return a`<${Lp} />`;case"lab":return a`<${Zv} />`;default:return a`<${Co} />`}}function o_(){ct(()=>{Kr(),oi(),Ai(),Pt(),Si(),Hn();const n=Yc();return Xc(),()=>{Yr(),n(),Qc()}},[]),ct(()=>{const n=setInterval(()=>{const s=M.value.tab;s==="command"?(de(),Bt(),_t.value==="swarm"&&Lt()):s==="mission"?Hn():s==="execution"?Pt():s==="intervene"?(Xt(),jt()):s==="memory"?It():s==="planning"?Te():s==="lab"&&Tt()},15e3);return()=>{clearInterval(n)}},[]),ct(()=>{const n=M.value.tab;n==="command"&&(de(),Bt(),_t.value==="swarm"&&Lt()),n==="mission"&&Hn(),n==="execution"&&Pt(),n==="intervene"&&(Xt(),jt()),n==="memory"&&It(),n==="planning"&&Te(),n==="lab"&&Tt()},[M.value.tab]);const t=M.value.tab,e=Va.find(n=>n.id===t);return a`
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
          <${t_} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${s_} />
        <main class="dashboard-main">
          ${Ra.value&&!ue.value?a`<div class="loading-indicator">Loading dashboard...</div>`:a`<${a_} />`}
        </main>
      </div>

      <${Um} />
      <${Jm} />
      <${zp} />
    </div>
  `}const Qo=document.getElementById("app");Qo&&zr(a`<${o_} />`,Qo);export{wd as _};
