var ml=Object.defineProperty;var vl=(t,e,n)=>e in t?ml(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Pe=(t,e,n)=>vl(t,typeof e!="symbol"?e+"":e,n);import{e as _l,_ as fl,c as _,b as Tt,y as lt,d as No,A as gl,G as $l}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const r of o.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=_l.bind(fl);const hl=["mission","execution","live","memory","governance","planning","intervene","command","lab"],Po={tab:"mission",params:{},postId:null};function Hi(t){return!!t&&hl.includes(t)}function Wa(t){try{return decodeURIComponent(t)}catch{return t}}function Ba(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function yl(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Lo(t,e){if(t[0]==="chains"){const o={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(o.operation=Wa(t[2])),{tab:"command",params:o,postId:null}}if(t[0]==="lab"){const o={...e};return t[1]&&(o.surface=Wa(t[1])),{tab:"lab",params:o,postId:null}}const n=t[0],s=e.tab;return{tab:Hi(n)?n:Hi(s)?s:"mission",params:e,postId:null}}function Is(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Po;const n=Wa(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const l=n.indexOf("?");l>=0&&(s=n.slice(0,l),a=n.slice(l+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=Ba(a),r=yl(s);return Lo(r,o)}function bl(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Po,params:Ba(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Ba(e.replace(/^\?/,""));return Lo(s,a)}function Mo(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const F=_(Is(window.location.hash));window.addEventListener("hashchange",()=>{F.value=Is(window.location.hash)});function $t(t,e){const n={tab:t,params:e??{}};window.location.hash=Mo(n)}function kl(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function xl(){if(window.location.hash&&window.location.hash!=="#"){F.value=Is(window.location.hash);return}const t=bl(window.location.pathname,window.location.search);if(t){F.value=t;const e=Mo(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",F.value=Is(window.location.hash)}const Wi="masc_dashboard_sse_session_id",Sl=1e3,Al=15e3,ue=_(!1),oa=_(0),Do=_(null),Rs=_([]);function Cl(){let t=sessionStorage.getItem(Wi);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Wi,t)),t}const wl=200;function Tl(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};Rs.value=[a,...Rs.value].slice(0,wl)}function Ga(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Bi(t,e){const n=Ga(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function At(t,e,n,s,a={}){Tl(t,e,n,{eventType:s,...a})}let Mt=null,Ke=null,Ja=0;function zo(){Ke&&(clearTimeout(Ke),Ke=null)}function Il(){if(Ke)return;Ja++;const t=Math.min(Ja,5),e=Math.min(Al,Sl*Math.pow(2,t));Ke=setTimeout(()=>{Ke=null,Eo()},e)}function Eo(){zo(),Mt&&(Mt.close(),Mt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Cl());const a=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(a);Mt=o,o.onopen=()=>{Mt===o&&(Ja=0,ue.value=!0)},o.onerror=()=>{Mt===o&&(ue.value=!1,o.close(),Mt=null,Il())},o.onmessage=r=>{try{const l=JSON.parse(r.data);oa.value++,Do.value=l,Rl(l)}catch{}}}function Rl(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":At(n,"Joined","system","agent_joined");break;case"agent_left":At(n,"Left","system","agent_left");break;case"broadcast":At(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":At(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":At(n,Bi("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Ga(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":At(n,Bi("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Ga(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":At(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":At(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":At(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":At(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:At(n,e,"system","unknown")}}function Nl(){zo(),Mt&&(Mt.close(),Mt=null),ue.value=!1}function jo(){return new URLSearchParams(window.location.search)}function Oo(){const t=jo(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function Fo(){return{...Oo(),"Content-Type":"application/json"}}const Pl=15e3,hi=3e4,Ll=6e4,Gi=new Set([408,425,429,500,502,503,504]);class Jn extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);Pe(this,"method");Pe(this,"path");Pe(this,"status");Pe(this,"statusText");Pe(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function yi(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Jn({method:r,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function Ml(){var e,n;const t=jo();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function rt(t){const e=await yi(t,{headers:Oo()},Pl);if(!e.ok)throw new Jn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Dl(t){return new Promise(e=>setTimeout(e,t))}function zl(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function El(t){if(t instanceof Jn)return t.timeout||typeof t.status=="number"&&Gi.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=zl(t.message);return e!==null&&Gi.has(e)}async function qo(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!El(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${o}ms`,a),await Dl(o),s+=1}}async function Ht(t,e,n,s=hi){const a=await yi(t,{method:"POST",headers:{...Fo(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Jn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function jl(t,e,n,s=hi){const a=await yi(t,{method:"POST",headers:{...Fo(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Jn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function Ol(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Fl(t){var e,n,s,a,o,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const p=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(p)}return((l=(r=(o=t.result)==null?void 0:o.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function me(t,e){const n=await jl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Ll),s=Ol(n);return Fl(s)}function ql(){return rt("/api/v1/dashboard/shell")}function Kl(){return rt("/api/v1/dashboard/execution")}function Ul(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),rt(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function Hl(){return rt("/api/v1/dashboard/governance")}function Wl(){return rt("/api/v1/dashboard/semantics")}function Bl(){return rt("/api/v1/dashboard/mission")}function Gl(t=!1){return rt(`/api/v1/dashboard/mission/briefing${t?"?force=1":""}`)}function Jl(){return rt("/api/v1/dashboard/planning")}function Vl(){return rt("/api/v1/operator")}function Ko(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return rt(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Yl(){return rt("/api/v1/command-plane")}function Ql(){return rt("/api/v1/command-plane/summary")}function Xl(){return rt("/api/v1/chains/summary")}function Zl(t){return rt(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function tc(){return rt("/api/v1/command-plane/help")}function ec(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return rt(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function nc(t,e){return Ht(t,e)}function sc(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return hi}}function ra(t){return Ht("/api/v1/operator/action",t,void 0,sc(t))}function ac(t,e){return Ht("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function gn(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function ic(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function oc(t){if(!H(t))return null;const e=h(t.id,"").trim(),n=h(t.author,"").trim(),s=h(t.content,"").trim();if(!e||!n)return null;const a=V(t.score,0),o=V(t.votes_up,0),r=V(t.votes_down,0),l=V(t.votes,a||o-r),p=V(t.comment_count,V(t.reply_count,0)),m=(()=>{const S=t.flair;if(typeof S=="string"&&S.trim())return S.trim();if(H(S)){const N=h(S.name,"").trim();if(N)return N}return h(t.flair_name,"").trim()||void 0})(),d=h(t.created_at_iso,"").trim()||gn(t.created_at),u=h(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?gn(t.updated_at):d),$=h(t.title,"").trim()||ic(s),x=Array.isArray(t.tags)?t.tags.filter(S=>typeof S=="string"&&S.trim()!==""):[];return{id:e,author:n,title:$,content:s,tags:x,votes:l,vote_balance:a,comment_count:p,created_at:d,updated_at:u,flair:m,hearth:h(t.hearth,"").trim()||null,visibility:h(t.visibility,"").trim()||void 0,expires_at:h(t.expires_at_iso,"").trim()||(t.expires_at!==void 0&&t.expires_at!==0?gn(t.expires_at):"")||null,hearth_count:V(t.hearth_count,0)}}function rc(t){if(!H(t))return null;const e=h(t.id,"").trim(),n=h(t.post_id,"").trim(),s=h(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:h(t.content,""),created_at:gn(t.created_at)}}async function lc(t){return qo("fetchBoardPost",async()=>{const e=await rt(`/api/v1/board/${t}?format=flat`),n=H(e.post)?e.post:e,s=oc(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},o=(Array.isArray(e.comments)?e.comments:[]).map(rc).filter(r=>r!==null);return{...s,comments:o}})}function Uo(t,e){return Ht("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Ml()})}function cc(t,e,n){return Ht("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function dc(t){const e=h(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function mt(...t){for(const e of t){const n=h(e,"");if(n.trim())return n.trim()}return""}function Ji(t){const e=dc(mt(t.outcome,t.result,t.result_code));if(!e)return;const n=mt(t.reason,t.reason_code,t.description,t.detail),s=mt(t.summary,t.summary_ko,t.summary_en,t.note),a=mt(t.details,t.details_text,t.text,t.note),o=mt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=mt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=mt(t.raw_reason,t.raw_reason_code,t.error_message),p=(()=>{const u=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof u=="string"?[u]:Array.isArray(u)?u.map(v=>{if(typeof v=="string")return v.trim();if(H(v)){const $=h(v.summary,"").trim();if($)return $;const x=h(v.text,"").trim();if(x)return x;const S=h(v.type,"").trim();return S||h(v.event_id,"").trim()}return""}).filter(v=>v.length>0):[]})(),m=(()=>{const u=V(t.turn,Number.NaN);if(Number.isFinite(u))return u;const v=V(t.turn_number,Number.NaN);if(Number.isFinite(v))return v;const $=V(t.current_turn,Number.NaN);if(Number.isFinite($))return $;const x=V(t.round,Number.NaN);return Number.isFinite(x)?x:void 0})(),d=mt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:r||void 0,evidence:p.length>0?p:void 0,raw_reason:l||void 0,turn:m,phase:d||void 0}}function uc(t,e){const n=H(t.state)?t.state:{};if(h(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>H(r)?h(r.type,"")==="session.outcome":!1),o=H(n.session_outcome)?n.session_outcome:{};if(H(o)&&Object.keys(o).length>0){const r=Ji(o);if(r)return r}if(H(a))return Ji(H(a.payload)?a.payload:{})}function H(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function V(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function pc(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Va(t,e=!1){return typeof t=="boolean"?t:e}function dn(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(H(e)){const n=h(e.name,"").trim(),s=h(e.id,"").trim(),a=h(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function mc(t){const e={};if(!H(t)&&!Array.isArray(t))return e;if(H(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),o=h(s,"").trim();!a||!o||(e[a]=o)}),e;for(const n of t){if(!H(n))continue;const s=mt(n.to,n.target,n.actor_id,n.name,n.id),a=mt(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function vc(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function bt(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const _c=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function fc(t){const e=H(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const o=s.trim();o&&(_c.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function gc(t,e){if(t!=="dice.rolled")return;const n=V(e.raw_d20,0),s=V(e.total,0),a=V(e.bonus,0),o=h(e.action,"roll"),r=V(e.dc,0);return{notation:r>0?`${o} (DC ${r})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function $c(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function hc(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function yc(t,e,n,s){const a=n||e||h(s.actor_id,"")||h(s.actor_name,"");switch(t){case"turn.action.proposed":{const o=h(s.proposed_action,h(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=h(s.reply,h(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return h(s.reply,h(s.content,h(s.text,"Narration")));case"dice.rolled":{const o=h(s.action,"roll"),r=V(s.total,0),l=V(s.dc,0),p=h(s.label,""),m=a||"actor",d=l>0?` vs DC ${l}`:"",u=p?` (${p})`:"";return`${m} ${o}: ${r}${d}${u}`}case"turn.started":return`Turn ${V(s.turn,1)} started`;case"phase.changed":return`Phase: ${h(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(s.name,H(s.actor)?h(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${h(s.keeper_name,h(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${h(s.keeper_name,h(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${V(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${V(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||h(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||h(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${h(s.reason_code,"unknown")}`;case"memory.signal":{const o=H(s.entity_refs)?s.entity_refs:{},r=h(o.requested_tier,""),l=h(o.effective_tier,""),p=Va(o.guardrail_applied,!1),m=h(s.summary_en,h(s.summary_ko,"Memory signal"));if(!r&&!l)return m;const d=r&&l?`${r}->${l}`:l||r;return`${m} [${d}${p?" (guardrail)":""}]`}case"world.event":{if(h(s.event_type,"")==="canon.check"){const r=h(s.status,"unknown"),l=h(s.contract_id,"n/a");return`Canon ${r}: ${l}`}return h(s.description,h(s.summary,"World event"))}case"combat.attack":return h(s.summary,h(s.result,"Attack resolved"));case"combat.defense":return h(s.summary,h(s.result,"Defense resolved"));case"session.outcome":return h(s.summary,h(s.outcome,"Session ended"));default:{const o=$c(s);return o?`${t}: ${o}`:t}}}function bc(t,e){const n=H(t)?t:{},s=h(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=h(n.actor_name,"").trim()||e[a]||h(H(n.payload)?n.payload.actor_name:"",""),r=H(n.payload)?n.payload:{},l=h(n.ts,h(n.timestamp,new Date().toISOString())),p=h(n.phase,h(r.phase,"")),m=h(n.category,"");return{type:s,actor:o||a||h(r.actor_name,""),actor_id:a||h(r.actor_id,""),actor_name:o,seq:n.seq,room_id:h(n.room_id,""),phase:p||void 0,category:m||hc(s),visibility:h(n.visibility,h(r.visibility,"public")),event_id:h(n.event_id,""),content:yc(s,a,o,r),dice_roll:gc(s,r),timestamp:l}}function kc(t,e,n){var K,tt;const s=h(t.room_id,"")||n||"default",a=H(t.state)?t.state:{},o=H(a.party)?a.party:{},r=H(a.actor_control)?a.actor_control:{},l=H(a.join_gate)?a.join_gate:{},p=H(a.contribution_ledger)?a.contribution_ledger:{},m=Object.entries(o).map(([B,st])=>{const k=H(st)?st:{},Rt=bt(k,"max_hp",void 0,10),te=bt(k,"hp",void 0,Rt),fe=bt(k,"max_mp",void 0,0),ge=bt(k,"mp",void 0,0),O=bt(k,"level",void 0,1),Nt=bt(k,"xp",void 0,0),$e=Va(k.alive,te>0),ln=r[B],cn=typeof ln=="string"?ln:void 0,ns=vc(k.role,B,cn),ss=pc(k.generation),as=mt(k.joined_at,k.joinedAt,k.started_at,k.startedAt),is=mt(k.claimed_at,k.claimedAt,k.assigned_at,k.assignedAt,k.assigned_time),U=mt(k.last_seen,k.lastSeen,k.last_seen_at,k.lastSeenAt,k.last_active,k.lastActive),Ne=mt(k.scene,k.current_scene,k.currentScene,k.world_scene,k.scene_name,k.sceneName),pl=mt(k.location,k.current_location,k.currentLocation,k.position,k.zone,k.area);return{id:B,name:h(k.name,B),role:ns,keeper:cn,archetype:h(k.archetype,""),persona:h(k.persona,""),portrait:h(k.portrait,"")||void 0,background:h(k.background,"")||void 0,traits:dn(k.traits),skills:dn(k.skills),stats_raw:fc(k),status:$e?"active":"dead",generation:ss,joined_at:as||void 0,claimed_at:is||void 0,last_seen:U||void 0,scene:Ne||void 0,location:pl||void 0,inventory:dn(k.inventory),notes:dn(k.notes),relationships:mc(k.relationships),stats:{hp:te,max_hp:Rt,mp:ge,max_mp:fe,level:O,xp:Nt,strength:bt(k,"strength","str",10),dexterity:bt(k,"dexterity","dex",10),constitution:bt(k,"constitution","con",10),intelligence:bt(k,"intelligence","int",10),wisdom:bt(k,"wisdom","wis",10),charisma:bt(k,"charisma","cha",10)}}}),d=m.filter(B=>B.status!=="dead"),u=uc(t,e),v={phase_open:Va(l.phase_open,!0),min_points:V(l.min_points,3),window:h(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},$=Object.entries(p).map(([B,st])=>{const k=H(st)?st:{};return{actor_id:B,score:V(k.score,0),last_reason:h(k.last_reason,"")||null,reasons:dn(k.reasons)}}),x=m.reduce((B,st)=>(B[st.id]=st.name,B),{}),S=e.map(B=>bc(B,x)),T=V(a.turn,1),N=h(a.phase,"round"),I=h(a.map,""),A=H(a.world)?a.world:{},L=I||h(A.ascii_map,h(A.map,"")),M=S.filter((B,st)=>{const k=e[st];if(!H(k))return!1;const Rt=H(k.payload)?k.payload:{};return V(Rt.turn,-1)===T}),Y=(M.length>0?M:S).slice(-12),J=h(a.status,"active");return{session:{id:s,room:s,status:J==="ended"?"ended":J==="paused"?"paused":"active",round:T,actors:d,created_at:((K=S[0])==null?void 0:K.timestamp)??new Date().toISOString()},current_round:{round_number:T,phase:N,events:Y,timestamp:((tt=S[S.length-1])==null?void 0:tt.timestamp)??new Date().toISOString()},map:L||void 0,join_gate:v,contribution_ledger:$,outcome:u,party:d,story_log:S,history:[]}}async function xc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await rt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Sc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([rt(`/api/v1/trpg/state${e}`),xc(t)]);return kc(n,s,t)}function Ac(t){return Ht("/api/v1/trpg/rounds/run",{room_id:t})}function Cc(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function wc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Ht("/api/v1/trpg/dice/roll",e)}function Tc(t,e){const n=Cc();return Ht("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function Ic(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Ht("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function Rc(t,e,n){return Ht("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Nc(t,e,n){const s=await me("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Pc(t){const e=await me("trpg.mid_join.request",t);return JSON.parse(e)}async function Lc(t,e){await me("masc_broadcast",{agent_name:t,message:e})}async function Mc(t=40){return(await me("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Dc(t,e=20){return me("masc_task_history",{task_id:t,limit:e})}async function zc(t){const e=await me("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Ec(t){return qo("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await rt(`/api/v1/council/debates/${e}/summary`);if(!H(n))return null;const s=h(n.id,"").trim();return s?{id:s,topic:h(n.topic,""),status:h(n.status,"open"),support_count:V(n.support_count,0),oppose_count:V(n.oppose_count,0),neutral_count:V(n.neutral_count,0),total_arguments:V(n.total_arguments,0),created_at:gn(n.created_at_iso??n.created_at),summary_text:h(n.summary_text,"")}:null})}function jc(t,e,n){return me("masc_keeper_msg",{name:t,message:e})}const Oc=_(""),Vt=_({}),vt=_({}),Ya=_({}),Qa=_({}),Xa=_({}),Za=_({}),Yt=_({});function pt(t,e,n){t.value={...t.value,[e]:n}}function Xt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function Q(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function wt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ee(t){return typeof t=="boolean"?t:void 0}function ti(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function ei(t){return Array.isArray(t)?t.map(e=>Q(e)).filter(e=>!!e):[]}function Fc(t){var n;const e=(n=Q(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function qc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function fa(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!Xt(s))continue;const a=Q(s.name);if(!a)continue;const o=Q(s[e]);e==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function Kc(t){if(!Xt(t))return null;const e=Q(t.name);return e?{name:e,trigger:Q(t.trigger),outcome:Q(t.outcome),summary:Q(t.summary),reason:Q(t.reason)}:null}function Uc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Hc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Ho(t,e,n){return Q(t)??Hc(e,n)}function Wo(t,e){return typeof t=="boolean"?t:e==="recover"}function Ns(t){if(!Xt(t))return null;const e=Q(t.health_state),n=Q(t.next_action_path),s=Q(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:Q(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:ti(t.last_reply_at),last_reply_preview:Q(t.last_reply_preview)??null,last_error:Q(t.last_error)??null,next_eligible_at_s:wt(t.next_eligible_at_s)??null,recoverable:Wo(t.recoverable,n),summary:Ho(t.summary,e,Q(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Bo(t){return Xt(t)?{hour:wt(t.hour),checked:wt(t.checked)??0,acted:wt(t.acted)??0,acted_names:ei(t.acted_names),activity_report:Q(t.activity_report),quiet_hours_overridden:Ee(t.quiet_hours_overridden),skipped_reason:Q(t.skipped_reason),acted_rows:fa(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:fa(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:fa(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Kc).filter(e=>e!==null):[]}:null}function Wc(t){return Xt(t)?{enabled:Ee(t.enabled)??!1,interval_s:wt(t.interval_s)??0,quiet_start:wt(t.quiet_start),quiet_end:wt(t.quiet_end),quiet_active:Ee(t.quiet_active),use_planner:Ee(t.use_planner),delegate_llm:Ee(t.delegate_llm),agent_count:wt(t.agent_count),agents:ei(t.agents),last_tick_ago_s:wt(t.last_tick_ago_s)??null,last_tick_ago:Q(t.last_tick_ago),total_ticks:wt(t.total_ticks),total_checkins:wt(t.total_checkins),last_skip_reason:Q(t.last_skip_reason)??null,last_tick_result:Bo(t.last_tick_result),active_self_heartbeats:ei(t.active_self_heartbeats)}:null}function Bc(t){return Xt(t)?{status:t.status,diagnostic:Ns(t.diagnostic)}:null}function Gc(t){return Xt(t)?{recovered:Ee(t.recovered)??!1,skipped_reason:Q(t.skipped_reason)??null,before:Ns(t.before),after:Ns(t.after),down:t.down,up:t.up}:null}function Jc(t,e){var I,A;if(!(t!=null&&t.name))return null;const n=Q((I=t.agent)==null?void 0:I.status)??Q(t.status)??"unknown",s=Q((A=t.agent)==null?void 0:A.error)??null,a=t.presence_keepalive??!0,o=t.keepalive_running??!1,r=t.turn_count??0,l=t.last_turn_ago_s??null,p=t.proactive_enabled??!1,m=t.proactive_cooldown_sec??0,d=t.last_proactive_ago_s??null,u=p&&d!=null?Math.max(0,m-d):null,v=r<=0||l==null?"never":l>900?"stale":"fresh",$=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,x=s??(a&&!o?"keeper keepalive is not running":null),S=n==="offline"||n==="inactive"?"offline":x?"degraded":v==="stale"?"stale":v==="never"?"idle":"healthy",T=x?Uc(x):e!=null&&e.quiet_active&&v!=="fresh"?"quiet_hours":a&&!o?"disabled":r<=0?"never_started":u!=null&&u>0?"min_gap":v==="fresh"||v==="stale"?"no_recent_activity":"unknown",N=S==="offline"||S==="degraded"||S==="stale"?"recover":T==="quiet_hours"?"manual_lodge_poke":T==="unknown"?"probe":"direct_message";return{health_state:S,quiet_reason:T,next_action_path:N,last_reply_status:v,last_reply_at:$,last_reply_preview:null,last_error:x,next_eligible_at_s:u!=null&&u>0?u:null,recoverable:Wo(void 0,N),summary:Ho(void 0,S,T),keepalive_running:o}}function Vc(t,e){if(!Xt(t))return null;const n=Fc(t.role),s=Q(t.content)??Q(t.preview);if(!s)return null;const a=ti(t.ts_unix)??ti(t.timestamp);return{id:`${n}-${a??"entry"}-${e}`,role:n,label:qc(n),text:s,timestamp:a,delivery:"history"}}function Yc(t,e,n){const s=Xt(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,r)=>Vc(o,r)).filter(o=>o!==null):[];return{name:t,diagnostic:Ns(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function Vi(t,e){const n=vt.value[t]??[];vt.value={...vt.value,[t]:[...n,e].slice(-50)}}function Qc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Xc(t,e){const s=(vt.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(o=>Qc(a,o)));vt.value={...vt.value,[t]:[...e,...s].slice(-50)}}function la(t,e){Vt.value={...Vt.value,[t]:e},Xc(t,e.history)}function Yi(t,e){const n=Vt.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};la(t,{...n,diagnostic:{...s,...e}})}async function bi(){try{await Vn()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Zc(t){Oc.value=t.trim()}async function Go(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Vt.value[n])return Vt.value[n];pt(Ya,n,!0),pt(Yt,n,null);try{const s=await me("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=Yc(n,s,a);return la(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return pt(Yt,n,a),null}finally{pt(Ya,n,!1)}}async function td(t,e){const n=t.trim(),s=e.trim();if(!n||!s)return;const a=`local-${Date.now()}`;Vi(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),pt(Qa,n,!0),pt(Yt,n,null);try{const o=await jc(n,s);vt.value={...vt.value,[n]:(vt.value[n]??[]).map(r=>r.id===a?{...r,delivery:"delivered"}:r)},Vi(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Yi(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await bi()}catch(o){const r=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw vt.value={...vt.value,[n]:(vt.value[n]??[]).map(l=>l.id===a?{...l,delivery:"error",error:r}:l)},Yi(n,{last_reply_status:"error",last_error:r}),pt(Yt,n,r),o}finally{pt(Qa,n,!1)}}async function ed(t,e){const n=t.trim();if(!n)return null;pt(Xa,n,!0),pt(Yt,n,null);try{const s=await ra({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=Bc(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const r=Vt.value[n];la(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??vt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await bi(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw pt(Yt,n,a),s}finally{pt(Xa,n,!1)}}async function nd(t,e){const n=t.trim();if(!n)return null;pt(Za,n,!0),pt(Yt,n,null);try{const s=await ra({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Gc(s.result),o=(a==null?void 0:a.after)??null;if(o){const r=Vt.value[n];la(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??vt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await bi(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw pt(Yt,n,a),s}finally{pt(Za,n,!1)}}function he(t){return(t??"").trim().toLowerCase()}function ht(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function hs(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function os(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function un(t){return t.last_heartbeat??os(t.last_turn_ago_s)??os(t.last_proactive_ago_s)??os(t.last_handoff_ago_s)??os(t.last_compaction_ago_s)}function sd(t){const e=t.title.trim();return e||hs(t.content)}function ad(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function id(t,e,n,s,a={}){var A;const o=he(t),r=e.filter(L=>he(L.assignee)===o&&(L.status==="claimed"||L.status==="in_progress")).length,l=n.filter(L=>he(L.from)===o).sort((L,M)=>ht(M.timestamp)-ht(L.timestamp))[0],p=s.filter(L=>he(L.agent)===o||he(L.author)===o).sort((L,M)=>ht(M.timestamp)-ht(L.timestamp))[0],m=(a.boardPosts??[]).filter(L=>he(L.author)===o).sort((L,M)=>ht(M.updated_at||M.created_at)-ht(L.updated_at||L.created_at))[0],d=(a.keepers??[]).filter(L=>he(L.name)===o&&un(L)!==null).sort((L,M)=>ht(un(M)??0)-ht(un(L)??0))[0],u=l?ht(l.timestamp):0,v=p?ht(p.timestamp):0,$=m?ht(m.updated_at||m.created_at):0,x=d?ht(un(d)??0):0,S=a.lastSeen?ht(a.lastSeen):0,T=((A=a.currentTask)==null?void 0:A.trim())||(r>0?`${r} claimed tasks`:null);if(u===0&&v===0&&$===0&&x===0&&S===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:T};const I=[l?{timestamp:l.timestamp,ts:u,text:hs(l.content)}:null,m?{timestamp:m.updated_at||m.created_at,ts:$,text:`Post: ${hs(sd(m))}`}:null,d?{timestamp:un(d),ts:x,text:ad(d)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:v,text:hs(p.text)}:null].filter(L=>L!==null).sort((L,M)=>M.ts-L.ts)[0];return I&&I.ts>=S?{activeAssignedCount:r,lastActivityAt:I.timestamp,lastActivityText:I.text}:{activeAssignedCount:r,lastActivityAt:a.lastSeen??null,lastActivityText:T??"Presence heartbeat"}}const It=_([]),Ot=_([]),Xe=_([]),Zt=_([]),xt=_(null),od=_(null),ni=_(new Map),Tn=_([]),In=_("recent"),je=_(!0),Jo=_(null),Jt=_(""),Ue=_([]),$n=_(!1),Vo=_(new Map),ki=_("unknown"),He=_(null),si=_(!1),Rn=_(!1),ai=_(!1),hn=_(!1),xi=_(null),Ps=_(!1),Ls=_(null),Yo=_(null),ii=_(null),rd=_(null),ld=_(null),cd=_(null);Tt(()=>It.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const Qo=Tt(()=>{const t=Ot.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Si=Tt(()=>{const t=new Map,e=Ot.value,n=Xe.value,s=Rs.value,a=Tn.value,o=Zt.value;for(const r of It.value)t.set(r.name.trim().toLowerCase(),id(r.name,e,n,s,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:a,keepers:o}));return t});function dd(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const ud=Tt(()=>{const t=new Map;for(const e of Zt.value)t.set(e.name,dd(e));return t}),pd=12e4;function md(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}const vd=Tt(()=>{const t=Date.now(),e=new Set,n=ni.value;for(const s of Zt.value){const a=md(s,n);a!=null&&t-a>pd&&e.add(s.name)}return e});let ga=null;function _d(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function ut(t){return typeof t=="object"&&t!==null}function b(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function R(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Dt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function oi(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Xo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function fd(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function gd(t){if(!ut(t))return null;const e=b(t.name);return e?{name:e,agent_type:b(t.agent_type),status:Xo(t.status),current_task:b(t.current_task)??null,joined_at:b(t.joined_at),last_seen:b(t.last_seen),capabilities:Dt(t.capabilities),emoji:b(t.emoji),koreanName:b(t.koreanName)??b(t.korean_name),model:b(t.model),traits:Dt(t.traits),interests:Dt(t.interests),activityLevel:R(t.activityLevel)??R(t.activity_level),primaryValue:b(t.primaryValue)??b(t.primary_value)}:null}function $d(t){if(!ut(t))return null;const e=b(t.id),n=b(t.title);return!e||!n?null:{id:e,title:n,status:fd(t.status),priority:R(t.priority),assignee:b(t.assignee),description:b(t.description),created_at:b(t.created_at),updated_at:b(t.updated_at)}}function hd(t){if(!ut(t))return null;const e=b(t.from)??b(t.from_agent)??"system",n=b(t.content)??"",s=b(t.timestamp)??new Date().toISOString();return{id:b(t.id),seq:R(t.seq),from:e,content:n,timestamp:s,type:b(t.type)}}function Qi(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function yd(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>Qi(s)-Qi(a)).slice(-500)}function bd(t){return Array.isArray(t)?t.map(e=>{if(!ut(e))return null;const n=R(e.ts_unix);if(n==null)return null;const s=ut(e.handoff)?e.handoff:null;return{ts:n,context_ratio:R(e.context_ratio)??0,context_tokens:R(e.context_tokens)??0,context_max:R(e.context_max)??0,latency_ms:R(e.latency_ms)??0,generation:R(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:R(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:R(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?R(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Xi(t){if(!ut(t))return null;const e=b(t.health_state),n=b(t.next_action_path),s=b(t.last_reply_status);if(!e||!n||!s)return null;const a=b(t.quiet_reason)??null,o=b(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:oi(t.last_reply_at)??b(t.last_reply_at)??null,last_reply_preview:b(t.last_reply_preview)??null,last_error:b(t.last_error)??null,next_eligible_at_s:R(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function kd(t,e){return(Array.isArray(t)?t:ut(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!ut(s))return null;const a=ut(s.agent)?s.agent:null,o=ut(s.context)?s.context:null,r=ut(s.metrics_window)?s.metrics_window:void 0,l=b(s.name);if(!l)return null;const p=R(s.context_ratio)??R(o==null?void 0:o.context_ratio),m=b(s.status)??b(a==null?void 0:a.status)??"offline",d=Xo(m),u=b(s.model)??b(s.active_model)??b(s.primary_model),v=Dt(s.skill_secondary),$=o?{source:b(o.source),context_ratio:R(o.context_ratio),context_tokens:R(o.context_tokens),context_max:R(o.context_max),message_count:R(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,x=a?{name:b(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:b(a.error),agent_type:b(a.agent_type),status:b(a.status),current_task:b(a.current_task)??null,joined_at:b(a.joined_at),last_seen:b(a.last_seen),last_seen_ago_s:R(a.last_seen_ago_s),capabilities:Dt(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,S=bd(s.metrics_series),T={name:l,emoji:b(s.emoji),koreanName:b(s.koreanName)??b(s.korean_name),agent_name:b(s.agent_name),trace_id:b(s.trace_id),model:u,primary_model:b(s.primary_model),active_model:b(s.active_model),next_model_hint:b(s.next_model_hint)??null,status:d,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:R(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:R(s.proactive_idle_sec),proactive_cooldown_sec:R(s.proactive_cooldown_sec),last_heartbeat:b(s.last_heartbeat)??b(a==null?void 0:a.last_seen),generation:R(s.generation),turn_count:R(s.turn_count)??R(s.total_turns),keeper_age_s:R(s.keeper_age_s),last_turn_ago_s:R(s.last_turn_ago_s),last_handoff_ago_s:R(s.last_handoff_ago_s),last_compaction_ago_s:R(s.last_compaction_ago_s),last_proactive_ago_s:R(s.last_proactive_ago_s),last_proactive_preview:b(s.last_proactive_preview)??null,context_ratio:p,context_tokens:R(s.context_tokens)??R(o==null?void 0:o.context_tokens),context_max:R(s.context_max)??R(o==null?void 0:o.context_max),context_source:b(s.context_source)??b(o==null?void 0:o.source),context:$,traits:Dt(s.traits),interests:Dt(s.interests),primaryValue:b(s.primaryValue)??b(s.primary_value),activityLevel:R(s.activityLevel)??R(s.activity_level),memory_recent_note:b(s.memory_recent_note)??null,recent_input_preview:b(s.recent_input_preview)??null,recent_output_preview:b(s.recent_output_preview)??null,recent_tool_names:Dt(s.recent_tool_names)??[],conversation_tail_count:R(s.conversation_tail_count),k2k_count:R(s.k2k_count),handoff_count_total:R(s.handoff_count_total)??R(s.trace_history_count),compaction_count:R(s.compaction_count),last_compaction_saved_tokens:R(s.last_compaction_saved_tokens),diagnostic:Xi(s.diagnostic),skill_primary:b(s.skill_primary)??null,skill_secondary:v,skill_reason:b(s.skill_reason)??null,metrics_series:S.length>0?S:void 0,metrics_window:r,agent:x};return T.diagnostic=Xi(s.diagnostic)??Jc(T,(e==null?void 0:e.lodge)??null),T}).filter(s=>s!==null)}function Zo(t){return ut(t)?{...t,lodge:Wc(t.lodge)??void 0}:null}function xd(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function Sd(t){if(!ut(t))return null;const e=R(t.iteration);if(e==null)return null;const n=R(t.metric_before)??0,s=R(t.metric_after)??n,a=ut(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:R(t.delta)??s-n,changes:b(t.changes)??"",failed_attempts:b(t.failed_attempts)??"",next_suggestion:b(t.next_suggestion)??"",elapsed_ms:R(t.elapsed_ms)??0,cost_usd:R(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:b(a.worker_model)??"",tool_call_count:R(a.tool_call_count)??0,tool_names:Dt(a.tool_names)??[],session_id:b(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function Ad(t){var o,r;if(!ut(t))return null;const e=b(t.loop_id);if(!e)return null;const n=R(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(Sd).filter(l=>l!==null):[],a=R(t.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:b(t.profile)??"unknown",status:xd(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:b(t.error_message)??b(t.error_reason)??null,stop_reason:b(t.stop_reason)??b(t.reason)??null,current_iteration:R(t.current_iteration)??((r=s[0])==null?void 0:r.iteration)??0,max_iterations:R(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:b(t.target)??"",stagnation_streak:R(t.stagnation_streak)??0,stagnation_limit:R(t.stagnation_limit)??0,elapsed_seconds:R(t.elapsed_seconds)??0,updated_at:oi(t.updated_at)??null,stopped_at:oi(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:b(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:R(t.latest_tool_call_count)??0,latest_tool_names:Dt(t.latest_tool_names)??[],session_id:b(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function Vn(){si.value=!0;try{await Promise.all([er(),Gt()]),Yo.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{si.value=!1}}async function tr(){Ps.value=!0,Ls.value=null;try{const t=await Wl();xi.value=t,cd.value=new Date().toISOString()}catch(t){Ls.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{Ps.value=!1}}function Cd(t){var e;return((e=xi.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function wd(t){var n;const e=((n=xi.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(o=>o.id===t);if(a)return a}return null}function Td(t){var s,a;Ue.value=(Array.isArray(t.goals)?t.goals:[]).map(o=>{if(!ut(o))return null;const r=b(o.id),l=b(o.title),p=b(o.horizon),m=b(o.status),d=b(o.created_at),u=b(o.updated_at);return!r||!l||!p||!m||!d||!u?null:{id:r,horizon:p,title:l,metric:b(o.metric)??null,target_value:b(o.target_value)??null,due_date:b(o.due_date)??null,priority:R(o.priority)??3,status:m,parent_goal_id:b(o.parent_goal_id)??null,last_review_note:b(o.last_review_note)??null,last_review_at:b(o.last_review_at)??null,created_at:d,updated_at:u}}).filter(o=>o!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const o of n){const r=Ad(o);r&&e.set(r.loop_id,r)}Vo.value=e,He.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,ki.value=He.value?"error":e.size===0?"idle":"ready"}async function er(){try{const t=await ql(),e=Zo(t.status);e&&(xt.value=e)}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Gt(){var t;try{const e=await Kl(),n=Zo(e.status),s=(t=xt.value)==null?void 0:t.room;n&&(xt.value=n);const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;It.value=(Array.isArray(e.agents)?e.agents:[]).map(gd).filter(r=>r!==null),Ot.value=(Array.isArray(e.tasks)?e.tasks:[]).map($d).filter(r=>r!==null);const o=(Array.isArray(e.messages)?e.messages:[]).map(hd).filter(r=>r!==null);Xe.value=a?o:yd(Xe.value,o),Zt.value=kd(e.keepers,n??xt.value),od.value=null,Yo.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function Ft(){Rn.value=!0;try{const t=await Ul(In.value,{excludeSystem:je.value});Tn.value=t.posts??[],ii.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Rn.value=!1}}async function qt(){var t;ai.value=!0;try{const e=Jt.value||((t=xt.value)==null?void 0:t.room)||"default";Jt.value||(Jt.value=e);const n=await Sc(e);Jo.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{ai.value=!1}}async function Nn(){$n.value=!0,hn.value=!0;try{const t=await Jl();Td(t),rd.value=new Date().toISOString(),ld.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),ki.value="error",He.value=t instanceof Error?t.message:String(t)}finally{$n.value=!1,hn.value=!1}}async function nr(){return Nn()}let ys=null;function Id(t){ys=t}let bs=null;function Rd(t){bs=t}let ks=null;function Nd(t){ks=t}const xe={};function ye(t,e,n=500){xe[t]&&clearTimeout(xe[t]),xe[t]=setTimeout(()=>{e(),delete xe[t]},n)}function Pd(){const t=Do.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(ni.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),ni.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&ye("execution",Gt),_d(e.type)&&(ga||(ga=setTimeout(()=>{Vn(),bs==null||bs(),ks==null||ks(),ga=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&ye("execution",Gt),e.type==="broadcast"&&ye("execution",Gt),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&ye("execution",Gt),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&ye("board",Ft),e.type.startsWith("decision_")&&ye("council",()=>ys==null?void 0:ys()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&ye("mdal",nr,350)}});return()=>{t();for(const e of Object.keys(xe))clearTimeout(xe[e]),delete xe[e]}}let yn=null;function Ld(){yn||(yn=setInterval(()=>{ue.value,Vn()},1e4))}function Md(){yn&&(clearInterval(yn),yn=null)}function Dd({metric:t}){return i`
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
  `}function zd({panel:t}){return i`
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
            ${t.metrics.map(e=>i`<${Dd} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function E({panelId:t,compact:e=!1,label:n="Why"}){const s=wd(t);return s?i`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${zd} panel=${s} />
    </details>
  `:Ps.value?i`<span class="semantic-inline-state">Loading semantics…</span>`:null}function St({surfaceId:t,compact:e=!1}){const n=Cd(t);return n?i`
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
  `:Ps.value?i`<div class="semantic-surface-card ${e?"compact":""}">Loading semantics…</div>`:Ls.value?i`<div class="semantic-surface-card ${e?"compact":""}">${Ls.value}</div>`:null}function P({title:t,class:e,semanticId:n,children:s}){return i`
    <div class="card ${e??""}">
      ${t?i`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?i`<${E} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${s}
    </div>
  `}function Ai(t){const e=t.indexOf("-");if(e<0)return{model:t,nickname:t,isKeeper:t==="keeper"};const n=t.slice(0,e),s=t.slice(e+1);return{model:n,nickname:s,isKeeper:n==="keeper"}}function Ed(t){return t==="keeper"||t.startsWith("keeper-")}const Ci=_(null),ri=_(!1),Ms=_(null),sr=_(null),Oe=_(!1),ke=_(null);let We=null;function Zi(){We!==null&&(window.clearTimeout(We),We=null)}function jd(t=1500){We===null&&(We=window.setTimeout(()=>{We=null,Pn(!1)},t))}function q(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function y(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function j(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Be(t){return typeof t=="boolean"?t:void 0}function nt(t,e=[]){if(Array.isArray(t))return t;if(!q(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function an(t){if(!q(t))return null;const e=y(t.kind),n=y(t.summary),s=y(t.target_type);return!e||!n||!s?null:{kind:e,severity:y(t.severity)??"warn",summary:n,target_type:s,target_id:y(t.target_id)??null,actor:y(t.actor)??null,evidence:t.evidence}}function Te(t){if(!q(t))return null;const e=y(t.action_type),n=y(t.target_type),s=y(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:y(t.target_id)??null,severity:y(t.severity)??"warn",reason:s,confirm_required:Be(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Od(t){if(!q(t))return null;const e=y(t.session_id);return e?{session_id:e,goal:y(t.goal),status:y(t.status),health:y(t.health),scale_profile:y(t.scale_profile),control_profile:y(t.control_profile),planned_worker_count:j(t.planned_worker_count),active_agent_count:j(t.active_agent_count),last_turn_age_sec:j(t.last_turn_age_sec)??null,attention_count:j(t.attention_count),recommended_action_count:j(t.recommended_action_count),top_attention:an(t.top_attention),top_recommendation:Te(t.top_recommendation)}:null}function Fd(t){if(!q(t))return null;const e=y(t.session_id);if(!e)return null;const n=q(t.status)?t.status:t,s=q(n.summary)?n.summary:void 0;return{session_id:e,status:y(t.status)??y(s==null?void 0:s.status)??(q(n.session)?y(n.session.status):void 0),progress_pct:j(t.progress_pct)??j(s==null?void 0:s.progress_pct),elapsed_sec:j(t.elapsed_sec)??j(s==null?void 0:s.elapsed_sec),remaining_sec:j(t.remaining_sec)??j(s==null?void 0:s.remaining_sec),done_delta_total:j(t.done_delta_total)??j(s==null?void 0:s.done_delta_total),summary:q(t.summary)?t.summary:s,team_health:q(t.team_health)?t.team_health:q(n.team_health)?n.team_health:void 0,communication_metrics:q(t.communication_metrics)?t.communication_metrics:q(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:q(t.orchestration_state)?t.orchestration_state:q(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:q(t.cascade_metrics)?t.cascade_metrics:q(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:q(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,o])=>{const r=y(o);return r?[a,r]:null}).filter(a=>a!==null)):q(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const r=y(o);return r?[a,r]:null}).filter(a=>a!==null)):void 0,session:q(t.session)?t.session:q(n.session)?n.session:void 0,recent_events:nt(t.recent_events,["events"]).filter(q)}}function qd(t){if(!q(t))return null;const e=y(t.name);return e?{name:e,agent_name:y(t.agent_name),status:y(t.status),autonomy_level:y(t.autonomy_level),context_ratio:j(t.context_ratio),generation:j(t.generation),active_goal_ids:nt(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:y(t.last_autonomous_action_at)??null,last_turn_ago_s:j(t.last_turn_ago_s),model:y(t.model)}:null}function Kd(t){if(!q(t))return null;const e=y(t.confirm_token)??y(t.token);return e?{confirm_token:e,actor:y(t.actor),action_type:y(t.action_type),target_type:y(t.target_type),target_id:y(t.target_id)??null,delegated_tool:y(t.delegated_tool),created_at:y(t.created_at),preview:t.preview}:null}function Ud(t){if(!q(t))return null;const e=y(t.action_type),n=y(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:y(t.description),confirm_required:Be(t.confirm_required)}}function Hd(t){const e=q(t)?t:{};return{room_health:y(e.room_health),cluster:y(e.cluster),project:y(e.project),current_room:y(e.current_room)??null,paused:Be(e.paused),tempo_interval_s:j(e.tempo_interval_s),active_agents:j(e.active_agents),keeper_pressure:j(e.keeper_pressure),active_operations:j(e.active_operations),pending_approvals:j(e.pending_approvals),incident_count:j(e.incident_count),recommended_action_count:j(e.recommended_action_count),top_attention:an(e.top_attention),top_action:Te(e.top_action)}}function Wd(t){const e=q(t)?t:{},n=q(e.swarm_overview)?e.swarm_overview:{};return{health:y(e.health),active_operations:j(e.active_operations),pending_approvals:j(e.pending_approvals),swarm_overview:{active_lanes:j(n.active_lanes),moving_lanes:j(n.moving_lanes),stalled_lanes:j(n.stalled_lanes),projected_lanes:j(n.projected_lanes),last_movement_at:y(n.last_movement_at)??null},top_attention:an(e.top_attention),top_action:Te(e.top_action),session_cards:nt(e.session_cards).map(Od).filter(s=>s!==null)}}function Bd(t){const e=q(t)?t:{};return{sessions:nt(e.sessions,["items"]).map(Fd).filter(n=>n!==null),keepers:nt(e.keepers,["items"]).map(qd).filter(n=>n!==null),pending_confirms:nt(e.pending_confirms).map(Kd).filter(n=>n!==null),available_actions:nt(e.available_actions).map(Ud).filter(n=>n!==null)}}function Gd(t){if(!q(t))return null;const e=y(t.id),n=y(t.kind),s=y(t.summary),a=y(t.target_type);return!e||!n||!s||!a?null:{id:e,kind:n,severity:y(t.severity)??"warn",summary:s,target_type:a,target_id:y(t.target_id)??null,top_action:Te(t.top_action),related_session_ids:nt(t.related_session_ids).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),related_agent_names:nt(t.related_agent_names).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),evidence_preview:nt(t.evidence_preview).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),last_seen_at:y(t.last_seen_at)??null}}function Jd(t){if(!q(t))return null;const e=y(t.session_id),n=y(t.goal);return!e||!n?null:{session_id:e,goal:n,room:y(t.room)??null,status:y(t.status),health:y(t.health),member_names:nt(t.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:y(t.started_at)??null,elapsed_sec:j(t.elapsed_sec)??null,last_event_at:y(t.last_event_at)??null,last_event_summary:y(t.last_event_summary)??null,communication_summary:y(t.communication_summary)??null,active_count:j(t.active_count),required_count:j(t.required_count),related_attention_count:j(t.related_attention_count)??0,top_attention:an(t.top_attention),top_recommendation:Te(t.top_recommendation)}}function Vd(t){if(!q(t))return null;const e=y(t.agent_name);return e?{agent_name:e,status:y(t.status),where:y(t.where)??null,with_whom:nt(t.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:y(t.current_work)??null,related_session_id:y(t.related_session_id)??null,related_attention_count:j(t.related_attention_count)??0,recent_output_preview:y(t.recent_output_preview)??null,recent_input_preview:y(t.recent_input_preview)??null,recent_event:y(t.recent_event)??null,recent_tool_names:nt(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean)}:null}function Yd(t){if(!q(t))return null;const e=y(t.name);return e?{name:e,agent_name:y(t.agent_name)??null,status:y(t.status),generation:j(t.generation),context_ratio:j(t.context_ratio)??null,last_turn_ago_s:j(t.last_turn_ago_s)??null,current_work:y(t.current_work)??null,last_autonomous_action_at:y(t.last_autonomous_action_at)??null}:null}function Qd(t){if(!q(t))return null;const e=y(t.id),n=y(t.signal_type),s=y(t.summary),a=y(t.target_type);return!e||!n||!s||!a?null:{id:e,signal_type:n==="action"?"action":"attention",severity:y(t.severity)??"warn",summary:s,target_type:a,target_id:y(t.target_id)??null,attention:an(t.attention),action:Te(t.action)}}function Xd(t){const e=q(t)?t:{};return{generated_at:y(e.generated_at),summary:Hd(e.summary),incidents:nt(e.incidents).map(an).filter(n=>n!==null),recommended_actions:nt(e.recommended_actions).map(Te).filter(n=>n!==null),command_focus:Wd(e.command_focus),operator_targets:Bd(e.operator_targets),attention_queue:nt(e.attention_queue).map(Gd).filter(n=>n!==null),session_briefs:nt(e.session_briefs).map(Jd).filter(n=>n!==null),agent_briefs:nt(e.agent_briefs).map(Vd).filter(n=>n!==null),keeper_briefs:nt(e.keeper_briefs).map(Yd).filter(n=>n!==null),internal_signals:nt(e.internal_signals).map(Qd).filter(n=>n!==null)}}function Zd(t){if(!q(t))return null;const e=y(t.id),n=y(t.label),s=y(t.summary);if(!e||!n||!s)return null;const a=y(t.status)??"unclear";return{id:e,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,evidence:nt(t.evidence).map(r=>typeof r=="string"?r.trim():"").filter(Boolean)}}function tu(t){const e=q(t)?t:{},n=q(e.basis)?e.basis:{},s=y(e.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:y(e.generated_at),cached:Be(e.cached),stale:Be(e.stale),refreshing:Be(e.refreshing),status:a,summary:y(e.summary)??null,model:y(e.model)??null,ttl_sec:j(e.ttl_sec),criteria:nt(e.criteria).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),basis:{current_room:y(n.current_room)??null,crew_count:j(n.crew_count),agent_count:j(n.agent_count),keeper_count:j(n.keeper_count)},sections:nt(e.sections).map(Zd).filter(o=>o!==null),error:y(e.error)??null,last_error:y(e.last_error)??null}}async function xs(){ri.value=!0,Ms.value=null;try{const t=await Bl();Ci.value=Xd(t)}catch(t){Ms.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{ri.value=!1}}async function Pn(t=!1){Oe.value=!0,ke.value=null;try{const e=await Gl(t),n=tu(e);sr.value=n,n.refreshing||n.status==="pending"?jd():Zi()}catch(e){ke.value=e instanceof Error?e.message:"Failed to load mission briefing",Zi()}finally{Oe.value=!1}}function ve({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function ar(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const o=Math.floor(a/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function ot({timestamp:t}){const e=ar(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return i`<span class="time-ago" title=${n}>${e}</span>`}let eu=0;const Se=_([]);function D(t,e="success",n=4e3){const s=++eu;Se.value=[...Se.value,{id:s,message:t,type:e}],setTimeout(()=>{Se.value=Se.value.filter(a=>a.id!==s)},n)}function nu(t){Se.value=Se.value.filter(e=>e.id!==t)}function su(){const t=Se.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>nu(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const au="masc_dashboard_agent_name",on=_(null),Ds=_(!1),Ln=_(""),zs=_([]),Mn=_([]),Ge=_(""),bn=_(!1);function Ze(t){on.value=t,wi()}function to(){on.value=null,Ln.value="",zs.value=[],Mn.value=[],Ge.value=""}function iu(){const t=on.value;return t?It.value.find(e=>e.name===t)??null:null}function ir(t){return t?Ot.value.filter(e=>e.assignee===t):[]}function or(t){return t?Zt.value.find(e=>e.agent_name===t||e.name===t)??null:null}function ou(t){if(!t)return[];const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function ru(t){const e=or(t);return e?e.recent_tool_names&&e.recent_tool_names.length>0?e.recent_tool_names:[]:[]}async function wi(){const t=on.value;if(t){Ds.value=!0,Ln.value="",zs.value=[],Mn.value=[];try{const e=await Mc(80);zs.value=e.filter(a=>a.includes(t)).slice(0,20);const n=ir(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await Dc(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const r=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));Mn.value=s}catch(e){Ln.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Ds.value=!1}}}async function eo(){var s;const t=on.value,e=Ge.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(au))==null?void 0:s.trim())||"dashboard";bn.value=!0;try{await Lc(n,`@${t} ${e}`),Ge.value="",D(`Mention sent to ${t}`,"success"),wi()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";D(o,"error")}finally{bn.value=!1}}function lu({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${ve} status=${t.status} />
    </div>
  `}function cu({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function du(){var u,v,$,x,S,T,N;const t=on.value;if(!t)return null;const e=iu(),n=or(t),s=ir(t),a=zs.value,o=ru(t),r=ou(n),l=(e==null?void 0:e.capabilities)??[],p=((u=xt.value)==null?void 0:u.room)??"default",m=((v=xt.value)==null?void 0:v.project)??"확인 없음",d=(($=xt.value)==null?void 0:$.cluster)??"확인 없음";return i`
    <div
      class="agent-detail-overlay"
      onClick=${I=>{I.target.classList.contains("agent-detail-overlay")&&to()}}
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
                        <${ve} status=${e.status} />
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
                ${(S=e==null?void 0:e.traits)==null?void 0:S.map(I=>i`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${I}</span>`)}
              </div>
            `:""}
            ${(((T=e==null?void 0:e.interests)==null?void 0:T.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(N=e==null?void 0:e.interests)==null?void 0:N.map(I=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${I}</span>`)}
              </div>
            `:""}
            ${l.length>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${l.map(I=>i`<span style="font-size:0.7rem;background:#183153;color:#7dd3fc;padding:2px 8px;border-radius:10px">${I}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?i`
                    ${e.current_task?i`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?i`<span>Last seen: <${ot} timestamp=${e.last_seen} /></span>`:null}
                    <span>Room: ${p}</span>
                    <span>Project: ${m}</span>
                    <span>Cluster: ${d}</span>
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{wi()}} disabled=${Ds.value}>
              ${Ds.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${to}>Close</button>
          </div>
        </div>

        ${Ln.value?i`<div class="council-error">${Ln.value}</div>`:null}

        <div class="agent-detail-grid">
          <${P} title="Assigned Tasks">
            ${s.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${s.map(I=>i`<${lu} key=${I.id} task=${I} />`)}</div>`}
          <//>

          <${P} title="Recent Activity">
            ${a.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${a.map((I,A)=>i`<div key=${A} class="agent-activity-line">${I}</div>`)}</div>`}
          <//>
        </div>

        <${P} title="Capabilities & Tools">
          <div style="display:flex; flex-direction:column; gap:12px;">
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Capabilities</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${l.length>0?l.map(I=>i`<span class="pill">${I}</span>`):i`<span class="empty-state" style="font-size:12px;">No capability metadata</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Recent tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${o.length>0?o.map(I=>i`<span class="pill">${I}</span>`):i`<span class="empty-state" style="font-size:12px;">No tool telemetry</span>`}
              </div>
            </div>
            ${o.length===0&&r.length>0?i`
                  <div>
                    <div style="font-size:12px; color:#888; margin-bottom:6px;">Window top tools</div>
                    <div style="display:flex; flex-wrap:wrap; gap:6px;">
                      ${r.map(I=>i`<span class="pill">${I}</span>`)}
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

        <${P} title="Task History">
          ${Mn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${Mn.value.map(I=>i`<${cu} key=${I.taskId} row=${I} />`)}</div>`}
        <//>

        <${P} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Ge.value}
              onInput=${I=>{Ge.value=I.target.value}}
              onKeyDown=${I=>{I.key==="Enter"&&eo()}}
              disabled=${bn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{eo()}}
              disabled=${bn.value||Ge.value.trim()===""}
            >
              ${bn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const Kt=_(null),rr=_(null),Ut=_(null),Dn=_(!1),pe=_(null),zn=_(!1),tn=_(null),X=_(!1),Es=_([]);let uu=1;function W(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function C(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function it(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function ca(t){return typeof t=="boolean"?t:void 0}function pu(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function zt(t,e=[]){if(Array.isArray(t))return t;if(!W(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function mu(t){return W(t)?{id:C(t.id),seq:it(t.seq),from:C(t.from)??C(t.from_agent)??"system",content:C(t.content)??"",timestamp:C(t.timestamp)??new Date().toISOString(),type:C(t.type)}:null}function vu(t){return W(t)?{room_id:C(t.room_id),current_room:C(t.current_room)??C(t.room),project:C(t.project),cluster:C(t.cluster),paused:ca(t.paused),pause_reason:C(t.pause_reason)??null,paused_by:C(t.paused_by)??null,paused_at:C(t.paused_at)??null}:{}}function no(t){if(!W(t))return;const e=Object.entries(t).map(([n,s])=>{const a=C(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function lr(t){if(!W(t))return null;const e=C(t.kind),n=C(t.summary),s=C(t.target_type);return!e||!n||!s?null:{kind:e,severity:C(t.severity)??"warn",summary:n,target_type:s,target_id:C(t.target_id)??null,actor:C(t.actor)??null,evidence:t.evidence}}function cr(t){if(!W(t))return null;const e=C(t.action_type),n=C(t.target_type),s=C(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:C(t.target_id)??null,severity:C(t.severity)??"warn",reason:s,confirm_required:ca(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function _u(t){return W(t)?{actor:C(t.actor)??null,spawn_agent:C(t.spawn_agent)??null,spawn_role:C(t.spawn_role)??null,spawn_model:C(t.spawn_model)??null,worker_class:C(t.worker_class)??null,parent_actor:C(t.parent_actor)??null,capsule_mode:C(t.capsule_mode)??null,runtime_pool:C(t.runtime_pool)??null,lane_id:C(t.lane_id)??null,controller_level:C(t.controller_level)??null,control_domain:C(t.control_domain)??null,supervisor_actor:C(t.supervisor_actor)??null,model_tier:C(t.model_tier)??null,task_profile:C(t.task_profile)??null,risk_level:C(t.risk_level)??null,routing_confidence:it(t.routing_confidence)??null,routing_reason:C(t.routing_reason)??null,status:C(t.status)??"unknown",turn_count:it(t.turn_count)??0,empty_note_turn_count:it(t.empty_note_turn_count)??0,has_turn:ca(t.has_turn)??!1,last_turn_ts_iso:C(t.last_turn_ts_iso)??null}:null}function fu(t){if(!W(t))return null;const e=C(t.session_id);return e?{session_id:e,goal:C(t.goal),status:C(t.status),health:C(t.health),scale_profile:C(t.scale_profile),control_profile:C(t.control_profile),planned_worker_count:it(t.planned_worker_count),active_agent_count:it(t.active_agent_count),last_turn_age_sec:it(t.last_turn_age_sec)??null,attention_count:it(t.attention_count),recommended_action_count:it(t.recommended_action_count),top_attention:lr(t.top_attention),top_recommendation:cr(t.top_recommendation)}:null}function dr(t){const e=W(t)?t:{};return{trace_id:C(e.trace_id),target_type:C(e.target_type)??"room",target_id:C(e.target_id)??null,health:C(e.health),swarm_status:W(e.swarm_status)?e.swarm_status:void 0,attention_items:zt(e.attention_items).map(lr).filter(n=>n!==null),recommended_actions:zt(e.recommended_actions).map(cr).filter(n=>n!==null),session_cards:zt(e.session_cards).map(fu).filter(n=>n!==null),worker_cards:zt(e.worker_cards).map(_u).filter(n=>n!==null)}}function gu(t){if(!W(t))return null;const e=W(t.status)?t.status:void 0,n=W(t.summary)?t.summary:W(e==null?void 0:e.summary)?e.summary:void 0,s=W(t.session)?t.session:W(e==null?void 0:e.session)?e.session:void 0,a=C(t.session_id)??C(n==null?void 0:n.session_id)??C(s==null?void 0:s.session_id);if(!a)return null;const o=no(t.report_paths)??no(e==null?void 0:e.report_paths),r=zt(t.recent_events,["events"]).filter(W);return{session_id:a,status:C(t.status)??C(n==null?void 0:n.status)??C(s==null?void 0:s.status),progress_pct:it(t.progress_pct)??it(n==null?void 0:n.progress_pct),elapsed_sec:it(t.elapsed_sec)??it(n==null?void 0:n.elapsed_sec),remaining_sec:it(t.remaining_sec)??it(n==null?void 0:n.remaining_sec),done_delta_total:it(t.done_delta_total)??it(n==null?void 0:n.done_delta_total),summary:n,team_health:W(t.team_health)?t.team_health:W(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:W(t.communication_metrics)?t.communication_metrics:W(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:W(t.orchestration_state)?t.orchestration_state:W(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:W(t.cascade_metrics)?t.cascade_metrics:W(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:s,recent_events:r}}function $u(t){if(!W(t))return null;const e=C(t.name);if(!e)return null;const n=W(t.context)?t.context:void 0;return{name:e,agent_name:C(t.agent_name),status:C(t.status),autonomy_level:C(t.autonomy_level),context_ratio:it(t.context_ratio)??it(n==null?void 0:n.context_ratio),generation:it(t.generation),active_goal_ids:pu(t.active_goal_ids),last_autonomous_action_at:C(t.last_autonomous_action_at)??null,last_turn_ago_s:it(t.last_turn_ago_s),model:C(t.model)??C(t.active_model)??C(t.primary_model)}}function hu(t){if(!W(t))return null;const e=C(t.confirm_token)??C(t.token);return e?{confirm_token:e,actor:C(t.actor),action_type:C(t.action_type),target_type:C(t.target_type),target_id:C(t.target_id)??null,delegated_tool:C(t.delegated_tool),created_at:C(t.created_at),preview:t.preview}:null}function yu(t){const e=W(t)?t:{};return{room:vu(e.room),sessions:zt(e.sessions,["items","sessions"]).map(gu).filter(n=>n!==null),keepers:zt(e.keepers,["items","keepers"]).map($u).filter(n=>n!==null),recent_messages:zt(e.recent_messages,["messages"]).map(mu).filter(n=>n!==null),pending_confirms:zt(e.pending_confirms,["items","confirms"]).map(hu).filter(n=>n!==null),available_actions:zt(e.available_actions,["actions"]).filter(W).map(n=>({action_type:C(n.action_type)??"unknown",target_type:C(n.target_type)??"unknown",description:C(n.description),confirm_required:ca(n.confirm_required)}))}}function rs(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function so(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function js(t){Es.value=[{...t,id:uu++,at:new Date().toISOString()},...Es.value].slice(0,20)}function ur(t){return t.confirm_required?rs(t.preview)||"Confirmation required":rs(t.result)||rs(t.executed_action)||rs(t.delegated_tool_result)||t.status}async function ct(){Dn.value=!0,pe.value=null;try{const t=await Vl();Kt.value=yu(t)}catch(t){pe.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Dn.value=!1}}async function Qt(){zn.value=!0,tn.value=null;try{const t=await Ko({targetType:"room"});rr.value=dr(t)}catch(t){tn.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{zn.value=!1}}async function en(t){if(!t){Ut.value=null;return}zn.value=!0,tn.value=null;try{const e=await Ko({targetType:"team_session",targetId:t,includeWorkers:!0});Ut.value=dr(e)}catch(e){tn.value=e instanceof Error?e.message:"Failed to load session digest"}finally{zn.value=!1}}async function bu(t){var e;X.value=!0,pe.value=null;try{const n=await ra(t);return js({actor:t.actor,action_type:t.action_type,target_label:so(t),outcome:n.confirm_required?"preview":"executed",message:ur(n),delegated_tool:n.delegated_tool}),await ct(),await Qt(),(e=Ut.value)!=null&&e.target_id&&await en(Ut.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw pe.value=s,js({actor:t.actor,action_type:t.action_type,target_label:so(t),outcome:"error",message:s}),n}finally{X.value=!1}}async function ku(t,e){var n;X.value=!0,pe.value=null;try{const s=await ac(t,e);return js({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:ur(s),delegated_tool:s.delegated_tool}),await ct(),await Qt(),(n=Ut.value)!=null&&n.target_id&&await en(Ut.value.target_id),s}catch(s){const a=s instanceof Error?s.message:"Operator confirmation failed";throw pe.value=a,js({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),s}finally{X.value=!1}}Nd(()=>{var t;ct(),Qt(),(t=Ut.value)!=null&&t.target_id&&en(Ut.value.target_id)});function xu(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Su(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Au(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function ao(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function pr(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Cu(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function mr(t){if(!t)return null;const e=Vt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function wu({keeper:t,showRawStatus:e=!1}){if(lt(()=>{t!=null&&t.name&&Go(t.name)},[t==null?void 0:t.name]),!t)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Vt.value[t.name],s=mr(t),a=Ya.value[t.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${xu(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Su((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?i` · ${pr(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?i` · next eligible ${Cu(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Tu({keeperName:t,placeholder:e}){const[n,s]=No("");lt(()=>{t&&Go(t)},[t]);const a=vt.value[t]??[],o=Qa.value[t]??!1,r=Yt.value[t],l=async()=>{const p=n.trim();if(!(!t||!p)){s("");try{await td(t,p)}catch(m){const d=m instanceof Error?m.message:`Failed to message ${t}`;D(d,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(p=>i`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${ao(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${ao(p)}`}>${Au(p)}</span>
                  ${p.timestamp?i`<span class="keeper-conversation-time">${pr(p.timestamp)}</span>`:null}
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
            onClick=${()=>{l()}}
            disabled=${o||n.trim()===""||!t}
          >
            ${o?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${r?i`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function Iu({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=mr(e),a=Xa.value[e.name]??!1,o=Za.value[e.name]??!1,r=(s==null?void 0:s.next_action_path)??"direct_message",l=(s==null?void 0:s.recoverable)??r==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{ed(e.name,t).catch(p=>{const m=p instanceof Error?p.message:`Failed to probe ${e.name}`;D(m,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{nd(e.name,t).catch(p=>{const m=p instanceof Error?p.message:`Failed to recover ${e.name}`;D(m,"error")})}}
        disabled=${o||!l||!t.trim()}
      >
        ${o?"Recovering...":"Recover"}
      </button>
      <button
        class=${`control-btn ghost ${r==="manual_lodge_poke"?"is-active":""}`}
        onClick=${n}
      >
        Poke Lodge
      </button>
    </div>
  `}const Ti=_(null);function Ii(t){Ti.value=t,Zc(t.name)}function io(){Ti.value=null}const De=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Ru(t){if(!t)return 0;const e=De.findIndex(n=>n.level===t);return e>=0?e:0}function Nu({keeper:t}){const e=Ru(t.autonomy_level),n=De[e]??De[0];if(!n)return null;const s=(e+1)/De.length*100;return i`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${De.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${De.map((a,o)=>i`
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
            <strong><${ot} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?i`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Ss(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Pu(t){switch(t){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(t==null?void 0:t.trim())||"action"}}function Lu(t){return t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]}function Mu(t){const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Du({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Ss(t.context_tokens)}</div>
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
  `}function zu({keeper:t}){var d,u;const e=t.metrics_series??[];if(e.length<2){const v=(((d=t.context)==null?void 0:d.context_ratio)??0)*100,$=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${$}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=e.length,r=e.map((v,$)=>{const x=a+$/(o-1)*(n-2*a),S=s-a-(v.context_ratio??0)*(s-2*a);return{x,y:S,p:v}}),l=r.map(({x:v,y:$})=>`${v.toFixed(1)},${$.toFixed(1)}`).join(" "),p=(((u=e[e.length-1])==null?void 0:u.context_ratio)??0)*100,m=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:v})=>v.is_handoff).map(({x:v})=>i`
          <line x1="${v.toFixed(1)}" y1="${a}" x2="${v.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${m}" stroke-width="1.5"/>
        ${r.filter(({p:v})=>v.is_compaction).map(({x:v,y:$})=>i`
          <circle cx="${v.toFixed(1)}" cy="${$.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}const $a=_("");function Eu({keeper:t}){var a,o,r,l;const e=$a.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],s=e?n.filter(p=>p.title.toLowerCase().includes(e)||p.key.includes(e)||p.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${$a.value}
        onInput=${p=>{$a.value=p.target.value}}
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
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Ss(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Ss(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Ss(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function ju({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
  `}function Ou({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Fu({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function oo({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function ha(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function qu({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:ha(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:ha(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:ha(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(s=>i`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function Ku({keeper:t}){var m,d,u,v,$,x,S;const e=((m=Kt.value)==null?void 0:m.room)??{},n=(((d=Kt.value)==null?void 0:d.available_actions)??[]).filter(T=>T.target_type==="keeper"||T.target_type==="room").slice(0,8),s=Lu(t),a=Mu(t),o=((u=t.agent)==null?void 0:u.capabilities)??[],r=e.current_room??e.room_id??((v=xt.value)==null?void 0:v.room)??"default",l=e.project??(($=xt.value)==null?void 0:$.project)??"확인 없음",p=e.cluster??((x=xt.value)==null?void 0:x.cluster)??"확인 없음";return i`
    <div class="keeper-signal-list">
      <div class="keeper-signal-row">
        <span>Room</span>
        <strong>${r}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Project</span>
        <strong>${l}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Cluster</span>
        <strong>${p}</strong>
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
          ${s.length>0?s.map(T=>i`<span class="pill">${T}</span>`):i`<span style="font-size:12px; color:#888;">도구 텔레메트리 없음</span>`}
        </div>
      </div>
      ${s.length===0&&a.length>0?i`
            <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
              <span style="font-size:12px; color:#888;">Window top tools</span>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${a.map(T=>i`<span class="pill">${T}</span>`)}
              </div>
            </div>
          `:null}
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Capabilities</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${o.length>0?o.map(T=>i`<span class="pill">${T}</span>`):i`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(T=>i`<span class="pill">${Pu(T.action_type)}</span>`):i`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function vr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function Uu(){try{const t=await ra({actor:vr(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Bo(t.result);await Vn(),e!=null&&e.skipped_reason?D(e.skipped_reason,"warning"):D(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";D(e,"error")}}function Hu({keeper:t}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${wu} keeper=${t} />
          <${Iu}
            actor=${vr()}
            keeper=${t}
            onPokeLodge=${()=>{Uu()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Tu}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function Wu(){var e,n,s;const t=Ti.value;return t?i`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&io()}}
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
            <${ve} status=${t.status} />
            ${t.model?i`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>io()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Du} keeper=${t} />

        ${""}
        <${zu} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${P} title="Field Dictionary">
            <${Eu} keeper=${t} />
          <//>

          ${""}
          <${P} title="Profile">
            <${oo} traits=${t.traits??[]} label="Traits" />
            <${oo} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${ot} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?i`
              <${P} title="Autonomy">
                <${Nu} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?i`
              <${P} title="TRPG Stats">
                <${ju} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${P} title="Equipment (${t.inventory.length})">
                <${Ou} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${P} title="Relationships (${Object.keys(t.relationships).length})">
                <${Fu} rels=${t.relationships} />
              <//>
            `:null}

          <${P} title="Runtime Signals">
            <${qu} keeper=${t} />
          <//>

          <${P} title="Neighborhood & Tools">
            <${Ku} keeper=${t} />
          <//>

          <${P} title="Memory & Context">
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
        <${Hu} keeper=${t} />
      </div>
    </div>
  `:null}const Os="masc_dashboard_workflow_context",Bu=900*1e3;function Ri(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function Ct(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function ee(t){const e=Ct(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function _r(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function li(t){return Ri(t)?t:null}function Gu(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function Ju(t){if(!t)return null;try{const e=JSON.parse(t);if(!Ri(e))return null;const n=Ct(e.id),s=Ct(e.source_surface),a=Ct(e.source_label),o=Ct(e.summary),r=Ct(e.created_at);return!n||s!=="mission"||!a||!o||!r?null:{id:n,source_surface:"mission",source_label:a,action_type:Ct(e.action_type),target_type:Ct(e.target_type),target_id:Ct(e.target_id),focus_kind:Ct(e.focus_kind),summary:o,payload_preview:Ct(e.payload_preview),suggested_payload:li(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:r}}catch{return null}}function Ni(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=Bu}function Vu(){const t=_r(),e=Ju((t==null?void 0:t.getItem(Os))??null);return e?Ni(e)?e:(t==null||t.removeItem(Os),null):null}const fr=_(Vu());function Yu(t){const e=t&&Ni(t)?t:null;fr.value=e;const n=_r();if(!n)return;if(!e){n.removeItem(Os);return}const s=Gu(e);s&&n.setItem(Os,s)}function Qu(t){if(!t)return null;const e=li(t.suggested_payload);if(e)return e;if(Ri(t.preview)){const n=li(t.preview.payload);if(n)return n}return null}function Xu(t){if(!t)return null;const e=ee(t.message);if(e)return e;const n=ee(t.task_title)??ee(t.title),s=ee(t.task_description)??ee(t.description),a=ee(t.reason),o=ee(t.priority)??ee(t.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function gr(t,e,n,s,a,o){return["mission",t,e??"action",n??"target",s??"room",a??"focus",o].join(":")}function rn(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=Qu(t),o=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,r=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,l=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,p=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:gr(n,(t==null?void 0:t.action_type)??null,o,r,l,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:o,target_id:r,focus_kind:l,summary:p,payload_preview:Xu(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function Zu(t,e){return e.source==="mission"&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)}function Yn(t){const{params:e}=t;if(e.source!=="mission")return null;const n=fr.value;if(n&&Ni(n)&&Zu(n,e))return n;const s=new Date().toISOString();return{id:gr("상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,s),source_surface:"mission",source_label:"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,summary:e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function tp(t){return{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function $r(t){const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.target_type==="room"?"summary":"swarm"}function ep(t){return{source:"mission",surface:$r(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function Pi(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function da(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";default:return(t==null?void 0:t.trim())||"추천 액션"}}function np(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}const ie=_(null),Bt=_(null);function et(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function _t(t){return t==="bad"||t==="offline"||t==="critical"||t==="risk"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"||t==="watch"?"warn":"ok"}function we(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:n<86400?`${Math.round(n/3600)}h 전`:`${Math.round(n/86400)}d 전`}function sp(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:t<86400?`${Math.round(t/3600)}h`:`${Math.round(t/86400)}d`}function ap(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function ip(t){return Pi(t?rn(t,null,"상황판 추천 액션"):null)}function ua(t,e=rn()){Yu(e),$t(t,t==="intervene"?tp(e):ep(e))}function hr(t){ua("intervene",rn(null,t,"상황판 incident"))}function yr(t){ua("command",rn(null,t,"상황판 incident"))}function Li(t,e,n="상황판 추천 액션"){ua("intervene",rn(t,e,n))}function br(t,e,n="상황판 추천 액션"){ua("command",rn(t,e,n))}function ro(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),$t(t,n)}function op(t){return{kind:t.kind,severity:t.severity,summary:t.summary,target_type:t.target_type,target_id:t.target_id??null,actor:null,evidence:t.evidence_preview}}function kr(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>(s.from??"").trim().toLowerCase()===n).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function rp(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>{if((s.from??"").trim().toLowerCase()===n)return!1;const o=(s.content??"").trim().toLowerCase();return o.includes(`@${n}`)||o.includes(n)}).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function lp(t){return Zt.value.find(e=>e.agent_name===t||e.name===t)??null}function xr(t){return It.value.find(e=>e.name===t)??null}function Sr(t,e){const n=et(t,100);if(!n)return null;const s=e.find(o=>o.id===n);if(s)return`${s.id} · ${et(s.title,92)}`;const a=e.find(o=>o.title===n);return a?`${a.id} · ${et(a.title,92)}`:n}function cp(t){var l,p;const e=xr(t.agent_name),n=lp(t.agent_name),s=kr(t.agent_name,Xe.value),a=rp(t.agent_name,Xe.value),o=Ai(t.agent_name),r=(n==null?void 0:n.skill_primary)??(e!=null&&e.capabilities&&e.capabilities.length>0?e.capabilities.slice(0,3).join(", "):null)??o.model??(e==null?void 0:e.agent_type)??null;return{brief:t,agent:e,keeper:n,where:t.where??"room",withWhom:t.with_whom,currentWork:t.current_work??Sr((e==null?void 0:e.current_task)??null,Ot.value)??"명시된 current task 없음",how:r,recentInput:et(t.recent_input_preview,120)??et(a==null?void 0:a.content,120)??et(n==null?void 0:n.recent_input_preview,120)??null,recentOutput:et(t.recent_output_preview,120)??et(s==null?void 0:s.content,120)??et(n==null?void 0:n.recent_output_preview,120)??et((l=n==null?void 0:n.diagnostic)==null?void 0:l.last_reply_preview,120)??null,recentEvent:et(t.recent_event,120)??et((p=n==null?void 0:n.diagnostic)==null?void 0:p.summary,120)??null,recentTools:t.recent_tool_names.length>0?t.recent_tool_names:(n==null?void 0:n.recent_tool_names)??[]}}function dp(t){var n,s;const e=Zt.value.find(a=>a.name===t.name||a.agent_name===t.agent_name)??null;return{brief:t,keeper:e,currentWork:et(t.current_work,110)??et(e==null?void 0:e.skill_primary,110)??et(e==null?void 0:e.last_proactive_reason,110)??"명시된 keeper focus 없음",recentInput:et(e==null?void 0:e.recent_input_preview,120)??null,recentOutput:et(e==null?void 0:e.recent_output_preview,120)??et((n=e==null?void 0:e.diagnostic)==null?void 0:n.last_reply_preview,120)??et(e==null?void 0:e.last_proactive_preview,120)??null,recentEvent:et(e==null?void 0:e.last_proactive_reason,120)??et((s=e==null?void 0:e.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(e==null?void 0:e.recent_tool_names)??[]}}function up(){const t=Ci.value;return t?new Map(t.session_briefs.map(e=>[e.session_id,e])):new Map}function pp(t){const e=xr(t),n=kr(t,Xe.value),s=Ai(t);return{name:t,model:s.model,nickname:s.nickname,currentTask:Sr((e==null?void 0:e.current_task)??null,Ot.value)??"agent snapshot 없음",output:et(n==null?void 0:n.content,96)}}function mp(t){ie.value=ie.value===t?null:t,Bt.value=null}function Ar(t){Bt.value=Bt.value===t?null:t}function vp(){ie.value=null,Bt.value=null}function _p({cluster:t,project:e,room:n,generatedAt:s}){return i`
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
        <strong>${s?we(s):"fresh"}</strong>
      </div>
    </div>
  `}function Le({label:t,value:e,detail:n,tone:s}){return i`
    <article class="mission-stat-card ${_t(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function fp(){const t=sr.value,e=_t((t==null?void 0:t.status)??(ke.value?"bad":"warn")),n=(t==null?void 0:t.status)==="error"||(t==null?void 0:t.status)==="unavailable"&&!(t!=null&&t.cached);return i`
    <${P} title="LLM 판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>heuristic 대신 별도 판단 계층</h3>
        <p>핵심 해석 3줄만 먼저 보여주고, 근거는 접어서 둡니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${e}">
          ${(t==null?void 0:t.status)??(ke.value?"error":"loading")}
        </span>
        ${t!=null&&t.model?i`<span class="command-chip">${t.model}</span>`:null}
        ${t!=null&&t.generated_at?i`<span class="command-chip">${we(t.generated_at)}</span>`:null}
        ${t!=null&&t.cached?i`<span class="command-chip">cached</span>`:null}
        ${t!=null&&t.stale?i`<span class="command-chip warn">stale</span>`:null}
      </div>

      ${ke.value?i`<div class="empty-state error">${ke.value}</div>`:null}
      ${t!=null&&t.error?i`<div class="empty-state error">${t.error}</div>`:null}
      ${t!=null&&t.summary?i`<div class="mission-inline-note">${t.summary}</div>`:null}

      ${t&&t.sections.length>0?i`
            <div class="mission-briefing-grid">
              ${t.sections.slice(0,3).map(s=>i`
                <article class="mission-briefing-section ${_t(s.status)}">
                  <div class="mission-card-head">
                    <strong>${s.label}</strong>
                    <span class="command-chip ${_t(s.status)}">${s.status}</span>
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
          `:!Oe.value&&!ke.value?i`<div class="empty-state">판단 레이어 결과가 아직 없습니다.</div>`:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{Pn(n)}} disabled=${Oe.value}>
          ${Oe.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{Pn(!0)}} disabled=${Oe.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function gp({item:t,selected:e,sessionLookup:n}){const s=op(t),a=t.related_session_ids.map(r=>n.get(r)).filter(r=>r!=null),o=t.top_action??null;return i`
    <article class="mission-attention-card ${_t((o==null?void 0:o.severity)??t.severity)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>mp(t.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.summary}</strong>
            <div class="mission-card-target">${t.kind}${t.target_id?` · ${t.target_id}`:""}</div>
          </div>
          <span class="command-chip ${_t((o==null?void 0:o.severity)??t.severity)}">${o?ap(o):t.severity}</span>
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
            <strong>${t.last_seen_at?we(t.last_seen_at):"n/a"}</strong>
            <small>${t.target_type}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${o?da(o.action_type):"판단 필요"}</strong>
            <small>${o?ip(o):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${o?i`<div class="mission-inline-note">${o.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?i`
              <div class="mission-link-list">
                ${a.slice(0,4).map(r=>i`
                  <button class="mission-link-row" onClick=${()=>Ar(r.session_id)}>
                    <strong>${r.goal}</strong>
                    <span>${r.status??"unknown"} · ${r.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:i`<div class="empty-state">직접 연결된 session이 아직 없습니다.</div>`}

        ${t.related_agent_names.length>0?i`
              <div class="mission-pill-row">
                ${t.related_agent_names.slice(0,8).map(r=>i`
                  <button class="mission-pill action" onClick=${()=>Ze(r)}>${r}</button>
                `)}
              </div>
            `:null}

        ${t.evidence_preview.length>0?i`
              <details class="mission-card-disclosure compact">
                <summary>evidence preview</summary>
                <div class="mission-evidence-list">
                  ${t.evidence_preview.map(r=>i`<span>${r}</span>`)}
                </div>
              </details>
            `:null}
      </details>

      <div class="mission-card-actions">
        ${o?i`
              <button class="control-btn ghost" onClick=${()=>Li(o,s,"Mission attention")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>br(o,s,"Mission attention")}>
                원인 보기
              </button>
            `:i`
              <button class="control-btn ghost" onClick=${()=>hr(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>yr(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function $p({brief:t,selected:e}){var o,r;const n=t.member_names.slice(0,6).map(pp),s=t.top_recommendation??null,a=t.top_attention??null;return i`
    <article class="mission-crew-card ${_t(((o=t.top_attention)==null?void 0:o.severity)??t.health??t.status)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Ar(t.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.goal}</strong>
            <div class="mission-card-target">${t.session_id}${t.room?` · ${t.room}`:""}</div>
          </div>
          <span class="command-chip ${_t(((r=t.top_attention)==null?void 0:r.severity)??t.health??t.status)}">${t.status??"unknown"}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${t.member_names.length}</strong>
            <small>${t.member_names.slice(0,3).join(", ")||"n/a"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${sp(t.elapsed_sec)}</strong>
            <small>${t.started_at?`${we(t.started_at)} 시작`:"시작 시각 없음"}</small>
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
        <small>${t.last_event_at?we(t.last_event_at):"시각 없음"}</small>
      </div>

      ${t.top_attention?i`<div class="mission-inline-note">attention: ${t.top_attention.summary}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>session detail</summary>
        ${n.length>0?i`
              <div class="mission-pill-row">
                ${n.map(l=>i`
                  <button class="mission-pill action" onClick=${()=>Ze(l.name)}>
                    ${l.model!==l.nickname?`${l.model} · `:""}${l.nickname}
                  </button>
                `)}
              </div>
            `:null}

        ${n.length>0?i`
              <details class="mission-card-disclosure compact">
                <summary>member output preview</summary>
                <div class="mission-link-list">
                  ${n.map(l=>i`
                    <button class="mission-link-row" onClick=${()=>Ze(l.name)}>
                      <strong>${l.nickname}</strong>
                      <span>${l.currentTask}</span>
                      <small>${l.output??"최근 출력 없음"}</small>
                    </button>
                  `)}
                </div>
              </details>
            `:null}
      </details>

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>ro("intervene",t.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>ro("command",t.session_id)}>세션 원인 보기</button>
        ${s?i`<button class="control-btn ghost" onClick=${()=>Li(s,a,"Mission session brief")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function hp({row:t}){var s,a,o,r,l;const e=Ai(t.brief.agent_name),n=t.withWhom.length>0?t.withWhom.slice(0,3).join(", "):"단독 또는 room-level";return i`
    <article class="mission-activity-card ${_t(t.brief.status??((s=t.agent)==null?void 0:s.status))}">
      <button class="mission-card-select" onClick=${()=>Ze(t.brief.agent_name)}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((a=t.agent)==null?void 0:a.emoji)??((o=t.keeper)==null?void 0:o.emoji)??""}</span>
            <div>
              <strong>${t.brief.agent_name}</strong>
              <span>${e.model!==e.nickname?`${e.model} · `:""}${e.nickname}</span>
            </div>
          </div>
          <span class="command-chip ${_t(t.brief.status??((r=t.agent)==null?void 0:r.status))}">${t.brief.status??((l=t.agent)==null?void 0:l.status)??"unknown"}</span>
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
  `}function yp({row:t}){var n,s,a,o,r,l,p,m,d,u;const e=[`gen ${t.brief.generation??((n=t.keeper)==null?void 0:n.generation)??0}`,t.brief.context_ratio!=null?`ctx ${Math.round(t.brief.context_ratio*100)}%`:((s=t.keeper)==null?void 0:s.context_ratio)!=null?`ctx ${Math.round(t.keeper.context_ratio*100)}%`:null,t.brief.last_turn_ago_s!=null?`last turn ${Math.round(t.brief.last_turn_ago_s)}s`:null].filter(v=>v!==null).join(" · ");return i`
    <article class="mission-activity-card ${_t(t.brief.status??((a=t.keeper)==null?void 0:a.status))}">
      <button class="mission-card-select" onClick=${()=>{t.keeper&&Ii(t.keeper)}}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((o=t.keeper)==null?void 0:o.emoji)??""}</span>
            <div>
              <strong>${t.brief.name}</strong>
              ${(r=t.keeper)!=null&&r.koreanName?i`<span>${t.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <span class="command-chip ${_t(t.brief.status??((l=t.keeper)==null?void 0:l.status))}">${t.brief.status??((p=t.keeper)==null?void 0:p.status)??"unknown"}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 heartbeat · ${(m=t.keeper)!=null&&m.last_heartbeat?we(t.keeper.last_heartbeat):"n/a"}</span>
          <span>${e||"continuity 정보 없음"}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${t.currentWork}</strong>
          ${(d=t.keeper)!=null&&d.skill_reason?i`<small>판단 요약 · ${et(t.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>continuity detail</summary>
        <div class="mission-activity-foot">
          <span>agent · ${t.brief.agent_name??((u=t.keeper)==null?void 0:u.agent_name)??"n/a"}</span>
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
  `}function bp({item:t}){const e=t.action??null,n=t.attention??null;return i`
    <article class="mission-action-card ${_t(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${_t(t.severity)}">
          ${t.signal_type==="action"&&e?da(e.action_type):(n==null?void 0:n.kind)??"signal"}
        </span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      ${e?i`<div class="mission-action-preview">${e.reason}</div>`:null}
      <div class="mission-card-actions">
        ${e?i`
              <button class="control-btn ghost" onClick=${()=>Li(e,n,"Mission internal signal")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>br(e,n,"Mission internal signal")}>이 이슈의 원인 보기</button>
            `:n?i`
                <button class="control-btn ghost" onClick=${()=>hr(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>yr(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function lo(){var v,$,x,S,T,N,I;const t=Ci.value;if(ri.value&&!t)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(Ms.value&&!t)return i`<div class="empty-state error">${Ms.value}</div>`;if(!t)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;ie.value&&!t.attention_queue.some(A=>A.id===ie.value)&&(ie.value=null),Bt.value&&!t.session_briefs.some(A=>A.session_id===Bt.value)&&(Bt.value=null);const e=t.attention_queue.find(A=>A.id===ie.value)??null,n=Bt.value,s=up(),a=e?new Set(e.related_session_ids):null,o=e?new Set(e.related_agent_names):null,r=(a?t.session_briefs.filter(A=>a.has(A.session_id)):t.session_briefs).slice(0,e?8:6),l=t.agent_briefs.filter(A=>!Ed(A.agent_name)).filter(A=>n?A.related_session_id===n:o&&a?o.has(A.agent_name)||(A.related_session_id?a.has(A.related_session_id):!1):!0).slice(0,n||e?10:8).map(cp),p=t.keeper_briefs.slice(0,6).map(dp),m=t.attention_queue.slice(0,6),d=t.internal_signals.slice(0,3),u=l.filter(A=>A.recentOutput).length+p.filter(A=>A.recentOutput).length;return i`
    <section class="dashboard-panel mission-view">
      <${St} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>원인 분석과 개입 판단을 먼저 보는 landing 입니다. 문제 → 영향 session → 관련 actor 순서로 좁혀서 읽습니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${_t(t.summary.room_health)}">${t.summary.room_health??"ok"}</span>
          <span class="command-chip">${t.summary.project??"room"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?we(t.generated_at):"fresh"}</span>
        </div>
      </div>

      <${_p}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <${fp} />

      <div class="mission-stat-grid">
        <${Le} label="주의 큐" value=${m.length} detail="개입 판단이 필요한 issue" tone=${((v=m[0])==null?void 0:v.severity)??"ok"} />
        <${Le} label="영향 session" value=${r.length} detail="현재 선택 기준으로 좁힌 흐름" tone=${((x=($=r[0])==null?void 0:$.top_attention)==null?void 0:x.severity)??((S=r[0])==null?void 0:S.health)??"ok"} />
        <${Le} label="영향 agent" value=${l.length} detail="선택된 흐름에 연결된 actor" tone=${((T=l[0])==null?void 0:T.brief.status)??"ok"} />
        <${Le} label="Keeper watch" value=${p.length} detail="continuity lane 관찰 대상" tone=${((N=p[0])==null?void 0:N.brief.status)??"ok"} />
        <${Le} label="최근 output" value=${u} detail="선택된 영역에서 바로 읽을 수 있는 출력 수" tone=${u>0?"ok":"warn"} />
        <${Le} label="내부 신호" value=${d.length} detail="room/system 진단은 하단 보조 lane" tone=${((I=d[0])==null?void 0:I.severity)??"ok"} />
      </div>

      ${e||n?i`
            <div class="mission-selection-bar">
              <span>현재 drill-down · ${e?e.summary:"session 선택"}${n?` · ${n}`:""}</span>
              <button class="control-btn ghost" onClick=${vp}>선택 해제</button>
            </div>
          `:null}

      <${P} title="Attention Queue" class="mission-list-card" semanticId="mission.attention_queue">
        <div class="mission-section-head">
          <h3>이슈에서 시작</h3>
          <p>문제와 경고를 먼저 보고, 여기서 session과 agent로 좁혀갑니다.</p>
        </div>
        <div class="mission-lane-stack">
          ${m.length>0?m.map(A=>i`<${gp} key=${A.id} item=${A} selected=${ie.value===A.id} sessionLookup=${s} />`):i`<div class="empty-state">지금 Mission attention queue가 비어 있습니다.</div>`}
        </div>
      <//>

      <div class="mission-human-grid">
        <${P} title="Affected Sessions" class="mission-list-card" semanticId="mission.session_briefs">
          <div class="mission-section-head">
            <h3>영향받는 session</h3>
            <p>attention과 직접 연결된 흐름만 먼저 보여주고, member preview는 한 단계 더 열었을 때만 보여줍니다.</p>
          </div>
          <div class="mission-list-stack">
            ${r.length>0?r.map(A=>i`<${$p} key=${A.session_id} brief=${A} selected=${Bt.value===A.session_id} />`):i`<div class="empty-state">현재 선택과 연결된 session이 없습니다.</div>`}
          </div>
        <//>

        <${P} title="Impacted Agents" class="mission-list-card" semanticId="mission.agent_activity">
          <div class="mission-section-head">
            <h3>관련 agent</h3>
            <p>선택된 incident 또는 session과 연결된 actor만 보여주고, input-output은 접어서 둡니다.</p>
          </div>
          <div class="mission-activity-list">
            ${l.length>0?l.map(A=>i`<${hp} key=${A.brief.agent_name} row=${A} />`):i`<div class="empty-state">현재 선택과 연결된 agent가 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${P} title="Keeper Continuity" class="mission-list-card" semanticId="mission.keeper_activity">
          <div class="mission-section-head">
            <h3>continuity lane</h3>
            <p>keeper는 별도 lane으로 보고, continuity 판단에 필요한 정보만 먼저 보여줍니다.</p>
          </div>
          <div class="mission-activity-list">
            ${p.length>0?p.map(A=>i`<${yp} key=${A.brief.name} row=${A} />`):i`<div class="empty-state">지금 보이는 keeper가 없습니다.</div>`}
          </div>
        <//>

        <${P} title="Internal Signals" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>room / system 보조 신호</h3>
            <p>artifact scope drift 같은 시스템 진단은 메인 판단 근거가 아니라 보조 lane으로만 유지합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${d.length>0?d.map(A=>i`<${bp} key=${A.id} item=${A} />`):i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>$t("execution")}>실행 관찰면 보기</button>
            <button class="control-btn ghost" onClick=${()=>$t("command")}>지휘 진단면 보기</button>
          </div>
        <//>
      </div>
    </section>
  `}const Mi=_(null),Wt=_(null),Fs=_(!1),qs=_(!1),Ks=_(null),Us=_(null),ci=_(null),Hs=_(null),G=_("warroom"),Qn=_(null),di=_(!1),Ws=_(null),Ie=_(null),Bs=_(!1),Gs=_(null),Xn=_(null),ui=_(!1),Js=_(null),En=_(null),Vs=_(!1),jn=_(null),Je=_(null);let _n=null;function Di(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"}function w(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function c(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function g(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function at(t){return typeof t=="boolean"?t:void 0}function ft(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Cr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function kp(){const e=Cr().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function xp(){const e=Cr().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Sp(t){if(w(t))return{policy_class:c(t.policy_class),approval_class:c(t.approval_class),tool_allowlist:ft(t.tool_allowlist),model_allowlist:ft(t.model_allowlist),requires_human_for:ft(t.requires_human_for),autonomy_level:c(t.autonomy_level),escalation_timeout_sec:g(t.escalation_timeout_sec),kill_switch:at(t.kill_switch),frozen:at(t.frozen)}}function Ap(t){if(w(t))return{headcount_cap:g(t.headcount_cap),active_operation_cap:g(t.active_operation_cap),max_cost_usd:g(t.max_cost_usd),max_tokens:g(t.max_tokens)}}function zi(t){if(!w(t))return null;const e=c(t.unit_id),n=c(t.label),s=c(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:c(t.parent_unit_id)??null,leader_id:c(t.leader_id)??null,roster:ft(t.roster),capability_profile:ft(t.capability_profile),source:c(t.source),created_at:c(t.created_at),updated_at:c(t.updated_at),policy:Sp(t.policy),budget:Ap(t.budget)}}function wr(t){if(!w(t))return null;const e=zi(t.unit);return e?{unit:e,leader_status:c(t.leader_status),roster_total:g(t.roster_total),roster_live:g(t.roster_live),active_operation_count:g(t.active_operation_count),health:c(t.health),reasons:ft(t.reasons),children:Array.isArray(t.children)?t.children.map(wr).filter(n=>n!==null):[]}:null}function Cp(t){if(w(t))return{total_units:g(t.total_units),company_count:g(t.company_count),platoon_count:g(t.platoon_count),squad_count:g(t.squad_count),leaf_agent_unit_count:g(t.leaf_agent_unit_count),live_agent_count:g(t.live_agent_count),managed_unit_count:g(t.managed_unit_count),active_operation_count:g(t.active_operation_count)}}function Tr(t){const e=w(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),source:c(e.source),summary:Cp(e.summary),units:Array.isArray(e.units)?e.units.map(wr).filter(n=>n!==null):[]}}function wp(t){if(!w(t))return null;const e=c(t.kind),n=c(t.status);return!e||!n?null:{kind:e,chain_id:c(t.chain_id)??null,goal:c(t.goal)??null,run_id:c(t.run_id)??null,status:n,viewer_path:c(t.viewer_path)??null,last_sync_at:c(t.last_sync_at)??null}}function pa(t){if(!w(t))return null;const e=c(t.operation_id),n=c(t.objective),s=c(t.assigned_unit_id),a=c(t.trace_id),o=c(t.status);return!e||!n||!s||!a||!o?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:c(t.autonomy_level),policy_class:c(t.policy_class),budget_class:c(t.budget_class),detachment_session_id:c(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:c(t.checkpoint_ref)??null,active_goal_ids:ft(t.active_goal_ids),note:c(t.note)??null,created_by:c(t.created_by),source:c(t.source),status:o,chain:wp(t.chain),created_at:c(t.created_at),updated_at:c(t.updated_at)}}function Tp(t){if(!w(t))return null;const e=pa(t.operation);return e?{operation:e,assigned_unit_label:c(t.assigned_unit_label)}:null}function pn(t){if(w(t))return{tone:c(t.tone),pending_ops:g(t.pending_ops),blocked_ops:g(t.blocked_ops),in_flight_ops:g(t.in_flight_ops),pipeline_stalls:g(t.pipeline_stalls),bus_traffic:g(t.bus_traffic),l1_hit_rate:g(t.l1_hit_rate),invalidation_count:g(t.invalidation_count),current_pending:g(t.current_pending),current_in_flight:g(t.current_in_flight),cdb_wakeups:g(t.cdb_wakeups),total_stolen:g(t.total_stolen),avg_best_score:g(t.avg_best_score),avg_candidate_count:g(t.avg_candidate_count),best_first_operations:g(t.best_first_operations),active_sessions:g(t.active_sessions),commit_rate:g(t.commit_rate),total_speculations:g(t.total_speculations)}}function Ip(t){if(!w(t))return;const e=w(t.pipeline)?t.pipeline:void 0,n=w(t.cache)?t.cache:void 0,s=w(t.ooo)?t.ooo:void 0,a=w(t.speculative)?t.speculative:void 0,o=w(t.search_fabric)?t.search_fabric:void 0,r=w(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:g(e.total_ops),completed_ops:g(e.completed_ops),stalled_cycles:g(e.stalled_cycles),hazards_detected:g(e.hazards_detected),forwarding_used:g(e.forwarding_used),pipeline_flushes:g(e.pipeline_flushes),ipc:g(e.ipc)}:void 0,cache:n?{total_reads:g(n.total_reads),total_writes:g(n.total_writes),l1_hit_rate:g(n.l1_hit_rate),invalidation_count:g(n.invalidation_count),writeback_count:g(n.writeback_count),bus_traffic:g(n.bus_traffic)}:void 0,ooo:s?{agent_count:g(s.agent_count),total_added:g(s.total_added),total_issued:g(s.total_issued),total_completed:g(s.total_completed),total_stolen:g(s.total_stolen),cdb_wakeups:g(s.cdb_wakeups),stall_cycles:g(s.stall_cycles),global_cdb_events:g(s.global_cdb_events),current_pending:g(s.current_pending),current_in_flight:g(s.current_in_flight)}:void 0,speculative:a?{total_speculations:g(a.total_speculations),total_commits:g(a.total_commits),total_aborts:g(a.total_aborts),commit_rate:g(a.commit_rate),total_fast_calls:g(a.total_fast_calls),total_cost_usd:g(a.total_cost_usd),active_sessions:g(a.active_sessions)}:void 0,search_fabric:o?{total_operations:g(o.total_operations),best_first_operations:g(o.best_first_operations),legacy_operations:g(o.legacy_operations),blocked_operations:g(o.blocked_operations),ready_operations:g(o.ready_operations),research_pipeline_operations:g(o.research_pipeline_operations),avg_candidate_count:g(o.avg_candidate_count),avg_best_score:g(o.avg_best_score),top_stage:c(o.top_stage)??null}:void 0,signals:r?{issue_pressure:pn(r.issue_pressure),cache_contention:pn(r.cache_contention),scheduler_efficiency:pn(r.scheduler_efficiency),routing_confidence:pn(r.routing_confidence),speculative_posture:pn(r.speculative_posture)}:void 0}}function Ir(t){const e=w(t)?t:{},n=w(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),summary:n?{total:g(n.total),active:g(n.active),paused:g(n.paused),managed:g(n.managed),projected:g(n.projected)}:void 0,microarch:Ip(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(Tp).filter(s=>s!==null):[]}}function Rr(t){if(!w(t))return null;const e=c(t.detachment_id),n=c(t.operation_id),s=c(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:c(t.leader_id)??null,roster:ft(t.roster),session_id:c(t.session_id)??null,checkpoint_ref:c(t.checkpoint_ref)??null,runtime_kind:c(t.runtime_kind)??null,runtime_ref:c(t.runtime_ref)??null,source:c(t.source),status:c(t.status),last_event_at:c(t.last_event_at)??null,last_progress_at:c(t.last_progress_at)??null,heartbeat_deadline:c(t.heartbeat_deadline)??null,created_at:c(t.created_at),updated_at:c(t.updated_at)}}function Rp(t){if(!w(t))return null;const e=Rr(t.detachment);return e?{detachment:e,assigned_unit_label:c(t.assigned_unit_label),operation:pa(t.operation)}:null}function Nr(t){const e=w(t)?t:{},n=w(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),summary:n?{total:g(n.total),active:g(n.active),projected:g(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(Rp).filter(s=>s!==null):[]}}function Np(t){if(!w(t))return null;const e=c(t.decision_id),n=c(t.trace_id),s=c(t.requested_action),a=c(t.scope_type),o=c(t.scope_id);return!e||!n||!s||!a||!o?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:c(t.operation_id)??null,target_unit_id:c(t.target_unit_id)??null,requested_by:c(t.requested_by),status:c(t.status),reason:c(t.reason)??null,source:c(t.source),detail:t.detail,created_at:c(t.created_at),decided_at:c(t.decided_at)??null,expires_at:c(t.expires_at)??null}}function Pr(t){const e=w(t)?t:{},n=w(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),summary:n?{total:g(n.total),pending:g(n.pending),approved:g(n.approved),denied:g(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(Np).filter(s=>s!==null):[]}}function Pp(t){if(!w(t))return null;const e=zi(t.unit);return e?{unit:e,roster_total:g(t.roster_total),roster_live:g(t.roster_live),headcount_cap:g(t.headcount_cap),active_operations:g(t.active_operations),active_operation_cap:g(t.active_operation_cap),utilization:g(t.utilization)}:null}function Lp(t){const e=w(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(Pp).filter(n=>n!==null):[]}}function Mp(t){if(!w(t))return null;const e=c(t.alert_id);return e?{alert_id:e,severity:c(t.severity),kind:c(t.kind),scope_type:c(t.scope_type),scope_id:c(t.scope_id),title:c(t.title),detail:c(t.detail),timestamp:c(t.timestamp)}:null}function Lr(t){const e=w(t)?t:{},n=w(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),summary:n?{total:g(n.total),bad:g(n.bad),warn:g(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(Mp).filter(s=>s!==null):[]}}function Mr(t){if(!w(t))return null;const e=c(t.event_id),n=c(t.trace_id),s=c(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:c(t.operation_id)??null,unit_id:c(t.unit_id)??null,actor:c(t.actor)??null,source:c(t.source),timestamp:c(t.timestamp),detail:t.detail}}function Dp(t){const e=w(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),events:Array.isArray(e.events)?e.events.map(Mr).filter(n=>n!==null):[]}}function zp(t){if(!w(t))return null;const e=c(t.code),n=c(t.severity),s=c(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function Ep(t){if(!w(t))return null;const e=c(t.lane_id),n=c(t.label),s=c(t.kind),a=c(t.phase),o=c(t.motion_state),r=c(t.source_of_truth),l=c(t.movement_reason),p=c(t.current_step);if(!e||!n||!s||!a||!o||!r||!l||!p)return null;const m=w(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:at(t.present)??!1,phase:a,motion_state:o,source_of_truth:r,last_movement_at:c(t.last_movement_at)??null,movement_reason:l,current_step:p,blockers:ft(t.blockers),counts:{operations:g(m.operations),detachments:g(m.detachments),workers:g(m.workers),approvals:g(m.approvals),alerts:g(m.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(zp).filter(d=>d!==null):[]}}function jp(t){if(!w(t))return null;const e=c(t.event_id),n=c(t.lane_id),s=c(t.kind),a=c(t.timestamp),o=c(t.title),r=c(t.detail),l=c(t.tone),p=c(t.source);return!e||!n||!s||!a||!o||!r||!l||!p?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:o,detail:r,tone:l,source:p}}function Op(t){if(!w(t))return null;const e=c(t.code),n=c(t.severity),s=c(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,lane_ids:ft(t.lane_ids),count:g(t.count)??0}}function Dr(t){if(!w(t))return;const e=w(t.overview)?t.overview:{},n=w(t.gaps)?t.gaps:{},s=w(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:c(t.generated_at),overview:{active_lanes:g(e.active_lanes),moving_lanes:g(e.moving_lanes),stalled_lanes:g(e.stalled_lanes),projected_lanes:g(e.projected_lanes),last_movement_at:c(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(Ep).filter(a=>a!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(jp).filter(a=>a!==null):[],gaps:{count:g(n.count),items:Array.isArray(n.items)?n.items.map(Op).filter(a=>a!==null):[]},recommended_next_action:s?{tool:c(s.tool)??"masc_operator_snapshot",label:c(s.label)??"Observe operator state",reason:c(s.reason)??"",lane_id:c(s.lane_id)??null}:void 0}}function Fp(t){if(!w(t))return;const e=w(t.workers)?t.workers:{},n=at(t.pass);return{status:c(t.status)??"missing",source:c(t.source)??"none",run_id:c(t.run_id)??null,captured_at:c(t.captured_at)??null,...n!==void 0?{pass:n}:{},...g(t.peak_hot_slots)!=null?{peak_hot_slots:g(t.peak_hot_slots)}:{},...g(t.ctx_per_slot)!=null?{ctx_per_slot:g(t.ctx_per_slot)}:{},workers:{expected:g(e.expected),joined:g(e.joined),current_task_bound:g(e.current_task_bound),fresh_heartbeats:g(e.fresh_heartbeats),done:g(e.done),final:g(e.final)},artifact_ref:c(t.artifact_ref)??null,missing_reason:c(t.missing_reason)??null}}function qp(t){const e=w(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),topology:Tr(e.topology),operations:Ir(e.operations),detachments:Nr(e.detachments),alerts:Lr(e.alerts),decisions:Pr(e.decisions),capacity:Lp(e.capacity),traces:Dp(e.traces),swarm_status:Dr(e.swarm_status)}}function Kp(t){const e=w(t)?t:{},n=Tr(e.topology),s=Ir(e.operations),a=Nr(e.detachments),o=Lr(e.alerts),r=Pr(e.decisions);return{version:c(e.version),generated_at:c(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:Dr(e.swarm_status),swarm_proof:Fp(e.swarm_proof)}}function Up(t){return w(t)?{chain_id:c(t.chain_id)??null,started_at:g(t.started_at)??null,progress:g(t.progress)??null,elapsed_sec:g(t.elapsed_sec)??null}:null}function zr(t){if(!w(t))return null;const e=c(t.event);return e?{event:e,chain_id:c(t.chain_id)??null,timestamp:c(t.timestamp)??null,duration_ms:g(t.duration_ms)??null,message:c(t.message)??null,tokens:g(t.tokens)??null}:null}function Hp(t){if(!w(t))return null;const e=pa(t.operation);return e?{operation:e,runtime:Up(t.runtime),history:zr(t.history),mermaid:c(t.mermaid)??null,preview_run:Er(t.preview_run)}:null}function Wp(t){const e=w(t)?t:{};return{status:c(e.status)??"disconnected",base_url:c(e.base_url)??null,message:c(e.message)??null}}function Bp(t){const e=w(t)?t:{},n=w(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),connection:Wp(e.connection),summary:n?{linked_operations:g(n.linked_operations),active_chains:g(n.active_chains),running_operations:g(n.running_operations),recent_failures:g(n.recent_failures),last_history_event_at:c(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(Hp).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(zr).filter(s=>s!==null):[]}}function Gp(t){if(!w(t))return null;const e=c(t.id);return e?{id:e,type:c(t.type),status:c(t.status),duration_ms:g(t.duration_ms)??null,error:c(t.error)??null}:null}function Er(t){if(!w(t))return null;const e=c(t.run_id),n=c(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:g(t.duration_ms),success:at(t.success),mermaid:c(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(Gp).filter(s=>s!==null):[]}:null}function Jp(t){const e=w(t)?t:{};return{run:Er(e.run)}}function Vp(t){if(!w(t))return null;const e=c(t.title),n=c(t.path);return!e||!n?null:{title:e,path:n}}function Yp(t){if(!w(t))return null;const e=c(t.id),n=c(t.title),s=c(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function Qp(t){if(!w(t))return null;const e=c(t.id),n=c(t.title),s=c(t.tool),a=c(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:ft(t.success_signals),pitfalls:ft(t.pitfalls)}}function Xp(t){if(!w(t))return null;const e=c(t.id),n=c(t.title),s=c(t.summary),a=c(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(Qp).filter(o=>o!==null):[]}}function Zp(t){if(!w(t))return null;const e=c(t.id),n=c(t.title),s=c(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:ft(t.tools)}}function tm(t){if(!w(t))return null;const e=c(t.id),n=c(t.title),s=c(t.symptom),a=c(t.why),o=c(t.fix_tool),r=c(t.fix_summary);return!e||!n||!s||!a||!o||!r?null:{id:e,title:n,symptom:s,why:a,fix_tool:o,fix_summary:r}}function em(t){if(!w(t))return null;const e=c(t.id),n=c(t.title),s=c(t.path_id),a=c(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:ft(t.notes)}}function nm(t){const e=w(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(Vp).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(Yp).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(Xp).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Zp).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(tm).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(em).filter(n=>n!==null):[]}}function sm(t){if(!w(t))return null;const e=c(t.id),n=c(t.title),s=c(t.status),a=c(t.detail),o=c(t.next_tool);return!e||!n||!s||!a||!o?null:{id:e,title:n,status:s,detail:a,next_tool:o}}function am(t){if(!w(t))return null;const e=c(t.code),n=c(t.severity),s=c(t.title),a=c(t.detail),o=c(t.next_tool);return!e||!n||!s||!a||!o?null:{code:e,severity:n,title:s,detail:a,next_tool:o}}function im(t){if(!w(t))return null;const e=c(t.from),n=c(t.content),s=c(t.timestamp),a=g(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function om(t){if(!w(t))return null;const e=c(t.name),n=c(t.role),s=c(t.lane),a=c(t.status),o=c(t.claim_marker),r=c(t.done_marker),l=c(t.final_marker);if(!e||!n||!s||!a||!o||!r||!l)return null;const p=(()=>{if(!w(t.last_message))return null;const m=g(t.last_message.seq),d=c(t.last_message.content),u=c(t.last_message.timestamp);return m==null||!d||!u?null:{seq:m,content:d,timestamp:u}})();return{name:e,role:n,lane:s,joined:at(t.joined)??!1,live_presence:at(t.live_presence)??!1,completed:at(t.completed)??!1,status:a,current_task:c(t.current_task)??null,bound_task_id:c(t.bound_task_id)??null,bound_task_title:c(t.bound_task_title)??null,bound_task_status:c(t.bound_task_status)??null,current_task_matches_run:at(t.current_task_matches_run)??!1,squad_member:at(t.squad_member)??!1,detachment_member:at(t.detachment_member)??!1,last_seen:c(t.last_seen)??null,heartbeat_age_sec:g(t.heartbeat_age_sec)??null,heartbeat_fresh:at(t.heartbeat_fresh)??!1,claim_marker_seen:at(t.claim_marker_seen)??!1,done_marker_seen:at(t.done_marker_seen)??!1,final_marker_seen:at(t.final_marker_seen)??!1,claim_marker:o,done_marker:r,final_marker:l,last_message:p}}function rm(t){if(!w(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!w(n))return null;const s=c(n.timestamp),a=g(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:c(t.slot_url)??null,provider_base_url:c(t.provider_base_url)??null,provider_reachable:at(t.provider_reachable)??null,provider_status_code:g(t.provider_status_code)??null,provider_model_id:c(t.provider_model_id)??null,actual_model_id:c(t.actual_model_id)??null,expected_slots:g(t.expected_slots),actual_slots:g(t.actual_slots),expected_ctx:g(t.expected_ctx),actual_ctx:g(t.actual_ctx),slot_reachable:at(t.slot_reachable)??null,slot_status_code:g(t.slot_status_code)??null,runtime_blocker:c(t.runtime_blocker)??null,detail:c(t.detail)??null,checked_at:c(t.checked_at)??null,total_slots:g(t.total_slots),ctx_per_slot:g(t.ctx_per_slot),active_slots_now:g(t.active_slots_now),peak_active_slots:g(t.peak_active_slots),sample_count:g(t.sample_count),last_sample_at:c(t.last_sample_at)??null,timeline:e}}function lm(t){const e=w(t)?t:{},n=w(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),run_id:c(e.run_id),room_id:c(e.room_id),operation_id:c(e.operation_id)??null,recommended_next_tool:c(e.recommended_next_tool),summary:n?{expected_workers:g(n.expected_workers),joined_workers:g(n.joined_workers),live_workers:g(n.live_workers),squad_roster_size:g(n.squad_roster_size),detachment_roster_size:g(n.detachment_roster_size),current_task_bound:g(n.current_task_bound),fresh_heartbeats:g(n.fresh_heartbeats),claim_markers_seen:g(n.claim_markers_seen),done_markers_seen:g(n.done_markers_seen),final_markers_seen:g(n.final_markers_seen),completed_workers:g(n.completed_workers),peak_hot_slots:g(n.peak_hot_slots),hot_window_ok:at(n.hot_window_ok),pass_hot_concurrency:at(n.pass_hot_concurrency),pass_end_to_end:at(n.pass_end_to_end),pending_decisions:g(n.pending_decisions),pass:at(n.pass)}:void 0,provider:rm(e.provider),operation:pa(e.operation),squad:zi(e.squad),detachment:Rr(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(om).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(sm).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(am).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(im).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(Mr).filter(s=>s!==null):[],truth_notes:ft(e.truth_notes)}}function Ce(t){G.value=t,Di(t)&&cm()}async function jr(){Fs.value=!0,Ks.value=null;try{const t=await Ql();Mi.value=Kp(t)}catch(t){Ks.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{Fs.value=!1}}function Ei(t){Je.value=t}async function ji(){qs.value=!0,Us.value=null;try{const t=await Yl();Wt.value=qp(t)}catch(t){Us.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{qs.value=!1}}async function cm(){Wt.value||qs.value||await ji()}async function oe(){await jr(),Di(G.value)&&await ji()}async function re(){var t;ui.value=!0,Js.value=null;try{const e=await Xl(),n=Bp(e);Xn.value=n;const s=Je.value;n.operations.length===0?Je.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Je.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Js.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{ui.value=!1}}function dm(){_n=null,En.value=null,Vs.value=!1,jn.value=null}async function um(t){_n=t,Vs.value=!0,jn.value=null;try{const e=await Zl(t);if(_n!==t)return;En.value=Jp(e)}catch(e){if(_n!==t)return;En.value=null,jn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{_n===t&&(Vs.value=!1)}}async function pm(){di.value=!0,Ws.value=null;try{const t=await tc();Qn.value=nm(t)}catch(t){Ws.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{di.value=!1}}async function Et(t=kp(),e=xp()){Bs.value=!0,Gs.value=null;try{const n=await ec(t,e);Ie.value=lm(n)}catch(n){Gs.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{Bs.value=!1}}async function _e(t,e,n){ci.value=t,Hs.value=null;try{await nc(e,n),await jr(),(Wt.value||Di(G.value))&&await ji(),await Et(),await re()}catch(s){throw Hs.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{ci.value=null}}function mm(t){return _e(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function vm(t){return _e(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function _m(t){return _e(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function fm(t={}){return _e("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function gm(t){return _e(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function $m(t){return _e(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function hm(t,e){return _e(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function ym(t,e){return _e(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}Rd(()=>{oe(),re(),(G.value==="swarm"||G.value==="warroom"||Ie.value!==null)&&Et(),G.value==="warroom"&&ct()});const bm="modulepreload",km=function(t){return"/dashboard/"+t},co={},xm=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let r=function(m){return Promise.all(m.map(d=>Promise.resolve(d).then(u=>({status:"fulfilled",value:u}),u=>({status:"rejected",reason:u}))))};document.getElementsByTagName("link");const l=document.querySelector("meta[property=csp-nonce]"),p=(l==null?void 0:l.nonce)||(l==null?void 0:l.getAttribute("nonce"));a=r(n.map(m=>{if(m=km(m),m in co)return;co[m]=!0;const d=m.endsWith(".css"),u=d?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${m}"]${u}`))return;const v=document.createElement("link");if(v.rel=d?"stylesheet":bm,d||(v.as="script"),v.crossOrigin="",v.href=m,p&&v.setAttribute("nonce",p),document.head.appendChild(v),d)return new Promise(($,x)=>{v.addEventListener("load",$),v.addEventListener("error",()=>x(new Error(`Unable to preload CSS for ${m}`)))})}))}function o(r){const l=new Event("vite:preloadError",{cancelable:!0});if(l.payload=r,window.dispatchEvent(l),!l.defaultPrevented)throw r}return a.then(r=>{for(const l of r||[])l.status==="rejected"&&o(l.reason);return e().catch(o)})};function Or(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Z(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function Sm(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Fr(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function z(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let uo=!1,Am=0;function Cm(){return++Am}let ya=null;async function wm(){ya||(ya=xm(()=>import("./mermaid.core-B8hkWMsC.js").then(e=>e.bE),[]).then(e=>e.default));const t=await ya;return uo||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),uo=!0),t}function le(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Zn(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function fn(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function ts(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function be(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:ts(t/e*100)}function Tm(t,e){const n=ts(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function qr(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const Im=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],Kr=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],Rm=Kr.map(t=>t.id),Nm=["chain_start","node_start","node_complete","chain_complete","chain_error"],Pm={warroom:{title:"라이브 워룸",description:"실제 run, worker, message, trace를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function po(t){return!!t&&Rm.includes(t)}function Lm(){const t=F.value.params;return t.source!=="mission"?{}:{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function Ur(t){const e=Lm();if(t==="operations")return e;if(t==="chains"){const n=Je.value;return n?{...e,surface:t,operation:n}:{...e,surface:t}}return{...e,surface:t}}function Mm(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function Dm(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function dt(t){return ci.value===t}function es(){return Mi.value}function zm(t){var a,o,r,l,p,m,d;const e=Mi.value,n=Ie.value,s=Xn.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"live run, worker, message, trace를 한 화면에서 보고 필요한 detail 표면으로 바로 점프합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((r=(o=e==null?void 0:e.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:r.tool)??"masc_observe_traces",reason:((p=(l=e==null?void 0:e.swarm_status)==null?void 0:l.recommended_next_action)==null?void 0:p.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(d=(m=s==null?void 0:s.operations[0])==null?void 0:m.preview_run)!=null&&d.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function Em(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function jm(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function Om(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Hr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function Fm(){const e=Hr().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Wr(){const e=Hr().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function qm(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function Km(t){return t.status==="claimed"||t.status==="in_progress"}function Um(t){const e=Qn.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function ba(t){var e;return((e=Qn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function Hm(t){const e=Qn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function ce(t){try{await t()}catch{}}function Oi(t){return(t==null?void 0:t.trim().toLowerCase())??""}function Fe(t){const e=Oi(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function ka(t){const e=Oi(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function Wm(){var e,n,s;const t=Ie.value;return t?!!(t.run_id||(e=t.operation)!=null&&e.operation_id||(n=t.detachment)!=null&&n.detachment_id||(((s=t.summary)==null?void 0:s.expected_workers)??0)>0||t.workers.length>0||t.recent_messages.length>0||t.recent_trace_events.length>0):!1}function Bm(t){const e=Oi(t.status);return e==="active"||e==="running"}function Gm(){var o,r,l,p;const t=((o=Kt.value)==null?void 0:o.sessions)??[],e=Ie.value,n=((r=e==null?void 0:e.detachment)==null?void 0:r.session_id)??null;if(n){const m=t.find(d=>d.session_id===n);if(m)return m}const s=((l=e==null?void 0:e.operation)==null?void 0:l.operation_id)??Wr();if(s){const m=t.find(d=>d.command_plane_operation_id===s);if(m)return m}const a=((p=e==null?void 0:e.detachment)==null?void 0:p.detachment_id)??null;if(a){const m=t.find(d=>d.command_plane_detachment_id===a);if(m)return m}return t.find(Bm)??t[0]??null}function Jm(){const t=Yn(F.value);return t?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${da(t.action_type)}</span>
        <span class="command-chip">${Pi(t)}</span>
        <span class="command-chip">${np(F.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?i`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function Vm(){const t=G.value,e=Pm[t],n=zm(t);return i`
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
  `}function ls({label:t,value:e,subtext:n,percent:s,color:a}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${Tm(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(ts(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function cs({label:t,value:e,detail:n,percent:s,tone:a}){return i`
    <article class="command-signal-rail ${z(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${z(a)}" style=${`width: ${Math.max(8,Math.round(ts(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function Ym(){var K,tt,B,st;const t=es(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,o=t==null?void 0:t.alerts.summary,r=(K=t==null?void 0:t.swarm_status)==null?void 0:K.overview,l=t==null?void 0:t.swarm_proof,p=t==null?void 0:t.operations.microarch,m=(e==null?void 0:e.managed_unit_count)??0,d=(e==null?void 0:e.total_units)??0,u=(n==null?void 0:n.active)??0,v=(s==null?void 0:s.active)??0,$=(r==null?void 0:r.moving_lanes)??0,x=(r==null?void 0:r.active_lanes)??0,S=(l==null?void 0:l.workers.done)??0,T=(l==null?void 0:l.workers.expected)??0,N=(o==null?void 0:o.bad)??0,I=(o==null?void 0:o.warn)??0,A=(a==null?void 0:a.pending)??0,L=(a==null?void 0:a.total)??0,M=u+v,Y=((tt=p==null?void 0:p.cache)==null?void 0:tt.l1_hit_rate)??((st=(B=p==null?void 0:p.signals)==null?void 0:B.cache_contention)==null?void 0:st.l1_hit_rate)??0,J=u>0||v>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",f=u>0||$>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${J}</h3>
        <p>${f}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${z(u>0?"ok":"warn")}">활성 작전 ${u}</span>
          <span class="command-chip ${z($>0?"ok":(x>0,"warn"))}">이동 레인 ${$}/${Math.max(x,$)}</span>
          <span class="command-chip ${z(N>0?"bad":I>0?"warn":"ok")}">치명 알림 ${N}</span>
          <span class="command-chip ${z(A>0?"warn":"ok")}">승인 대기 ${A}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${ls}
          label="관리 단위 범위"
          value=${`${m}/${Math.max(d,m)}`}
          subtext=${d>0?`${d-m}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${be(m,Math.max(d,m))}
          color="#67e8f9"
        />
        <${ls}
          label="실행 열도"
          value=${String(M)}
          subtext=${`${u}개 작전 + ${v}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${be(M,Math.max(m,M||1))}
          color="#4ade80"
        />
        <${ls}
          label="스웜 이동감"
          value=${`${$}/${Math.max(x,$)}`}
          subtext=${r!=null&&r.last_movement_at?`마지막 이동 ${Z(r.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${be($,Math.max(x,$||1))}
          color="#fbbf24"
        />
        <${ls}
          label="증거 수집률"
          value=${`${S}/${Math.max(T,S)}`}
          subtext=${l!=null&&l.status?`증거 소스 ${l.source} · ${l.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${be(S,Math.max(T,S||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${cs}
        label="승인 대기열"
        value=${`${A}건 대기`}
        detail=${`현재 정책 창에서 ${L}개 결정을 추적 중입니다`}
        percent=${be(A,Math.max(L,A||1))}
        tone=${A>0?"warn":"ok"}
      />
      <${cs}
        label="알림 압력"
        value=${`${N} bad / ${I} warn`}
        detail=${N>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${be(N*2+I,Math.max((N+I)*2,1))}
        tone=${N>0?"bad":I>0?"warn":"ok"}
      />
      <${cs}
        label="디스패치 점유"
          value=${`${v}개 가동`}
        detail=${m>0?`${m}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${be(v,Math.max(m,v||1))}
        tone=${v>0?"ok":"warn"}
      />
      <${cs}
        label="캐시 신뢰도"
        value=${Y?Zn(Y):"n/a"}
        detail=${Y?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${ts((Y??0)*100)}
        tone=${Y>=.75?"ok":Y>=.4?"warn":"bad"}
      />
    </div>
  `}function Qm(){var v,$,x,S,T;const t=es(),e=Xn.value,n=Yn(F.value),s=Em(n),a=t==null?void 0:t.topology.summary,o=t==null?void 0:t.operations.summary,r=(v=t==null?void 0:t.swarm_status)==null?void 0:v.overview,l=t==null?void 0:t.operations.microarch,p=t==null?void 0:t.decisions.summary,m=t==null?void 0:t.alerts.summary,d=($=l==null?void 0:l.signals)==null?void 0:$.issue_pressure,u=l==null?void 0:l.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((x=t==null?void 0:t.detachments.summary)==null?void 0:x.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(p==null?void 0:p.pending)??0}</strong><small>${(p==null?void 0:p.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(m==null?void 0:m.bad)??0}</strong><small>${(m==null?void 0:m.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((S=e==null?void 0:e.summary)==null?void 0:S.active_chains)??0}</strong><small>${((T=e==null?void 0:e.summary)==null?void 0:T.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(r==null?void 0:r.active_lanes)??0}</strong><small>${r?`${r.stalled_lanes??0}개 정체 · ${Z(r.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(d==null?void 0:d.pending_ops)??0}</strong><small>${(u==null?void 0:u.l1_hit_rate)!=null?`${Zn(u.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(d==null?void 0:d.tone)??"n/a"}</small></div>
    </div>
  `}function Xm(){var K,tt,B,st,k,Rt,te,fe,ge;const t=es(),e=Wt.value,n=xt.value,s=Om(),a=s?It.value.find(O=>O.name===s)??null:null,o=s?Ot.value.filter(O=>O.assignee===s&&Km(O)):[],r=((K=t==null?void 0:t.operations.summary)==null?void 0:K.active)??0,l=((tt=t==null?void 0:t.detachments.summary)==null?void 0:tt.total)??0,p=((B=t==null?void 0:t.decisions.summary)==null?void 0:B.pending)??0,m=e==null?void 0:e.detachments.detachments.find(O=>{const Nt=O.detachment.heartbeat_deadline,$e=Nt?Date.parse(Nt):Number.NaN;return O.detachment.status==="stalled"||!Number.isNaN($e)&&$e<=Date.now()}),d=e==null?void 0:e.alerts.alerts.find(O=>O.severity==="bad"),u=!!(n!=null&&n.room||n!=null&&n.project),v=(a==null?void 0:a.current_task)??null,$=qm(a==null?void 0:a.last_seen),x=$!=null?$<=120:null,S=[u?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:Ot.value.length>0?"masc_claim":"masc_add_task"}:v?x===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${v} 이지만 heartbeat가 stale 합니다 (${$}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${v}${$!=null?` · 마지막 활동 ${$}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((st=t.topology.summary)==null?void 0:st.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:r===0?{title:"작전 준비도",tone:"warn",detail:`${((k=t.topology.summary)==null?void 0:k.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((Rt=t.topology.summary)==null?void 0:Rt.managed_unit_count)??0}개 관리 단위 위에서 ${r}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},p>0?{title:"디스패치 준비도",tone:"warn",detail:`${p}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:r>0&&l===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:m||d?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${m?` · detachment ${m.detachment.detachment_id} 가 stalled 상태입니다`:""}${d?` · alert ${d.title??d.alert_id}`:""}${!e&&!m&&!d?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${l}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],T=u?!s||!a?"masc_join":o.length===0?Ot.value.length>0?"masc_claim":"masc_add_task":v?x===!1?"masc_heartbeat":!t||(((te=t.topology.summary)==null?void 0:te.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":p>0?"masc_policy_approve":r>0&&l===0||m||d?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",N=Um(T),A=Hm(T==="masc_set_room"?["repo-root-room"]:T==="masc_plan_set_task"?["claimed-not-current"]:T==="masc_heartbeat"?["heartbeat-stale"]:T==="masc_dispatch_tick"?["no-detachments"]:T==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),L=ba("room_task_hygiene"),M=ba("cpv2_benchmark"),Y=ba("supervisor_session"),J=((fe=Qn.value)==null?void 0:fe.docs)??[],f=[L,M,Y].filter(O=>O!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${E} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(N==null?void 0:N.title)??T}</strong>
            <span class="command-chip ok">${T}</span>
          </div>
          <p>${(N==null?void 0:N.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(ge=N==null?void 0:N.success_signals)!=null&&ge.length?i`<div class="command-tag-row">
                ${N.success_signals.map(O=>i`<span class="command-tag ok">${O}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${S.map(O=>i`
            <article class="command-readiness-row ${z(O.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${O.title}</strong>
                  <span class="command-chip ${z(O.tone)}">${O.tone}</span>
                </div>
                <p>${O.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${O.tool}</div>
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
                  ${A.map(O=>i`
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
          <${E} panelId="command.summary" compact=${!0} />
        </div>
        ${di.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:Ws.value?i`<div class="empty-state error">${Ws.value}</div>`:i`
                <div class="command-path-grid">
                  ${f.map(O=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${O.title}</strong>
                        <span class="command-chip">${O.id}</span>
                      </div>
                      <p>${O.summary}</p>
                      <div class="command-card-sub">${O.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${O.steps.slice(0,4).map(Nt=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Nt.tool}</span>
                            <span>${Nt.title}</span>
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
  `}function Zm(){return i`
    <${Ym} />
    <${Qm} />
    <${Xm} />
  `}function tv(){return qs.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:Us.value?i`<div class="empty-state error">${Us.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function Br({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,o=t.unit.policy;return i`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${Dm(t.unit.kind)}</span>
            <span class="command-chip ${z(t.health)}">${t.health??"ok"}</span>
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
                ${t.reasons.map(r=>i`<span class="command-tag warn">${r}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?i`<div class="command-tree-children">
            ${t.children.map(r=>i`<${Br} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function ev({alert:t}){return i`
    <article class="command-alert ${z(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${z(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${Z(t.timestamp)}</span>
      </div>
      ${t.detail?i`<p>${t.detail}</p>`:null}
    </article>
  `}function Fi({event:t}){return i`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${Z(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${Or(t.detail)}</pre>
    </article>
  `}function nv(){const t=Wt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${E} panelId="command.topology" compact=${!0} />
      </div>
      ${t&&t.topology.units.length>0?i`${t.topology.units.map(e=>i`<${Br} node=${e} />`)}`:i`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function sv(){const t=Wt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${E} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>i`<${ev} alert=${e} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function av(){const t=Wt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${E} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?i`<div class="command-trace-stack">
            ${t.traces.events.map(e=>i`<${Fi} event=${e} />`)}
          </div>`:i`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function Gr(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function Jr({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const o=a.motion_state;o in e?e[o]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return i`
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
  `}function iv({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${a.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?i`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function ov({lane:t}){const e=t.counts??{},n=Gr(t),s=e.workers??0,a=e.operations??0,o=e.detachments??0,r=a+o,l=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return i`
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
          <span class="command-chip">${Z(t.last_movement_at)}</span>
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
        ${s>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${iv} total=${s} />
              </div>
            `:null}
        ${r>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">흐름</span>
                <div class="swarm-mini-bar">
                  <div class="swarm-mini-bar-fill" style="width: ${r>0?Math.round(a/r*100):0}%; background: var(--${n==="bad"?"bad":n==="warn"?"warn":"ok"})"></div>
                </div>
                <span class="swarm-worker-count">작전 ${a} · 실행체 ${o}</span>
              </div>
            `:null}
      </div>
      ${t.blockers.length>0?i`<div class="swarm-lane-blockers">막힘: ${t.blockers.join(" · ")}</div>`:null}
      ${t.hard_flags.length>0?i`
            <div class="swarm-lane-flags">
              ${t.hard_flags.map(p=>i`<span class="command-chip ${z(p.severity)}">${p.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Vr({lanes:t}){const e=t.slice(0,4);return e.length===0?null:i`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=Gr(n),a=n.counts.workers??0,o=n.counts.operations??0,r=n.counts.detachments??0;return i`
          <article class="swarm-story-card ${z(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${z(s)}">${n.motion_state}</span>
              <span class="command-chip">${n.phase}</span>
            </div>
            <strong>${n.label}</strong>
            <p>${n.current_step}</p>
            <div class="swarm-story-strip">
              <span>워커 ${a}</span>
              <span>작전 ${o}</span>
              <span>실행체 ${r}</span>
            </div>
            <small>${n.movement_reason}</small>
          </article>
        `})}
    </div>
  `}function rv({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${z(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?i`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function lv({gap:t}){return i`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${z(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function cv({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${z(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${z(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?i`
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${Z(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.artifact_ref?i`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?i`<p>${t.missing_reason}</p>`:null}
          `:i`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function dv(){const t=es(),e=Yn(F.value),n=jm(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,o=(s==null?void 0:s.lanes.filter(u=>u.present))??[],r=(s==null?void 0:s.gaps.items)??[],l=(s==null?void 0:s.timeline.slice(0,8))??[],p=s==null?void 0:s.overview,m=s==null?void 0:s.recommended_next_action,d=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${E} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${Vr} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(p==null?void 0:p.active_lanes)??0}</strong><small>${(p==null?void 0:p.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(p==null?void 0:p.stalled_lanes)??0}</strong><small>${(p==null?void 0:p.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${Z(p==null?void 0:p.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${Z(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong><small>${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${Jr} lanes=${o} />`:null}

            <div class="command-swarm-layout ${d?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(u=>i`<${ov} lane=${u} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${cv} proof=${a} />

                <div class="command-guide-card ${r.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${z(r.some(u=>u.severity==="bad")?"bad":r.length>0?"warn":"ok")}">${r.length}</span>
                  </div>
                  ${r.length>0?i`<div class="swarm-event-rail">${r.slice(0,4).map(u=>i`<${lv} gap=${u} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${l.length}</span>
                  </div>
                  ${l.length>0?i`<div class="swarm-event-rail">${l.map(u=>i`<${rv} event=${u} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function uv({item:t}){return i`
    <article class="command-guide-card ${z(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${z(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Yr({blocker:t}){return i`
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
  `}function pv({worker:t}){return i`
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
      ${t.last_message?i`<div class="command-card-foot">${Z(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function mv(){var p,m,d,u,v,$,x,S,T,N,I,A,L,M,Y,J,f,K,tt,B,st;const t=Ie.value,e=Fm(),n=Wr(),s=(p=t==null?void 0:t.provider)!=null&&p.runtime_blocker?"blocked":(m=t==null?void 0:t.provider)!=null&&m.provider_reachable?"ready":"check",a=((d=t==null?void 0:t.provider)==null?void 0:d.actual_slots)??((u=t==null?void 0:t.provider)==null?void 0:u.total_slots)??0,o=((v=t==null?void 0:t.provider)==null?void 0:v.expected_slots)??"n/a",r=(($=t==null?void 0:t.provider)==null?void 0:$.actual_ctx)??((x=t==null?void 0:t.provider)==null?void 0:x.ctx_per_slot)??0,l=((S=t==null?void 0:t.provider)==null?void 0:S.expected_ctx)??"n/a";return i`
    <div class="command-section-stack">
      <${dv} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${E} panelId="command.swarm" compact=${!0} />
          </div>
          ${Bs.value?i`<div class="empty-state">Loading swarm live state…</div>`:Gs.value?i`<div class="empty-state error">${Gs.value}</div>`:t?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((T=t.summary)==null?void 0:T.joined_workers)??0}/${((N=t.summary)==null?void 0:N.expected_workers)??0}</strong><small>${((I=t.summary)==null?void 0:I.live_workers)??0}개 가동 · ${((A=t.summary)==null?void 0:A.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${o} · ctx ${r}/${l}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(L=t.summary)!=null&&L.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((M=t.provider)==null?void 0:M.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(Y=t.summary)!=null&&Y.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((J=t.operation)==null?void 0:J.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((f=t.squad)==null?void 0:f.label)??"없음"}</span>
                      <span>실행체</span><span>${((K=t.detachment)==null?void 0:K.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((tt=t.summary)==null?void 0:tt.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((B=t.summary)==null?void 0:B.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((st=t.provider)==null?void 0:st.runtime_blocker)??"없음"}</span>
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
            <${E} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?i`<div class="command-card-stack">
                ${t.checklist.map(k=>i`<${uv} item=${k} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${E} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?i`<div class="command-card-stack">
                ${t.workers.map(k=>i`<${pv} worker=${k} />`)}
              </div>`:i`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${E} panelId="command.swarm" compact=${!0} />
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
                  <span>Last Sample</span><span>${t.provider.last_sample_at?Z(t.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${t.provider.checked_at?Z(t.provider.checked_at):"n/a"}</span>
                </div>
                ${t.provider.detail?i`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?i`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(k=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${k.active_slots} active</strong>
                              <span class="command-chip">${Z(k.timestamp)}</span>
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
            <${E} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?i`<div class="command-card-stack">
                ${t.blockers.map(k=>i`<${Yr} blocker=${k} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${E} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?i`<div class="command-trace-stack">
                ${t.recent_messages.map(k=>i`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${k.from}</strong>
                        <span class="command-chip">${Z(k.timestamp)}</span>
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
            <${E} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${t.recent_trace_events.map(k=>i`<${Fi} event=${k} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function vv(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"none",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}s`:t.heartbeat_fresh?"clean":"n/a",detail:[t.bound_task_status??null,t.detachment_member?"detachment":null,t.squad_member?"squad":null].filter(Boolean).join(" · ")||"live swarm worker",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function _v(t,e){const n=t.actor??t.spawn_role??`worker-${e+1}`,s=t.spawn_role??t.worker_class??t.spawn_agent??"worker",a=t.lane_id??t.capsule_mode??t.control_domain??"session",o=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:s,lane:a,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"session lane",heartbeat:t.last_turn_ts_iso?Z(t.last_turn_ts_iso):"n/a",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?Zn(t.routing_confidence):null].filter(Boolean).join(" · ")||"session worker",markers:o,note:t.routing_reason??null}}function mo(t){return z(t.severity)}function fv({worker:t}){return i`
    <article class="command-card compact warroom-worker-card ${z(Fe(t.status))}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${z(Fe(t.status))}">${t.status}</span>
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
  `}function ne({label:t,surface:e,params:n={}}){return i`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(e){Ce(e),$t("command",{...Ur(e),...n});return}$t("intervene")}}
    >
      ${t}
    </button>
  `}function gv(){var J,f,K,tt,B,st,k,Rt,te,fe,ge,O,Nt,$e,ln,cn,ns,ss,as,is;const t=es(),e=Ie.value,n=Kt.value,s=Ut.value,a=Gm(),o=e!=null&&e.operation?((J=Xn.value)==null?void 0:J.operations.find(U=>{var Ne;return U.operation.operation_id===((Ne=e.operation)==null?void 0:Ne.operation_id)}))??null:null,r=(e==null?void 0:e.workers)??[],l=(s==null?void 0:s.worker_cards)??[],p=r.length>0?r.map(vv):l.map(_v),m=Wm(),d=((f=t==null?void 0:t.decisions.summary)==null?void 0:f.pending)??0,u=(n==null?void 0:n.pending_confirms)??[],v=(e==null?void 0:e.blockers)??[],$=(s==null?void 0:s.recommended_actions)??[],x=(s==null?void 0:s.attention_items)??[],S=((K=e==null?void 0:e.recent_messages[0])==null?void 0:K.timestamp)??null,T=((tt=e==null?void 0:e.recent_trace_events[0])==null?void 0:tt.timestamp)??null,N=S??T??null,I=a==null?void 0:a.summary,A=((B=e==null?void 0:e.summary)==null?void 0:B.expected_workers)??(typeof(I==null?void 0:I.planned_worker_count)=="number"?I.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,L=((st=e==null?void 0:e.summary)==null?void 0:st.joined_workers)??(typeof(I==null?void 0:I.active_agent_count)=="number"?I.active_agent_count:void 0)??p.length,M=v.length>0||d>0||u.length>0?"warn":m||a?"ok":"warn",Y=((k=t==null?void 0:t.swarm_status)==null?void 0:k.lanes.filter(U=>U.present))??[];return lt(()=>{ct()},[]),lt(()=>{a!=null&&a.session_id&&en(a.session_id)},[a==null?void 0:a.session_id,n,(Rt=e==null?void 0:e.detachment)==null?void 0:Rt.session_id]),!m&&!a?Bs.value||Dn.value?i`<div class="empty-state">live war room 불러오는 중…</div>`:i`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">라이브 워룸</div>
          <${E} panelId="command.warroom" compact=${!0} />
        </div>
        <div class="command-warroom-empty-copy">
          <strong>현재 live run 없음</strong>
          <p>활성 operation 또는 team session이 시작되면 이 화면이 자동으로 붙잡습니다.</p>
        </div>
        <div class="command-action-row">
          <${ne} label="작전 보기" surface="operations" />
          <${ne} label="스웜 보기" surface="swarm" />
          <${ne} label="개입 열기" />
          <${ne} label="제어 보기" surface="control" />
        </div>
      </section>
    `:i`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${z(M)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">Live War Room</span>
            <strong>${((te=e==null?void 0:e.operation)==null?void 0:te.objective)??(a==null?void 0:a.session_id)??"active run"}</strong>
            <div class="command-card-sub">
              ${((fe=e==null?void 0:e.operation)==null?void 0:fe.operation_id)??"operation 없음"}
              ${a!=null&&a.session_id?` · session ${a.session_id}`:""}
              ${(ge=e==null?void 0:e.detachment)!=null&&ge.detachment_id?` · detachment ${e.detachment.detachment_id}`:""}
            </div>
          </div>
          <div class="command-action-row">
            <${ne}
              label="스웜 상세"
              surface="swarm"
              params=${{...(O=e==null?void 0:e.operation)!=null&&O.operation_id?{operation_id:e.operation.operation_id}:{},...e!=null&&e.run_id?{run_id:e.run_id}:{}}}
            />
            <${ne} label="트레이스" surface="trace" />
            ${o?i`<${ne}
                  label="체인"
                  surface="chains"
                  params=${{operation:o.operation.operation_id}}
                />`:null}
            <${ne} label="Intervene" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>Workers</span>
            <strong>${L??0}/${A??0}</strong>
            <small>${((Nt=e==null?void 0:e.summary)==null?void 0:Nt.completed_workers)??0} 완료 · ${p.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>Runtime</span>
            <strong>${($e=e==null?void 0:e.provider)!=null&&$e.runtime_blocker?"blocked":(ln=e==null?void 0:e.provider)!=null&&ln.provider_reachable?"ready":a?ka(a.status):"check"}</strong>
            <small>slots ${((cn=e==null?void 0:e.provider)==null?void 0:cn.active_slots_now)??0}/${((ns=e==null?void 0:e.provider)==null?void 0:ns.actual_slots)??((ss=e==null?void 0:e.provider)==null?void 0:ss.total_slots)??0} · ctx ${((as=e==null?void 0:e.provider)==null?void 0:as.actual_ctx)??((is=e==null?void 0:e.provider)==null?void 0:is.ctx_per_slot)??0}</small>
          </div>
          <div class="monitor-stat-card ${z(v.length>0||d>0?"warn":"ok")}">
            <span>Pressure</span>
            <strong>${v.length+d+u.length}</strong>
            <small>blockers ${v.length} · approvals ${d} · confirms ${u.length}</small>
          </div>
          <div class="monitor-stat-card">
            <span>Last signal</span>
            <strong>${Z(N)}</strong>
            <small>${S?"message":T?"trace":"waiting"}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${E} panelId="command.warroom" compact=${!0} />
            </div>
            ${Y.length>0?i`
                  <${Vr} lanes=${Y} />
                  <${Jr} lanes=${Y} />
                `:a?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${z(Fe(a.status))}">${ka(a.status)}</span>
                      </div>
                      <p>command-plane live run은 아직 옅지만, session 쪽 worker와 digest를 기준으로 워룸을 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${fn(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${fn(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:i`<div class="empty-state">보이는 lane이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Worker Roster</div>
              <${E} panelId="command.warroom" compact=${!0} />
            </div>
            ${p.length>0?i`<div class="command-card-stack">
                  ${p.map(U=>i`<${fv} worker=${U} />`)}
                </div>`:i`<div class="empty-state">활성 worker 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Live Feed</div>
              <${E} panelId="command.warroom" compact=${!0} />
            </div>
            ${e&&e.recent_messages.length>0?i`<div class="command-trace-stack">
                  ${e.recent_messages.map(U=>i`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${U.from}</strong>
                          <span class="command-chip">${Z(U.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${U.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${U.content}</pre>
                    </article>
                  `)}
                </div>`:$.length>0||x.length>0?i`<div class="command-card-stack">
                    ${$.slice(0,4).map(U=>i`
                      <article class="command-guide-card ${mo(U)}">
                        <div class="command-guide-head">
                          <strong>${U.action_type}</strong>
                          <span class="command-chip ${mo(U)}">${U.target_type}</span>
                        </div>
                        <p>${U.reason}</p>
                      </article>
                    `)}
                    ${x.slice(0,3).map(U=>i`
                      <article class="command-alert ${z(U.severity)}">
                        <div class="command-card-head">
                          <strong>${U.kind}</strong>
                          <span class="command-chip ${z(U.severity)}">${U.severity}</span>
                        </div>
                        <p>${U.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?i`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((U,Ne)=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>session-event-${Ne+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${Or(U)}</pre>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">메시지나 attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Trace Feed</div>
              <${E} panelId="command.trace" compact=${!0} />
            </div>
            ${e&&e.recent_trace_events.length>0?i`<div class="command-trace-stack">
                  ${e.recent_trace_events.map(U=>i`<${Fi} event=${U} />`)}
                </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Pressure</div>
              <${E} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${v.length>0?v.map(U=>i`<${Yr} blocker=${U} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${d>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending approvals</strong>
                        <span class="command-chip warn">${d}</span>
                      </div>
                      <p>strict action이 묶여 있습니다. 실제 승인 처리는 control 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${u.length>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending confirms</strong>
                        <span class="command-chip warn">${u.length}</span>
                      </div>
                      <p>operator preview가 사람 확인을 기다리고 있습니다.</p>
                      <div class="command-tag-row">
                        ${u.slice(0,3).map(U=>i`<span class="command-tag">${U.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
            </div>
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Focus Detail</div>
              <${E} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${e!=null&&e.operation?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${e.operation.objective}</strong>
                          <div class="command-card-sub">${e.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${z(Fe(e.operation.status))}">${e.operation.status}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Unit</span><span>${e.operation.assigned_unit_id}</span>
                        <span>Trace</span><span>${e.operation.trace_id}</span>
                        <span>Autonomy</span><span>${e.operation.autonomy_level??"n/a"}</span>
                        <span>Updated</span><span>${Z(e.operation.updated_at)}</span>
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
                        <span class="command-chip ${z(Fe(e.detachment.status))}">${e.detachment.status??"active"}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Leader</span><span>${e.detachment.leader_id??"unassigned"}</span>
                        <span>Roster</span><span>${e.detachment.roster.length}</span>
                        <span>Session</span><span>${e.detachment.session_id??"none"}</span>
                        <span>Heartbeat</span><span>${Fr(e.detachment.heartbeat_deadline)}</span>
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
                        <span class="command-chip ${z(Fe(a.status))}">${ka(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${fn(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${fn(a.remaining_sec)}</span>
                        <span>Done delta</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function $v({source:t}){const e=gl(null),[n,s]=No(null);return lt(()=>{let a=!1;const o=e.current;return o?(o.innerHTML="",s(null),(async()=>{try{const l=await wm(),{svg:p}=await l.render(`command-chain-${Cm()}`,t);if(a||!e.current)return;e.current.innerHTML=p}catch(l){if(a)return;s(l instanceof Error?l.message:"Mermaid render failed")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function hv({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return i`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${le(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?i`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?i`<span class="command-tag ${le(s==null?void 0:s.status)}">${Zn(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${qr(t.history)}</div>
    </button>
  `}function yv({item:t}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${le(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${Z(t.timestamp)}</div>
      <div class="command-card-sub">${qr(t)}</div>
    </article>
  `}function bv({node:t}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${le(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?i`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function kv({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,o=e.chain,r=(o==null?void 0:o.run_id)??null;return i`
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
        <span>Updated</span><span>${Z(e.updated_at)}</span>
      </div>
      ${o?i`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${le(o.status)}">${o.status}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">run ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?i`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Ce("swarm"),$t("command",{surface:"swarm",operation_id:e.operation_id,...r?{run_id:r}:{}})}}
        >
          Swarm Live
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{Ei(e.operation_id),Ce("chains"),$t("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?i`
              <button class="control-btn ghost" disabled=${dt(n)} onClick=${()=>ce(()=>mm(e.operation_id))}>
                ${dt(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${dt(a)} onClick=${()=>ce(()=>_m(e.operation_id))}>
                ${dt(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?i`
              <button class="control-btn ghost" disabled=${dt(s)} onClick=${()=>ce(()=>vm(e.operation_id))}>
                ${dt(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function xv({card:t}){var n;const e=t.detachment;return i`
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
        <span>Progress</span><span>${Z(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Fr(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${Z(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?i`<span class="command-tag ${Sm(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Sv(){const t=Wt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${E} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?i`<div class="command-card-stack">
              ${t.operations.operations.map(e=>i`<${kv} card=${e} />`)}
            </div>`:i`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${E} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>i`<${xv} card=${e} />`)}
            </div>`:i`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function Av(){var l,p,m,d,u,v,$,x,S,T,N,I,A,L,M,Y;const t=Xn.value,e=(t==null?void 0:t.operations)??[],n=Je.value,s=e.find(J=>J.operation.operation_id===n)??e[0]??null,a=((l=s==null?void 0:s.operation.chain)==null?void 0:l.run_id)??null,o=((p=En.value)==null?void 0:p.run)??(s==null?void 0:s.preview_run)??null,r=!((m=En.value)!=null&&m.run)&&!!(s!=null&&s.preview_run);return lt(()=>{a?um(a):dm()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${E} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${le(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${le(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(t==null?void 0:t.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((d=t==null?void 0:t.summary)==null?void 0:d.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((u=t==null?void 0:t.summary)==null?void 0:u.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((v=t==null?void 0:t.summary)==null?void 0:v.recent_failures)??0}</span>
            <span>Last Event</span><span>${Z(($=t==null?void 0:t.summary)==null?void 0:$.last_history_event_at)}</span>
          </div>
        </article>

        ${Js.value?i`<div class="empty-state error">${Js.value}</div>`:null}

        ${ui.value&&!t?i`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?i`
                <div class="command-chain-list">
                  ${e.map(J=>i`
                    <${hv}
                      overlay=${J}
                      selected=${(s==null?void 0:s.operation.operation_id)===J.operation.operation_id}
                      onSelect=${()=>Ei(J.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(J=>i`<${yv} item=${J} />`)}
                </div>
              `:i`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chain Detail</div>
          <${E} panelId="command.chains" compact=${!0} />
        </div>
        ${s?i`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${le((x=s.operation.chain)==null?void 0:x.status)}">
                    ${((S=s.operation.chain)==null?void 0:S.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((T=s.operation.chain)==null?void 0:T.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((N=s.operation.chain)==null?void 0:N.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${Zn((I=s.runtime)==null?void 0:I.progress)}</span>
                  <span>Elapsed</span><span>${fn((A=s.runtime)==null?void 0:A.elapsed_sec)}</span>
                  <span>Updated</span><span>${Z(((L=s.operation.chain)==null?void 0:L.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(M=s.operation.chain)!=null&&M.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((Y=s.operation.chain)==null?void 0:Y.chain_id)??"graph"}</span>
                      </div>
                      <${$v} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"failed":r?"preview":"captured":"pending"}
                  </span>
                </div>
                ${Vs.value?i`<div class="empty-state">Loading run detail…</div>`:jn.value?i`<div class="empty-state error">${jn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${o.chain_id}</span>
                            <span>Run</span><span>${o.run_id??"preview only"}</span>
                            <span>Duration</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${o.nodes.length}</span>
                          </div>
                          ${r?i`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(J=>i`<${bv} node=${J} />`)}
                          </div>
                        `:i`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:i`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function Cv({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return i`
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
        <span>Created</span><span>${Z(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!s?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${dt(e)} onClick=${()=>ce(()=>gm(t.decision_id))}>
                ${dt(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${dt(n)} onClick=${()=>ce(()=>$m(t.decision_id))}>
                ${dt(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function wv({row:t}){var l,p,m;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((l=e.policy)!=null&&l.frozen),o=!!((p=e.policy)!=null&&p.kill_switch),r=Math.round((t.utilization??0)*100);return i`
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
        <span>Autonomy</span><span>${((m=e.policy)==null?void 0:m.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${a?"yes":"no"}</span>
        <span>Kill Switch</span><span>${o?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${dt(n)} onClick=${()=>ce(()=>hm(e.unit_id,!a))}>
          ${dt(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${dt(s)} onClick=${()=>ce(()=>ym(e.unit_id,!o))}>
          ${dt(s)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function Tv(){const t=Wt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${E} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>i`<${Cv} decision=${e} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${E} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>i`<${wv} row=${e} />`)}
            </div>`:i`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function Iv(){return i`
    <div class="command-surface-tabs grouped">
      ${Im.map(t=>i`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${Kr.filter(e=>e.group===t.id).map(e=>i`
                <button
                  class="command-surface-tab ${G.value===e.id?"active":""}"
                  onClick=${()=>{Ce(e.id),$t("command",Ur(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function Rv(){if(G.value==="warroom")return i`<${gv} />`;if(G.value==="summary")return i`<${Zm} />`;if(G.value==="swarm")return i`<${mv} />`;if(!Wt.value)return i`<${tv} />`;switch(G.value){case"chains":return i`<${Av} />`;case"topology":return i`<${nv} />`;case"alerts":return i`<${sv} />`;case"trace":return i`<${av} />`;case"control":return i`<${Tv} />`;case"operations":default:return i`<${Sv} />`}}function Nv(){return lt(()=>{oe(),re(),pm(),Et()},[]),lt(()=>{if(F.value.tab!=="command")return;const t=F.value.params.surface,e=F.value.params.operation,n=Yn(F.value);if(po(t))Ce(t);else if(n){const s=$r(n);po(s)&&Ce(s)}else t||Ce("warroom");e&&Ei(e),(t==="swarm"||t==="warroom"||G.value==="warroom")&&Et(),(t==="warroom"||G.value==="warroom")&&ct()},[F.value.tab,F.value.params.surface,F.value.params.operation,F.value.params.operation_id,F.value.params.run_id,F.value.params.source,F.value.params.action_type,F.value.params.target_type,F.value.params.target_id,F.value.params.focus_kind]),lt(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,oe(),re(),(G.value==="swarm"||G.value==="warroom")&&Et(),G.value==="warroom"&&ct()},250))},n=new EventSource(Mm()),s=Nm.map(a=>{const o=()=>e();return n.addEventListener(a,o),{type:a,handler:o}});return n.onerror=()=>{e()},()=>{s.forEach(({type:a,handler:o})=>{n.removeEventListener(a,o)}),n.close(),t&&window.clearTimeout(t)}},[]),lt(()=>{const t=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const e=G.value;e!=="swarm"&&e!=="warroom"||(oe(),Et(),e==="warroom"&&ct())},5e3);return()=>{window.clearInterval(t)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{ce(()=>fm())}}
            disabled=${dt("dispatch:tick")}
          >
            ${dt("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{oe(),re(),Et(),G.value==="warroom"&&ct()}}
            disabled=${Fs.value}
          >
            ${Fs.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Ks.value?i`<div class="empty-state error">${Ks.value}</div>`:null}
      ${Hs.value?i`<div class="empty-state error">${Hs.value}</div>`:null}
      <${St} surfaceId="command" />
      <${Jm} />
      ${G.value==="warroom"?null:i`<${Vm} />`}
      <${Iv} />
      <${Rv} />
    </section>
  `}const Qr="masc_dashboard_agent_name";function Pv(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Qr))==null?void 0:s.trim())||"dashboard"}const ma=_(Pv()),Ve=_(""),pi=_("운영 점검"),Ye=_(""),On=_(""),Fn=_("2"),qn=_(""),jt=_("note"),Kn=_(""),Un=_(""),Hn=_(""),Wn=_("2"),Ys=_("운영자 중지 요청"),Qs=_(""),Qe=_(""),ds=_(null);function Lv(t){const e=t.trim()||"dashboard";ma.value=e,localStorage.setItem(Qr,e)}function vo(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Mv(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function nn(t){return typeof t=="string"?t.trim().toLowerCase():""}function Dv(t){var s;const e=nn(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=nn((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function xa(t){const e=nn(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function _o(t){return t.some(e=>nn(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function zv(t){return t.target_type==="team_session"}function Ev(t){return t.target_type==="keeper"}function us(t){switch(t){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";case"keeper_msg":return"keeper 메시지";default:return(t==null?void 0:t.trim())||"액션"}}function ps(t){switch(t){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";default:return(t==null?void 0:t.trim())||"target"}}function mn(t){switch(nn(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function fo(t){return t?"확인 후 실행":"즉시 실행"}function jv(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";default:return t}}function gt(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function Ov(t){if(t.action_type==="team_task_inject")return"task";if(t.action_type==="team_broadcast")return"broadcast";if(t.action_type==="team_note")return"note";if(t.action_type==="team_turn"){const e=gt(t.suggested_payload,"turn_kind");if(e==="broadcast"||e==="task")return e}return"note"}function Fv(t){const e=t.suggested_payload;if(t.target_type==="room"){if(t.action_type==="broadcast"){Ve.value=gt(e,"message")??t.summary;return}t.action_type==="task_inject"&&(Ye.value=gt(e,"title")??"운영자 주입 작업",On.value=gt(e,"description")??t.summary,Fn.value=gt(e,"priority")??Fn.value);return}if(t.target_type==="team_session"){if(t.target_id&&(qn.value=t.target_id),t.action_type==="team_stop"){Ys.value=gt(e,"reason")??t.summary;return}jt.value=Ov(t);const n=gt(e,"message");n&&(Kn.value=n),jt.value==="task"&&(Un.value=gt(e,"task_title")??gt(e,"title")??"운영자 주입 작업",Hn.value=gt(e,"task_description")??gt(e,"description")??t.summary,Wn.value=gt(e,"task_priority")??gt(e,"priority")??Wn.value);return}t.target_type==="keeper"&&(t.target_id&&(Qs.value=t.target_id),Qe.value=gt(e,"message")??t.summary)}function qv(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function Re(t){const e=ma.value.trim()||"dashboard";try{const n=await bu({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?D("확인 대기열에 올렸습니다","warning"):D(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return D(s,"error"),null}}async function go(){const t=Ve.value.trim();if(!t)return;await Re({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(Ve.value="")}async function Kv(){await Re({action_type:"room_pause",target_type:"room",payload:{reason:pi.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function $o(){await Re({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function Uv(){const t=Ye.value.trim();if(!t)return;await Re({action_type:"task_inject",target_type:"room",payload:{title:t,description:On.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(Fn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(Ye.value="",On.value="")}async function Hv(){var r;const t=Kt.value,e=qn.value||((r=t==null?void 0:t.sessions[0])==null?void 0:r.session_id)||"";if(!e){D("먼저 세션을 고르세요","warning");return}const n={},s=Kn.value.trim();s&&(n.message=s);let a="team_note";jt.value==="broadcast"?a="team_broadcast":jt.value==="task"&&(a="team_task_inject"),jt.value==="task"&&(n.task_title=Un.value.trim()||"운영자 주입 작업",n.task_description=Hn.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(Wn.value,10)||2),await Re({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Kn.value="",jt.value==="task"&&(Un.value="",Hn.value=""))}async function Wv(){var n;const t=Kt.value,e=qn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){D("먼저 세션을 고르세요","warning");return}await Re({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Ys.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function Bv(){var a;const t=Kt.value,e=Qs.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=Qe.value.trim();if(!e){D("먼저 keeper를 고르세요","warning");return}if(!n)return;await Re({action_type:"keeper_message",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`${e}에게 메시지를 보냈습니다`})&&(Qe.value="")}async function Gv(t){const e=ma.value.trim()||"dashboard";try{await ku(e,t),D("확인 실행을 완료했습니다","success")}catch(n){const s=n instanceof Error?n.message:"확인 실행에 실패했습니다";D(s,"error")}}function Jv(){var M,Y,J;const t=Kt.value,e=F.value.tab==="intervene"?Yn(F.value):null,n=rr.value,s=Ut.value,a=(t==null?void 0:t.room)??{},o=(t==null?void 0:t.sessions)??[],r=(t==null?void 0:t.keepers)??[],l=(t==null?void 0:t.pending_confirms)??[],p=(t==null?void 0:t.recent_messages)??[],m=(n==null?void 0:n.recommended_actions)??[],d=(t==null?void 0:t.available_actions)??[],u=o.find(f=>f.session_id===qn.value)??o[0]??null,v=r.find(f=>f.name===Qs.value)??r[0]??null,$=(n==null?void 0:n.attention_items)??[],x=$.filter(zv),S=$.filter(Ev),T=o.filter(f=>Dv(f)!=="ok"),N=r.filter(f=>xa(f)!=="ok"),I=p.slice(0,5),A=qv(e,o,r);lt(()=>{Qt()},[]),lt(()=>{if(F.value.tab!=="intervene"){ds.value=null;return}if(!e){ds.value=null;return}ds.value!==e.id&&(ds.value=e.id,Fv(e))},[F.value.tab,F.value.params.source,F.value.params.action_type,F.value.params.target_type,F.value.params.target_id,F.value.params.focus_kind,e==null?void 0:e.id]),lt(()=>{const f=(u==null?void 0:u.session_id)??null;en(f)},[u==null?void 0:u.session_id]);const L=[{key:"room",label:"Room 게이트",value:a.paused?"일시정지":"열림",detail:a.paused?`재개 전환 대기 중${a.pause_reason?` · ${a.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:a.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:l.length,detail:l.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:l.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:x.length>0?x.length:o.length,detail:x.length>0?((M=x[0])==null?void 0:M.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":o.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:x.length>0?_o(x):o.length===0?"warn":T.some(f=>nn(f.status)==="paused")?"bad":T.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:S.length>0?S.length:N.length,detail:S.length>0?((Y=S[0])==null?void 0:Y.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":N.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:S.length>0?_o(S):N.some(f=>xa(f)==="bad")?"bad":N.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${St} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">Intervene</div>
            <${E} panelId="intervene.action_studio" compact=${!0} />
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
            value=${ma.value}
            onInput=${f=>Lv(f.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{ct(),Qt(),en((u==null?void 0:u.session_id)??null)}}
            disabled=${Dn.value||X.value}
          >
            ${Dn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${pe.value?i`<section class="ops-banner error">${pe.value}</section>`:null}
      ${tn.value?i`<section class="ops-banner error">${tn.value}</section>`:null}
      ${e?i`
        <section class="ops-banner ${A?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${da(e.action_type)}</span>
            <span>${Pi(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?i`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${A?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const f=[];if(l.length>0&&f.push({label:`확인 대기 ${l.length}건 처리`,desc:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:"bad",onClick:()=>{const K=document.querySelector(".ops-pending-section");K==null||K.scrollIntoView({behavior:"smooth"})}}),a.paused&&f.push({label:"Room 재개",desc:`현재 일시정지 상태${a.pause_reason?` (${a.pause_reason})`:""}`,tone:"warn",onClick:()=>void $o()}),N.length>0){const K=N.filter(tt=>xa(tt)==="bad");f.push({label:K.length>0?`Keeper ${K.length}개 오프라인`:`Keeper ${N.length}개 점검 필요`,desc:K.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:K.length>0?"bad":"warn",onClick:()=>{const tt=document.querySelector(".ops-keeper-section");tt==null||tt.scrollIntoView({behavior:"smooth"})}})}return f.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${f.slice(0,3).map(K=>i`
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
          <${E} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 room인지, session인지, keeper인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${L.map(f=>i`
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
              <${E} panelId="intervene.action_studio" compact=${!0} />
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
                value=${Ve.value}
                onInput=${f=>{Ve.value=f.target.value}}
                onKeyDown=${f=>{f.key==="Enter"&&go()}}
                disabled=${X.value}
              />
              <button class="control-btn" onClick=${()=>{go()}} disabled=${X.value||Ve.value.trim()===""}>
                보내기
              </button>
            </div>

            <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
            <div class="control-row ops-split-row">
              <input
                id="ops-pause-reason"
                class="control-input"
                type="text"
                value=${pi.value}
                onInput=${f=>{pi.value=f.target.value}}
                disabled=${X.value}
              />
              <button class="control-btn ghost" onClick=${()=>{Kv()}} disabled=${X.value}>
                일시정지
              </button>
              <button class="control-btn ghost" onClick=${()=>{$o()}} disabled=${X.value}>
                재개
              </button>
            </div>

            <div class="ops-section-head">작업 주입</div>
            <input
              class="control-input"
              type="text"
              placeholder="작업 제목"
              value=${Ye.value}
              onInput=${f=>{Ye.value=f.target.value}}
              disabled=${X.value}
            />
            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="작업 설명"
              value=${On.value}
              onInput=${f=>{On.value=f.target.value}}
              disabled=${X.value}
            ></textarea>
            <div class="control-row ops-split-row">
              <select
                class="control-input ops-select"
                value=${Fn.value}
                onChange=${f=>{Fn.value=f.target.value}}
                disabled=${X.value}
              >
                <option value="1">P1</option>
                <option value="2">P2</option>
                <option value="3">P3</option>
                <option value="4">P4</option>
                <option value="5">P5</option>
              </select>
              <button class="control-btn" onClick=${()=>{Uv()}} disabled=${X.value||Ye.value.trim()===""}>
                주입
              </button>
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">추천 개입</div>
              <${E} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
            ${zn.value&&!n?i`
              <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
            `:m.length>0?i`
              <div class="ops-log-list">
                ${m.map(f=>i`
                  <article key=${`${f.action_type}:${f.target_type}:${f.target_id??"room"}`} class="ops-log-entry ${f.severity}">
                    <div class="ops-log-head">
                      <strong>${us(f.action_type)}</strong>
                      <span>${ps(f.target_type)}${f.target_id?` · ${f.target_id}`:""}</span>
                      <span>${fo(f.confirm_required)}</span>
                    </div>
                    <div class="ops-log-body">${f.reason}</div>
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
              <${E} panelId="intervene.pending_confirmations" compact=${!0} />
            </div>
            <p class="ops-context-note">미리보기만 끝났고 아직 사람이 눌러줘야 하는 액션만 남깁니다.</p>
            ${l.length>0?i`
              <div class="ops-confirmation-list">
                ${l.map(f=>i`
                  <article key=${f.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${us(f.action_type)}</strong>
                      <span>${ps(f.target_type)}${f.target_id?` · ${f.target_id}`:""}</span>
                      <span>${f.delegated_tool??"위임 도구 확인 필요"}</span>
                    </div>
                    ${f.preview?i`<pre class="ops-code-block compact">${vo(f.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{Gv(f.confirm_token)}} disabled=${X.value}>
                        실행
                      </button>
                      <span class="ops-token">${f.confirm_token}</span>
                    </div>
                  </article>
                `)}
              </div>
            `:i`<div class="ops-empty">지금 승인 대기는 없습니다.</div>`}
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 Room 메시지</div>
              <${E} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
            ${I.length>0?i`
              <div class="ops-feed-list">
                ${I.map(f=>i`
                  <article key=${f.seq??f.id??f.timestamp} class="ops-feed-item">
                    <div class="ops-feed-meta">
                      <strong>${f.from}</strong>
                      <span>${f.timestamp}</span>
                    </div>
                    <div class="ops-feed-content">${f.content}</div>
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
              <${E} panelId="intervene.session_queue" compact=${!0} />
            </div>
            <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

            <div class="ops-entity-list">
              ${o.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:o.map(f=>{var K;return i`
                <button
                  key=${f.session_id}
                  class="ops-entity-card ${(u==null?void 0:u.session_id)===f.session_id?"active":""}"
                  onClick=${()=>{qn.value=f.session_id}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${f.session_id}</strong>
                    <span class="status-badge ${f.status??"idle"}">${mn(f.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round(f.progress_pct??0)}%</span>
                    <span>${f.done_delta_total??0}건 완료</span>
                    <span>${(K=f.team_health)!=null&&K.status?mn(String(f.team_health.status)):"상태 확인 필요"}</span>
                  </div>
                </button>
              `})}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">선택한 Session 요약</div>
              <${E} panelId="intervene.session_digest" compact=${!0} />
            </div>
            <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
            ${u&&s?i`
              <div class="ops-log-list">
                ${s.attention_items.length>0?s.attention_items.map(f=>i`
                  <article key=${`${f.kind}:${f.target_id??"session"}`} class="ops-log-entry ${f.severity}">
                    <div class="ops-log-head">
                      <strong>${f.kind}</strong>
                      <span>${ps(f.target_type)}${f.target_id?` · ${f.target_id}`:""}</span>
                    </div>
                    <div class="ops-log-body">${f.summary}</div>
                  </article>
                `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
                ${s.worker_cards.length>0?s.worker_cards.map(f=>i`
                  <article key=${`${f.actor??f.spawn_role??"worker"}:${f.spawn_agent??f.runtime_pool??"runtime"}`} class="ops-log-entry">
                    <div class="ops-log-head">
                      <strong>${f.actor??f.spawn_role??"worker"}</strong>
                      <span>${mn(f.status)}</span>
                      <span>${f.spawn_agent??f.runtime_pool??"runtime 확인 필요"}</span>
                    </div>
                    <div class="ops-log-body">
                      ${f.worker_class??"worker"}${f.lane_id?` · ${f.lane_id}`:""}${f.routing_reason?` · ${f.routing_reason}`:""}
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
              <${E} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>

            ${u?i`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${u.session_id}</div>
                <div class="ops-detail-meta">
                  <span>상태: ${mn(u.status)}</span>
                  <span>경과: ${u.elapsed_sec??0}초</span>
                  <span>남은 시간: ${u.remaining_sec??0}초</span>
                </div>
                ${u.recent_events&&u.recent_events.length>0?i`
                  <pre class="ops-code-block compact">${vo(u.recent_events.slice(-3))}</pre>
                `:null}
              </div>
            `:i`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

            <label class="control-label" for="ops-turn-kind">세션 액션</label>
            <div class="control-row ops-split-row">
              <select
                id="ops-turn-kind"
                class="control-input ops-select"
                value=${jt.value}
                onChange=${f=>{jt.value=f.target.value}}
                disabled=${X.value||!u}
              >
                <option value="note">노트</option>
                <option value="broadcast">방송</option>
                <option value="task">작업</option>
              </select>
              <button class="control-btn" onClick=${()=>{Hv()}} disabled=${X.value||!u}>
                적용
              </button>
            </div>
            <div class="ops-context-note">현재 선택: ${jv(jt.value)}</div>

            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="세션에 남길 메시지"
              value=${Kn.value}
              onInput=${f=>{Kn.value=f.target.value}}
              disabled=${X.value||!u}
            ></textarea>

            ${jt.value==="task"?i`
              <input
                class="control-input"
                type="text"
                placeholder="주입할 작업 제목"
                value=${Un.value}
                onInput=${f=>{Un.value=f.target.value}}
                disabled=${X.value||!u}
              />
              <textarea
                class="control-textarea"
                rows=${2}
                placeholder="주입할 작업 설명"
                value=${Hn.value}
                onInput=${f=>{Hn.value=f.target.value}}
                disabled=${X.value||!u}
              ></textarea>
              <select
                class="control-input ops-select"
                value=${Wn.value}
                onChange=${f=>{Wn.value=f.target.value}}
                disabled=${X.value||!u}
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
                value=${Ys.value}
                onInput=${f=>{Ys.value=f.target.value}}
                disabled=${X.value||!u}
              />
              <button class="control-btn ghost" onClick=${()=>{Wv()}} disabled=${X.value||!u}>
                세션 중지
              </button>
            </div>
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel ops-keeper-section">
            <div class="card-title-row">
              <div class="card-title">Keeper 개입</div>
              <${E} panelId="intervene.keeper_queue" compact=${!0} />
            </div>
            <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

            <div class="ops-entity-list">
              ${r.length===0?i`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:r.map(f=>i`
                <button
                  key=${f.name}
                  class="ops-entity-card ${(v==null?void 0:v.name)===f.name?"active":""}"
                  onClick=${()=>{Qs.value=f.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${f.name}</strong>
                    <span class="status-badge ${f.status??"idle"}">${mn(f.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${f.model??"model 확인 필요"}</span>
                    <span>${typeof f.context_ratio=="number"?`${Math.round(f.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                    <span>${Mv(f.last_turn_ago_s)}</span>
                  </div>
                </button>
              `)}
            </div>
          </section>

          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">선택한 Keeper 액션</div>
              <${E} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">선택한 keeper에만 직접 메시지를 보내서 probe, 수정, 재지시를 합니다.</p>

            ${v?i`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${v.name}</div>
                <div class="ops-detail-meta">
                  <span>자율성: ${v.autonomy_level??"확인 없음"}</span>
                  <span>세대: ${v.generation??0}</span>
                  <span>활성 목표: ${((J=v.active_goal_ids)==null?void 0:J.length)??0}</span>
                </div>
              </div>
            `:i`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

            <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
            <textarea
              id="ops-keeper-message"
              class="control-textarea"
              rows=${6}
              placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
              value=${Qe.value}
              onInput=${f=>{Qe.value=f.target.value}}
              disabled=${X.value||!v}
            ></textarea>
            <div class="control-row">
              <button class="control-btn" onClick=${()=>{Bv()}} disabled=${X.value||!v||Qe.value.trim()===""}>
                keeper에 보내기
              </button>
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">가능한 액션 목록</div>
              <${E} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
            <div class="ops-log-list">
              ${d.length?d.map(f=>i`
                    <article key=${`${f.action_type}:${f.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${us(f.action_type)}</strong>
                        <span>${ps(f.target_type)}</span>
                        <span>${fo(f.confirm_required)}</span>
                      </div>
                      <div class="ops-log-body">${f.description??"설명이 아직 없습니다."}</div>
                    </article>
                  `):i`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 개입 로그</div>
              <${E} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <div class="ops-log-list">
              ${Es.value.length===0?i`
                <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
              `:Es.value.map(f=>i`
                <article key=${f.id} class="ops-log-entry ${f.outcome}">
                  <div class="ops-log-head">
                    <strong>${us(f.action_type)}</strong>
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
  `}function Vv({text:t}){if(!t)return null;const e=Yv(t);return i`<div class="markdown-content">${e}</div>`}function Yv(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],l=a.slice(r.length).trim(),p=[];for(s++;s<e.length&&!e[s].startsWith(r);)p.push(e[s]),s++;s++,n.push(i`<pre><code class=${l?`language-${l}`:""}>${p.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],l=a.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const m=e[s].replace("</think>","").trim();m&&r.push(m),s++}const p=r.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Sa(p)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(i`<blockquote>${Sa(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;o.push(r),s++}o.length>0&&n.push(i`<p>${Sa(o.join(`
`))}</p>`)}return n}function Sa(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&e.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Xr=[{id:"recent",label:"Latest"},{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],As=_(null),Cs=_([]),sn=_(!1),Ae=_(null),kn=_(""),xn=_(!1),qe=_(!0);function Qv(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Xv=_(Qv());function Zv(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function ho(t){return t.updated_at!==t.created_at}function t_(t){const e=`${t.title} ${t.tags.join(" ")} ${t.flair??""}`.toLowerCase();return/\b(test|smoke|harness|sandbox|dummy|sample|tmp|qa|e2e)\b/.test(e)||e.includes("테스트")||e.includes("실험")}function e_(t){const e=(t.hearth??"").toLowerCase();return t.visibility!=="internal"||!t.expires_at||!e?!1:!!(e.startsWith("mdal")||e.includes("harness"))}function Zr(t){return qe.value?t.filter(e=>e_(e)?!1:e.hearth||e.visibility||e.expires_at?!0:!t_(e)):t}async function qi(t){Ae.value=t,As.value=null,Cs.value=[],sn.value=!0;try{const e=await lc(t);if(Ae.value!==t)return;As.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth:e.hearth,visibility:e.visibility,expires_at:e.expires_at,hearth_count:e.hearth_count},Cs.value=e.comments??[]}catch{Ae.value===t&&(As.value=null,Cs.value=[])}finally{Ae.value===t&&(sn.value=!1)}}async function yo(t){const e=kn.value.trim();if(e){xn.value=!0;try{await cc(t,Xv.value,e),kn.value="",D("Comment posted","success"),await qi(t),Ft()}catch{D("Failed to post comment","error")}finally{xn.value=!1}}}function n_(){const t=In.value,e=qe.value?"Hiding automation posts":"Show automation posts";return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Xr.map(n=>i`
          <button
            class="board-sort-btn ${t===n.id?"active":""}"
            onClick=${()=>{In.value=n.id,Ft()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${qe.value?"is-active":""}"
          onClick=${()=>{qe.value=!qe.value}}
        >
          ${e}
        </button>
        <button
          class="control-btn ghost ${je.value?"is-active":""}"
          onClick=${()=>{je.value=!je.value,Ft()}}
        >
          ${je.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${Ft} disabled=${Rn.value}>
          ${Rn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function Aa(){var s;const t=((s=Xr.find(a=>a.id===In.value))==null?void 0:s.label)??In.value,e=Zr(Tn.value),n=Tn.value.length-e.length;return i`
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
        <strong>${qe.value?`automation ${n} hidden`:"full feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${je.value?"Auto reports hidden":"Full memory feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${ii.value?i`<${ot} timestamp=${ii.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function s_({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Uo(t.id,n),Ft()}catch{D("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>kl(t.id)}>
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
                ${ho(t)?i`<span class="board-meta-chip">Updated</span>`:null}
                ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${ot} timestamp=${t.created_at} /></span>
            ${ho(t)?i`<span>Updated <${ot} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${Zv(t.content)}</div>
      </div>
    </div>
  `}function a_({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${ot} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function i_({postId:t}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${kn.value}
        onInput=${e=>{kn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&yo(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${xn.value}
      />
      <button
        onClick=${()=>yo(t)}
        disabled=${xn.value||kn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${xn.value?"...":"Post"}
      </button>
    </div>
  `}function o_({post:t}){Ae.value!==t.id&&!sn.value&&qi(t.id);const e=async n=>{try{await Uo(t.id,n),Ft()}catch{D("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>$t("memory")}>← Back to Memory</button>
      <${P} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${Vv} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${t.author}</span>
            <${ot} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
          </div>
          ${t.hearth||t.visibility||t.expires_at?i`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                  ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
                  ${t.expires_at?i`<span class="board-meta-chip">expires <${ot} timestamp=${t.expires_at} /></span>`:null}
                </div>
              `:null}
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${P} title="Comments" semanticId="memory.feed">
        ${sn.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${a_} comments=${Cs.value} />`}
        <${i_} postId=${t.id} />
      <//>
    </div>
  `}function r_(){const t=Zr(Tn.value),e=F.value.params.post??null,n=e?t.find(s=>s.id===e)??(Ae.value===e?As.value:null):null;return e&&!n&&Ae.value!==e&&!sn.value&&qi(e),e?n?i`
          <${St} surfaceId="memory" />
          <${Aa} />
          <${o_} post=${n} />
        `:i`
          <div>
            <${St} surfaceId="memory" />
            <${Aa} />
            <button class="back-btn" onClick=${()=>$t("memory")}>← Back to Memory</button>
            ${sn.value?i`<div class="loading-indicator">Loading post...</div>`:i`<div class="empty-state">Post not found</div>`}
          </div>
        `:i`
    <div>
      <${St} surfaceId="memory" />
      <${Aa} />
      <${n_} />
      ${Rn.value?i`<div class="loading-indicator">Loading memory feed...</div>`:t.length===0?i`<div class="empty-state">No posts in durable memory right now</div>`:i`
              <${P} title="Posts / Comments" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.map(s=>i`<${s_} key=${s.id} post=${s} />`)}
                </div>
              <//>
            `}
    </div>
  `}function tl({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,o=2*Math.PI*s,r=o*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),i`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${l}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${o}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${l}">${Math.round(t*100)}%</span>
    </div>
  `}const Ca=600*1e3,l_=1200*1e3,bo=.8;function se(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Me(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function c_(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function d_(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function u_(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function p_(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function m_(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function v_(t){var p,m;const e=Si.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,s=n?Math.max(0,Date.now()-se(n)):Number.POSITIVE_INFINITY,a=!!((p=t.current_task)!=null&&p.trim())||e.activeAssignedCount>0;let o="watching",r="ok",l="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",r="bad",l=n?"Offline or inactive":"No recent presence"):s>l_?(o="quiet",r="bad",l=a?"Working without a fresh signal":"No fresh agent signal"):a?(o="working",r=s>Ca?"warn":"ok",l=s>Ca?"Execution looks quiet for too long":"Task and live signal aligned"):s>Ca?(o="quiet",r="warn",l="Quiet but still reachable"):t.status==="idle"&&(o="watching",r="ok",l="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:r,focus:((m=t.current_task)==null?void 0:m.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:l}}function __(t){const e=ud.value.get(t.name)??"idle",n=vd.value.has(t.name),s=t.context_ratio??0;let a="healthy",o="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(a="critical",o="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||s>=bo)&&(a="warning",o="warn",r=s>=bo?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:a,tone:o,focus:p_(t),note:r}}function vn({label:t,value:e,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function f_({item:t}){const e=t.kind==="agent"?()=>Ze(t.agent.name):()=>Ii(t.keeper);return i`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?i`<span><${ot} timestamp=${t.timestamp} /></span>`:i`<span>No signal</span>`}
      </div>
    </button>
  `}function ko({row:t}){const{agent:e,motion:n}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Ze(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${tl} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${ve} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${c_(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?i`<span>Signal <${ot} timestamp=${t.lastSignalAt} /></span>`:i`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
        ${e.last_seen?i`<span>Seen <${ot} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?i`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function g_({row:t}){const{keeper:e}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Ii(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${tl} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${ve} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${d_(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?i`<span>Heartbeat <${ot} timestamp=${e.last_heartbeat} /></span>`:i`<span>No heartbeat</span>`}
        <span>${m_(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${u_(e.context_ratio)}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?i`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function $_(){const t=[...It.value].map(v_).sort((d,u)=>{const v=Me(u.tone)-Me(d.tone);if(v!==0)return v;const $=u.activeTaskCount-d.activeTaskCount;return $!==0?$:se(u.lastSignalAt)-se(d.lastSignalAt)}),e=[...Zt.value].map(__).sort((d,u)=>{const v=Me(u.tone)-Me(d.tone);if(v!==0)return v;const $=(u.keeper.context_ratio??0)-(d.keeper.context_ratio??0);return $!==0?$:se(u.keeper.last_heartbeat)-se(d.keeper.last_heartbeat)}),n=t.filter(d=>d.state!=="offline"),s=t.filter(d=>d.state==="offline"),a=n.length,o=t.filter(d=>d.state==="working").length,r=t.filter(d=>d.lastSignalAt&&Date.now()-se(d.lastSignalAt)<=12e4).length,l=t.filter(d=>d.tone!=="ok"),p=e.filter(d=>d.tone!=="ok"),m=[...p.map(d=>({kind:"keeper",key:`keeper-${d.keeper.name}`,tone:d.tone,title:d.keeper.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.keeper.last_heartbeat??null,keeper:d.keeper})),...l.map(d=>({kind:"agent",key:`agent-${d.agent.name}`,tone:d.tone,title:d.agent.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt,agent:d.agent}))].sort((d,u)=>{const v=Me(u.tone)-Me(d.tone);return v!==0?v:se(u.timestamp)-se(d.timestamp)}).slice(0,8);return i`
    <div class="agents-monitor">
      <${St} surfaceId="execution" />
      <div class="stats-grid">
        <${vn} label="Workers online" value=${a} color="#4ade80" caption="활성 + 대기 실행 actor" />
        <${vn} label="Working now" value=${o} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${vn} label="Fresh signals" value=${r} color="#22d3ee" caption="최근 2분 이내 신호" />
        <${vn} label="Worker alerts" value=${l.length} color=${l.length>0?"#fb7185":"#4ade80"} caption="실행 actor 경고" />
        <${vn} label="Continuity alerts" value=${p.length} color=${p.length>0?"#fb7185":"#4ade80"} caption="keeper 연속성 경고" />
      </div>

      <${P} title="Execution Priorities" class="section" semanticId="execution.priority_queue">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs execution attention right now</h2>
          <p class="monitor-subheadline">Worker drift and keeper continuity risk are ranked together here, but diagnosed in separate sections below.</p>
        </div>
        <div class="monitor-alert-list">
          ${m.length===0?i`<div class="empty-state">No execution alerts right now</div>`:m.map(d=>i`<${f_} key=${d.key} item=${d} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${P} title="Workers" class="section" semanticId="execution.workers">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Live workers stay grouped here so owner drift is visible before you scan offline history.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?i`<div class="empty-state">No active workers visible</div>`:n.map(d=>i`<${ko} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>

        <${P} title="Continuity" class="section" semanticId="execution.continuity">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper continuity</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and handoff state are isolated from worker execution drift.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?i`<div class="empty-state">No keepers active</div>`:e.map(d=>i`<${g_} key=${d.keeper.name} row=${d} />`)}
          </div>
        <//>

        <${P} title="Offline Workers" class="section" semanticId="execution.offline">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who dropped out of the live loop</h2>
            <p class="monitor-subheadline">Offline rows stay separate so they do not drown the active execution monitor.</p>
          </div>
          <div class="monitor-list">
            ${s.length===0?i`<div class="empty-state">No offline workers right now</div>`:s.map(d=>i`<${ko} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Xs=_("all"),Zs=_("all"),mi=_(new Set);function h_(t){const e=new Set(mi.value);e.has(t)?e.delete(t):e.add(t),mi.value=e}const el=Tt(()=>{let t=Ue.value;return Xs.value!=="all"&&(t=t.filter(e=>e.horizon===Xs.value)),Zs.value!=="all"&&(t=t.filter(e=>e.status===Zs.value)),t}),y_=Tt(()=>{const t={short:[],mid:[],long:[]};for(const e of el.value){const n=t[e.horizon];n&&n.push(e)}return t}),b_=Tt(()=>{const t=Array.from(Vo.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function k_(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Ki(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function ws(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function x_(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function xo(t){return t.toFixed(4)}function So(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function S_(t){switch(t){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function Ao(t,e){return(t.priority??4)-(e.priority??4)}function A_(t,e){const n=t.updated_at??t.created_at??"";return(e.updated_at??e.created_at??"").localeCompare(n)}function C_(t,e){return t.length<=e?t:t.slice(0,e)+"..."}function w_({goal:t}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ws(t.horizon)}">
            ${Ki(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${k_(t.priority)}</span>
          ${t.metric?i`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?i`<span class="goal-due">Due: <${ot} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?i`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${ve} status=${t.status} />
        <div class="goal-updated">
          <${ot} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function wa({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return i`
    <${P} title="${Ki(t)} Goals (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${w_} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function T_(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>i`
          <button
            class="goal-filter-btn ${Xs.value===t?"active":""}"
            onClick=${()=>{Xs.value=t}}
          >
            ${t==="all"?"All":Ki(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>i`
          <button
            class="goal-filter-btn ${Zs.value===t?"active":""}"
            onClick=${()=>{Zs.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function I_(){const t=Ue.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return i`
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
  `}function R_({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return i`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${ve} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${xo(t.baseline_metric)}</span>
          <span>Current ${xo(t.current_metric)}</span>
          <span class=${So(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${So(t)}
          </span>
          <span>Elapsed ${x_(t.elapsed_seconds)}</span>
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
  `}function Ta({task:t}){const e=t.priority??4,n=e<=1?"p1":e===2?"p2":e===3?"p3":"p4",s=mi.value.has(t.id),a=!!t.description;return i`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${S_(e)}</span>
        <div class="kanban-card-title">${t.title}</div>
      </div>
      ${a?i`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>h_(t.id)}
        >
          ${s?t.description:C_(t.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${t.created_at?i`<${ot} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function N_(){const{todo:t,inProgress:e,done:n}=Qo.value,s=[...t].sort(Ao),a=[...e].sort(Ao),o=[...n].sort(A_);return i`
    <${P} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${s.length===0?i`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:s.map(r=>i`<${Ta} key=${r.id} task=${r} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${a.length===0?i`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:a.map(r=>i`<${Ta} key=${r.id} task=${r} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${o.length===0?i`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:o.slice(0,20).map(r=>i`<${Ta} key=${r.id} task=${r} />`)}
          ${o.length>20?i`<div class="empty-state" style="opacity: 0.5;">...and ${o.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function P_(){const{todo:t,inProgress:e,done:n}=Qo.value,s=t.length+e.length+n.length,a=[...t,...e].filter(d=>(d.priority??4)<=2).length,o=y_.value,r=b_.value,l=Ue.value.length>0,p=r.length>0,m=ki.value;return i`
    <div>
      <${St} surfaceId="planning" />

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
          onClick=${()=>{Nn(),nr()}}
          disabled=${$n.value||hn.value}
        >
          ${$n.value||hn.value?"Refreshing...":"Refresh planning data"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${N_} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${l}>
        <summary>
          Goal Pipeline
          <span class="monitor-pill">${Ue.value.length}</span>
        </summary>
        <div>
          ${l?i`
            <${I_} />
            <${T_} />
            ${$n.value&&Ue.value.length===0?i`<div class="loading-indicator">Loading goals...</div>`:el.value.length===0?i`<div class="empty-state">No goals match the current filters</div>`:i`
                    <${wa} horizon="short" items=${o.short??[]} />
                    <${wa} horizon="mid" items=${o.mid??[]} />
                    <${wa} horizon="long" items=${o.long??[]} />
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
          <span class="monitor-pill">${r.length}</span>
        </summary>
        <div>
          ${hn.value&&r.length===0?i`<div class="loading-indicator">Loading MDAL loops...</div>`:r.length===0&&(m==="error"||He.value)?i`<div class="empty-state">MDAL snapshot could not be loaded${He.value?`: ${He.value}`:""}. Check backend health.</div>`:r.length===0?i`<div class="empty-state">No active loops. Use <code>masc_mdal_start</code> to start a loop.</div>`:i`
                  <div class="planning-loop-list">
                    ${r.map(d=>i`<${R_} key=${d.loop_id} loop=${d} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const Sn=_("debates"),ta=_([]),ea=_([]),na=_(!1),An=_(!1),Bn=_(""),Cn=_(""),sa=_(null),Pt=_(null),vi=_(!1);async function va(){na.value=!0,Bn.value="";try{const t=await Hl();ta.value=Array.isArray(t.debates)?t.debates:[],ea.value=Array.isArray(t.sessions)?t.sessions:[]}catch(t){Bn.value=t instanceof Error?t.message:"Failed to load governance state"}finally{na.value=!1}}Id(va);async function Co(){const t=Cn.value.trim();if(t){An.value=!0;try{const e=await zc(t);Cn.value="",D(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await va()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";D(n,"error")}finally{An.value=!1}}}async function L_(t){sa.value=t,Pt.value=null,vi.value=!0;try{Pt.value=await Ec(t)}catch(e){Bn.value=e instanceof Error?e.message:"Failed to load debate detail"}finally{vi.value=!1}}function M_(){return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${ta.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Voting sessions</span>
        <strong>${ea.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Active view</span>
        <strong>${Sn.value==="debates"?"Debates":"Voting"}</strong>
      </div>
    </div>
  `}function D_({debate:t}){const e=sa.value===t.id;return i`
    <button class="council-row ${e?"selected":""}" onClick=${()=>L_(t.id)}>
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Arguments: ${t.argument_count}</span>
          ${t.created_at?i`<span><${ot} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </button>
  `}function z_({session:t}){return i`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.created_at?i`<span><${ot} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function E_(){const t=Sn.value;return i`
    <div class="overview-sub-tabs" style="margin-bottom:12px;">
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{Sn.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{Sn.value="voting"}}>Voting</button>
    </div>
  `}function j_(){return i`
    <div>
      <${P} title="Start Debate" class="section" semanticId="governance.debates">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Cn.value}
            onInput=${t=>{Cn.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&Co()}}
            disabled=${An.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Co}
            disabled=${An.value||Cn.value.trim()===""}
          >
            ${An.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${va} disabled=${na.value}>
            ${na.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Bn.value?i`<div class="council-error">${Bn.value}</div>`:null}
      <//>

      <${P} title="Debates" class="section" semanticId="governance.debates">
        <div class="council-list">
          ${ta.value.length===0?i`<div class="empty-state">No debates yet</div>`:ta.value.map(t=>i`<${D_} key=${t.id} debate=${t} />`)}
        </div>
      <//>

      <${P} title=${sa.value?`Debate Detail (${sa.value})`:"Debate Detail"} class="section" semanticId="governance.debates">
        ${vi.value?i`<div class="loading-indicator">Loading debate detail...</div>`:Pt.value?i`
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Status: ${Pt.value.status}</span>
                  <span>Total arguments: ${Pt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Support: ${Pt.value.support_count}</span>
                  <span>Oppose: ${Pt.value.oppose_count}</span>
                  <span>Neutral: ${Pt.value.neutral_count}</span>
                </div>
                ${Pt.value.summary_text?i`<pre class="council-detail">${Pt.value.summary_text}</pre>`:null}
              `:i`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function O_(){return i`
    <${P} title="Voting Sessions" class="section" semanticId="governance.voting">
      <div class="council-list">
        ${ea.value.length===0?i`<div class="empty-state">No active sessions</div>`:ea.value.map(t=>i`<${z_} key=${t.id} session=${t} />`)}
      </div>
    <//>
  `}function F_(){return lt(()=>{va()},[]),i`
    <div>
      <${St} surfaceId="governance" />
      <${M_} />
      <${E_} />
      ${Sn.value==="debates"?i`<${j_} />`:i`<${O_} />`}
    </div>
  `}const ze=_(""),Ia=_("ability_check"),Ra=_("10"),Na=_("12"),ms=_(""),vs=_("idle"),ae=_(""),_s=_("keeper-late"),Pa=_("player"),La=_(""),kt=_("idle"),Ma=_(null),fs=_(""),Da=_(""),za=_("player"),Ea=_(""),ja=_(""),Oa=_(""),wn=_("20"),Fa=_("20"),qa=_(""),gs=_("idle"),_i=_(null),nl=_("overview"),Ka=_("all"),Ua=_("all"),Ha=_("all"),q_=12e4,_a=_(null),wo=_(Date.now());function K_(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function U_(t,e){return e>0?Math.round(t/e*100):0}const H_={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},W_={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function $s(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function B_(t){const e=t.trim().toLowerCase();return H_[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function G_(t){const e=t.trim().toLowerCase();return W_[e]??"상황에 따라 선택되는 전술 액션입니다."}function de(t){return typeof t=="object"&&t!==null}function yt(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function Lt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function Gn(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const J_=new Set(["str","dex","con","int","wis","cha"]);function V_(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!de(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const r=a.trim();if(r){if(typeof o=="number"&&Number.isFinite(o)){s[r]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const l=Number.parseFloat(o.trim());if(Number.isFinite(l)){s[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),s}function Y_(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(wn.value.trim(),10);Number.isFinite(s)&&s>n&&(wn.value=String(n))}function fi(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Q_(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function X_(t){nl.value=t}function sl(t){const e=_a.value;return e==null||e<=t}function Z_(t){const e=_a.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function aa(){_a.value=null}function al(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function tf(t,e){al(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(_a.value=Date.now()+q_,D("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function Ts(t){return sl(t)?(D("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function gi(t,e,n){return al([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function ef({hp:t,max:e}){const n=U_(t,e),s=K_(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function nf({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function sf({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function il({actor:t}){var p,m,d,u;const e=(p=t.archetype)==null?void 0:p.trim(),n=(m=t.persona)==null?void 0:m.trim(),s=(d=t.portrait)==null?void 0:d.trim(),a=(u=t.background)==null?void 0:u.trim(),o=t.traits??[],r=t.skills??[],l=Object.entries(t.stats_raw??{}).filter(([v,$])=>Number.isFinite($)).filter(([v])=>!J_.has(v.toLowerCase()));return i`
    <div class="trpg-actor">
      ${s?i`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${v=>{const $=v.target;$&&($.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${ve} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${sf} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${ef} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${nf} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${$s(e)}</div>`:null}
      ${a?i`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${l.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${l.map(([v,$])=>i`
                <span class="trpg-custom-stat-chip">${$s(v)} ${$}</span>
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
                  <span class="trpg-annot-name">${$s(v)}</span>
                  <span class="trpg-annot-desc">${B_(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(v=>i`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${$s(v)}</span>
                  <span class="trpg-annot-desc">${G_(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function af({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function ol({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?i`<div class="empty-state" style="font-size:13px">${e}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Q_(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${fi(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${ot} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function of({events:t}){const e="__none__",n=Ka.value,s=Ua.value,a=Ha.value,o=Array.from(new Set(t.map(fi).map(u=>u.trim()).filter(u=>u!==""))).sort((u,v)=>u.localeCompare(v)),r=Array.from(new Set(t.map(u=>(u.type??"").trim()).filter(u=>u!==""))).sort((u,v)=>u.localeCompare(v)),l=t.some(u=>(u.type??"").trim()===""),p=Array.from(new Set(t.map(u=>(u.phase??"").trim()).filter(u=>u!==""))).sort((u,v)=>u.localeCompare(v)),m=t.some(u=>(u.phase??"").trim()===""),d=t.filter(u=>{if(n!=="all"&&fi(u)!==n)return!1;const v=(u.type??"").trim(),$=(u.phase??"").trim();if(s===e){if(v!=="")return!1}else if(s!=="all"&&v!==s)return!1;if(a===e){if($!=="")return!1}else if(a!=="all"&&$!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${u=>{Ka.value=u.target.value}}>
          <option value="all">all</option>
          ${o.map(u=>i`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${u=>{Ua.value=u.target.value}}>
          <option value="all">all</option>
          ${l?i`<option value=${e}>(none)</option>`:null}
          ${r.map(u=>i`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${u=>{Ha.value=u.target.value}}>
          <option value="all">all</option>
          ${m?i`<option value=${e}>(none)</option>`:null}
          ${p.map(u=>i`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Ka.value="all",Ua.value="all",Ha.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${d.length} / 전체 ${t.length}
      </span>
    </div>
    <${ol} events=${d.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function rf({outcome:t}){if(!t)return null;const e=o=>{const r=o.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function rl({state:t}){const e=t.history??[];return e.length===0?null:i`
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
  `}function lf({state:t,nowMs:e}){var m;const n=Jt.value||((m=t.session)==null?void 0:m.room)||"",s=vs.value,a=t.party??[];if(!a.find(d=>d.id===ze.value)&&a.length>0){const d=a[0];d&&(ze.value=d.id)}const r=async()=>{var u,v;if(!n){D("Room ID가 비어 있습니다.","error");return}if(!Ts(e))return;const d=((u=t.current_round)==null?void 0:u.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(gi("라운드 실행",n,d)){vs.value="running";try{const $=await Ac(n);_i.value=$,vs.value="ok";const x=de($.summary)?$.summary:null,S=x?Gn(x,"advanced",!1):!1,T=x?yt(x,"progress_reason",""):"";D(S?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${T?`: ${T}`:""}`,S?"success":"warning"),qt()}catch($){_i.value=null,vs.value="error";const x=$ instanceof Error?$.message:"라운드 실행에 실패했습니다.";D(x,"error")}finally{aa()}}},l=async()=>{var u,v;if(!n||!Ts(e))return;const d=((u=t.current_round)==null?void 0:u.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(gi("턴 강제 진행",n,d))try{await Tc(n),D("턴을 다음 단계로 이동했습니다.","success"),qt()}catch{D("턴 이동에 실패했습니다.","error")}finally{aa()}},p=async()=>{if(!n||!Ts(e))return;const d=ze.value.trim();if(!d){D("먼저 Actor를 선택하세요.","warning");return}const u=Number.parseInt(Ra.value,10),v=Number.parseInt(Na.value,10);if(Number.isNaN(u)||Number.isNaN(v)){D("stat/dc는 숫자여야 합니다.","warning");return}const $=Number.parseInt(ms.value,10),x=ms.value.trim()===""||Number.isNaN($)?void 0:$;try{await wc({roomId:n,actorId:d,action:Ia.value.trim()||"ability_check",statValue:u,dc:v,rawD20:x}),D("주사위 판정을 기록했습니다.","success"),qt()}catch{D("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${d=>{Jt.value=d.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${ze.value}
            onChange=${d=>{ze.value=d.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(d=>i`<option value=${d.id}>${d.name} (${d.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${Ia.value}
              onInput=${d=>{Ia.value=d.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Ra.value}
              onInput=${d=>{Ra.value=d.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Na.value}
              onInput=${d=>{Na.value=d.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${ms.value}
              onInput=${d=>{ms.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&p()}}
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

      ${s!=="idle"?i`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function cf({state:t}){var a;const e=Jt.value||((a=t.session)==null?void 0:a.room)||"",n=gs.value,s=async()=>{if(!e){D("Room ID가 비어 있습니다.","warning");return}const o=fs.value.trim(),r=Da.value.trim();if(!r&&!o){D("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt(wn.value.trim(),10),p=Number.parseInt(Fa.value.trim(),10),m=Number.isFinite(p)?Math.max(1,p):20,d=Number.isFinite(l)?Math.max(0,Math.min(m,l)):m;let u={};try{u=V_(qa.value)}catch(v){D(v instanceof Error?v.message:"능력치 JSON 오류","error");return}gs.value="spawning";try{const v=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,$=await Ic(e,{actor_id:o||void 0,name:r||void 0,role:za.value,idempotencyKey:v,portrait:ja.value.trim()||void 0,background:Oa.value.trim()||void 0,hp:d,max_hp:m,alive:d>0,stats:Object.keys(u).length>0?u:void 0}),x=typeof $.actor_id=="string"?$.actor_id.trim():"";if(!x)throw new Error("생성 응답에 actor_id가 없습니다.");const S=Ea.value.trim();S&&await Rc(e,x,S),ze.value=x,ae.value=x,o||(fs.value=""),gs.value="ok",D(`Actor 생성 완료: ${x}`,"success"),await qt()}catch(v){gs.value="error",D(v instanceof Error?v.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Da.value}
            onInput=${o=>{Da.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${za.value}
            onChange=${o=>{za.value=o.target.value}}
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
            value=${Ea.value}
            onInput=${o=>{Ea.value=o.target.value}}
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
              value=${fs.value}
              onInput=${o=>{fs.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${ja.value}
              onInput=${o=>{ja.value=o.target.value}}
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
              value=${wn.value}
              onInput=${o=>{wn.value=o.target.value}}
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
              onInput=${o=>{const r=o.target.value;Fa.value=r,Y_(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Oa.value}
              onInput=${o=>{Oa.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${qa.value}
              onInput=${o=>{qa.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function df({state:t,nowMs:e}){var v;const n=Jt.value||((v=t.session)==null?void 0:v.room)||"",s=t.join_gate,a=Ma.value,o=de(a)?a:null,r=(t.party??[]).filter($=>$.role!=="dm"),l=ae.value.trim(),p=r.some($=>$.id===l),m=p?l:l?"__manual__":"",d=async()=>{const $=ae.value.trim(),x=_s.value.trim();if(!n||!$){D("Room/Actor가 필요합니다.","warning");return}kt.value="checking";try{const S=await Nc(n,$,x||void 0);Ma.value=S,kt.value="ok",D("참가 가능 여부를 갱신했습니다.","success")}catch(S){kt.value="error";const T=S instanceof Error?S.message:"참가 가능 여부 확인에 실패했습니다.";D(T,"error")}},u=async()=>{var N,I;const $=ae.value.trim(),x=_s.value.trim(),S=La.value.trim();if(!n||!$||!x){D("Room/Actor/Keeper가 필요합니다.","warning");return}if(!Ts(e))return;const T=((N=t.current_round)==null?void 0:N.phase)??((I=t.session)==null?void 0:I.status)??"unknown";if(gi("Mid-Join 승인 요청",n,T)){kt.value="requesting";try{const A=await Pc({room_id:n,actor_id:$,keeper_name:x,role:Pa.value,...S?{name:S}:{}});Ma.value=A;const L=de(A)?Gn(A,"granted",!1):!1,M=de(A)?yt(A,"reason_code",""):"";L?D("Mid-Join이 승인되었습니다.","success"):D(`Mid-Join이 거절되었습니다${M?`: ${M}`:""}`,"warning"),kt.value=L?"ok":"error",qt()}catch(A){kt.value="error";const L=A instanceof Error?A.message:"Mid-Join 요청에 실패했습니다.";D(L,"error")}finally{aa()}}};return i`
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
            onChange=${$=>{const x=$.target.value;if(x==="__manual__"){(p||!l)&&(ae.value="");return}ae.value=x}}
          >
            <option value="">Actor 선택</option>
            ${r.map($=>i`
              <option value=${$.id}>${$.name} (${$.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${m==="__manual__"?i`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${ae.value}
                onInput=${$=>{ae.value=$.target.value}}
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
            value=${_s.value}
            onInput=${$=>{_s.value=$.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Pa.value}
            onChange=${$=>{Pa.value=$.target.value}}
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
            value=${La.value}
            onInput=${$=>{La.value=$.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${d} disabled=${kt.value==="checking"||kt.value==="requesting"}>
              ${kt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${u} disabled=${kt.value==="checking"||kt.value==="requesting"}>
              ${kt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Gn(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Lt(o,"effective_score",0)}/${Lt(o,"required_points",0)}</span>
            ${yt(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${yt(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function ll({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function cl({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function dl(){const t=_i.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=de(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(de).slice(-8),o=t.canon_check,r=de(o)?o:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(M=>typeof M=="string").slice(0,3):[],p=r&&Array.isArray(r.violations)?r.violations.filter(M=>typeof M=="string").slice(0,3):[],m=n?Gn(n,"advanced",!1):!1,d=n?yt(n,"progress_reason",""):"",u=n?yt(n,"progress_detail",""):"",v=n?Lt(n,"player_successes",0):0,$=n?Lt(n,"player_required_successes",0):0,x=n?Gn(n,"dm_success",!1):!1,S=n?Lt(n,"timeouts",0):0,T=n?Lt(n,"unavailable",0):0,N=n?Lt(n,"reprompts",0):0,I=n?Lt(n,"npc_attacks",0):0,A=n?Lt(n,"keeper_timeout_sec",0):0,L=n?Lt(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${m?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${m?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${x?"DM ok":"DM stalled"} / players ${v}/${$}
          </span>
        </div>
        ${d?i`<div style="margin-top:4px; font-size:12px;">${d}</div>`:null}
        ${u?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${u}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${N}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${I}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${A||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${L}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(M=>{const Y=yt(M,"status","unknown"),J=yt(M,"actor_id","-"),f=yt(M,"role","-"),K=yt(M,"reason",""),tt=yt(M,"action_type",""),B=yt(M,"reply","");return i`
                <div class="trpg-round-item ${Y.includes("fallback")||Y.includes("timeout")?"failed":"active"}">
                  <span>${J} (${f})</span>
                  <span style="margin-left:auto; font-size:11px;">${Y}</span>
                  ${tt?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${tt}</div>`:null}
                  ${K?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${K}</div>`:null}
                  ${B?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${B.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${yt(r,"status","unknown")}</strong>
            </div>
            ${p.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${p.map(M=>i`<div>violation: ${M}</div>`)}
                </div>`:null}
            ${l.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${l.map(M=>i`<div>warning: ${M}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function uf({state:t,nowMs:e}){var r,l,p;const n=Jt.value||((r=t.session)==null?void 0:r.room)||"",s=((l=t.current_round)==null?void 0:l.phase)??((p=t.session)==null?void 0:p.status)??"unknown",a=sl(e),o=Z_(e);return i`
    <${P} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="lab.trpg">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${o}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>tf(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{aa(),D("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function pf({active:t}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>X_(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function mf({state:t}){const e=t.party??[],n=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${P} title="관전 가이드" semanticId="lab.trpg">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${P} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${ol} events=${n.slice(-20)} />
        <//>

        ${t.map?i`
            <${P} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${af} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${P} title="현재 라운드" semanticId="lab.trpg">
          <${cl} state=${t} />
        <//>

        <${P} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${ll} state=${t} />
        <//>

        <${P} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>i`<${il} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?i`
            <${P} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${rl} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function vf({state:t}){const e=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${P} title=${`이벤트 타임라인 (${e.length})`}>
          <${of} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${P} title="최근 라운드 결과" semanticId="lab.trpg">
          <${dl} />
        <//>

        <${P} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${cl} state=${t} />
        <//>
      </div>
    </div>
  `}function _f({state:t,nowMs:e}){const n=t.party??[];return i`
    <div>
      <${uf} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${P} title="조작 패널" semanticId="lab.trpg">
            <${lf} state=${t} nowMs=${e} />
          <//>

          <${P} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${cf} state=${t} />
          <//>

          <${P} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${df} state=${t} nowMs=${e} />
          <//>

          <${P} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${dl} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${P} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${ll} state=${t} />
          <//>

          <${P} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${il} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?i`
              <${P} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${rl} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function ff(){var l,p,m,d,u;const t=Jo.value,e=ai.value;if(lt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const v=window.setInterval(()=>{wo.value=Date.now()},1e3);return()=>{window.clearInterval(v)}},[]),e&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>qt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,o=nl.value,r=wo.value;return i`
    <div>
      <${St} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Jt.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((p=t.current_round)==null?void 0:p.phase)??((m=t.session)==null?void 0:m.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>qt()}>새로고침</button>
      </div>

      <${rf} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((d=t.session)==null?void 0:d.status)??"active"}</div>
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

      <${pf} active=${o} />

      ${o==="overview"?i`<${mf} state=${t} />`:o==="timeline"?i`<${vf} state=${t} />`:i`<${_f} state=${t} nowMs=${r} />`}
    </div>
  `}function gf(){return i`
    <div>
      <${St} surfaceId="lab" />
      <${P} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${P} title="TRPG" class="section" semanticId="lab.trpg">
        <${ff} />
      <//>
    </div>
  `}const ia=_(new Set(["broadcast","tasks","keepers","system"]));function $f(t){const e=new Set(ia.value);e.has(t)?e.delete(t):e.add(t),ia.value=e}const Ui=_(null);function ul(t){Ui.value=t}function hf(t){return t.kind==="board"?"broadcast":t.kind==="tasks"?"tasks":t.kind==="keepers"?"keepers":"system"}const yf=Tt(()=>{const t=ia.value;return Rs.value.filter(e=>t.has(hf(e)))}),bf=12e4,kf=Tt(()=>{const t=Si.value,e=Date.now();return It.value.map(n=>{const s=n.name.trim().toLowerCase(),a=t.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const r=a==null?void 0:a.lastActivityAt;r?o=e-new Date(r).getTime()>bf?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),xf=Tt(()=>{const t=Si.value;return It.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle").map(e=>{const n=e.name.trim().toLowerCase(),s=t.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:e.name,emoji:e.emoji??"",koreanName:e.koreanName??null,currentTask:e.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((e,n)=>{const s={hot:0,normal:1,calm:2};return s[e.pressure]-s[n.pressure]})});function To(t){return t.kind==="board"?"live-event-broadcast":t.kind==="tasks"?"live-event-task":t.kind==="keepers"?"live-event-keeper":"live-event-system"}function Sf(t){const e=t.eventType;return e==="broadcast"?"broadcast":e==="agent_joined"?"joined":e==="agent_left"?"left":e==="task_update"?"task":e==="board_post"?"post":e==="board_comment"?"comment":e==="keeper_heartbeat"?"heartbeat":e==="keeper_handoff"?"handoff":e==="keeper_compaction"?"compact":e==="keeper_guardrail"?"guardrail":t.kind==="board"?"board":t.kind==="tasks"?"task":t.kind==="keepers"?"keeper":"system"}function Af(t){switch(t){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function Cf(){const t=kf.value,e=Ui.value;return t.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${t.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${Af(n.state)} ${e===n.name?"pulse-selected":""}"
          onClick=${()=>ul(e===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const wf=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function Tf(){const t=ia.value;return i`
    <div class="activity-filter-bar">
      ${wf.map(e=>i`
        <button
          key=${e.kind}
          class="activity-filter-btn ${e.cssClass} ${t.has(e.kind)?"active":""}"
          onClick=${()=>$f(e.kind)}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function If(){const t=yf.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${t.length} events</span>
      </div>
      <${Tf} />
      <div class="activity-stream-list">
        ${t.length===0?i`<div class="activity-empty">No events matching filters</div>`:t.map((e,n)=>i`
            <div
              key=${`${e.timestamp}-${n}`}
              class="activity-item ${To(e)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${To(e)}">${Sf(e)}</span>
                <span class="activity-agent">${e.agent}</span>
                <span class="activity-time">${ar(e.timestamp)}</span>
              </div>
              <div class="activity-item-text">${e.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function Rf(t){switch(t){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function Nf(t){switch(t){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function Pf(){const t=xf.value,e=Ui.value;return i`
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
              onClick=${()=>ul(e===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?i`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${Rf(n.pressure)}">
                  ${Nf(n.pressure)}
                  ${n.assignedCount>0?i` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?i`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?i`<span class="focus-activity-text">${n.lastActivityText}</span>`:i`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?i`<${ot} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function Lf(){const t=ue.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>Live Monitor</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${t?"connected":"disconnected"}"></span>
            ${t?"Connected":"Offline"}
          </span>
          <span class="live-stat">${It.value.length} agents</span>
          <span class="live-stat">${oa.value} events</span>
        </div>
      </div>

      <${Cf} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${If} />
        </div>
        <div class="live-panel-side">
          <${Pf} />
        </div>
      </div>
    </div>
  `}const Io=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],$i=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"live",label:"Live",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}];function Mf(){const t=ue.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${oa.value} events</span>
    </div>
  `}function Df({currentTab:t,currentSectionLabel:e}){const n=ue.value;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>Snapshot</h3>
        <${E} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${n?"ok":"bad"}">${n?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agents</span>
          <strong>${It.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keepers</span>
          <strong>${Zt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Tasks</span>
          <strong>${Ot.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Events</span>
          <strong>${oa.value}</strong>
        </div>
      </div>
      <div class="rail-snapshot-copy">
        <span>Connection ${n?"healthy":"recovering"}</span>
        <span>${e} workspace active</span>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Vn(),tr(),t==="command"&&(oe(),re(),(G.value==="swarm"||G.value==="warroom")&&Et(),G.value==="warroom"&&ct()),t==="mission"&&(xs(),Pn()),t==="execution"&&Gt(),t==="intervene"&&(ct(),Qt()),t==="memory"&&Ft(),t==="planning"&&Nn(),t==="lab"&&qt()}}
        >
          Refresh Now
        </button>
        <button class="rail-secondary-btn" onClick=${()=>$t("intervene")}>
          Open Intervene
        </button>
      </div>
    </section>
  `}function zf(){const t=Kt.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${E} panelId="side_rail.quick_actions" compact=${!0} />
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
          onClick=${()=>{ct(),Qt()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>$t("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function Ef(){const t=F.value.tab,e=$i.find(s=>s.id===t),n=Io.find(s=>s.id===(e==null?void 0:e.group));return i`
    <aside class="dashboard-rail">
      <${St} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          <${E} panelId="side_rail.navigate" compact=${!0} />
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${Io.map(s=>i`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${$i.filter(a=>a.group===s.id).map(a=>i`
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

      <${Df} currentTab=${t} currentSectionLabel=${(n==null?void 0:n.label)??"Observe"} />
      <${zf} />
    </aside>
  `}function jf(){switch(F.value.tab){case"mission":return i`<${lo} />`;case"execution":return i`<${$_} />`;case"live":return i`<${Lf} />`;case"memory":return i`<${r_} />`;case"governance":return i`<${F_} />`;case"planning":return i`<${P_} />`;case"intervene":return i`<${Jv} />`;case"command":return i`<${Nv} />`;case"lab":return i`<${gf} />`;default:return i`<${lo} />`}}function Of(){lt(()=>{xl(),Eo(),er(),Gt(),tr(),xs();const n=Pd();return Ld(),()=>{Nl(),n(),Md()}},[]),lt(()=>{const n=setInterval(()=>{const s=F.value.tab;s==="command"?(oe(),re(),(G.value==="swarm"||G.value==="warroom")&&Et(),G.value==="warroom"&&ct()):s==="mission"?xs():s==="execution"?Gt():s==="intervene"?(ct(),Qt()):s==="memory"?Ft():s==="planning"?Nn():s==="lab"&&qt()},15e3);return()=>{clearInterval(n)}},[]),lt(()=>{const n=F.value.tab;n==="command"&&(oe(),re(),(G.value==="swarm"||G.value==="warroom")&&Et(),G.value==="warroom"&&ct()),n==="mission"&&(xs(),Pn()),n==="execution"&&Gt(),n==="intervene"&&(ct(),Qt()),n==="memory"&&Ft(),n==="planning"&&Nn(),n==="lab"&&qt()},[F.value.tab]);const t=F.value.tab,e=$i.find(n=>n.id===t);return i`
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
          <${Mf} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${Ef} />
        <main class="dashboard-main">
          ${si.value&&!ue.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${jf} />`}
        </main>
      </div>

      <${Wu} />
      <${du} />
      <${su} />
    </div>
  `}const Ro=document.getElementById("app");Ro&&$l(i`<${Of} />`,Ro);export{xm as _};
