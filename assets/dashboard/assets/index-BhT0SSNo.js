var ml=Object.defineProperty;var vl=(t,e,n)=>e in t?ml(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Re=(t,e,n)=>vl(t,typeof e!="symbol"?e+"":e,n);import{e as _l,_ as fl,c as _,b as Rt,y as rt,d as ki,A as gl,G as $l}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const r of o.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=_l.bind(fl);const hl=["mission","execution","live","memory","governance","planning","intervene","command","lab"],Lo={tab:"mission",params:{},postId:null};function Wi(t){return!!t&&hl.includes(t)}function Ja(t){try{return decodeURIComponent(t)}catch{return t}}function Va(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function yl(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Mo(t,e){if(t[0]==="chains"){const o={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(o.operation=Ja(t[2])),{tab:"command",params:o,postId:null}}if(t[0]==="lab"){const o={...e};return t[1]&&(o.surface=Ja(t[1])),{tab:"lab",params:o,postId:null}}const n=t[0],s=e.tab;return{tab:Wi(n)?n:Wi(s)?s:"mission",params:e,postId:null}}function ws(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Lo;const n=Ja(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=Va(a),r=yl(s);return Mo(r,o)}function bl(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Lo,params:Va(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Va(e.replace(/^\?/,""));return Mo(s,a)}function Do(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const O=_(ws(window.location.hash));window.addEventListener("hashchange",()=>{O.value=ws(window.location.hash)});function $t(t,e){const n={tab:t,params:e??{}};window.location.hash=Do(n)}function kl(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function xl(){if(window.location.hash&&window.location.hash!=="#"){O.value=ws(window.location.hash);return}const t=bl(window.location.pathname,window.location.search);if(t){O.value=t;const e=Do(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",O.value=ws(window.location.hash)}const Bi="masc_dashboard_sse_session_id",Sl=1e3,Al=15e3,ue=_(!1),aa=_(0),Eo=_(null),Ts=_([]);function Cl(){let t=sessionStorage.getItem(Bi);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Bi,t)),t}const wl=200;function Tl(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};Ts.value=[a,...Ts.value].slice(0,wl)}function Ya(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Gi(t,e){const n=Ya(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function Tt(t,e,n,s,a={}){Tl(t,e,n,{eventType:s,...a})}let Et=null,qe=null,Xa=0;function zo(){qe&&(clearTimeout(qe),qe=null)}function Il(){if(qe)return;Xa++;const t=Math.min(Xa,5),e=Math.min(Al,Sl*Math.pow(2,t));qe=setTimeout(()=>{qe=null,jo()},e)}function jo(){zo(),Et&&(Et.close(),Et=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Cl());const a=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(a);Et=o,o.onopen=()=>{Et===o&&(Xa=0,ue.value=!0)},o.onerror=()=>{Et===o&&(ue.value=!1,o.close(),Et=null,Il())},o.onmessage=r=>{try{const c=JSON.parse(r.data);aa.value++,Eo.value=c,Nl(c)}catch{}}}function Nl(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":Tt(n,"Joined","system","agent_joined");break;case"agent_left":Tt(n,"Left","system","agent_left");break;case"broadcast":Tt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Tt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Tt(n,Gi("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Ya(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":Tt(n,Gi("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Ya(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":Tt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Tt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Tt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Tt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Tt(n,e,"system","unknown")}}function Rl(){zo(),Et&&(Et.close(),Et=null),ue.value=!1}function Oo(){return new URLSearchParams(window.location.search)}function Fo(){const t=Oo(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function qo(){return{...Fo(),"Content-Type":"application/json"}}const Pl=15e3,xi=3e4,Ll=6e4,Ji=new Set([408,425,429,500,502,503,504]);class Bn extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);Re(this,"method");Re(this,"path");Re(this,"status");Re(this,"statusText");Re(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function Si(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Bn({method:r,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function Ml(){var e,n;const t=Oo();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function ot(t){const e=await Si(t,{headers:Fo()},Pl);if(!e.ok)throw new Bn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Dl(t){return new Promise(e=>setTimeout(e,t))}function El(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function zl(t){if(t instanceof Bn)return t.timeout||typeof t.status=="number"&&Ji.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=El(t.message);return e!==null&&Ji.has(e)}async function Ko(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!zl(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${o}ms`,a),await Dl(o),s+=1}}async function Bt(t,e,n,s=xi){const a=await Si(t,{method:"POST",headers:{...qo(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Bn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function jl(t,e,n,s=xi){const a=await Si(t,{method:"POST",headers:{...qo(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Bn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function Ol(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Fl(t){var e,n,s,a,o,r,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((c=(r=(o=t.result)==null?void 0:o.content)==null?void 0:r[0])==null?void 0:c.text)??""}async function ve(t,e){const n=await jl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Ll),s=Ol(n);return Fl(s)}function ql(){return ot("/api/v1/dashboard/shell")}function Kl(){return ot("/api/v1/dashboard/execution")}function Ul(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),ot(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function Hl(){return ot("/api/v1/dashboard/governance")}function Wl(){return ot("/api/v1/dashboard/semantics")}function Bl(){return ot("/api/v1/dashboard/mission")}function Gl(t=!1){return ot(`/api/v1/dashboard/mission/briefing${t?"?force=1":""}`)}function Jl(){return ot("/api/v1/dashboard/planning")}function Vl(){return ot("/api/v1/operator")}function Uo(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return ot(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Yl(){return ot("/api/v1/command-plane")}function Xl(){return ot("/api/v1/command-plane/summary")}function Ql(){return ot("/api/v1/chains/summary")}function Zl(t){return ot(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function tc(){return ot("/api/v1/command-plane/help")}function ec(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return ot(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function nc(t,e){return Bt(t,e)}function sc(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return xi}}function ia(t){return Bt("/api/v1/operator/action",t,void 0,sc(t))}function ac(t,e){return Bt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function vn(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function ic(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function oc(t){if(!H(t))return null;const e=h(t.id,"").trim(),n=h(t.author,"").trim(),s=h(t.content,"").trim();if(!e||!n)return null;const a=V(t.score,0),o=V(t.votes_up,0),r=V(t.votes_down,0),c=V(t.votes,a||o-r),d=V(t.comment_count,V(t.reply_count,0)),m=(()=>{const k=t.flair;if(typeof k=="string"&&k.trim())return k.trim();if(H(k)){const R=h(k.name,"").trim();if(R)return R}return h(t.flair_name,"").trim()||void 0})(),u=h(t.created_at_iso,"").trim()||vn(t.created_at),p=h(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?vn(t.updated_at):u),$=h(t.title,"").trim()||ic(s),x=Array.isArray(t.tags)?t.tags.filter(k=>typeof k=="string"&&k.trim()!==""):[];return{id:e,author:n,post_kind:(()=>{const k=h(t.post_kind,"").trim().toLowerCase();return k==="automation"||k==="system"||k==="human"?k:void 0})(),title:$,content:s,tags:x,votes:c,vote_balance:a,comment_count:d,created_at:u,updated_at:p,flair:m,hearth:h(t.hearth,"").trim()||null,visibility:h(t.visibility,"").trim()||void 0,expires_at:h(t.expires_at_iso,"").trim()||(t.expires_at!==void 0&&t.expires_at!==0?vn(t.expires_at):"")||null,hearth_count:V(t.hearth_count,0)}}function rc(t){if(!H(t))return null;const e=h(t.id,"").trim(),n=h(t.post_id,"").trim(),s=h(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:h(t.content,""),created_at:vn(t.created_at)}}async function lc(t){return Ko("fetchBoardPost",async()=>{const e=await ot(`/api/v1/board/${t}?format=flat`),n=H(e.post)?e.post:e,s=oc(n)??{id:t,author:"unknown",post_kind:"human",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},o=(Array.isArray(e.comments)?e.comments:[]).map(rc).filter(r=>r!==null);return{...s,comments:o}})}function Ho(t,e){return Bt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Ml()})}function cc(t,e,n){return Bt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function dc(t){const e=h(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function pt(...t){for(const e of t){const n=h(e,"");if(n.trim())return n.trim()}return""}function Vi(t){const e=dc(pt(t.outcome,t.result,t.result_code));if(!e)return;const n=pt(t.reason,t.reason_code,t.description,t.detail),s=pt(t.summary,t.summary_ko,t.summary_en,t.note),a=pt(t.details,t.details_text,t.text,t.note),o=pt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=pt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=pt(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const p=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof p=="string"?[p]:Array.isArray(p)?p.map(v=>{if(typeof v=="string")return v.trim();if(H(v)){const $=h(v.summary,"").trim();if($)return $;const x=h(v.text,"").trim();if(x)return x;const k=h(v.type,"").trim();return k||h(v.event_id,"").trim()}return""}).filter(v=>v.length>0):[]})(),m=(()=>{const p=V(t.turn,Number.NaN);if(Number.isFinite(p))return p;const v=V(t.turn_number,Number.NaN);if(Number.isFinite(v))return v;const $=V(t.current_turn,Number.NaN);if(Number.isFinite($))return $;const x=V(t.round,Number.NaN);return Number.isFinite(x)?x:void 0})(),u=pt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:c||void 0,turn:m,phase:u||void 0}}function uc(t,e){const n=H(t.state)?t.state:{};if(h(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>H(r)?h(r.type,"")==="session.outcome":!1),o=H(n.session_outcome)?n.session_outcome:{};if(H(o)&&Object.keys(o).length>0){const r=Vi(o);if(r)return r}if(H(a))return Vi(H(a.payload)?a.payload:{})}function H(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function V(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function pc(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Qa(t,e=!1){return typeof t=="boolean"?t:e}function rn(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(H(e)){const n=h(e.name,"").trim(),s=h(e.id,"").trim(),a=h(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function mc(t){const e={};if(!H(t)&&!Array.isArray(t))return e;if(H(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),o=h(s,"").trim();!a||!o||(e[a]=o)}),e;for(const n of t){if(!H(n))continue;const s=pt(n.to,n.target,n.actor_id,n.name,n.id),a=pt(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function vc(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function kt(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const _c=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function fc(t){const e=H(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const o=s.trim();o&&(_c.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function gc(t,e){if(t!=="dice.rolled")return;const n=V(e.raw_d20,0),s=V(e.total,0),a=V(e.bonus,0),o=h(e.action,"roll"),r=V(e.dc,0);return{notation:r>0?`${o} (DC ${r})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function $c(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function hc(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function yc(t,e,n,s){const a=n||e||h(s.actor_id,"")||h(s.actor_name,"");switch(t){case"turn.action.proposed":{const o=h(s.proposed_action,h(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=h(s.reply,h(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return h(s.reply,h(s.content,h(s.text,"Narration")));case"dice.rolled":{const o=h(s.action,"roll"),r=V(s.total,0),c=V(s.dc,0),d=h(s.label,""),m=a||"actor",u=c>0?` vs DC ${c}`:"",p=d?` (${d})`:"";return`${m} ${o}: ${r}${u}${p}`}case"turn.started":return`Turn ${V(s.turn,1)} started`;case"phase.changed":return`Phase: ${h(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(s.name,H(s.actor)?h(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${h(s.keeper_name,h(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${h(s.keeper_name,h(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${V(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${V(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||h(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||h(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${h(s.reason_code,"unknown")}`;case"memory.signal":{const o=H(s.entity_refs)?s.entity_refs:{},r=h(o.requested_tier,""),c=h(o.effective_tier,""),d=Qa(o.guardrail_applied,!1),m=h(s.summary_en,h(s.summary_ko,"Memory signal"));if(!r&&!c)return m;const u=r&&c?`${r}->${c}`:c||r;return`${m} [${u}${d?" (guardrail)":""}]`}case"world.event":{if(h(s.event_type,"")==="canon.check"){const r=h(s.status,"unknown"),c=h(s.contract_id,"n/a");return`Canon ${r}: ${c}`}return h(s.description,h(s.summary,"World event"))}case"combat.attack":return h(s.summary,h(s.result,"Attack resolved"));case"combat.defense":return h(s.summary,h(s.result,"Defense resolved"));case"session.outcome":return h(s.summary,h(s.outcome,"Session ended"));default:{const o=$c(s);return o?`${t}: ${o}`:t}}}function bc(t,e){const n=H(t)?t:{},s=h(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=h(n.actor_name,"").trim()||e[a]||h(H(n.payload)?n.payload.actor_name:"",""),r=H(n.payload)?n.payload:{},c=h(n.ts,h(n.timestamp,new Date().toISOString())),d=h(n.phase,h(r.phase,"")),m=h(n.category,"");return{type:s,actor:o||a||h(r.actor_name,""),actor_id:a||h(r.actor_id,""),actor_name:o,seq:n.seq,room_id:h(n.room_id,""),phase:d||void 0,category:m||hc(s),visibility:h(n.visibility,h(r.visibility,"public")),event_id:h(n.event_id,""),content:yc(s,a,o,r),dice_roll:gc(s,r),timestamp:c}}function kc(t,e,n){var F,tt;const s=h(t.room_id,"")||n||"default",a=H(t.state)?t.state:{},o=H(a.party)?a.party:{},r=H(a.actor_control)?a.actor_control:{},c=H(a.join_gate)?a.join_gate:{},d=H(a.contribution_ledger)?a.contribution_ledger:{},m=Object.entries(o).map(([B,et])=>{const b=H(et)?et:{},Pt=kt(b,"max_hp",void 0,10),ee=kt(b,"hp",void 0,Pt),ge=kt(b,"max_mp",void 0,0),$e=kt(b,"mp",void 0,0),j=kt(b,"level",void 0,1),Lt=kt(b,"xp",void 0,0),he=Qa(b.alive,ee>0),an=r[B],on=typeof an=="string"?an:void 0,ts=vc(b.role,B,on),es=pc(b.generation),ns=pt(b.joined_at,b.joinedAt,b.started_at,b.startedAt),ss=pt(b.claimed_at,b.claimedAt,b.assigned_at,b.assignedAt,b.assigned_time),U=pt(b.last_seen,b.lastSeen,b.last_seen_at,b.lastSeenAt,b.last_active,b.lastActive),Ne=pt(b.scene,b.current_scene,b.currentScene,b.world_scene,b.scene_name,b.sceneName),pl=pt(b.location,b.current_location,b.currentLocation,b.position,b.zone,b.area);return{id:B,name:h(b.name,B),role:ts,keeper:on,archetype:h(b.archetype,""),persona:h(b.persona,""),portrait:h(b.portrait,"")||void 0,background:h(b.background,"")||void 0,traits:rn(b.traits),skills:rn(b.skills),stats_raw:fc(b),status:he?"active":"dead",generation:es,joined_at:ns||void 0,claimed_at:ss||void 0,last_seen:U||void 0,scene:Ne||void 0,location:pl||void 0,inventory:rn(b.inventory),notes:rn(b.notes),relationships:mc(b.relationships),stats:{hp:ee,max_hp:Pt,mp:$e,max_mp:ge,level:j,xp:Lt,strength:kt(b,"strength","str",10),dexterity:kt(b,"dexterity","dex",10),constitution:kt(b,"constitution","con",10),intelligence:kt(b,"intelligence","int",10),wisdom:kt(b,"wisdom","wis",10),charisma:kt(b,"charisma","cha",10)}}}),u=m.filter(B=>B.status!=="dead"),p=uc(t,e),v={phase_open:Qa(c.phase_open,!0),min_points:V(c.min_points,3),window:h(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},$=Object.entries(d).map(([B,et])=>{const b=H(et)?et:{};return{actor_id:B,score:V(b.score,0),last_reason:h(b.last_reason,"")||null,reasons:rn(b.reasons)}}),x=m.reduce((B,et)=>(B[et.id]=et.name,B),{}),k=e.map(B=>bc(B,x)),C=V(a.turn,1),R=h(a.phase,"round"),w=h(a.map,""),E=H(a.world)?a.world:{},P=w||h(E.ascii_map,h(E.map,"")),L=k.filter((B,et)=>{const b=e[et];if(!H(b))return!1;const Pt=H(b.payload)?b.payload:{};return V(Pt.turn,-1)===C}),Y=(L.length>0?L:k).slice(-12),J=h(a.status,"active");return{session:{id:s,room:s,status:J==="ended"?"ended":J==="paused"?"paused":"active",round:C,actors:u,created_at:((F=k[0])==null?void 0:F.timestamp)??new Date().toISOString()},current_round:{round_number:C,phase:R,events:Y,timestamp:((tt=k[k.length-1])==null?void 0:tt.timestamp)??new Date().toISOString()},map:P||void 0,join_gate:v,contribution_ledger:$,outcome:p,party:u,story_log:k,history:[]}}async function xc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await ot(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Sc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([ot(`/api/v1/trpg/state${e}`),xc(t)]);return kc(n,s,t)}function Ac(t){return Bt("/api/v1/trpg/rounds/run",{room_id:t})}function Cc(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function wc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Bt("/api/v1/trpg/dice/roll",e)}function Tc(t,e){const n=Cc();return Bt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function Ic(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Bt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function Nc(t,e,n){return Bt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Rc(t,e,n){const s=await ve("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Pc(t){const e=await ve("trpg.mid_join.request",t);return JSON.parse(e)}async function Lc(t,e){await ve("masc_broadcast",{agent_name:t,message:e})}async function Mc(t=40){return(await ve("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Dc(t,e=20){return ve("masc_task_history",{task_id:t,limit:e})}async function Ec(t){const e=await ve("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function zc(t){return Ko("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await ot(`/api/v1/council/debates/${e}/summary`);if(!H(n))return null;const s=h(n.id,"").trim();return s?{id:s,topic:h(n.topic,""),status:h(n.status,"open"),support_count:V(n.support_count,0),oppose_count:V(n.oppose_count,0),neutral_count:V(n.neutral_count,0),total_arguments:V(n.total_arguments,0),created_at:vn(n.created_at_iso??n.created_at),summary_text:h(n.summary_text,"")}:null})}function jc(t,e,n){return ve("masc_keeper_msg",{name:t,message:e})}const Oc=_(""),Yt=_({}),vt=_({}),Za=_({}),ti=_({}),ei=_({}),ni=_({}),Xt=_({});function ut(t,e,n){t.value={...t.value,[e]:n}}function Zt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function X(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function Nt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ee(t){return typeof t=="boolean"?t:void 0}function si(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function ai(t){return Array.isArray(t)?t.map(e=>X(e)).filter(e=>!!e):[]}function Fc(t){var n;const e=(n=X(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function qc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function $a(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!Zt(s))continue;const a=X(s.name);if(!a)continue;const o=X(s[e]);e==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function Kc(t){if(!Zt(t))return null;const e=X(t.name);return e?{name:e,trigger:X(t.trigger),outcome:X(t.outcome),summary:X(t.summary),reason:X(t.reason)}:null}function Uc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Hc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Wo(t,e,n){return X(t)??Hc(e,n)}function Bo(t,e){return typeof t=="boolean"?t:e==="recover"}function Is(t){if(!Zt(t))return null;const e=X(t.health_state),n=X(t.next_action_path),s=X(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:X(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:si(t.last_reply_at),last_reply_preview:X(t.last_reply_preview)??null,last_error:X(t.last_error)??null,next_eligible_at_s:Nt(t.next_eligible_at_s)??null,recoverable:Bo(t.recoverable,n),summary:Wo(t.summary,e,X(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Go(t){return Zt(t)?{hour:Nt(t.hour),checked:Nt(t.checked)??0,acted:Nt(t.acted)??0,acted_names:ai(t.acted_names),activity_report:X(t.activity_report),quiet_hours_overridden:Ee(t.quiet_hours_overridden),skipped_reason:X(t.skipped_reason),acted_rows:$a(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:$a(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:$a(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Kc).filter(e=>e!==null):[]}:null}function Wc(t){return Zt(t)?{enabled:Ee(t.enabled)??!1,interval_s:Nt(t.interval_s)??0,quiet_start:Nt(t.quiet_start),quiet_end:Nt(t.quiet_end),quiet_active:Ee(t.quiet_active),use_planner:Ee(t.use_planner),delegate_llm:Ee(t.delegate_llm),agent_count:Nt(t.agent_count),agents:ai(t.agents),last_tick_ago_s:Nt(t.last_tick_ago_s)??null,last_tick_ago:X(t.last_tick_ago),total_ticks:Nt(t.total_ticks),total_checkins:Nt(t.total_checkins),last_skip_reason:X(t.last_skip_reason)??null,last_tick_result:Go(t.last_tick_result),active_self_heartbeats:ai(t.active_self_heartbeats)}:null}function Bc(t){return Zt(t)?{status:t.status,diagnostic:Is(t.diagnostic)}:null}function Gc(t){return Zt(t)?{recovered:Ee(t.recovered)??!1,skipped_reason:X(t.skipped_reason)??null,before:Is(t.before),after:Is(t.after),down:t.down,up:t.up}:null}function Jc(t,e){var w,E;if(!(t!=null&&t.name))return null;const n=X((w=t.agent)==null?void 0:w.status)??X(t.status)??"unknown",s=X((E=t.agent)==null?void 0:E.error)??null,a=t.presence_keepalive??!0,o=t.keepalive_running??!1,r=t.turn_count??0,c=t.last_turn_ago_s??null,d=t.proactive_enabled??!1,m=t.proactive_cooldown_sec??0,u=t.last_proactive_ago_s??null,p=d&&u!=null?Math.max(0,m-u):null,v=r<=0||c==null?"never":c>900?"stale":"fresh",$=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,x=s??(a&&!o?"keeper keepalive is not running":null),k=n==="offline"||n==="inactive"?"offline":x?"degraded":v==="stale"?"stale":v==="never"?"idle":"healthy",C=x?Uc(x):e!=null&&e.quiet_active&&v!=="fresh"?"quiet_hours":a&&!o?"disabled":r<=0?"never_started":p!=null&&p>0?"min_gap":v==="fresh"||v==="stale"?"no_recent_activity":"unknown",R=k==="offline"||k==="degraded"||k==="stale"?"recover":C==="quiet_hours"?"manual_lodge_poke":C==="unknown"?"probe":"direct_message";return{health_state:k,quiet_reason:C,next_action_path:R,last_reply_status:v,last_reply_at:$,last_reply_preview:null,last_error:x,next_eligible_at_s:p!=null&&p>0?p:null,recoverable:Bo(void 0,R),summary:Wo(void 0,k,C),keepalive_running:o}}function Vc(t,e){if(!Zt(t))return null;const n=Fc(t.role),s=X(t.content)??X(t.preview);if(!s)return null;const a=si(t.ts_unix)??si(t.timestamp);return{id:`${n}-${a??"entry"}-${e}`,role:n,label:qc(n),text:s,timestamp:a,delivery:"history"}}function Yc(t,e,n){const s=Zt(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,r)=>Vc(o,r)).filter(o=>o!==null):[];return{name:t,diagnostic:Is(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function Yi(t,e){const n=vt.value[t]??[];vt.value={...vt.value,[t]:[...n,e].slice(-50)}}function Xc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Qc(t,e){const s=(vt.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(o=>Xc(a,o)));vt.value={...vt.value,[t]:[...e,...s].slice(-50)}}function oa(t,e){Yt.value={...Yt.value,[t]:e},Qc(t,e.history)}function Xi(t,e){const n=Yt.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};oa(t,{...n,diagnostic:{...s,...e}})}async function Ai(){try{await Gn()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Zc(t){Oc.value=t.trim()}async function Jo(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Yt.value[n])return Yt.value[n];ut(Za,n,!0),ut(Xt,n,null);try{const s=await ve("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=Yc(n,s,a);return oa(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return ut(Xt,n,a),null}finally{ut(Za,n,!1)}}async function td(t,e){const n=t.trim(),s=e.trim();if(!n||!s)return;const a=`local-${Date.now()}`;Yi(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),ut(ti,n,!0),ut(Xt,n,null);try{const o=await jc(n,s);vt.value={...vt.value,[n]:(vt.value[n]??[]).map(r=>r.id===a?{...r,delivery:"delivered"}:r)},Yi(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Xi(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await Ai()}catch(o){const r=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw vt.value={...vt.value,[n]:(vt.value[n]??[]).map(c=>c.id===a?{...c,delivery:"error",error:r}:c)},Xi(n,{last_reply_status:"error",last_error:r}),ut(Xt,n,r),o}finally{ut(ti,n,!1)}}async function ed(t,e){const n=t.trim();if(!n)return null;ut(ei,n,!0),ut(Xt,n,null);try{const s=await ia({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=Bc(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const r=Yt.value[n];oa(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??vt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Ai(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw ut(Xt,n,a),s}finally{ut(ei,n,!1)}}async function nd(t,e){const n=t.trim();if(!n)return null;ut(ni,n,!0),ut(Xt,n,null);try{const s=await ia({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Gc(s.result),o=(a==null?void 0:a.after)??null;if(o){const r=Yt.value[n];oa(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??vt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Ai(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw ut(Xt,n,a),s}finally{ut(ni,n,!1)}}function ye(t){return(t??"").trim().toLowerCase()}function ht(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function gs(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function as(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function ln(t){return t.last_heartbeat??as(t.last_turn_ago_s)??as(t.last_proactive_ago_s)??as(t.last_handoff_ago_s)??as(t.last_compaction_ago_s)}function sd(t){const e=t.title.trim();return e||gs(t.content)}function ad(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function id(t,e,n,s,a={}){var E;const o=ye(t),r=e.filter(P=>ye(P.assignee)===o&&(P.status==="claimed"||P.status==="in_progress")).length,c=n.filter(P=>ye(P.from)===o).sort((P,L)=>ht(L.timestamp)-ht(P.timestamp))[0],d=s.filter(P=>ye(P.agent)===o||ye(P.author)===o).sort((P,L)=>ht(L.timestamp)-ht(P.timestamp))[0],m=(a.boardPosts??[]).filter(P=>ye(P.author)===o).sort((P,L)=>ht(L.updated_at||L.created_at)-ht(P.updated_at||P.created_at))[0],u=(a.keepers??[]).filter(P=>ye(P.name)===o&&ln(P)!==null).sort((P,L)=>ht(ln(L)??0)-ht(ln(P)??0))[0],p=c?ht(c.timestamp):0,v=d?ht(d.timestamp):0,$=m?ht(m.updated_at||m.created_at):0,x=u?ht(ln(u)??0):0,k=a.lastSeen?ht(a.lastSeen):0,C=((E=a.currentTask)==null?void 0:E.trim())||(r>0?`${r} claimed tasks`:null);if(p===0&&v===0&&$===0&&x===0&&k===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:C};const w=[c?{timestamp:c.timestamp,ts:p,text:gs(c.content)}:null,m?{timestamp:m.updated_at||m.created_at,ts:$,text:`Post: ${gs(sd(m))}`}:null,u?{timestamp:ln(u),ts:x,text:ad(u)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:v,text:gs(d.text)}:null].filter(P=>P!==null).sort((P,L)=>L.ts-P.ts)[0];return w&&w.ts>=k?{activeAssignedCount:r,lastActivityAt:w.timestamp,lastActivityText:w.text}:{activeAssignedCount:r,lastActivityAt:a.lastSeen??null,lastActivityText:C??"Presence heartbeat"}}const wt=_([]),qt=_([]),Xe=_([]),te=_([]),At=_(null),od=_(null),ii=_(new Map),An=_([]),Cn=_("recent"),ze=_(!0),Vo=_(null),Vt=_(""),Ke=_([]),_n=_(!1),Yo=_(new Map),Ci=_("unknown"),Ue=_(null),oi=_(!1),wn=_(!1),ri=_(!1),fn=_(!1),wi=_(null),Ns=_(!1),Rs=_(null),Xo=_(null),li=_(null),rd=_(null),ld=_(null),cd=_(null);Rt(()=>wt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const Qo=Rt(()=>{const t=qt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),ra=Rt(()=>{const t=new Map,e=qt.value,n=Xe.value,s=Ts.value,a=An.value,o=te.value;for(const r of wt.value)t.set(r.name.trim().toLowerCase(),id(r.name,e,n,s,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:a,keepers:o}));return t});function dd(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const ud=Rt(()=>{const t=new Map;for(const e of te.value)t.set(e.name,dd(e));return t}),pd=12e4;function md(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}const vd=Rt(()=>{const t=Date.now(),e=new Set,n=ii.value;for(const s of te.value){const a=md(s,n);a!=null&&t-a>pd&&e.add(s.name)}return e});let ha=null;function _d(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function dt(t){return typeof t=="object"&&t!==null}function y(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function T(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function zt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function ci(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Zo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function fd(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function gd(t){if(!dt(t))return null;const e=y(t.name);return e?{name:e,agent_type:y(t.agent_type),status:Zo(t.status),current_task:y(t.current_task)??null,joined_at:y(t.joined_at),last_seen:y(t.last_seen),capabilities:zt(t.capabilities),emoji:y(t.emoji),koreanName:y(t.koreanName)??y(t.korean_name),model:y(t.model),traits:zt(t.traits),interests:zt(t.interests),activityLevel:T(t.activityLevel)??T(t.activity_level),primaryValue:y(t.primaryValue)??y(t.primary_value)}:null}function $d(t){if(!dt(t))return null;const e=y(t.id),n=y(t.title);return!e||!n?null:{id:e,title:n,status:fd(t.status),priority:T(t.priority),assignee:y(t.assignee),description:y(t.description),created_at:y(t.created_at),updated_at:y(t.updated_at)}}function hd(t){if(!dt(t))return null;const e=y(t.from)??y(t.from_agent)??"system",n=y(t.content)??"",s=y(t.timestamp)??new Date().toISOString();return{id:y(t.id),seq:T(t.seq),from:e,content:n,timestamp:s,type:y(t.type)}}function Qi(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function yd(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>Qi(s)-Qi(a)).slice(-500)}function bd(t){return Array.isArray(t)?t.map(e=>{if(!dt(e))return null;const n=T(e.ts_unix);if(n==null)return null;const s=dt(e.handoff)?e.handoff:null;return{ts:n,context_ratio:T(e.context_ratio)??0,context_tokens:T(e.context_tokens)??0,context_max:T(e.context_max)??0,latency_ms:T(e.latency_ms)??0,generation:T(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:T(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:T(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?T(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Zi(t){if(!dt(t))return null;const e=y(t.health_state),n=y(t.next_action_path),s=y(t.last_reply_status);if(!e||!n||!s)return null;const a=y(t.quiet_reason)??null,o=y(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:ci(t.last_reply_at)??y(t.last_reply_at)??null,last_reply_preview:y(t.last_reply_preview)??null,last_error:y(t.last_error)??null,next_eligible_at_s:T(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function kd(t,e){return(Array.isArray(t)?t:dt(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!dt(s))return null;const a=dt(s.agent)?s.agent:null,o=dt(s.context)?s.context:null,r=dt(s.metrics_window)?s.metrics_window:void 0,c=y(s.name);if(!c)return null;const d=T(s.context_ratio)??T(o==null?void 0:o.context_ratio),m=y(s.status)??y(a==null?void 0:a.status)??"offline",u=Zo(m),p=y(s.model)??y(s.active_model)??y(s.primary_model),v=zt(s.skill_secondary),$=o?{source:y(o.source),context_ratio:T(o.context_ratio),context_tokens:T(o.context_tokens),context_max:T(o.context_max),message_count:T(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,x=a?{name:y(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:y(a.error),agent_type:y(a.agent_type),status:y(a.status),current_task:y(a.current_task)??null,joined_at:y(a.joined_at),last_seen:y(a.last_seen),last_seen_ago_s:T(a.last_seen_ago_s),capabilities:zt(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,k=bd(s.metrics_series),C={name:c,emoji:y(s.emoji),koreanName:y(s.koreanName)??y(s.korean_name),agent_name:y(s.agent_name),trace_id:y(s.trace_id),model:p,primary_model:y(s.primary_model),active_model:y(s.active_model),next_model_hint:y(s.next_model_hint)??null,status:u,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:T(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:T(s.proactive_idle_sec),proactive_cooldown_sec:T(s.proactive_cooldown_sec),last_heartbeat:y(s.last_heartbeat)??y(a==null?void 0:a.last_seen),generation:T(s.generation),turn_count:T(s.turn_count)??T(s.total_turns),keeper_age_s:T(s.keeper_age_s),last_turn_ago_s:T(s.last_turn_ago_s),last_handoff_ago_s:T(s.last_handoff_ago_s),last_compaction_ago_s:T(s.last_compaction_ago_s),last_proactive_ago_s:T(s.last_proactive_ago_s),last_proactive_preview:y(s.last_proactive_preview)??null,context_ratio:d,context_tokens:T(s.context_tokens)??T(o==null?void 0:o.context_tokens),context_max:T(s.context_max)??T(o==null?void 0:o.context_max),context_source:y(s.context_source)??y(o==null?void 0:o.source),context:$,traits:zt(s.traits),interests:zt(s.interests),primaryValue:y(s.primaryValue)??y(s.primary_value),activityLevel:T(s.activityLevel)??T(s.activity_level),memory_recent_note:y(s.memory_recent_note)??null,recent_input_preview:y(s.recent_input_preview)??null,recent_output_preview:y(s.recent_output_preview)??null,recent_tool_names:zt(s.recent_tool_names)??[],conversation_tail_count:T(s.conversation_tail_count),k2k_count:T(s.k2k_count),handoff_count_total:T(s.handoff_count_total)??T(s.trace_history_count),compaction_count:T(s.compaction_count),last_compaction_saved_tokens:T(s.last_compaction_saved_tokens),diagnostic:Zi(s.diagnostic),skill_primary:y(s.skill_primary)??null,skill_secondary:v,skill_reason:y(s.skill_reason)??null,metrics_series:k.length>0?k:void 0,metrics_window:r,agent:x};return C.diagnostic=Zi(s.diagnostic)??Jc(C,(e==null?void 0:e.lodge)??null),C}).filter(s=>s!==null)}function tr(t){return dt(t)?{...t,lodge:Wc(t.lodge)??void 0}:null}function xd(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function Sd(t){if(!dt(t))return null;const e=T(t.iteration);if(e==null)return null;const n=T(t.metric_before)??0,s=T(t.metric_after)??n,a=dt(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:T(t.delta)??s-n,changes:y(t.changes)??"",failed_attempts:y(t.failed_attempts)??"",next_suggestion:y(t.next_suggestion)??"",elapsed_ms:T(t.elapsed_ms)??0,cost_usd:T(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:y(a.worker_model)??"",tool_call_count:T(a.tool_call_count)??0,tool_names:zt(a.tool_names)??[],session_id:y(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function Ad(t){var o,r;if(!dt(t))return null;const e=y(t.loop_id);if(!e)return null;const n=T(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(Sd).filter(c=>c!==null):[],a=T(t.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:y(t.profile)??"unknown",status:xd(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:y(t.error_message)??y(t.error_reason)??null,stop_reason:y(t.stop_reason)??y(t.reason)??null,current_iteration:T(t.current_iteration)??((r=s[0])==null?void 0:r.iteration)??0,max_iterations:T(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:y(t.target)??"",stagnation_streak:T(t.stagnation_streak)??0,stagnation_limit:T(t.stagnation_limit)??0,elapsed_seconds:T(t.elapsed_seconds)??0,updated_at:ci(t.updated_at)??null,stopped_at:ci(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:y(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:T(t.latest_tool_call_count)??0,latest_tool_names:zt(t.latest_tool_names)??[],session_id:y(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function Gn(){oi.value=!0;try{await Promise.all([nr(),Jt()]),Xo.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{oi.value=!1}}async function er(){Ns.value=!0,Rs.value=null;try{const t=await Wl();wi.value=t,cd.value=new Date().toISOString()}catch(t){Rs.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{Ns.value=!1}}function Cd(t){var e;return((e=wi.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function wd(t){var n;const e=((n=wi.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(o=>o.id===t);if(a)return a}return null}function Td(t){var s,a;Ke.value=(Array.isArray(t.goals)?t.goals:[]).map(o=>{if(!dt(o))return null;const r=y(o.id),c=y(o.title),d=y(o.horizon),m=y(o.status),u=y(o.created_at),p=y(o.updated_at);return!r||!c||!d||!m||!u||!p?null:{id:r,horizon:d,title:c,metric:y(o.metric)??null,target_value:y(o.target_value)??null,due_date:y(o.due_date)??null,priority:T(o.priority)??3,status:m,parent_goal_id:y(o.parent_goal_id)??null,last_review_note:y(o.last_review_note)??null,last_review_at:y(o.last_review_at)??null,created_at:u,updated_at:p}}).filter(o=>o!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const o of n){const r=Ad(o);r&&e.set(r.loop_id,r)}Yo.value=e,Ue.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,Ci.value=Ue.value?"error":e.size===0?"idle":"ready"}async function nr(){try{const t=await ql(),e=tr(t.status);e&&(At.value=e)}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Jt(){var t;try{const e=await Kl(),n=tr(e.status),s=(t=At.value)==null?void 0:t.room;n&&(At.value=n);const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;wt.value=(Array.isArray(e.agents)?e.agents:[]).map(gd).filter(r=>r!==null),qt.value=(Array.isArray(e.tasks)?e.tasks:[]).map($d).filter(r=>r!==null);const o=(Array.isArray(e.messages)?e.messages:[]).map(hd).filter(r=>r!==null);Xe.value=a?o:yd(Xe.value,o),te.value=kd(e.keepers,n??At.value),od.value=null,Xo.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function Kt(){wn.value=!0;try{const t=await Ul(Cn.value,{excludeSystem:ze.value});An.value=t.posts??[],li.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{wn.value=!1}}async function Ut(){var t;ri.value=!0;try{const e=Vt.value||((t=At.value)==null?void 0:t.room)||"default";Vt.value||(Vt.value=e);const n=await Sc(e);Vo.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{ri.value=!1}}async function Tn(){_n.value=!0,fn.value=!0;try{const t=await Jl();Td(t),rd.value=new Date().toISOString(),ld.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),Ci.value="error",Ue.value=t instanceof Error?t.message:String(t)}finally{_n.value=!1,fn.value=!1}}async function sr(){return Tn()}let $s=null;function Id(t){$s=t}let hs=null;function Nd(t){hs=t}let ys=null;function Rd(t){ys=t}const Se={};function be(t,e,n=500){Se[t]&&clearTimeout(Se[t]),Se[t]=setTimeout(()=>{e(),delete Se[t]},n)}function Pd(){const t=Eo.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(ii.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),ii.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&be("execution",Jt),_d(e.type)&&(ha||(ha=setTimeout(()=>{Gn(),hs==null||hs(),ys==null||ys(),ha=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&be("execution",Jt),e.type==="broadcast"&&be("execution",Jt),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&be("execution",Jt),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&be("board",Kt),e.type.startsWith("decision_")&&be("council",()=>$s==null?void 0:$s()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&be("mdal",sr,350)}});return()=>{t();for(const e of Object.keys(Se))clearTimeout(Se[e]),delete Se[e]}}let gn=null;function Ld(){gn||(gn=setInterval(()=>{ue.value,Gn()},1e4))}function Md(){gn&&(clearInterval(gn),gn=null)}function Dd({metric:t}){return i`
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
  `}function Ed({panel:t}){return i`
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
  `}function z({panelId:t,compact:e=!1,label:n="Why"}){const s=wd(t);return s?i`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${Ed} panel=${s} />
    </details>
  `:Ns.value?i`<span class="semantic-inline-state">Loading semantics…</span>`:null}function Ct({surfaceId:t,compact:e=!1}){const n=Cd(t);return n?i`
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
  `:Ns.value?i`<div class="semantic-surface-card ${e?"compact":""}">Loading semantics…</div>`:Rs.value?i`<div class="semantic-surface-card ${e?"compact":""}">${Rs.value}</div>`:null}function N({title:t,class:e,semanticId:n,children:s}){return i`
    <div class="card ${e??""}">
      ${t?i`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?i`<${z} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${s}
    </div>
  `}function zd(t){const e=t.indexOf("-");if(e<0)return{model:t,nickname:t,isKeeper:t==="keeper"};const n=t.slice(0,e),s=t.slice(e+1);return{model:n,nickname:s,isKeeper:n==="keeper"}}function jd(t){return t==="keeper"||t.startsWith("keeper-")}const la=_(null),di=_(!1),Ps=_(null),ar=_(null),je=_(!1),xe=_(null);let He=null;function to(){He!==null&&(window.clearTimeout(He),He=null)}function Od(t=1500){He===null&&(He=window.setTimeout(()=>{He=null,In(!1)},t))}function q(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function I(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function K(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function We(t){return typeof t=="boolean"?t:void 0}function St(t,e=[]){if(Array.isArray(t))return t;if(!q(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function ca(t){if(!q(t))return null;const e=I(t.kind),n=I(t.summary),s=I(t.target_type);return!e||!n||!s?null:{kind:e,severity:I(t.severity)??"warn",summary:n,target_type:s,target_id:I(t.target_id)??null,actor:I(t.actor)??null,evidence:t.evidence}}function da(t){if(!q(t))return null;const e=I(t.action_type),n=I(t.target_type),s=I(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:I(t.target_id)??null,severity:I(t.severity)??"warn",reason:s,confirm_required:We(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Fd(t){if(!q(t))return null;const e=I(t.session_id);return e?{session_id:e,goal:I(t.goal),status:I(t.status),health:I(t.health),scale_profile:I(t.scale_profile),control_profile:I(t.control_profile),planned_worker_count:K(t.planned_worker_count),active_agent_count:K(t.active_agent_count),last_turn_age_sec:K(t.last_turn_age_sec)??null,attention_count:K(t.attention_count),recommended_action_count:K(t.recommended_action_count),top_attention:ca(t.top_attention),top_recommendation:da(t.top_recommendation)}:null}function qd(t){if(!q(t))return null;const e=I(t.session_id);if(!e)return null;const n=q(t.status)?t.status:t,s=q(n.summary)?n.summary:void 0;return{session_id:e,status:I(t.status)??I(s==null?void 0:s.status)??(q(n.session)?I(n.session.status):void 0),progress_pct:K(t.progress_pct)??K(s==null?void 0:s.progress_pct),elapsed_sec:K(t.elapsed_sec)??K(s==null?void 0:s.elapsed_sec),remaining_sec:K(t.remaining_sec)??K(s==null?void 0:s.remaining_sec),done_delta_total:K(t.done_delta_total)??K(s==null?void 0:s.done_delta_total),summary:q(t.summary)?t.summary:s,team_health:q(t.team_health)?t.team_health:q(n.team_health)?n.team_health:void 0,communication_metrics:q(t.communication_metrics)?t.communication_metrics:q(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:q(t.orchestration_state)?t.orchestration_state:q(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:q(t.cascade_metrics)?t.cascade_metrics:q(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:q(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,o])=>{const r=I(o);return r?[a,r]:null}).filter(a=>a!==null)):q(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const r=I(o);return r?[a,r]:null}).filter(a=>a!==null)):void 0,session:q(t.session)?t.session:q(n.session)?n.session:void 0,recent_events:St(t.recent_events,["events"]).filter(q)}}function Kd(t){if(!q(t))return null;const e=I(t.name);return e?{name:e,agent_name:I(t.agent_name),status:I(t.status),autonomy_level:I(t.autonomy_level),context_ratio:K(t.context_ratio),generation:K(t.generation),active_goal_ids:St(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:I(t.last_autonomous_action_at)??null,last_turn_ago_s:K(t.last_turn_ago_s),model:I(t.model)}:null}function Ud(t){if(!q(t))return null;const e=I(t.confirm_token)??I(t.token);return e?{confirm_token:e,actor:I(t.actor),action_type:I(t.action_type),target_type:I(t.target_type),target_id:I(t.target_id)??null,delegated_tool:I(t.delegated_tool),created_at:I(t.created_at),preview:t.preview}:null}function Hd(t){if(!q(t))return null;const e=I(t.action_type),n=I(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:I(t.description),confirm_required:We(t.confirm_required)}}function Wd(t){const e=q(t)?t:{};return{room_health:I(e.room_health),cluster:I(e.cluster),project:I(e.project),current_room:I(e.current_room)??null,paused:We(e.paused),tempo_interval_s:K(e.tempo_interval_s),active_agents:K(e.active_agents),keeper_pressure:K(e.keeper_pressure),active_operations:K(e.active_operations),pending_approvals:K(e.pending_approvals),incident_count:K(e.incident_count),recommended_action_count:K(e.recommended_action_count),top_attention:ca(e.top_attention),top_action:da(e.top_action)}}function Bd(t){const e=q(t)?t:{},n=q(e.swarm_overview)?e.swarm_overview:{};return{health:I(e.health),active_operations:K(e.active_operations),pending_approvals:K(e.pending_approvals),swarm_overview:{active_lanes:K(n.active_lanes),moving_lanes:K(n.moving_lanes),stalled_lanes:K(n.stalled_lanes),projected_lanes:K(n.projected_lanes),last_movement_at:I(n.last_movement_at)??null},top_attention:ca(e.top_attention),top_action:da(e.top_action),session_cards:St(e.session_cards).map(Fd).filter(s=>s!==null)}}function Gd(t){const e=q(t)?t:{};return{sessions:St(e.sessions,["items"]).map(qd).filter(n=>n!==null),keepers:St(e.keepers,["items"]).map(Kd).filter(n=>n!==null),pending_confirms:St(e.pending_confirms).map(Ud).filter(n=>n!==null),available_actions:St(e.available_actions).map(Hd).filter(n=>n!==null)}}function Jd(t){const e=q(t)?t:{};return{generated_at:I(e.generated_at),summary:Wd(e.summary),incidents:St(e.incidents).map(ca).filter(n=>n!==null),recommended_actions:St(e.recommended_actions).map(da).filter(n=>n!==null),command_focus:Bd(e.command_focus),operator_targets:Gd(e.operator_targets)}}function Vd(t){if(!q(t))return null;const e=I(t.id),n=I(t.label),s=I(t.summary);if(!e||!n||!s)return null;const a=I(t.status)??"unclear";return{id:e,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,evidence:St(t.evidence).map(r=>typeof r=="string"?r.trim():"").filter(Boolean)}}function Yd(t){const e=q(t)?t:{},n=q(e.basis)?e.basis:{},s=I(e.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:I(e.generated_at),cached:We(e.cached),stale:We(e.stale),refreshing:We(e.refreshing),status:a,summary:I(e.summary)??null,model:I(e.model)??null,ttl_sec:K(e.ttl_sec),criteria:St(e.criteria).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),basis:{current_room:I(n.current_room)??null,crew_count:K(n.crew_count),agent_count:K(n.agent_count),keeper_count:K(n.keeper_count)},sections:St(e.sections).map(Vd).filter(o=>o!==null),error:I(e.error)??null,last_error:I(e.last_error)??null}}async function bs(){di.value=!0,Ps.value=null;try{const t=await Bl();la.value=Jd(t)}catch(t){Ps.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{di.value=!1}}async function In(t=!1){je.value=!0,xe.value=null;try{const e=await Gl(t),n=Yd(e);ar.value=n,n.refreshing||n.status==="pending"?Od():to()}catch(e){xe.value=e instanceof Error?e.message:"Failed to load mission briefing",to()}finally{je.value=!1}}function _e({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function ir(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const o=Math.floor(a/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function it({timestamp:t}){const e=ir(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return i`<span class="time-ago" title=${n}>${e}</span>`}let Xd=0;const Ae=_([]);function M(t,e="success",n=4e3){const s=++Xd;Ae.value=[...Ae.value,{id:s,message:t,type:e}],setTimeout(()=>{Ae.value=Ae.value.filter(a=>a.id!==s)},n)}function Qd(t){Ae.value=Ae.value.filter(e=>e.id!==t)}function Zd(){const t=Ae.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Qd(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const tu="masc_dashboard_agent_name",nn=_(null),Ls=_(!1),Nn=_(""),Ms=_([]),Rn=_([]),Be=_(""),$n=_(!1);function ua(t){nn.value=t,Ti()}function eo(){nn.value=null,Nn.value="",Ms.value=[],Rn.value=[],Be.value=""}function eu(){const t=nn.value;return t?wt.value.find(e=>e.name===t)??null:null}function or(t){return t?qt.value.filter(e=>e.assignee===t):[]}function rr(t){return t?te.value.find(e=>e.agent_name===t||e.name===t)??null:null}function nu(t){if(!t)return[];const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function su(t){const e=rr(t);return e?e.recent_tool_names&&e.recent_tool_names.length>0?e.recent_tool_names:[]:[]}async function Ti(){const t=nn.value;if(t){Ls.value=!0,Nn.value="",Ms.value=[],Rn.value=[];try{const e=await Mc(80);Ms.value=e.filter(a=>a.includes(t)).slice(0,20);const n=or(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await Dc(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const r=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));Rn.value=s}catch(e){Nn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Ls.value=!1}}}async function no(){var s;const t=nn.value,e=Be.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(tu))==null?void 0:s.trim())||"dashboard";$n.value=!0;try{await Lc(n,`@${t} ${e}`),Be.value="",M(`Mention sent to ${t}`,"success"),Ti()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";M(o,"error")}finally{$n.value=!1}}function au({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${_e} status=${t.status} />
    </div>
  `}function iu({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function ou(){var p,v,$,x,k,C,R;const t=nn.value;if(!t)return null;const e=eu(),n=rr(t),s=or(t),a=Ms.value,o=su(t),r=nu(n),c=(e==null?void 0:e.capabilities)??[],d=((p=At.value)==null?void 0:p.room)??"default",m=((v=At.value)==null?void 0:v.project)??"확인 없음",u=(($=At.value)==null?void 0:$.cluster)??"확인 없음";return i`
    <div
      class="agent-detail-overlay"
      onClick=${w=>{w.target.classList.contains("agent-detail-overlay")&&eo()}}
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
                        <${_e} status=${e.status} />
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
                ${(k=e==null?void 0:e.traits)==null?void 0:k.map(w=>i`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${w}</span>`)}
              </div>
            `:""}
            ${(((C=e==null?void 0:e.interests)==null?void 0:C.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(R=e==null?void 0:e.interests)==null?void 0:R.map(w=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${w}</span>`)}
              </div>
            `:""}
            ${c.length>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${c.map(w=>i`<span style="font-size:0.7rem;background:#183153;color:#7dd3fc;padding:2px 8px;border-radius:10px">${w}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?i`
                    ${e.current_task?i`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?i`<span>Last seen: <${it} timestamp=${e.last_seen} /></span>`:null}
                    <span>Room: ${d}</span>
                    <span>Project: ${m}</span>
                    <span>Cluster: ${u}</span>
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Ti()}} disabled=${Ls.value}>
              ${Ls.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${eo}>Close</button>
          </div>
        </div>

        ${Nn.value?i`<div class="council-error">${Nn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${N} title="Assigned Tasks">
            ${s.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${s.map(w=>i`<${au} key=${w.id} task=${w} />`)}</div>`}
          <//>

          <${N} title="Recent Activity">
            ${a.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${a.map((w,E)=>i`<div key=${E} class="agent-activity-line">${w}</div>`)}</div>`}
          <//>
        </div>

        <${N} title="Capabilities & Tools">
          <div style="display:flex; flex-direction:column; gap:12px;">
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Capabilities</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${c.length>0?c.map(w=>i`<span class="pill">${w}</span>`):i`<span class="empty-state" style="font-size:12px;">No capability metadata</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Recent tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${o.length>0?o.map(w=>i`<span class="pill">${w}</span>`):i`<span class="empty-state" style="font-size:12px;">No tool telemetry</span>`}
              </div>
            </div>
            ${o.length===0&&r.length>0?i`
                  <div>
                    <div style="font-size:12px; color:#888; margin-bottom:6px;">Window top tools</div>
                    <div style="display:flex; flex-wrap:wrap; gap:6px;">
                      ${r.map(w=>i`<span class="pill">${w}</span>`)}
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

        <${N} title="Task History">
          ${Rn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${Rn.value.map(w=>i`<${iu} key=${w.taskId} row=${w} />`)}</div>`}
        <//>

        <${N} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Be.value}
              onInput=${w=>{Be.value=w.target.value}}
              onKeyDown=${w=>{w.key==="Enter"&&no()}}
              disabled=${$n.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{no()}}
              disabled=${$n.value||Be.value.trim()===""}
            >
              ${$n.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const Ht=_(null),lr=_(null),Wt=_(null),Pn=_(!1),pe=_(null),Ln=_(!1),Qe=_(null),Q=_(!1),Ds=_([]);let ru=1;function W(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function S(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function at(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function pa(t){return typeof t=="boolean"?t:void 0}function lu(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function jt(t,e=[]){if(Array.isArray(t))return t;if(!W(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function cu(t){return W(t)?{id:S(t.id),seq:at(t.seq),from:S(t.from)??S(t.from_agent)??"system",content:S(t.content)??"",timestamp:S(t.timestamp)??new Date().toISOString(),type:S(t.type)}:null}function du(t){return W(t)?{room_id:S(t.room_id),current_room:S(t.current_room)??S(t.room),project:S(t.project),cluster:S(t.cluster),paused:pa(t.paused),pause_reason:S(t.pause_reason)??null,paused_by:S(t.paused_by)??null,paused_at:S(t.paused_at)??null}:{}}function so(t){if(!W(t))return;const e=Object.entries(t).map(([n,s])=>{const a=S(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function cr(t){if(!W(t))return null;const e=S(t.kind),n=S(t.summary),s=S(t.target_type);return!e||!n||!s?null:{kind:e,severity:S(t.severity)??"warn",summary:n,target_type:s,target_id:S(t.target_id)??null,actor:S(t.actor)??null,evidence:t.evidence}}function dr(t){if(!W(t))return null;const e=S(t.action_type),n=S(t.target_type),s=S(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:S(t.target_id)??null,severity:S(t.severity)??"warn",reason:s,confirm_required:pa(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function uu(t){return W(t)?{actor:S(t.actor)??null,spawn_agent:S(t.spawn_agent)??null,spawn_role:S(t.spawn_role)??null,spawn_model:S(t.spawn_model)??null,worker_class:S(t.worker_class)??null,parent_actor:S(t.parent_actor)??null,capsule_mode:S(t.capsule_mode)??null,runtime_pool:S(t.runtime_pool)??null,lane_id:S(t.lane_id)??null,controller_level:S(t.controller_level)??null,control_domain:S(t.control_domain)??null,supervisor_actor:S(t.supervisor_actor)??null,model_tier:S(t.model_tier)??null,task_profile:S(t.task_profile)??null,risk_level:S(t.risk_level)??null,routing_confidence:at(t.routing_confidence)??null,routing_reason:S(t.routing_reason)??null,status:S(t.status)??"unknown",turn_count:at(t.turn_count)??0,empty_note_turn_count:at(t.empty_note_turn_count)??0,has_turn:pa(t.has_turn)??!1,last_turn_ts_iso:S(t.last_turn_ts_iso)??null}:null}function pu(t){if(!W(t))return null;const e=S(t.session_id);return e?{session_id:e,goal:S(t.goal),status:S(t.status),health:S(t.health),scale_profile:S(t.scale_profile),control_profile:S(t.control_profile),planned_worker_count:at(t.planned_worker_count),active_agent_count:at(t.active_agent_count),last_turn_age_sec:at(t.last_turn_age_sec)??null,attention_count:at(t.attention_count),recommended_action_count:at(t.recommended_action_count),top_attention:cr(t.top_attention),top_recommendation:dr(t.top_recommendation)}:null}function ur(t){const e=W(t)?t:{};return{trace_id:S(e.trace_id),target_type:S(e.target_type)??"room",target_id:S(e.target_id)??null,health:S(e.health),swarm_status:W(e.swarm_status)?e.swarm_status:void 0,attention_items:jt(e.attention_items).map(cr).filter(n=>n!==null),recommended_actions:jt(e.recommended_actions).map(dr).filter(n=>n!==null),session_cards:jt(e.session_cards).map(pu).filter(n=>n!==null),worker_cards:jt(e.worker_cards).map(uu).filter(n=>n!==null)}}function mu(t){if(!W(t))return null;const e=W(t.status)?t.status:void 0,n=W(t.summary)?t.summary:W(e==null?void 0:e.summary)?e.summary:void 0,s=W(t.session)?t.session:W(e==null?void 0:e.session)?e.session:void 0,a=S(t.session_id)??S(n==null?void 0:n.session_id)??S(s==null?void 0:s.session_id);if(!a)return null;const o=so(t.report_paths)??so(e==null?void 0:e.report_paths),r=jt(t.recent_events,["events"]).filter(W);return{session_id:a,status:S(t.status)??S(n==null?void 0:n.status)??S(s==null?void 0:s.status),progress_pct:at(t.progress_pct)??at(n==null?void 0:n.progress_pct),elapsed_sec:at(t.elapsed_sec)??at(n==null?void 0:n.elapsed_sec),remaining_sec:at(t.remaining_sec)??at(n==null?void 0:n.remaining_sec),done_delta_total:at(t.done_delta_total)??at(n==null?void 0:n.done_delta_total),summary:n,team_health:W(t.team_health)?t.team_health:W(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:W(t.communication_metrics)?t.communication_metrics:W(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:W(t.orchestration_state)?t.orchestration_state:W(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:W(t.cascade_metrics)?t.cascade_metrics:W(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:s,recent_events:r}}function vu(t){if(!W(t))return null;const e=S(t.name);if(!e)return null;const n=W(t.context)?t.context:void 0;return{name:e,agent_name:S(t.agent_name),status:S(t.status),autonomy_level:S(t.autonomy_level),context_ratio:at(t.context_ratio)??at(n==null?void 0:n.context_ratio),generation:at(t.generation),active_goal_ids:lu(t.active_goal_ids),last_autonomous_action_at:S(t.last_autonomous_action_at)??null,last_turn_ago_s:at(t.last_turn_ago_s),model:S(t.model)??S(t.active_model)??S(t.primary_model)}}function _u(t){if(!W(t))return null;const e=S(t.confirm_token)??S(t.token);return e?{confirm_token:e,actor:S(t.actor),action_type:S(t.action_type),target_type:S(t.target_type),target_id:S(t.target_id)??null,delegated_tool:S(t.delegated_tool),created_at:S(t.created_at),preview:t.preview}:null}function fu(t){const e=W(t)?t:{};return{room:du(e.room),sessions:jt(e.sessions,["items","sessions"]).map(mu).filter(n=>n!==null),keepers:jt(e.keepers,["items","keepers"]).map(vu).filter(n=>n!==null),recent_messages:jt(e.recent_messages,["messages"]).map(cu).filter(n=>n!==null),pending_confirms:jt(e.pending_confirms,["items","confirms"]).map(_u).filter(n=>n!==null),available_actions:jt(e.available_actions,["actions"]).filter(W).map(n=>({action_type:S(n.action_type)??"unknown",target_type:S(n.target_type)??"unknown",description:S(n.description),confirm_required:pa(n.confirm_required)}))}}function is(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function ao(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Es(t){Ds.value=[{...t,id:ru++,at:new Date().toISOString()},...Ds.value].slice(0,20)}function pr(t){return t.confirm_required?is(t.preview)||"Confirmation required":is(t.result)||is(t.executed_action)||is(t.delegated_tool_result)||t.status}async function lt(){Pn.value=!0,pe.value=null;try{const t=await Vl();Ht.value=fu(t)}catch(t){pe.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Pn.value=!1}}async function Qt(){Ln.value=!0,Qe.value=null;try{const t=await Uo({targetType:"room"});lr.value=ur(t)}catch(t){Qe.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{Ln.value=!1}}async function Ze(t){if(!t){Wt.value=null;return}Ln.value=!0,Qe.value=null;try{const e=await Uo({targetType:"team_session",targetId:t,includeWorkers:!0});Wt.value=ur(e)}catch(e){Qe.value=e instanceof Error?e.message:"Failed to load session digest"}finally{Ln.value=!1}}async function gu(t){var e;Q.value=!0,pe.value=null;try{const n=await ia(t);return Es({actor:t.actor,action_type:t.action_type,target_label:ao(t),outcome:n.confirm_required?"preview":"executed",message:pr(n),delegated_tool:n.delegated_tool}),await lt(),await Qt(),(e=Wt.value)!=null&&e.target_id&&await Ze(Wt.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw pe.value=s,Es({actor:t.actor,action_type:t.action_type,target_label:ao(t),outcome:"error",message:s}),n}finally{Q.value=!1}}async function $u(t,e){var n;Q.value=!0,pe.value=null;try{const s=await ac(t,e);return Es({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:pr(s),delegated_tool:s.delegated_tool}),await lt(),await Qt(),(n=Wt.value)!=null&&n.target_id&&await Ze(Wt.value.target_id),s}catch(s){const a=s instanceof Error?s.message:"Operator confirmation failed";throw pe.value=a,Es({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),s}finally{Q.value=!1}}Rd(()=>{var t;lt(),Qt(),(t=Wt.value)!=null&&t.target_id&&Ze(Wt.value.target_id)});function hu(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function yu(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function bu(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function io(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function mr(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function ku(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function vr(t){if(!t)return null;const e=Yt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function xu({keeper:t,showRawStatus:e=!1}){if(rt(()=>{t!=null&&t.name&&Jo(t.name)},[t==null?void 0:t.name]),!t)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Yt.value[t.name],s=vr(t),a=Za.value[t.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${hu(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${yu((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?i` · ${mr(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?i` · next eligible ${ku(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Su({keeperName:t,placeholder:e}){const[n,s]=ki("");rt(()=>{t&&Jo(t)},[t]);const a=vt.value[t]??[],o=ti.value[t]??!1,r=Xt.value[t],c=async()=>{const d=n.trim();if(!(!t||!d)){s("");try{await td(t,d)}catch(m){const u=m instanceof Error?m.message:`Failed to message ${t}`;M(u,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(d=>i`
              <div class="keeper-conversation-item" key=${d.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${io(d)}`}>${d.label}</span>
                  <span class=${`keeper-role-chip ${io(d)}`}>${bu(d)}</span>
                  ${d.timestamp?i`<span class="keeper-conversation-time">${mr(d.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${d.text}</div>
                ${d.error?i`<div class="keeper-conversation-error">${d.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${e}
          value=${n}
          onInput=${d=>{s(d.target.value)}}
          disabled=${o||!t}
        ></textarea>
        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${()=>{c()}}
            disabled=${o||n.trim()===""||!t}
          >
            ${o?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${r?i`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function Au({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=vr(e),a=ei.value[e.name]??!1,o=ni.value[e.name]??!1,r=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??r==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{ed(e.name,t).catch(d=>{const m=d instanceof Error?d.message:`Failed to probe ${e.name}`;M(m,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{nd(e.name,t).catch(d=>{const m=d instanceof Error?d.message:`Failed to recover ${e.name}`;M(m,"error")})}}
        disabled=${o||!c||!t.trim()}
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
  `}const Ii=_(null);function Ni(t){Ii.value=t,Zc(t.name)}function oo(){Ii.value=null}const Me=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Cu(t){if(!t)return 0;const e=Me.findIndex(n=>n.level===t);return e>=0?e:0}function wu({keeper:t}){const e=Cu(t.autonomy_level),n=Me[e]??Me[0];if(!n)return null;const s=(e+1)/Me.length*100;return i`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${Me.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Me.map((a,o)=>i`
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
            <strong><${it} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?i`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function ks(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Tu(t){switch(t){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(t==null?void 0:t.trim())||"action"}}function Iu(t){return t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]}function Nu(t){const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Ru({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${ks(t.context_tokens)}</div>
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
  `}function Pu({keeper:t}){var u,p;const e=t.metrics_series??[];if(e.length<2){const v=(((u=t.context)==null?void 0:u.context_ratio)??0)*100,$=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${$}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=e.length,r=e.map((v,$)=>{const x=a+$/(o-1)*(n-2*a),k=s-a-(v.context_ratio??0)*(s-2*a);return{x,y:k,p:v}}),c=r.map(({x:v,y:$})=>`${v.toFixed(1)},${$.toFixed(1)}`).join(" "),d=(((p=e[e.length-1])==null?void 0:p.context_ratio)??0)*100,m=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:v})=>v.is_handoff).map(({x:v})=>i`
          <line x1="${v.toFixed(1)}" y1="${a}" x2="${v.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${m}" stroke-width="1.5"/>
        ${r.filter(({p:v})=>v.is_compaction).map(({x:v,y:$})=>i`
          <circle cx="${v.toFixed(1)}" cy="${$.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const ya=_("");function Lu({keeper:t}){var a,o,r,c;const e=ya.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${ya.value}
        onInput=${d=>{ya.value=d.target.value}}
      />
      ${s.map(d=>i`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${d.title}</span>
          <span class="keeper-field-key">${d.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${d.value}</span>
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
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${ks(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${ks(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${ks(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Mu({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
  `}function Du({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Eu({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function ro({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function ba(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function zu({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:ba(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:ba(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:ba(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(s=>i`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function ju({keeper:t}){var m,u,p,v,$,x,k;const e=((m=Ht.value)==null?void 0:m.room)??{},n=(((u=Ht.value)==null?void 0:u.available_actions)??[]).filter(C=>C.target_type==="keeper"||C.target_type==="room").slice(0,8),s=Iu(t),a=Nu(t),o=((p=t.agent)==null?void 0:p.capabilities)??[],r=e.current_room??e.room_id??((v=At.value)==null?void 0:v.room)??"default",c=e.project??(($=At.value)==null?void 0:$.project)??"확인 없음",d=e.cluster??((x=At.value)==null?void 0:x.cluster)??"확인 없음";return i`
    <div class="keeper-signal-list">
      <div class="keeper-signal-row">
        <span>Room</span>
        <strong>${r}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Project</span>
        <strong>${c}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Cluster</span>
        <strong>${d}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Current task</span>
        <strong>${((k=t.agent)==null?void 0:k.current_task)??"없음"}</strong>
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
          ${n.length>0?n.map(C=>i`<span class="pill">${Tu(C.action_type)}</span>`):i`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function _r(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function Ou(){try{const t=await ia({actor:_r(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Go(t.result);await Gn(),e!=null&&e.skipped_reason?M(e.skipped_reason,"warning"):M(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";M(e,"error")}}function Fu({keeper:t}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${xu} keeper=${t} />
          <${Au}
            actor=${_r()}
            keeper=${t}
            onPokeLodge=${()=>{Ou()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Su}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function qu(){var e,n,s;const t=Ii.value;return t?i`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&oo()}}
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
            <${_e} status=${t.status} />
            ${t.model?i`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>oo()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Ru} keeper=${t} />

        ${""}
        <${Pu} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${N} title="Field Dictionary">
            <${Lu} keeper=${t} />
          <//>

          ${""}
          <${N} title="Profile">
            <${ro} traits=${t.traits??[]} label="Traits" />
            <${ro} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${it} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?i`
              <${N} title="Autonomy">
                <${wu} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?i`
              <${N} title="TRPG Stats">
                <${Mu} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${N} title="Equipment (${t.inventory.length})">
                <${Du} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${N} title="Relationships (${Object.keys(t.relationships).length})">
                <${Eu} rels=${t.relationships} />
              <//>
            `:null}

          <${N} title="Runtime Signals">
            <${zu} keeper=${t} />
          <//>

          <${N} title="Neighborhood & Tools">
            <${ju} keeper=${t} />
          <//>

          <${N} title="Memory & Context">
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
        <${Fu} keeper=${t} />
      </div>
    </div>
  `:null}const zs="masc_dashboard_workflow_context",Ku=900*1e3;function Ri(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function It(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function ne(t){const e=It(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function fr(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function ui(t){return Ri(t)?t:null}function Uu(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function Hu(t){if(!t)return null;try{const e=JSON.parse(t);if(!Ri(e))return null;const n=It(e.id),s=It(e.source_surface),a=It(e.source_label),o=It(e.summary),r=It(e.created_at);return!n||s!=="mission"||!a||!o||!r?null:{id:n,source_surface:"mission",source_label:a,action_type:It(e.action_type),target_type:It(e.target_type),target_id:It(e.target_id),focus_kind:It(e.focus_kind),summary:o,payload_preview:It(e.payload_preview),suggested_payload:ui(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:r}}catch{return null}}function Pi(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=Ku}function Wu(){const t=fr(),e=Hu((t==null?void 0:t.getItem(zs))??null);return e?Pi(e)?e:(t==null||t.removeItem(zs),null):null}const gr=_(Wu());function Bu(t){const e=t&&Pi(t)?t:null;gr.value=e;const n=fr();if(!n)return;if(!e){n.removeItem(zs);return}const s=Uu(e);s&&n.setItem(zs,s)}function $r(t){if(!t)return null;const e=ui(t.suggested_payload);if(e)return e;if(Ri(t.preview)){const n=ui(t.preview.payload);if(n)return n}return null}function hr(t){if(!t)return null;const e=ne(t.message);if(e)return e;const n=ne(t.task_title)??ne(t.title),s=ne(t.task_description)??ne(t.description),a=ne(t.reason),o=ne(t.priority)??ne(t.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function yr(t,e,n,s,a,o){return["mission",t,e??"action",n??"target",s??"room",a??"focus",o].join(":")}function sn(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=$r(t),o=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,r=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,c=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,d=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:yr(n,(t==null?void 0:t.action_type)??null,o,r,c,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:o,target_id:r,focus_kind:c,summary:d,payload_preview:hr(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function Gu(t,e){return e.source==="mission"&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)}function Jn(t){const{params:e}=t;if(e.source!=="mission")return null;const n=gr.value;if(n&&Pi(n)&&Gu(n,e))return n;const s=new Date().toISOString();return{id:yr("상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,s),source_surface:"mission",source_label:"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,summary:e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function Ju(t){return{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function br(t){const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.target_type==="room"?"summary":"swarm"}function Vu(t){return{source:"mission",surface:br(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function Li(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function Mi(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";default:return(t==null?void 0:t.trim())||"추천 액션"}}function Yu(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}function bt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function mt(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function Mn(t){return typeof t=="number"&&Number.isFinite(t)?t:null}function ka(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function nt(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function _t(t){return t==="bad"||t==="offline"||t==="critical"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"?"warn":"ok"}function me(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:n<86400?`${Math.round(n/3600)}h 전`:`${Math.round(n/86400)}d 전`}function Xu(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:t<86400?`${Math.round(t/3600)}h`:`${Math.round(t/86400)}d`}function lo(t){const e=Mn(t.ts);if(e!=null)return e;const n=mt(t.ts_iso);if(!n)return 0;const s=Date.parse(n);return Number.isNaN(s)?0:s}function Qu(t){return[...new Set(t.filter(Boolean))]}function Zu(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function tp(t){return hr($r(t))}function ep(t){return Li(t?sn(t,null,"상황판 추천 액션"):null)}function ma(t,e=sn()){Bu(e),$t(t,t==="intervene"?Ju(e):Vu(e))}function np(t){ma("intervene",sn(null,t,"상황판 incident"))}function sp(t){ma("command",sn(null,t,"상황판 incident"))}function ap(t,e,n="상황판 추천 액션"){ma("intervene",sn(t,e,n))}function ip(t,e,n="상황판 추천 액션"){ma("command",sn(t,e,n))}function co(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),$t(t,n)}function kr(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>(s.from??"").trim().toLowerCase()===n).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function op(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>{if((s.from??"").trim().toLowerCase()===n)return!1;const o=(s.content??"").trim().toLowerCase();return o.includes(`@${n}`)||o.includes(n)}).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function rp(t){const e=bt(t.session)?t.session:{},n=bt(t.summary)?t.summary:{};return Qu([...ka(e.agent_names),...ka(n.active_agents),...ka(n.planned_participants)]).filter(s=>!jd(s))}function lp(t){const e=bt(t.session)?t.session:{};return mt(e.goal)??mt(e.session_id)??t.session_id}function cp(t){const e=bt(t.session)?t.session:{};return mt(e.room_id)}function dp(t){const e=bt(t.session)?t.session:{};return mt(e.created_at_iso)}function up(t){const e=bt(t.session)?t.session:{};return mt(e.updated_at_iso)}function pp(t){const e=bt(t.communication_metrics)?t.communication_metrics:{};return mt(e.mode)}function mp(t){const e=bt(t.communication_metrics)?t.communication_metrics:{};return Mn(e.broadcast_count)??0}function vp(t){const e=bt(t.communication_metrics)?t.communication_metrics:{};return Mn(e.portal_count)??0}function _p(t){const e=bt(t.team_health)?t.team_health:{};return{active:Mn(e.active_agents_count)??0,required:Mn(e.required_agents)??0}}function fp(t){const n=[...t.recent_events??[]].sort((u,p)=>lo(p)-lo(u))[0];if(!n)return{at:null,summary:"최근 session event가 없습니다."};const s=bt(n.detail)?n.detail:{},a=mt(n.event_type)??"event",o=mt(s.actor),r=mt(s.task_title)??mt(s.title),c=nt(mt(s.result),120),d=nt(mt(s.reason),120),m=r?`${o?`${o} · `:""}${r}`:c??d??a.replace(/_/g," ");return{at:mt(n.ts_iso),summary:m}}function gp(){const t=la.value;return t?t.operator_targets.sessions.map(e=>{var o,r;const n=_p(e),s=fp(e),a=t.command_focus.session_cards.find(c=>c.session_id===e.session_id);return{session:e,goal:lp(e),room:cp(e),status:e.status??"unknown",memberNames:rp(e),startedAt:dp(e),stoppedAt:up(e),elapsedSec:e.elapsed_sec??null,lastEventAt:s.at,lastEventSummary:s.summary,communicationMode:pp(e),broadcastCount:mp(e),portalCount:vp(e),activeCount:n.active,requiredCount:n.required,attentionSummary:((o=a==null?void 0:a.top_attention)==null?void 0:o.summary)??((r=a==null?void 0:a.top_recommendation)==null?void 0:r.reason)??null}}).sort((e,n)=>{const s=Date.parse(e.lastEventAt??e.startedAt??"")||0;return(Date.parse(n.lastEventAt??n.startedAt??"")||0)-s}):[]}function xr(t){if(t.recent_tool_names&&t.recent_tool_names.length>0)return t.recent_tool_names;const e=bt(t.metrics_window)?t.metrics_window:{};return(Array.isArray(e.top_tools)?e.top_tools:[]).map(s=>bt(s)?mt(s.tool):null).filter(s=>s!==null)}function $p(t){return te.value.find(e=>e.agent_name===t||e.name===t)??null}function Sr(t,e){const n=nt(t.current_task,100);if(!n)return"명시된 current task 없음";const s=e.find(o=>o.id===n);if(s)return`${s.id} · ${nt(s.title,92)}`;const a=e.find(o=>o.title===n);return a?`${a.id} · ${nt(a.title,92)}`:n}function hp(t){const e=new Map;for(const n of t)for(const s of n.memberNames)e.has(s)||e.set(s,n);return[...wt.value].map(n=>{var v,$;const s=e.get(n.name),a=$p(n.name),o=kr(n.name,Xe.value),r=op(n.name,Xe.value),c=ra.value.get(n.name.trim().toLowerCase()),d=s?s.memberNames.filter(x=>x!==n.name):[],m=s?`${s.goal}${s.room?` · ${s.room}`:""}`:((v=la.value)==null?void 0:v.summary.current_room)??"room",u=(a==null?void 0:a.skill_primary)??(n.capabilities&&n.capabilities.length>0?n.capabilities.slice(0,3).join(", "):null)??n.agent_type??null,p=Sr(n,qt.value);return{agent:n,where:m,withWhom:d,activeSince:(s==null?void 0:s.startedAt)??n.joined_at??n.last_seen??null,currentWork:p,how:u,recentInput:nt(r==null?void 0:r.content,120)??nt(a==null?void 0:a.recent_input_preview,120)??null,recentOutput:nt(o==null?void 0:o.content,120)??nt(a==null?void 0:a.recent_output_preview,120)??nt(($=a==null?void 0:a.diagnostic)==null?void 0:$.last_reply_preview,120)??null,recentEvent:nt(c==null?void 0:c.lastActivityText,120)??(s==null?void 0:s.lastEventSummary)??null,recentTools:a?xr(a):[]}}).sort((n,s)=>{const a=d=>d==="busy"?4:d==="active"?3:d==="listening"?2:d==="idle"?1:0,o=a(s.agent.status)-a(n.agent.status);if(o!==0)return o;const r=Date.parse(n.agent.last_seen??n.activeSince??"")||0;return(Date.parse(s.agent.last_seen??s.activeSince??"")||0)-r})}function yp(){return[...te.value].map(t=>{var e,n,s,a;return{keeper:t,activeSince:((e=t.agent)==null?void 0:e.joined_at)??t.created_at??t.last_heartbeat??null,currentWork:nt((n=t.agent)==null?void 0:n.current_task,110)??nt(t.skill_primary,110)??nt(t.last_proactive_reason,110)??"명시된 keeper focus 없음",recentInput:nt(t.recent_input_preview,120)??null,recentOutput:nt(t.recent_output_preview,120)??nt((s=t.diagnostic)==null?void 0:s.last_reply_preview,120)??nt(t.last_proactive_preview,120)??null,recentEvent:nt(t.last_proactive_reason,120)??nt((a=t.diagnostic)==null?void 0:a.summary,120)??null,recentTools:xr(t)}}).sort((t,e)=>{const n=Date.parse(t.keeper.last_heartbeat??t.activeSince??"")||0;return(Date.parse(e.keeper.last_heartbeat??e.activeSince??"")||0)-n})}function bp({cluster:t,project:e,room:n,generatedAt:s}){return i`
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
        <strong>${s?me(s):"fresh"}</strong>
      </div>
    </div>
  `}function Pe({label:t,value:e,detail:n,tone:s}){return i`
    <article class="mission-stat-card ${_t(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function kp(){const t=ar.value,e=_t((t==null?void 0:t.status)??(xe.value?"bad":"warn")),n=!t||t.sections.length===0,s=(t==null?void 0:t.status)==="error"||(t==null?void 0:t.status)==="unavailable"&&!(t!=null&&t.cached);return i`
    <${N} title="LLM 판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>heuristic 대신 별도 판단 계층</h3>
        <p>아래 해석은 LLM이 사실 스냅샷만 읽고 만든 요약입니다. raw thinking은 숨기고, 기준과 근거만 남깁니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${e}">
          ${(t==null?void 0:t.status)??(xe.value?"error":"loading")}
        </span>
        ${t!=null&&t.model?i`<span class="command-chip">${t.model}</span>`:null}
        ${t!=null&&t.generated_at?i`<span class="command-chip">${me(t.generated_at)}</span>`:null}
        ${t!=null&&t.cached?i`<span class="command-chip">cached</span>`:null}
        ${t!=null&&t.stale?i`<span class="command-chip warn">stale</span>`:null}
        ${t!=null&&t.refreshing?i`<span class="command-chip warn">refreshing</span>`:null}
      </div>

      ${xe.value?i`<div class="empty-state error">${xe.value}</div>`:null}
      ${t!=null&&t.error?i`<div class="empty-state error">${t.error}</div>`:null}
      ${t!=null&&t.summary?i`<div class="mission-inline-note">${t.summary}</div>`:null}
      ${t!=null&&t.last_error&&!t.error?i`<div class="mission-inline-note">최근 refresh 실패: ${t.last_error}</div>`:null}

      ${t&&t.sections.length>0?i`
            <div class="mission-briefing-grid">
              ${t.sections.map(a=>i`
                <article class="mission-briefing-section ${_t(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <span class="command-chip ${_t(a.status)}">${a.status}</span>
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
          `:!je.value&&!xe.value&&n?i`
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
        <button class="control-btn ghost" onClick=${()=>{In(s)}} disabled=${je.value}>
          ${je.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{In(!0)}} disabled=${je.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function xp({rows:t}){const[e,n]=ki(!1);return i`
    <div class="mission-stale-section">
      <button class="mission-stale-toggle" onClick=${()=>n(!e)}>
        ${e?"▾":"▸"} 종료/중단된 세션 (${t.length})
      </button>
      ${e?t.map(s=>i`<${Ar} key=${s.session.session_id} row=${s} />`):null}
    </div>
  `}function Ar({row:t}){const e=t.memberNames.slice(0,4).map(n=>{const s=wt.value.find(r=>r.name===n),a=kr(n,Xe.value),o=zd(n);return{name:n,model:o.model,nickname:o.nickname,currentTask:s?Sr(s,qt.value):"서버 재시작 후 상태 소실",output:nt(a==null?void 0:a.content,96)}});return i`
    <article class="mission-crew-card ${_t(t.status)}">
      <div class="mission-card-head">
        <div>
          <strong>${t.goal}</strong>
          <div class="mission-card-target">${t.session.session_id}${t.room?` · ${t.room}`:""}</div>
        </div>
        <span class="command-chip ${_t(t.status)}">${t.status}</span>
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
          <strong>${Xu(t.elapsedSec)}</strong>
          <small>${t.startedAt?`${me(t.startedAt)} 시작`:"시작 시각 없음"}</small>
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
        <small>${t.lastEventAt?me(t.lastEventAt):"시각 없음"}</small>
      </div>

      ${e.length>0?i`
            <div class="mission-member-stack">
              ${e.map(n=>i`
                <button class="mission-member-row" onClick=${()=>ua(n.name)}>
                  <strong>${n.model!==n.nickname?i`<span class="model-badge">${n.model}</span> `:""}${n.nickname}</strong>
                  <span>${n.currentTask}</span>
                  <small>${n.output??"최근 출력 없음"}</small>
                </button>
              `)}
            </div>
          `:null}

      ${t.attentionSummary?i`<div class="mission-inline-note">attention: ${t.attentionSummary}</div>`:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>co("intervene",t.session.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>co("command",t.session.session_id)}>세션 원인 보기</button>
      </div>
    </article>
  `}function Sp({row:t}){const e=t.recentTools.length>0?t.recentTools.join(", "):"도구 텔레메트리 없음",n=t.withWhom.length>0?t.withWhom.slice(0,3).join(", "):"단독 또는 room-level";return i`
    <button class="mission-activity-card ${_t(t.agent.status)}" onClick=${()=>ua(t.agent.name)}>
      <div class="mission-activity-head">
        <div class="mission-activity-title">
          <span class="agent-emoji">${t.agent.emoji??""}</span>
          <div>
            <strong>${t.agent.name}</strong>
            ${t.agent.koreanName?i`<span>${t.agent.koreanName}</span>`:null}
          </div>
        </div>
        <span class="command-chip ${_t(t.agent.status)}">${t.agent.status}</span>
      </div>

      <div class="mission-activity-meta">
        <span>어디서 · ${t.where}</span>
        <span>누구와 · ${n}</span>
        <span>언제부터 · ${t.activeSince?me(t.activeSince):"n/a"}</span>
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
  `}function Ap({row:t}){const e=[`gen ${t.keeper.generation??0}`,`handoff ${t.keeper.handoff_count_total??0}`,`compact ${t.keeper.compaction_count??0}`,t.keeper.context_ratio!=null?`ctx ${Math.round(t.keeper.context_ratio*100)}%`:null].filter(n=>n!==null).join(" · ");return i`
    <button class="mission-activity-card ${_t(t.keeper.status)}" onClick=${()=>Ni(t.keeper)}>
      <div class="mission-activity-head">
        <div class="mission-activity-title">
          <span class="agent-emoji">${t.keeper.emoji??""}</span>
          <div>
            <strong>${t.keeper.name}</strong>
            ${t.keeper.koreanName?i`<span>${t.keeper.koreanName}</span>`:null}
          </div>
        </div>
        <span class="command-chip ${_t(t.keeper.status)}">${t.keeper.status}</span>
      </div>

      <div class="mission-activity-meta">
        <span>언제부터 · ${t.activeSince?me(t.activeSince):"n/a"}</span>
        <span>최근 heartbeat · ${t.keeper.last_heartbeat?me(t.keeper.last_heartbeat):"n/a"}</span>
        <span>${e}</span>
      </div>

      <div class="mission-activity-focus">
        <span>무엇을</span>
        <strong>${t.currentWork}</strong>
        ${t.keeper.skill_reason?i`<small>판단 요약 · ${nt(t.keeper.skill_reason,120)}</small>`:null}
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
  `}function Cp({item:t}){return i`
    <article class="mission-action-card ${_t(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${_t(t.severity)}">${t.kind}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>np(t)}>이 이슈로 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>sp(t)}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `}function wp({action:t,incident:e}){const n=tp(t);return i`
    <article class="mission-action-card ${_t(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${_t(t.severity)}">${Mi(t.action_type)}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.reason}</p>
      <div class="mission-action-detail">
        <span>${Zu(t)}</span>
        <span>${ep(t)}</span>
      </div>
      ${n?i`<div class="mission-action-preview">${n}</div>`:null}
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>ap(t,e,"상황판 추천 액션")}>이 액션으로 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>ip(t,e,"상황판 추천 액션")}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `}function uo(){const t=la.value;if(di.value&&!t)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(Ps.value&&!t)return i`<div class="empty-state error">${Ps.value}</div>`;if(!t)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;const e=gp(),n=hp(e),s=yp(),a=n.filter(d=>["active","busy","listening","idle"].includes(d.agent.status)).length,o=n.filter(d=>d.recentOutput).length+s.filter(d=>d.recentOutput).length,r=t.incidents[0]??null,c=t.recommended_actions[0]??null;return i`
    <section class="dashboard-panel mission-view">
      <${Ct} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>사람 운영자가 누가 어디서 누구와 무엇을 하고 있는지 바로 보는 관찰면입니다. 내부 메트릭은 아래가 아니라 Command로 내렸습니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${_t(t.summary.room_health)}">${t.summary.room_health??"ok"}</span>
          <span class="command-chip">${t.summary.project??"room"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?me(t.generated_at):"fresh"}</span>
        </div>
      </div>

      <${bp}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <${kp} />

      <div class="mission-stat-grid">
        <${Pe} label="활성 흐름" value=${e.length} detail="지금 보이는 crew / session" tone=${e.length>0?"ok":"warn"} />
        <${Pe} label="응답 가능 에이전트" value=${a} detail="지금 응답 가능한 actor 수" tone=${a>0?"ok":"warn"} />
        <${Pe} label="Keeper 수" value=${s.length} detail="연속성 runtime / generation 관찰 대상" tone=${s.length>0?"ok":"warn"} />
        <${Pe} label="최근 output" value=${o} detail="main 화면에서 바로 볼 수 있는 최근 출력 수" tone=${o>0?"ok":"warn"} />
        <${Pe} label="내부 incident" value=${t.incidents.length} detail="시스템 진단 신호는 아래 보조 카드로만 유지" tone=${(r==null?void 0:r.severity)??"ok"} />
        <${Pe} label="추천 액션" value=${t.recommended_actions.length} detail="개입이 필요하면 Intervene로 바로 이동" tone=${(c==null?void 0:c.severity)??"ok"} />
      </div>

      <div class="mission-human-grid">
        <${N} title="같이 움직이는 흐름" class="mission-list-card" semanticId="mission.crews">
          <div class="mission-section-head">
            <h3>누가 누구와 같은 목표를 향하는지</h3>
            <p>team session 단위로 목표, 멤버, 최근 사건, 커뮤니케이션 흔적을 바로 보여줍니다.</p>
          </div>
          <div class="mission-list-stack">
            ${(()=>{const d=e.filter(u=>u.status!=="interrupted"&&u.status!=="completed"),m=e.filter(u=>u.status==="interrupted"||u.status==="completed");return d.length===0&&m.length===0?i`<div class="empty-state">지금 열려 있는 crew / session 이 없습니다.</div>`:i`
                ${d.map(u=>i`<${Ar} key=${u.session.session_id} row=${u} />`)}
                ${m.length>0?i`<${xp} rows=${m} />`:null}
              `})()}
          </div>
        <//>

        <${N} title="에이전트 활동" class="mission-list-card" semanticId="mission.agent_activity">
          <div class="mission-section-head">
            <h3>각 에이전트가 지금 뭘 하는가</h3>
            <p>where / with whom / current task / recent input-output / recent tools 를 preview-first로 보여줍니다.</p>
          </div>
          <div class="mission-activity-list">
            ${n.length>0?n.slice(0,10).map(d=>i`<${Sp} key=${d.agent.name} row=${d} />`):i`<div class="empty-state">지금 보이는 에이전트 활동이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${N} title="Keeper 연속성" class="mission-list-card" semanticId="mission.keeper_activity">
          <div class="mission-section-head">
            <h3>generation / compaction / handoff 를 거치는 장기 실행체</h3>
            <p>keeper 는 별도 continuity lane 으로 보고, raw thinking 대신 최근 입출력과 판단 요약만 노출합니다.</p>
          </div>
          <div class="mission-activity-list">
            ${s.length>0?s.slice(0,8).map(d=>i`<${Ap} key=${d.keeper.name} row=${d} />`):i`<div class="empty-state">지금 보이는 keeper 가 없습니다.</div>`}
          </div>
        <//>

        <${N} title="내부 진단은 여기서만" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>internal signal / recommendation</h3>
            <p>artifact_scope_drift 같은 시스템 진단은 메인 판단 근거가 아니라 보조 신호로만 유지합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${t.incidents.slice(0,2).map(d=>i`<${Cp} key=${`${d.kind}:${d.target_id??"room"}`} item=${d} />`)}
            ${t.recommended_actions.slice(0,2).map(d=>i`<${wp} key=${`${d.action_type}:${d.target_id??"room"}`} action=${d} />`)}
            ${t.incidents.length===0&&t.recommended_actions.length===0?i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`:null}
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>$t("execution")}>실행 관찰면 보기</button>
            <button class="control-btn ghost" onClick=${()=>$t("command")}>지휘 진단면 보기</button>
          </div>
        <//>
      </div>
    </section>
  `}const Di=_(null),Gt=_(null),js=_(!1),Os=_(!1),Fs=_(null),qs=_(null),pi=_(null),Ks=_(null),G=_("warroom"),Vn=_(null),mi=_(!1),Us=_(null),Te=_(null),Hs=_(!1),Ws=_(null),Yn=_(null),vi=_(!1),Bs=_(null),Dn=_(null),Gs=_(!1),En=_(null),Ge=_(null);let pn=null;function Ei(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"}function A(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function l(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function g(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function st(t){return typeof t=="boolean"?t:void 0}function ft(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Cr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function Tp(){const e=Cr().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Ip(){const e=Cr().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Np(t){if(A(t))return{policy_class:l(t.policy_class),approval_class:l(t.approval_class),tool_allowlist:ft(t.tool_allowlist),model_allowlist:ft(t.model_allowlist),requires_human_for:ft(t.requires_human_for),autonomy_level:l(t.autonomy_level),escalation_timeout_sec:g(t.escalation_timeout_sec),kill_switch:st(t.kill_switch),frozen:st(t.frozen)}}function Rp(t){if(A(t))return{headcount_cap:g(t.headcount_cap),active_operation_cap:g(t.active_operation_cap),max_cost_usd:g(t.max_cost_usd),max_tokens:g(t.max_tokens)}}function zi(t){if(!A(t))return null;const e=l(t.unit_id),n=l(t.label),s=l(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:l(t.parent_unit_id)??null,leader_id:l(t.leader_id)??null,roster:ft(t.roster),capability_profile:ft(t.capability_profile),source:l(t.source),created_at:l(t.created_at),updated_at:l(t.updated_at),policy:Np(t.policy),budget:Rp(t.budget)}}function wr(t){if(!A(t))return null;const e=zi(t.unit);return e?{unit:e,leader_status:l(t.leader_status),roster_total:g(t.roster_total),roster_live:g(t.roster_live),active_operation_count:g(t.active_operation_count),health:l(t.health),reasons:ft(t.reasons),children:Array.isArray(t.children)?t.children.map(wr).filter(n=>n!==null):[]}:null}function Pp(t){if(A(t))return{total_units:g(t.total_units),company_count:g(t.company_count),platoon_count:g(t.platoon_count),squad_count:g(t.squad_count),leaf_agent_unit_count:g(t.leaf_agent_unit_count),live_agent_count:g(t.live_agent_count),managed_unit_count:g(t.managed_unit_count),active_operation_count:g(t.active_operation_count)}}function Tr(t){const e=A(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),source:l(e.source),summary:Pp(e.summary),units:Array.isArray(e.units)?e.units.map(wr).filter(n=>n!==null):[]}}function Lp(t){if(!A(t))return null;const e=l(t.kind),n=l(t.status);return!e||!n?null:{kind:e,chain_id:l(t.chain_id)??null,goal:l(t.goal)??null,run_id:l(t.run_id)??null,status:n,viewer_path:l(t.viewer_path)??null,last_sync_at:l(t.last_sync_at)??null}}function va(t){if(!A(t))return null;const e=l(t.operation_id),n=l(t.objective),s=l(t.assigned_unit_id),a=l(t.trace_id),o=l(t.status);return!e||!n||!s||!a||!o?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:l(t.autonomy_level),policy_class:l(t.policy_class),budget_class:l(t.budget_class),detachment_session_id:l(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:l(t.checkpoint_ref)??null,active_goal_ids:ft(t.active_goal_ids),note:l(t.note)??null,created_by:l(t.created_by),source:l(t.source),status:o,chain:Lp(t.chain),created_at:l(t.created_at),updated_at:l(t.updated_at)}}function Mp(t){if(!A(t))return null;const e=va(t.operation);return e?{operation:e,assigned_unit_label:l(t.assigned_unit_label)}:null}function cn(t){if(A(t))return{tone:l(t.tone),pending_ops:g(t.pending_ops),blocked_ops:g(t.blocked_ops),in_flight_ops:g(t.in_flight_ops),pipeline_stalls:g(t.pipeline_stalls),bus_traffic:g(t.bus_traffic),l1_hit_rate:g(t.l1_hit_rate),invalidation_count:g(t.invalidation_count),current_pending:g(t.current_pending),current_in_flight:g(t.current_in_flight),cdb_wakeups:g(t.cdb_wakeups),total_stolen:g(t.total_stolen),avg_best_score:g(t.avg_best_score),avg_candidate_count:g(t.avg_candidate_count),best_first_operations:g(t.best_first_operations),active_sessions:g(t.active_sessions),commit_rate:g(t.commit_rate),total_speculations:g(t.total_speculations)}}function Dp(t){if(!A(t))return;const e=A(t.pipeline)?t.pipeline:void 0,n=A(t.cache)?t.cache:void 0,s=A(t.ooo)?t.ooo:void 0,a=A(t.speculative)?t.speculative:void 0,o=A(t.search_fabric)?t.search_fabric:void 0,r=A(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:g(e.total_ops),completed_ops:g(e.completed_ops),stalled_cycles:g(e.stalled_cycles),hazards_detected:g(e.hazards_detected),forwarding_used:g(e.forwarding_used),pipeline_flushes:g(e.pipeline_flushes),ipc:g(e.ipc)}:void 0,cache:n?{total_reads:g(n.total_reads),total_writes:g(n.total_writes),l1_hit_rate:g(n.l1_hit_rate),invalidation_count:g(n.invalidation_count),writeback_count:g(n.writeback_count),bus_traffic:g(n.bus_traffic)}:void 0,ooo:s?{agent_count:g(s.agent_count),total_added:g(s.total_added),total_issued:g(s.total_issued),total_completed:g(s.total_completed),total_stolen:g(s.total_stolen),cdb_wakeups:g(s.cdb_wakeups),stall_cycles:g(s.stall_cycles),global_cdb_events:g(s.global_cdb_events),current_pending:g(s.current_pending),current_in_flight:g(s.current_in_flight)}:void 0,speculative:a?{total_speculations:g(a.total_speculations),total_commits:g(a.total_commits),total_aborts:g(a.total_aborts),commit_rate:g(a.commit_rate),total_fast_calls:g(a.total_fast_calls),total_cost_usd:g(a.total_cost_usd),active_sessions:g(a.active_sessions)}:void 0,search_fabric:o?{total_operations:g(o.total_operations),best_first_operations:g(o.best_first_operations),legacy_operations:g(o.legacy_operations),blocked_operations:g(o.blocked_operations),ready_operations:g(o.ready_operations),research_pipeline_operations:g(o.research_pipeline_operations),avg_candidate_count:g(o.avg_candidate_count),avg_best_score:g(o.avg_best_score),top_stage:l(o.top_stage)??null}:void 0,signals:r?{issue_pressure:cn(r.issue_pressure),cache_contention:cn(r.cache_contention),scheduler_efficiency:cn(r.scheduler_efficiency),routing_confidence:cn(r.routing_confidence),speculative_posture:cn(r.speculative_posture)}:void 0}}function Ir(t){const e=A(t)?t:{},n=A(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:g(n.total),active:g(n.active),paused:g(n.paused),managed:g(n.managed),projected:g(n.projected)}:void 0,microarch:Dp(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(Mp).filter(s=>s!==null):[]}}function Nr(t){if(!A(t))return null;const e=l(t.detachment_id),n=l(t.operation_id),s=l(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:l(t.leader_id)??null,roster:ft(t.roster),session_id:l(t.session_id)??null,checkpoint_ref:l(t.checkpoint_ref)??null,runtime_kind:l(t.runtime_kind)??null,runtime_ref:l(t.runtime_ref)??null,source:l(t.source),status:l(t.status),last_event_at:l(t.last_event_at)??null,last_progress_at:l(t.last_progress_at)??null,heartbeat_deadline:l(t.heartbeat_deadline)??null,created_at:l(t.created_at),updated_at:l(t.updated_at)}}function Ep(t){if(!A(t))return null;const e=Nr(t.detachment);return e?{detachment:e,assigned_unit_label:l(t.assigned_unit_label),operation:va(t.operation)}:null}function Rr(t){const e=A(t)?t:{},n=A(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:g(n.total),active:g(n.active),projected:g(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(Ep).filter(s=>s!==null):[]}}function zp(t){if(!A(t))return null;const e=l(t.decision_id),n=l(t.trace_id),s=l(t.requested_action),a=l(t.scope_type),o=l(t.scope_id);return!e||!n||!s||!a||!o?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:l(t.operation_id)??null,target_unit_id:l(t.target_unit_id)??null,requested_by:l(t.requested_by),status:l(t.status),reason:l(t.reason)??null,source:l(t.source),detail:t.detail,created_at:l(t.created_at),decided_at:l(t.decided_at)??null,expires_at:l(t.expires_at)??null}}function Pr(t){const e=A(t)?t:{},n=A(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:g(n.total),pending:g(n.pending),approved:g(n.approved),denied:g(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(zp).filter(s=>s!==null):[]}}function jp(t){if(!A(t))return null;const e=zi(t.unit);return e?{unit:e,roster_total:g(t.roster_total),roster_live:g(t.roster_live),headcount_cap:g(t.headcount_cap),active_operations:g(t.active_operations),active_operation_cap:g(t.active_operation_cap),utilization:g(t.utilization)}:null}function Op(t){const e=A(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(jp).filter(n=>n!==null):[]}}function Fp(t){if(!A(t))return null;const e=l(t.alert_id);return e?{alert_id:e,severity:l(t.severity),kind:l(t.kind),scope_type:l(t.scope_type),scope_id:l(t.scope_id),title:l(t.title),detail:l(t.detail),timestamp:l(t.timestamp)}:null}function Lr(t){const e=A(t)?t:{},n=A(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:g(n.total),bad:g(n.bad),warn:g(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(Fp).filter(s=>s!==null):[]}}function Mr(t){if(!A(t))return null;const e=l(t.event_id),n=l(t.trace_id),s=l(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:l(t.operation_id)??null,unit_id:l(t.unit_id)??null,actor:l(t.actor)??null,source:l(t.source),timestamp:l(t.timestamp),detail:t.detail}}function qp(t){const e=A(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),events:Array.isArray(e.events)?e.events.map(Mr).filter(n=>n!==null):[]}}function Kp(t){if(!A(t))return null;const e=l(t.code),n=l(t.severity),s=l(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function Up(t){if(!A(t))return null;const e=l(t.lane_id),n=l(t.label),s=l(t.kind),a=l(t.phase),o=l(t.motion_state),r=l(t.source_of_truth),c=l(t.movement_reason),d=l(t.current_step);if(!e||!n||!s||!a||!o||!r||!c||!d)return null;const m=A(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:st(t.present)??!1,phase:a,motion_state:o,source_of_truth:r,last_movement_at:l(t.last_movement_at)??null,movement_reason:c,current_step:d,blockers:ft(t.blockers),counts:{operations:g(m.operations),detachments:g(m.detachments),workers:g(m.workers),approvals:g(m.approvals),alerts:g(m.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(Kp).filter(u=>u!==null):[]}}function Hp(t){if(!A(t))return null;const e=l(t.event_id),n=l(t.lane_id),s=l(t.kind),a=l(t.timestamp),o=l(t.title),r=l(t.detail),c=l(t.tone),d=l(t.source);return!e||!n||!s||!a||!o||!r||!c||!d?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:o,detail:r,tone:c,source:d}}function Wp(t){if(!A(t))return null;const e=l(t.code),n=l(t.severity),s=l(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,lane_ids:ft(t.lane_ids),count:g(t.count)??0}}function Dr(t){if(!A(t))return;const e=A(t.overview)?t.overview:{},n=A(t.gaps)?t.gaps:{},s=A(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:l(t.generated_at),overview:{active_lanes:g(e.active_lanes),moving_lanes:g(e.moving_lanes),stalled_lanes:g(e.stalled_lanes),projected_lanes:g(e.projected_lanes),last_movement_at:l(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(Up).filter(a=>a!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(Hp).filter(a=>a!==null):[],gaps:{count:g(n.count),items:Array.isArray(n.items)?n.items.map(Wp).filter(a=>a!==null):[]},recommended_next_action:s?{tool:l(s.tool)??"masc_operator_snapshot",label:l(s.label)??"Observe operator state",reason:l(s.reason)??"",lane_id:l(s.lane_id)??null}:void 0}}function Bp(t){if(!A(t))return;const e=A(t.workers)?t.workers:{},n=st(t.pass);return{status:l(t.status)??"missing",source:l(t.source)??"none",run_id:l(t.run_id)??null,captured_at:l(t.captured_at)??null,...n!==void 0?{pass:n}:{},...g(t.peak_hot_slots)!=null?{peak_hot_slots:g(t.peak_hot_slots)}:{},...g(t.ctx_per_slot)!=null?{ctx_per_slot:g(t.ctx_per_slot)}:{},workers:{expected:g(e.expected),joined:g(e.joined),current_task_bound:g(e.current_task_bound),fresh_heartbeats:g(e.fresh_heartbeats),done:g(e.done),final:g(e.final)},artifact_ref:l(t.artifact_ref)??null,missing_reason:l(t.missing_reason)??null}}function Gp(t){const e=A(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),topology:Tr(e.topology),operations:Ir(e.operations),detachments:Rr(e.detachments),alerts:Lr(e.alerts),decisions:Pr(e.decisions),capacity:Op(e.capacity),traces:qp(e.traces),swarm_status:Dr(e.swarm_status)}}function Jp(t){const e=A(t)?t:{},n=Tr(e.topology),s=Ir(e.operations),a=Rr(e.detachments),o=Lr(e.alerts),r=Pr(e.decisions);return{version:l(e.version),generated_at:l(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:Dr(e.swarm_status),swarm_proof:Bp(e.swarm_proof)}}function Vp(t){return A(t)?{chain_id:l(t.chain_id)??null,started_at:g(t.started_at)??null,progress:g(t.progress)??null,elapsed_sec:g(t.elapsed_sec)??null}:null}function Er(t){if(!A(t))return null;const e=l(t.event);return e?{event:e,chain_id:l(t.chain_id)??null,timestamp:l(t.timestamp)??null,duration_ms:g(t.duration_ms)??null,message:l(t.message)??null,tokens:g(t.tokens)??null}:null}function Yp(t){if(!A(t))return null;const e=va(t.operation);return e?{operation:e,runtime:Vp(t.runtime),history:Er(t.history),mermaid:l(t.mermaid)??null,preview_run:zr(t.preview_run)}:null}function Xp(t){const e=A(t)?t:{};return{status:l(e.status)??"disconnected",base_url:l(e.base_url)??null,message:l(e.message)??null}}function Qp(t){const e=A(t)?t:{},n=A(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),connection:Xp(e.connection),summary:n?{linked_operations:g(n.linked_operations),active_chains:g(n.active_chains),running_operations:g(n.running_operations),recent_failures:g(n.recent_failures),last_history_event_at:l(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(Yp).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(Er).filter(s=>s!==null):[]}}function Zp(t){if(!A(t))return null;const e=l(t.id);return e?{id:e,type:l(t.type),status:l(t.status),duration_ms:g(t.duration_ms)??null,error:l(t.error)??null}:null}function zr(t){if(!A(t))return null;const e=l(t.run_id),n=l(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:g(t.duration_ms),success:st(t.success),mermaid:l(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(Zp).filter(s=>s!==null):[]}:null}function tm(t){const e=A(t)?t:{};return{run:zr(e.run)}}function em(t){if(!A(t))return null;const e=l(t.title),n=l(t.path);return!e||!n?null:{title:e,path:n}}function nm(t){if(!A(t))return null;const e=l(t.id),n=l(t.title),s=l(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function sm(t){if(!A(t))return null;const e=l(t.id),n=l(t.title),s=l(t.tool),a=l(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:ft(t.success_signals),pitfalls:ft(t.pitfalls)}}function am(t){if(!A(t))return null;const e=l(t.id),n=l(t.title),s=l(t.summary),a=l(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(sm).filter(o=>o!==null):[]}}function im(t){if(!A(t))return null;const e=l(t.id),n=l(t.title),s=l(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:ft(t.tools)}}function om(t){if(!A(t))return null;const e=l(t.id),n=l(t.title),s=l(t.symptom),a=l(t.why),o=l(t.fix_tool),r=l(t.fix_summary);return!e||!n||!s||!a||!o||!r?null:{id:e,title:n,symptom:s,why:a,fix_tool:o,fix_summary:r}}function rm(t){if(!A(t))return null;const e=l(t.id),n=l(t.title),s=l(t.path_id),a=l(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:ft(t.notes)}}function lm(t){const e=A(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(em).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(nm).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(am).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(im).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(om).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(rm).filter(n=>n!==null):[]}}function cm(t){if(!A(t))return null;const e=l(t.id),n=l(t.title),s=l(t.status),a=l(t.detail),o=l(t.next_tool);return!e||!n||!s||!a||!o?null:{id:e,title:n,status:s,detail:a,next_tool:o}}function dm(t){if(!A(t))return null;const e=l(t.code),n=l(t.severity),s=l(t.title),a=l(t.detail),o=l(t.next_tool);return!e||!n||!s||!a||!o?null:{code:e,severity:n,title:s,detail:a,next_tool:o}}function um(t){if(!A(t))return null;const e=l(t.from),n=l(t.content),s=l(t.timestamp),a=g(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function pm(t){if(!A(t))return null;const e=l(t.name),n=l(t.role),s=l(t.lane),a=l(t.status),o=l(t.claim_marker),r=l(t.done_marker),c=l(t.final_marker);if(!e||!n||!s||!a||!o||!r||!c)return null;const d=(()=>{if(!A(t.last_message))return null;const m=g(t.last_message.seq),u=l(t.last_message.content),p=l(t.last_message.timestamp);return m==null||!u||!p?null:{seq:m,content:u,timestamp:p}})();return{name:e,role:n,lane:s,joined:st(t.joined)??!1,live_presence:st(t.live_presence)??!1,completed:st(t.completed)??!1,status:a,current_task:l(t.current_task)??null,bound_task_id:l(t.bound_task_id)??null,bound_task_title:l(t.bound_task_title)??null,bound_task_status:l(t.bound_task_status)??null,current_task_matches_run:st(t.current_task_matches_run)??!1,squad_member:st(t.squad_member)??!1,detachment_member:st(t.detachment_member)??!1,last_seen:l(t.last_seen)??null,heartbeat_age_sec:g(t.heartbeat_age_sec)??null,heartbeat_fresh:st(t.heartbeat_fresh)??!1,claim_marker_seen:st(t.claim_marker_seen)??!1,done_marker_seen:st(t.done_marker_seen)??!1,final_marker_seen:st(t.final_marker_seen)??!1,claim_marker:o,done_marker:r,final_marker:c,last_message:d}}function mm(t){if(!A(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!A(n))return null;const s=l(n.timestamp),a=g(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:l(t.slot_url)??null,provider_base_url:l(t.provider_base_url)??null,provider_reachable:st(t.provider_reachable)??null,provider_status_code:g(t.provider_status_code)??null,provider_model_id:l(t.provider_model_id)??null,actual_model_id:l(t.actual_model_id)??null,expected_slots:g(t.expected_slots),actual_slots:g(t.actual_slots),expected_ctx:g(t.expected_ctx),actual_ctx:g(t.actual_ctx),slot_reachable:st(t.slot_reachable)??null,slot_status_code:g(t.slot_status_code)??null,runtime_blocker:l(t.runtime_blocker)??null,detail:l(t.detail)??null,checked_at:l(t.checked_at)??null,total_slots:g(t.total_slots),ctx_per_slot:g(t.ctx_per_slot),active_slots_now:g(t.active_slots_now),peak_active_slots:g(t.peak_active_slots),sample_count:g(t.sample_count),last_sample_at:l(t.last_sample_at)??null,timeline:e}}function vm(t){const e=A(t)?t:{},n=A(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),run_id:l(e.run_id),room_id:l(e.room_id),operation_id:l(e.operation_id)??null,recommended_next_tool:l(e.recommended_next_tool),summary:n?{expected_workers:g(n.expected_workers),joined_workers:g(n.joined_workers),live_workers:g(n.live_workers),squad_roster_size:g(n.squad_roster_size),detachment_roster_size:g(n.detachment_roster_size),current_task_bound:g(n.current_task_bound),fresh_heartbeats:g(n.fresh_heartbeats),claim_markers_seen:g(n.claim_markers_seen),done_markers_seen:g(n.done_markers_seen),final_markers_seen:g(n.final_markers_seen),completed_workers:g(n.completed_workers),peak_hot_slots:g(n.peak_hot_slots),hot_window_ok:st(n.hot_window_ok),pass_hot_concurrency:st(n.pass_hot_concurrency),pass_end_to_end:st(n.pass_end_to_end),pending_decisions:g(n.pending_decisions),pass:st(n.pass)}:void 0,provider:mm(e.provider),operation:va(e.operation),squad:zi(e.squad),detachment:Nr(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(pm).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(cm).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(dm).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(um).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(Mr).filter(s=>s!==null):[],truth_notes:ft(e.truth_notes)}}function we(t){G.value=t,Ei(t)&&_m()}async function jr(){js.value=!0,Fs.value=null;try{const t=await Xl();Di.value=Jp(t)}catch(t){Fs.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{js.value=!1}}function ji(t){Ge.value=t}async function Oi(){Os.value=!0,qs.value=null;try{const t=await Yl();Gt.value=Gp(t)}catch(t){qs.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{Os.value=!1}}async function _m(){Gt.value||Os.value||await Oi()}async function oe(){await jr(),Ei(G.value)&&await Oi()}async function re(){var t;vi.value=!0,Bs.value=null;try{const e=await Ql(),n=Qp(e);Yn.value=n;const s=Ge.value;n.operations.length===0?Ge.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Ge.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Bs.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{vi.value=!1}}function fm(){pn=null,Dn.value=null,Gs.value=!1,En.value=null}async function gm(t){pn=t,Gs.value=!0,En.value=null;try{const e=await Zl(t);if(pn!==t)return;Dn.value=tm(e)}catch(e){if(pn!==t)return;Dn.value=null,En.value=e instanceof Error?e.message:"Failed to load chain run"}finally{pn===t&&(Gs.value=!1)}}async function $m(){mi.value=!0,Us.value=null;try{const t=await tc();Vn.value=lm(t)}catch(t){Us.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{mi.value=!1}}async function Ot(t=Tp(),e=Ip()){Hs.value=!0,Ws.value=null;try{const n=await ec(t,e);Te.value=vm(n)}catch(n){Ws.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{Hs.value=!1}}async function fe(t,e,n){pi.value=t,Ks.value=null;try{await nc(e,n),await jr(),(Gt.value||Ei(G.value))&&await Oi(),await Ot(),await re()}catch(s){throw Ks.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{pi.value=null}}function hm(t){return fe(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function ym(t){return fe(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function bm(t){return fe(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function km(t={}){return fe("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function xm(t){return fe(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Sm(t){return fe(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Am(t,e){return fe(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Cm(t,e){return fe(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}Nd(()=>{oe(),re(),(G.value==="swarm"||G.value==="warroom"||Te.value!==null)&&Ot(),G.value==="warroom"&&lt()});const wm="modulepreload",Tm=function(t){return"/dashboard/"+t},po={},Im=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let r=function(m){return Promise.all(m.map(u=>Promise.resolve(u).then(p=>({status:"fulfilled",value:p}),p=>({status:"rejected",reason:p}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),d=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=r(n.map(m=>{if(m=Tm(m),m in po)return;po[m]=!0;const u=m.endsWith(".css"),p=u?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${m}"]${p}`))return;const v=document.createElement("link");if(v.rel=u?"stylesheet":wm,u||(v.as="script"),v.crossOrigin="",v.href=m,d&&v.setAttribute("nonce",d),document.head.appendChild(v),u)return new Promise(($,x)=>{v.addEventListener("load",$),v.addEventListener("error",()=>x(new Error(`Unable to preload CSS for ${m}`)))})}))}function o(r){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=r,window.dispatchEvent(c),!c.defaultPrevented)throw r}return a.then(r=>{for(const c of r||[])c.status==="rejected"&&o(c.reason);return e().catch(o)})};function Or(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Z(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function Nm(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Fr(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function D(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let mo=!1,Rm=0;function Pm(){return++Rm}let xa=null;async function Lm(){xa||(xa=Im(()=>import("./mermaid.core-CaAs5tcR.js").then(e=>e.bE),[]).then(e=>e.default));const t=await xa;return mo||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),mo=!0),t}function le(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Xn(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function mn(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function Qn(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function ke(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:Qn(t/e*100)}function Mm(t,e){const n=Qn(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function qr(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const Dm=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],Kr=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],Em=Kr.map(t=>t.id),zm=["chain_start","node_start","node_complete","chain_complete","chain_error"],jm={warroom:{title:"라이브 워룸",description:"실제 run, worker, message, trace를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function vo(t){return!!t&&Em.includes(t)}function Om(){const t=O.value.params;return t.source!=="mission"?{}:{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function Ur(t){const e=Om();if(t==="operations")return e;if(t==="chains"){const n=Ge.value;return n?{...e,surface:t,operation:n}:{...e,surface:t}}return{...e,surface:t}}function Fm(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function qm(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function ct(t){return pi.value===t}function Zn(){return Di.value}function Km(t){var a,o,r,c,d,m,u;const e=Di.value,n=Te.value,s=Yn.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"live run, worker, message, trace를 한 화면에서 보고 필요한 detail 표면으로 바로 점프합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((r=(o=e==null?void 0:e.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:r.tool)??"masc_observe_traces",reason:((d=(c=e==null?void 0:e.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:d.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(u=(m=s==null?void 0:s.operations[0])==null?void 0:m.preview_run)!=null&&u.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function Um(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function Hm(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function Wm(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Hr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function Bm(){const e=Hr().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Wr(){const e=Hr().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Gm(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function Jm(t){return t.status==="claimed"||t.status==="in_progress"}function Vm(t){const e=Vn.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function Sa(t){var e;return((e=Vn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function Ym(t){const e=Vn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function ce(t){try{await t()}catch{}}function Fi(t){return(t==null?void 0:t.trim().toLowerCase())??""}function Oe(t){const e=Fi(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function Aa(t){const e=Fi(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function Xm(){var e,n,s;const t=Te.value;return t?!!(t.run_id||(e=t.operation)!=null&&e.operation_id||(n=t.detachment)!=null&&n.detachment_id||(((s=t.summary)==null?void 0:s.expected_workers)??0)>0||t.workers.length>0||t.recent_messages.length>0||t.recent_trace_events.length>0):!1}function Qm(t){const e=Fi(t.status);return e==="active"||e==="running"}function Zm(){var o,r,c,d;const t=((o=Ht.value)==null?void 0:o.sessions)??[],e=Te.value,n=((r=e==null?void 0:e.detachment)==null?void 0:r.session_id)??null;if(n){const m=t.find(u=>u.session_id===n);if(m)return m}const s=((c=e==null?void 0:e.operation)==null?void 0:c.operation_id)??Wr();if(s){const m=t.find(u=>u.command_plane_operation_id===s);if(m)return m}const a=((d=e==null?void 0:e.detachment)==null?void 0:d.detachment_id)??null;if(a){const m=t.find(u=>u.command_plane_detachment_id===a);if(m)return m}return t.find(Qm)??t[0]??null}function tv(){const t=Jn(O.value);return t?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${Mi(t.action_type)}</span>
        <span class="command-chip">${Li(t)}</span>
        <span class="command-chip">${Yu(O.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?i`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function ev(){const t=G.value,e=jm[t],n=Km(t);return i`
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
  `}function os({label:t,value:e,subtext:n,percent:s,color:a}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${Mm(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(Qn(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function rs({label:t,value:e,detail:n,percent:s,tone:a}){return i`
    <article class="command-signal-rail ${D(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${D(a)}" style=${`width: ${Math.max(8,Math.round(Qn(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function nv(){var F,tt,B,et;const t=Zn(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,o=t==null?void 0:t.alerts.summary,r=(F=t==null?void 0:t.swarm_status)==null?void 0:F.overview,c=t==null?void 0:t.swarm_proof,d=t==null?void 0:t.operations.microarch,m=(e==null?void 0:e.managed_unit_count)??0,u=(e==null?void 0:e.total_units)??0,p=(n==null?void 0:n.active)??0,v=(s==null?void 0:s.active)??0,$=(r==null?void 0:r.moving_lanes)??0,x=(r==null?void 0:r.active_lanes)??0,k=(c==null?void 0:c.workers.done)??0,C=(c==null?void 0:c.workers.expected)??0,R=(o==null?void 0:o.bad)??0,w=(o==null?void 0:o.warn)??0,E=(a==null?void 0:a.pending)??0,P=(a==null?void 0:a.total)??0,L=p+v,Y=((tt=d==null?void 0:d.cache)==null?void 0:tt.l1_hit_rate)??((et=(B=d==null?void 0:d.signals)==null?void 0:B.cache_contention)==null?void 0:et.l1_hit_rate)??0,J=p>0||v>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",f=p>0||$>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${J}</h3>
        <p>${f}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${D(p>0?"ok":"warn")}">활성 작전 ${p}</span>
          <span class="command-chip ${D($>0?"ok":(x>0,"warn"))}">이동 레인 ${$}/${Math.max(x,$)}</span>
          <span class="command-chip ${D(R>0?"bad":w>0?"warn":"ok")}">치명 알림 ${R}</span>
          <span class="command-chip ${D(E>0?"warn":"ok")}">승인 대기 ${E}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${os}
          label="관리 단위 범위"
          value=${`${m}/${Math.max(u,m)}`}
          subtext=${u>0?`${u-m}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${ke(m,Math.max(u,m))}
          color="#67e8f9"
        />
        <${os}
          label="실행 열도"
          value=${String(L)}
          subtext=${`${p}개 작전 + ${v}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${ke(L,Math.max(m,L||1))}
          color="#4ade80"
        />
        <${os}
          label="스웜 이동감"
          value=${`${$}/${Math.max(x,$)}`}
          subtext=${r!=null&&r.last_movement_at?`마지막 이동 ${Z(r.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${ke($,Math.max(x,$||1))}
          color="#fbbf24"
        />
        <${os}
          label="증거 수집률"
          value=${`${k}/${Math.max(C,k)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${ke(k,Math.max(C,k||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${rs}
        label="승인 대기열"
        value=${`${E}건 대기`}
        detail=${`현재 정책 창에서 ${P}개 결정을 추적 중입니다`}
        percent=${ke(E,Math.max(P,E||1))}
        tone=${E>0?"warn":"ok"}
      />
      <${rs}
        label="알림 압력"
        value=${`${R} bad / ${w} warn`}
        detail=${R>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${ke(R*2+w,Math.max((R+w)*2,1))}
        tone=${R>0?"bad":w>0?"warn":"ok"}
      />
      <${rs}
        label="디스패치 점유"
          value=${`${v}개 가동`}
        detail=${m>0?`${m}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${ke(v,Math.max(m,v||1))}
        tone=${v>0?"ok":"warn"}
      />
      <${rs}
        label="캐시 신뢰도"
        value=${Y?Xn(Y):"n/a"}
        detail=${Y?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Qn((Y??0)*100)}
        tone=${Y>=.75?"ok":Y>=.4?"warn":"bad"}
      />
    </div>
  `}function sv(){var v,$,x,k,C;const t=Zn(),e=Yn.value,n=Jn(O.value),s=Um(n),a=t==null?void 0:t.topology.summary,o=t==null?void 0:t.operations.summary,r=(v=t==null?void 0:t.swarm_status)==null?void 0:v.overview,c=t==null?void 0:t.operations.microarch,d=t==null?void 0:t.decisions.summary,m=t==null?void 0:t.alerts.summary,u=($=c==null?void 0:c.signals)==null?void 0:$.issue_pressure,p=c==null?void 0:c.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((x=t==null?void 0:t.detachments.summary)==null?void 0:x.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(d==null?void 0:d.pending)??0}</strong><small>${(d==null?void 0:d.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(m==null?void 0:m.bad)??0}</strong><small>${(m==null?void 0:m.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((k=e==null?void 0:e.summary)==null?void 0:k.active_chains)??0}</strong><small>${((C=e==null?void 0:e.summary)==null?void 0:C.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(r==null?void 0:r.active_lanes)??0}</strong><small>${r?`${r.stalled_lanes??0}개 정체 · ${Z(r.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(u==null?void 0:u.pending_ops)??0}</strong><small>${(p==null?void 0:p.l1_hit_rate)!=null?`${Xn(p.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(u==null?void 0:u.tone)??"n/a"}</small></div>
    </div>
  `}function av(){var F,tt,B,et,b,Pt,ee,ge,$e;const t=Zn(),e=Gt.value,n=At.value,s=Wm(),a=s?wt.value.find(j=>j.name===s)??null:null,o=s?qt.value.filter(j=>j.assignee===s&&Jm(j)):[],r=((F=t==null?void 0:t.operations.summary)==null?void 0:F.active)??0,c=((tt=t==null?void 0:t.detachments.summary)==null?void 0:tt.total)??0,d=((B=t==null?void 0:t.decisions.summary)==null?void 0:B.pending)??0,m=e==null?void 0:e.detachments.detachments.find(j=>{const Lt=j.detachment.heartbeat_deadline,he=Lt?Date.parse(Lt):Number.NaN;return j.detachment.status==="stalled"||!Number.isNaN(he)&&he<=Date.now()}),u=e==null?void 0:e.alerts.alerts.find(j=>j.severity==="bad"),p=!!(n!=null&&n.room||n!=null&&n.project),v=(a==null?void 0:a.current_task)??null,$=Gm(a==null?void 0:a.last_seen),x=$!=null?$<=120:null,k=[p?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:qt.value.length>0?"masc_claim":"masc_add_task"}:v?x===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${v} 이지만 heartbeat가 stale 합니다 (${$}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${v}${$!=null?` · 마지막 활동 ${$}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((et=t.topology.summary)==null?void 0:et.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:r===0?{title:"작전 준비도",tone:"warn",detail:`${((b=t.topology.summary)==null?void 0:b.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((Pt=t.topology.summary)==null?void 0:Pt.managed_unit_count)??0}개 관리 단위 위에서 ${r}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},d>0?{title:"디스패치 준비도",tone:"warn",detail:`${d}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:r>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:m||u?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${m?` · detachment ${m.detachment.detachment_id} 가 stalled 상태입니다`:""}${u?` · alert ${u.title??u.alert_id}`:""}${!e&&!m&&!u?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:d>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],C=p?!s||!a?"masc_join":o.length===0?qt.value.length>0?"masc_claim":"masc_add_task":v?x===!1?"masc_heartbeat":!t||(((ee=t.topology.summary)==null?void 0:ee.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":d>0?"masc_policy_approve":r>0&&c===0||m||u?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",R=Vm(C),E=Ym(C==="masc_set_room"?["repo-root-room"]:C==="masc_plan_set_task"?["claimed-not-current"]:C==="masc_heartbeat"?["heartbeat-stale"]:C==="masc_dispatch_tick"?["no-detachments"]:C==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),P=Sa("room_task_hygiene"),L=Sa("cpv2_benchmark"),Y=Sa("supervisor_session"),J=((ge=Vn.value)==null?void 0:ge.docs)??[],f=[P,L,Y].filter(j=>j!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${z} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(R==null?void 0:R.title)??C}</strong>
            <span class="command-chip ok">${C}</span>
          </div>
          <p>${(R==null?void 0:R.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${($e=R==null?void 0:R.success_signals)!=null&&$e.length?i`<div class="command-tag-row">
                ${R.success_signals.map(j=>i`<span class="command-tag ok">${j}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${k.map(j=>i`
            <article class="command-readiness-row ${D(j.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${j.title}</strong>
                  <span class="command-chip ${D(j.tone)}">${j.tone}</span>
                </div>
                <p>${j.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${j.tool}</div>
            </article>
          `)}
        </div>

        ${E.length>0?i`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${E.length}</span>
                </div>
                <div class="command-guide-list">
                  ${E.map(j=>i`
                    <article class="command-guide-inline">
                      <strong>${j.title}</strong>
                      <div>${j.symptom}</div>
                      <div class="command-card-sub">${j.fix_tool} 로 해결: ${j.fix_summary}</div>
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
        ${mi.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:Us.value?i`<div class="empty-state error">${Us.value}</div>`:i`
                <div class="command-path-grid">
                  ${f.map(j=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${j.title}</strong>
                        <span class="command-chip">${j.id}</span>
                      </div>
                      <p>${j.summary}</p>
                      <div class="command-card-sub">${j.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${j.steps.slice(0,4).map(Lt=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Lt.tool}</span>
                            <span>${Lt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${J.length>0?i`<div class="command-doc-links">
                      ${J.map(j=>i`<span class="command-tag">${j.title}: ${j.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function iv(){return i`
    <${nv} />
    <${sv} />
    <${av} />
  `}function ov(){return Os.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:qs.value?i`<div class="empty-state error">${qs.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function Br({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,o=t.unit.policy;return i`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${qm(t.unit.kind)}</span>
            <span class="command-chip ${D(t.health)}">${t.health??"ok"}</span>
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
  `}function rv({alert:t}){return i`
    <article class="command-alert ${D(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${D(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${Z(t.timestamp)}</span>
      </div>
      ${t.detail?i`<p>${t.detail}</p>`:null}
    </article>
  `}function qi({event:t}){return i`
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
  `}function lv(){const t=Gt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${z} panelId="command.topology" compact=${!0} />
      </div>
      ${t&&t.topology.units.length>0?i`${t.topology.units.map(e=>i`<${Br} node=${e} />`)}`:i`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function cv(){const t=Gt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${z} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>i`<${rv} alert=${e} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function dv(){const t=Gt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${z} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?i`<div class="command-trace-stack">
            ${t.traces.events.map(e=>i`<${qi} event=${e} />`)}
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
  `}function uv({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${a.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?i`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function pv({lane:t}){const e=t.counts??{},n=Gr(t),s=e.workers??0,a=e.operations??0,o=e.detachments??0,r=a+o,c=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return i`
    <article class="swarm-lane-strip ${D(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${D(n)}">${t.phase}</span>
          <span class="command-chip ${D(n)}">${t.motion_state}</span>
          <span class="command-chip">${Z(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${D(n)}" style=${`width:${c}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${s>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${uv} total=${s} />
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
              ${t.hard_flags.map(d=>i`<span class="command-chip ${D(d.severity)}">${d.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Vr({lanes:t}){const e=t.slice(0,4);return e.length===0?null:i`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=Gr(n),a=n.counts.workers??0,o=n.counts.operations??0,r=n.counts.detachments??0;return i`
          <article class="swarm-story-card ${D(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${D(s)}">${n.motion_state}</span>
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
  `}function mv({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${D(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?i`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function vv({gap:t}){return i`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${D(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function _v({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${D(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${D(e)}">${(t==null?void 0:t.status)??"missing"}</span>
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
  `}function fv(){const t=Zn(),e=Jn(O.value),n=Hm(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,o=(s==null?void 0:s.lanes.filter(p=>p.present))??[],r=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],d=s==null?void 0:s.overview,m=s==null?void 0:s.recommended_next_action,u=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${z} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${Vr} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(d==null?void 0:d.active_lanes)??0}</strong><small>${(d==null?void 0:d.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(d==null?void 0:d.stalled_lanes)??0}</strong><small>${(d==null?void 0:d.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${Z(d==null?void 0:d.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${Z(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong><small>${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${Jr} lanes=${o} />`:null}

            <div class="command-swarm-layout ${u?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(p=>i`<${pv} lane=${p} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${_v} proof=${a} />

                <div class="command-guide-card ${r.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${D(r.some(p=>p.severity==="bad")?"bad":r.length>0?"warn":"ok")}">${r.length}</span>
                  </div>
                  ${r.length>0?i`<div class="swarm-event-rail">${r.slice(0,4).map(p=>i`<${vv} gap=${p} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?i`<div class="swarm-event-rail">${c.map(p=>i`<${mv} event=${p} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function gv({item:t}){return i`
    <article class="command-guide-card ${D(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${D(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Yr({blocker:t}){return i`
    <article class="command-alert ${D(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${D(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function $v({worker:t}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${D(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
  `}function hv(){var d,m,u,p,v,$,x,k,C,R,w,E,P,L,Y,J,f,F,tt,B,et;const t=Te.value,e=Bm(),n=Wr(),s=(d=t==null?void 0:t.provider)!=null&&d.runtime_blocker?"blocked":(m=t==null?void 0:t.provider)!=null&&m.provider_reachable?"ready":"check",a=((u=t==null?void 0:t.provider)==null?void 0:u.actual_slots)??((p=t==null?void 0:t.provider)==null?void 0:p.total_slots)??0,o=((v=t==null?void 0:t.provider)==null?void 0:v.expected_slots)??"n/a",r=(($=t==null?void 0:t.provider)==null?void 0:$.actual_ctx)??((x=t==null?void 0:t.provider)==null?void 0:x.ctx_per_slot)??0,c=((k=t==null?void 0:t.provider)==null?void 0:k.expected_ctx)??"n/a";return i`
    <div class="command-section-stack">
      <${fv} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${Hs.value?i`<div class="empty-state">Loading swarm live state…</div>`:Ws.value?i`<div class="empty-state error">${Ws.value}</div>`:t?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((C=t.summary)==null?void 0:C.joined_workers)??0}/${((R=t.summary)==null?void 0:R.expected_workers)??0}</strong><small>${((w=t.summary)==null?void 0:w.live_workers)??0}개 가동 · ${((E=t.summary)==null?void 0:E.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${o} · ctx ${r}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(P=t.summary)!=null&&P.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((L=t.provider)==null?void 0:L.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(Y=t.summary)!=null&&Y.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((J=t.operation)==null?void 0:J.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((f=t.squad)==null?void 0:f.label)??"없음"}</span>
                      <span>실행체</span><span>${((F=t.detachment)==null?void 0:F.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((tt=t.summary)==null?void 0:tt.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((B=t.summary)==null?void 0:B.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((et=t.provider)==null?void 0:et.runtime_blocker)??"없음"}</span>
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
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?i`<div class="command-card-stack">
                ${t.checklist.map(b=>i`<${gv} item=${b} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?i`<div class="command-card-stack">
                ${t.workers.map(b=>i`<${$v} worker=${b} />`)}
              </div>`:i`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${z} panelId="command.swarm" compact=${!0} />
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
                      ${t.provider.timeline.slice(-12).map(b=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${b.active_slots} active</strong>
                              <span class="command-chip">${Z(b.timestamp)}</span>
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
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?i`<div class="command-card-stack">
                ${t.blockers.map(b=>i`<${Yr} blocker=${b} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?i`<div class="command-trace-stack">
                ${t.recent_messages.map(b=>i`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${b.from}</strong>
                        <span class="command-chip">${Z(b.timestamp)}</span>
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
            <${z} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${t.recent_trace_events.map(b=>i`<${qi} event=${b} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function yv(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"none",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}s`:t.heartbeat_fresh?"clean":"n/a",detail:[t.bound_task_status??null,t.detachment_member?"detachment":null,t.squad_member?"squad":null].filter(Boolean).join(" · ")||"live swarm worker",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function bv(t,e){const n=t.actor??t.spawn_role??`worker-${e+1}`,s=t.spawn_role??t.worker_class??t.spawn_agent??"worker",a=t.lane_id??t.capsule_mode??t.control_domain??"session",o=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:s,lane:a,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"session lane",heartbeat:t.last_turn_ts_iso?Z(t.last_turn_ts_iso):"n/a",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?Xn(t.routing_confidence):null].filter(Boolean).join(" · ")||"session worker",markers:o,note:t.routing_reason??null}}function _o(t){return D(t.severity)}function kv({worker:t}){return i`
    <article class="command-card compact warroom-worker-card ${D(Oe(t.status))}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${D(Oe(t.status))}">${t.status}</span>
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
  `}function se({label:t,surface:e,params:n={}}){return i`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(e){we(e),$t("command",{...Ur(e),...n});return}$t("intervene")}}
    >
      ${t}
    </button>
  `}function xv(){var J,f,F,tt,B,et,b,Pt,ee,ge,$e,j,Lt,he,an,on,ts,es,ns,ss;const t=Zn(),e=Te.value,n=Ht.value,s=Wt.value,a=Zm(),o=e!=null&&e.operation?((J=Yn.value)==null?void 0:J.operations.find(U=>{var Ne;return U.operation.operation_id===((Ne=e.operation)==null?void 0:Ne.operation_id)}))??null:null,r=(e==null?void 0:e.workers)??[],c=(s==null?void 0:s.worker_cards)??[],d=r.length>0?r.map(yv):c.map(bv),m=Xm(),u=((f=t==null?void 0:t.decisions.summary)==null?void 0:f.pending)??0,p=(n==null?void 0:n.pending_confirms)??[],v=(e==null?void 0:e.blockers)??[],$=(s==null?void 0:s.recommended_actions)??[],x=(s==null?void 0:s.attention_items)??[],k=((F=e==null?void 0:e.recent_messages[0])==null?void 0:F.timestamp)??null,C=((tt=e==null?void 0:e.recent_trace_events[0])==null?void 0:tt.timestamp)??null,R=k??C??null,w=a==null?void 0:a.summary,E=((B=e==null?void 0:e.summary)==null?void 0:B.expected_workers)??(typeof(w==null?void 0:w.planned_worker_count)=="number"?w.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,P=((et=e==null?void 0:e.summary)==null?void 0:et.joined_workers)??(typeof(w==null?void 0:w.active_agent_count)=="number"?w.active_agent_count:void 0)??d.length,L=v.length>0||u>0||p.length>0?"warn":m||a?"ok":"warn",Y=((b=t==null?void 0:t.swarm_status)==null?void 0:b.lanes.filter(U=>U.present))??[];return rt(()=>{lt()},[]),rt(()=>{a!=null&&a.session_id&&Ze(a.session_id)},[a==null?void 0:a.session_id,n,(Pt=e==null?void 0:e.detachment)==null?void 0:Pt.session_id]),!m&&!a?Hs.value||Pn.value?i`<div class="empty-state">live war room 불러오는 중…</div>`:i`
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
          <${se} label="작전 보기" surface="operations" />
          <${se} label="스웜 보기" surface="swarm" />
          <${se} label="개입 열기" />
          <${se} label="제어 보기" surface="control" />
        </div>
      </section>
    `:i`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${D(L)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">Live War Room</span>
            <strong>${((ee=e==null?void 0:e.operation)==null?void 0:ee.objective)??(a==null?void 0:a.session_id)??"active run"}</strong>
            <div class="command-card-sub">
              ${((ge=e==null?void 0:e.operation)==null?void 0:ge.operation_id)??"operation 없음"}
              ${a!=null&&a.session_id?` · session ${a.session_id}`:""}
              ${($e=e==null?void 0:e.detachment)!=null&&$e.detachment_id?` · detachment ${e.detachment.detachment_id}`:""}
            </div>
          </div>
          <div class="command-action-row">
            <${se}
              label="스웜 상세"
              surface="swarm"
              params=${{...(j=e==null?void 0:e.operation)!=null&&j.operation_id?{operation_id:e.operation.operation_id}:{},...e!=null&&e.run_id?{run_id:e.run_id}:{}}}
            />
            <${se} label="트레이스" surface="trace" />
            ${o?i`<${se}
                  label="체인"
                  surface="chains"
                  params=${{operation:o.operation.operation_id}}
                />`:null}
            <${se} label="Intervene" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>Workers</span>
            <strong>${P??0}/${E??0}</strong>
            <small>${((Lt=e==null?void 0:e.summary)==null?void 0:Lt.completed_workers)??0} 완료 · ${d.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>Runtime</span>
            <strong>${(he=e==null?void 0:e.provider)!=null&&he.runtime_blocker?"blocked":(an=e==null?void 0:e.provider)!=null&&an.provider_reachable?"ready":a?Aa(a.status):"check"}</strong>
            <small>slots ${((on=e==null?void 0:e.provider)==null?void 0:on.active_slots_now)??0}/${((ts=e==null?void 0:e.provider)==null?void 0:ts.actual_slots)??((es=e==null?void 0:e.provider)==null?void 0:es.total_slots)??0} · ctx ${((ns=e==null?void 0:e.provider)==null?void 0:ns.actual_ctx)??((ss=e==null?void 0:e.provider)==null?void 0:ss.ctx_per_slot)??0}</small>
          </div>
          <div class="monitor-stat-card ${D(v.length>0||u>0?"warn":"ok")}">
            <span>Pressure</span>
            <strong>${v.length+u+p.length}</strong>
            <small>blockers ${v.length} · approvals ${u} · confirms ${p.length}</small>
          </div>
          <div class="monitor-stat-card">
            <span>Last signal</span>
            <strong>${Z(R)}</strong>
            <small>${k?"message":C?"trace":"waiting"}</small>
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
            ${Y.length>0?i`
                  <${Vr} lanes=${Y} />
                  <${Jr} lanes=${Y} />
                `:a?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${D(Oe(a.status))}">${Aa(a.status)}</span>
                      </div>
                      <p>command-plane live run은 아직 옅지만, session 쪽 worker와 digest를 기준으로 워룸을 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${mn(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${mn(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:i`<div class="empty-state">보이는 lane이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Worker Roster</div>
              <${z} panelId="command.warroom" compact=${!0} />
            </div>
            ${d.length>0?i`<div class="command-card-stack">
                  ${d.map(U=>i`<${kv} worker=${U} />`)}
                </div>`:i`<div class="empty-state">활성 worker 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Live Feed</div>
              <${z} panelId="command.warroom" compact=${!0} />
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
                      <article class="command-guide-card ${_o(U)}">
                        <div class="command-guide-head">
                          <strong>${U.action_type}</strong>
                          <span class="command-chip ${_o(U)}">${U.target_type}</span>
                        </div>
                        <p>${U.reason}</p>
                      </article>
                    `)}
                    ${x.slice(0,3).map(U=>i`
                      <article class="command-alert ${D(U.severity)}">
                        <div class="command-card-head">
                          <strong>${U.kind}</strong>
                          <span class="command-chip ${D(U.severity)}">${U.severity}</span>
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
              <${z} panelId="command.trace" compact=${!0} />
            </div>
            ${e&&e.recent_trace_events.length>0?i`<div class="command-trace-stack">
                  ${e.recent_trace_events.map(U=>i`<${qi} event=${U} />`)}
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
              ${v.length>0?v.map(U=>i`<${Yr} blocker=${U} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
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
                        ${p.slice(0,3).map(U=>i`<span class="command-tag">${U.confirm_token}</span>`)}
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
              ${e!=null&&e.operation?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${e.operation.objective}</strong>
                          <div class="command-card-sub">${e.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${D(Oe(e.operation.status))}">${e.operation.status}</span>
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
                        <span class="command-chip ${D(Oe(e.detachment.status))}">${e.detachment.status??"active"}</span>
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
                        <span class="command-chip ${D(Oe(a.status))}">${Aa(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${mn(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${mn(a.remaining_sec)}</span>
                        <span>Done delta</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function Sv({source:t}){const e=gl(null),[n,s]=ki(null);return rt(()=>{let a=!1;const o=e.current;return o?(o.innerHTML="",s(null),(async()=>{try{const c=await Lm(),{svg:d}=await c.render(`command-chain-${Pm()}`,t);if(a||!e.current)return;e.current.innerHTML=d}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid render failed")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function Av({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return i`
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
        ${a?i`<span class="command-tag ${le(s==null?void 0:s.status)}">${Xn(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${qr(t.history)}</div>
    </button>
  `}function Cv({item:t}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${le(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${Z(t.timestamp)}</div>
      <div class="command-card-sub">${qr(t)}</div>
    </article>
  `}function wv({node:t}){return i`
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
  `}function Tv({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,o=e.chain,r=(o==null?void 0:o.run_id)??null;return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${D(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
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
          onClick=${()=>{we("swarm"),$t("command",{surface:"swarm",operation_id:e.operation_id,...r?{run_id:r}:{}})}}
        >
          Swarm Live
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{ji(e.operation_id),we("chains"),$t("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?i`
              <button class="control-btn ghost" disabled=${ct(n)} onClick=${()=>ce(()=>hm(e.operation_id))}>
                ${ct(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${ct(a)} onClick=${()=>ce(()=>bm(e.operation_id))}>
                ${ct(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?i`
              <button class="control-btn ghost" disabled=${ct(s)} onClick=${()=>ce(()=>ym(e.operation_id))}>
                ${ct(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Iv({card:t}){var n;const e=t.detachment;return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${D(e.status)}">${e.status??"active"}</span>
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
        ${e.heartbeat_deadline?i`<span class="command-tag ${Nm(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Nv(){const t=Gt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${z} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?i`<div class="command-card-stack">
              ${t.operations.operations.map(e=>i`<${Tv} card=${e} />`)}
            </div>`:i`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${z} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>i`<${Iv} card=${e} />`)}
            </div>`:i`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function Rv(){var c,d,m,u,p,v,$,x,k,C,R,w,E,P,L,Y;const t=Yn.value,e=(t==null?void 0:t.operations)??[],n=Ge.value,s=e.find(J=>J.operation.operation_id===n)??e[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,o=((d=Dn.value)==null?void 0:d.run)??(s==null?void 0:s.preview_run)??null,r=!((m=Dn.value)!=null&&m.run)&&!!(s!=null&&s.preview_run);return rt(()=>{a?gm(a):fm()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${z} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${le(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${le(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(t==null?void 0:t.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((u=t==null?void 0:t.summary)==null?void 0:u.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((p=t==null?void 0:t.summary)==null?void 0:p.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((v=t==null?void 0:t.summary)==null?void 0:v.recent_failures)??0}</span>
            <span>Last Event</span><span>${Z(($=t==null?void 0:t.summary)==null?void 0:$.last_history_event_at)}</span>
          </div>
        </article>

        ${Bs.value?i`<div class="empty-state error">${Bs.value}</div>`:null}

        ${vi.value&&!t?i`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?i`
                <div class="command-chain-list">
                  ${e.map(J=>i`
                    <${Av}
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
            <span class="command-chip">${(t==null?void 0:t.recent_history.length)??0}</span>
          </div>
          ${t&&t.recent_history.length>0?i`
                <div class="command-card-stack">
                  ${t.recent_history.slice(0,6).map(J=>i`<${Cv} item=${J} />`)}
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
                  <span class="command-chip ${le((x=s.operation.chain)==null?void 0:x.status)}">
                    ${((k=s.operation.chain)==null?void 0:k.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((C=s.operation.chain)==null?void 0:C.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((R=s.operation.chain)==null?void 0:R.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${Xn((w=s.runtime)==null?void 0:w.progress)}</span>
                  <span>Elapsed</span><span>${mn((E=s.runtime)==null?void 0:E.elapsed_sec)}</span>
                  <span>Updated</span><span>${Z(((P=s.operation.chain)==null?void 0:P.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(L=s.operation.chain)!=null&&L.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((Y=s.operation.chain)==null?void 0:Y.chain_id)??"graph"}</span>
                      </div>
                      <${Sv} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"failed":r?"preview":"captured":"pending"}
                  </span>
                </div>
                ${Gs.value?i`<div class="empty-state">Loading run detail…</div>`:En.value?i`<div class="empty-state error">${En.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${o.chain_id}</span>
                            <span>Run</span><span>${o.run_id??"preview only"}</span>
                            <span>Duration</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${o.nodes.length}</span>
                          </div>
                          ${r?i`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(J=>i`<${wv} node=${J} />`)}
                          </div>
                        `:i`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:i`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function Pv({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return i`
    <article class="command-card ${D(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${D(t.status)}">${t.status??"pending"}</span>
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
              <button class="control-btn ghost" disabled=${ct(e)} onClick=${()=>ce(()=>xm(t.decision_id))}>
                ${ct(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${ct(n)} onClick=${()=>ce(()=>Sm(t.decision_id))}>
                ${ct(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function Lv({row:t}){var c,d,m;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((c=e.policy)!=null&&c.frozen),o=!!((d=e.policy)!=null&&d.kill_switch),r=Math.round((t.utilization??0)*100);return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${D(r>100?"bad":r>70?"warn":"ok")}">${r}%</span>
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
        <button class="control-btn ghost" disabled=${ct(n)} onClick=${()=>ce(()=>Am(e.unit_id,!a))}>
          ${ct(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${ct(s)} onClick=${()=>ce(()=>Cm(e.unit_id,!o))}>
          ${ct(s)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function Mv(){const t=Gt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${z} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>i`<${Pv} decision=${e} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${z} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>i`<${Lv} row=${e} />`)}
            </div>`:i`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function Dv(){return i`
    <div class="command-surface-tabs grouped">
      ${Dm.map(t=>i`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${Kr.filter(e=>e.group===t.id).map(e=>i`
                <button
                  class="command-surface-tab ${G.value===e.id?"active":""}"
                  onClick=${()=>{we(e.id),$t("command",Ur(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function Ev(){if(G.value==="warroom")return i`<${xv} />`;if(G.value==="summary")return i`<${iv} />`;if(G.value==="swarm")return i`<${hv} />`;if(!Gt.value)return i`<${ov} />`;switch(G.value){case"chains":return i`<${Rv} />`;case"topology":return i`<${lv} />`;case"alerts":return i`<${cv} />`;case"trace":return i`<${dv} />`;case"control":return i`<${Mv} />`;case"operations":default:return i`<${Nv} />`}}function zv(){return rt(()=>{oe(),re(),$m(),Ot()},[]),rt(()=>{if(O.value.tab!=="command")return;const t=O.value.params.surface,e=O.value.params.operation,n=Jn(O.value);if(vo(t))we(t);else if(n){const s=br(n);vo(s)&&we(s)}else t||we("warroom");e&&ji(e),(t==="swarm"||t==="warroom"||G.value==="warroom")&&Ot(),(t==="warroom"||G.value==="warroom")&&lt()},[O.value.tab,O.value.params.surface,O.value.params.operation,O.value.params.operation_id,O.value.params.run_id,O.value.params.source,O.value.params.action_type,O.value.params.target_type,O.value.params.target_id,O.value.params.focus_kind]),rt(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,oe(),re(),(G.value==="swarm"||G.value==="warroom")&&Ot(),G.value==="warroom"&&lt()},250))},n=new EventSource(Fm()),s=zm.map(a=>{const o=()=>e();return n.addEventListener(a,o),{type:a,handler:o}});return n.onerror=()=>{e()},()=>{s.forEach(({type:a,handler:o})=>{n.removeEventListener(a,o)}),n.close(),t&&window.clearTimeout(t)}},[]),rt(()=>{const t=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const e=G.value;e!=="swarm"&&e!=="warroom"||(oe(),Ot(),e==="warroom"&&lt())},5e3);return()=>{window.clearInterval(t)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{ce(()=>km())}}
            disabled=${ct("dispatch:tick")}
          >
            ${ct("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{oe(),re(),Ot(),G.value==="warroom"&&lt()}}
            disabled=${js.value}
          >
            ${js.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Fs.value?i`<div class="empty-state error">${Fs.value}</div>`:null}
      ${Ks.value?i`<div class="empty-state error">${Ks.value}</div>`:null}
      <${Ct} surfaceId="command" />
      <${tv} />
      ${G.value==="warroom"?null:i`<${ev} />`}
      <${Dv} />
      <${Ev} />
    </section>
  `}const Xr="masc_dashboard_agent_name";function jv(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Xr))==null?void 0:s.trim())||"dashboard"}const _a=_(jv()),Je=_(""),_i=_("운영 점검"),Ve=_(""),zn=_(""),jn=_("2"),On=_(""),Ft=_("note"),Fn=_(""),qn=_(""),Kn=_(""),Un=_("2"),Js=_("운영자 중지 요청"),Vs=_(""),Ye=_(""),ls=_(null);function Ov(t){const e=t.trim()||"dashboard";_a.value=e,localStorage.setItem(Xr,e)}function fo(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Fv(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function tn(t){return typeof t=="string"?t.trim().toLowerCase():""}function qv(t){var s;const e=tn(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=tn((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function Ca(t){const e=tn(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function go(t){return t.some(e=>tn(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function Kv(t){return t.target_type==="team_session"}function Uv(t){return t.target_type==="keeper"}function cs(t){switch(t){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";case"keeper_msg":return"keeper 메시지";default:return(t==null?void 0:t.trim())||"액션"}}function ds(t){switch(t){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";default:return(t==null?void 0:t.trim())||"target"}}function dn(t){switch(tn(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function $o(t){return t?"확인 후 실행":"즉시 실행"}function Hv(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";default:return t}}function gt(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function Wv(t){if(t.action_type==="team_task_inject")return"task";if(t.action_type==="team_broadcast")return"broadcast";if(t.action_type==="team_note")return"note";if(t.action_type==="team_turn"){const e=gt(t.suggested_payload,"turn_kind");if(e==="broadcast"||e==="task")return e}return"note"}function Bv(t){const e=t.suggested_payload;if(t.target_type==="room"){if(t.action_type==="broadcast"){Je.value=gt(e,"message")??t.summary;return}t.action_type==="task_inject"&&(Ve.value=gt(e,"title")??"운영자 주입 작업",zn.value=gt(e,"description")??t.summary,jn.value=gt(e,"priority")??jn.value);return}if(t.target_type==="team_session"){if(t.target_id&&(On.value=t.target_id),t.action_type==="team_stop"){Js.value=gt(e,"reason")??t.summary;return}Ft.value=Wv(t);const n=gt(e,"message");n&&(Fn.value=n),Ft.value==="task"&&(qn.value=gt(e,"task_title")??gt(e,"title")??"운영자 주입 작업",Kn.value=gt(e,"task_description")??gt(e,"description")??t.summary,Un.value=gt(e,"task_priority")??gt(e,"priority")??Un.value);return}t.target_type==="keeper"&&(t.target_id&&(Vs.value=t.target_id),Ye.value=gt(e,"message")??t.summary)}function Gv(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function Ie(t){const e=_a.value.trim()||"dashboard";try{const n=await gu({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?M("확인 대기열에 올렸습니다","warning"):M(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return M(s,"error"),null}}async function ho(){const t=Je.value.trim();if(!t)return;await Ie({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(Je.value="")}async function Jv(){await Ie({action_type:"room_pause",target_type:"room",payload:{reason:_i.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function yo(){await Ie({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function Vv(){const t=Ve.value.trim();if(!t)return;await Ie({action_type:"task_inject",target_type:"room",payload:{title:t,description:zn.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(jn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(Ve.value="",zn.value="")}async function Yv(){var r;const t=Ht.value,e=On.value||((r=t==null?void 0:t.sessions[0])==null?void 0:r.session_id)||"";if(!e){M("먼저 세션을 고르세요","warning");return}const n={},s=Fn.value.trim();s&&(n.message=s);let a="team_note";Ft.value==="broadcast"?a="team_broadcast":Ft.value==="task"&&(a="team_task_inject"),Ft.value==="task"&&(n.task_title=qn.value.trim()||"운영자 주입 작업",n.task_description=Kn.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(Un.value,10)||2),await Ie({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Fn.value="",Ft.value==="task"&&(qn.value="",Kn.value=""))}async function Xv(){var n;const t=Ht.value,e=On.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){M("먼저 세션을 고르세요","warning");return}await Ie({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Js.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function Qv(){var a;const t=Ht.value,e=Vs.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=Ye.value.trim();if(!e){M("먼저 keeper를 고르세요","warning");return}if(!n)return;await Ie({action_type:"keeper_message",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`${e}에게 메시지를 보냈습니다`})&&(Ye.value="")}async function Zv(t){const e=_a.value.trim()||"dashboard";try{await $u(e,t),M("확인 실행을 완료했습니다","success")}catch(n){const s=n instanceof Error?n.message:"확인 실행에 실패했습니다";M(s,"error")}}function t_(){var L,Y,J;const t=Ht.value,e=O.value.tab==="intervene"?Jn(O.value):null,n=lr.value,s=Wt.value,a=(t==null?void 0:t.room)??{},o=(t==null?void 0:t.sessions)??[],r=(t==null?void 0:t.keepers)??[],c=(t==null?void 0:t.pending_confirms)??[],d=(t==null?void 0:t.recent_messages)??[],m=(n==null?void 0:n.recommended_actions)??[],u=(t==null?void 0:t.available_actions)??[],p=o.find(f=>f.session_id===On.value)??o[0]??null,v=r.find(f=>f.name===Vs.value)??r[0]??null,$=(n==null?void 0:n.attention_items)??[],x=$.filter(Kv),k=$.filter(Uv),C=o.filter(f=>qv(f)!=="ok"),R=r.filter(f=>Ca(f)!=="ok"),w=d.slice(0,5),E=Gv(e,o,r);rt(()=>{Qt()},[]),rt(()=>{if(O.value.tab!=="intervene"){ls.value=null;return}if(!e){ls.value=null;return}ls.value!==e.id&&(ls.value=e.id,Bv(e))},[O.value.tab,O.value.params.source,O.value.params.action_type,O.value.params.target_type,O.value.params.target_id,O.value.params.focus_kind,e==null?void 0:e.id]),rt(()=>{const f=(p==null?void 0:p.session_id)??null;Ze(f)},[p==null?void 0:p.session_id]);const P=[{key:"room",label:"Room 게이트",value:a.paused?"일시정지":"열림",detail:a.paused?`재개 전환 대기 중${a.pause_reason?` · ${a.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:a.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:c.length,detail:c.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:c.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:x.length>0?x.length:o.length,detail:x.length>0?((L=x[0])==null?void 0:L.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":o.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:x.length>0?go(x):o.length===0?"warn":C.some(f=>tn(f.status)==="paused")?"bad":C.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:k.length>0?k.length:R.length,detail:k.length>0?((Y=k[0])==null?void 0:Y.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":R.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:k.length>0?go(k):R.some(f=>Ca(f)==="bad")?"bad":R.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${Ct} surfaceId="intervene" />
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
            value=${_a.value}
            onInput=${f=>Ov(f.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{lt(),Qt(),Ze((p==null?void 0:p.session_id)??null)}}
            disabled=${Pn.value||Q.value}
          >
            ${Pn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${pe.value?i`<section class="ops-banner error">${pe.value}</section>`:null}
      ${Qe.value?i`<section class="ops-banner error">${Qe.value}</section>`:null}
      ${e?i`
        <section class="ops-banner ${E?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${Mi(e.action_type)}</span>
            <span>${Li(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?i`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${E?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const f=[];if(c.length>0&&f.push({label:`확인 대기 ${c.length}건 처리`,desc:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:"bad",onClick:()=>{const F=document.querySelector(".ops-pending-section");F==null||F.scrollIntoView({behavior:"smooth"})}}),a.paused&&f.push({label:"Room 재개",desc:`현재 일시정지 상태${a.pause_reason?` (${a.pause_reason})`:""}`,tone:"warn",onClick:()=>void yo()}),R.length>0){const F=R.filter(tt=>Ca(tt)==="bad");f.push({label:F.length>0?`Keeper ${F.length}개 오프라인`:`Keeper ${R.length}개 점검 필요`,desc:F.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:F.length>0?"bad":"warn",onClick:()=>{const tt=document.querySelector(".ops-keeper-section");tt==null||tt.scrollIntoView({behavior:"smooth"})}})}return f.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${f.slice(0,3).map(F=>i`
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
          ${P.map(f=>i`
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
                value=${Je.value}
                onInput=${f=>{Je.value=f.target.value}}
                onKeyDown=${f=>{f.key==="Enter"&&ho()}}
                disabled=${Q.value}
              />
              <button class="control-btn" onClick=${()=>{ho()}} disabled=${Q.value||Je.value.trim()===""}>
                보내기
              </button>
            </div>

            <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
            <div class="control-row ops-split-row">
              <input
                id="ops-pause-reason"
                class="control-input"
                type="text"
                value=${_i.value}
                onInput=${f=>{_i.value=f.target.value}}
                disabled=${Q.value}
              />
              <button class="control-btn ghost" onClick=${()=>{Jv()}} disabled=${Q.value}>
                일시정지
              </button>
              <button class="control-btn ghost" onClick=${()=>{yo()}} disabled=${Q.value}>
                재개
              </button>
            </div>

            <div class="ops-section-head">작업 주입</div>
            <input
              class="control-input"
              type="text"
              placeholder="작업 제목"
              value=${Ve.value}
              onInput=${f=>{Ve.value=f.target.value}}
              disabled=${Q.value}
            />
            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="작업 설명"
              value=${zn.value}
              onInput=${f=>{zn.value=f.target.value}}
              disabled=${Q.value}
            ></textarea>
            <div class="control-row ops-split-row">
              <select
                class="control-input ops-select"
                value=${jn.value}
                onChange=${f=>{jn.value=f.target.value}}
                disabled=${Q.value}
              >
                <option value="1">P1</option>
                <option value="2">P2</option>
                <option value="3">P3</option>
                <option value="4">P4</option>
                <option value="5">P5</option>
              </select>
              <button class="control-btn" onClick=${()=>{Vv()}} disabled=${Q.value||Ve.value.trim()===""}>
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
            ${Ln.value&&!n?i`
              <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
            `:m.length>0?i`
              <div class="ops-log-list">
                ${m.map(f=>i`
                  <article key=${`${f.action_type}:${f.target_type}:${f.target_id??"room"}`} class="ops-log-entry ${f.severity}">
                    <div class="ops-log-head">
                      <strong>${cs(f.action_type)}</strong>
                      <span>${ds(f.target_type)}${f.target_id?` · ${f.target_id}`:""}</span>
                      <span>${$o(f.confirm_required)}</span>
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
              <${z} panelId="intervene.pending_confirmations" compact=${!0} />
            </div>
            <p class="ops-context-note">미리보기만 끝났고 아직 사람이 눌러줘야 하는 액션만 남깁니다.</p>
            ${c.length>0?i`
              <div class="ops-confirmation-list">
                ${c.map(f=>i`
                  <article key=${f.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${cs(f.action_type)}</strong>
                      <span>${ds(f.target_type)}${f.target_id?` · ${f.target_id}`:""}</span>
                      <span>${f.delegated_tool??"위임 도구 확인 필요"}</span>
                    </div>
                    ${f.preview?i`<pre class="ops-code-block compact">${fo(f.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{Zv(f.confirm_token)}} disabled=${Q.value}>
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
              <${z} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
            ${w.length>0?i`
              <div class="ops-feed-list">
                ${w.map(f=>i`
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
              <${z} panelId="intervene.session_queue" compact=${!0} />
            </div>
            <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

            <div class="ops-entity-list">
              ${o.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:o.map(f=>{var F;return i`
                <button
                  key=${f.session_id}
                  class="ops-entity-card ${(p==null?void 0:p.session_id)===f.session_id?"active":""}"
                  onClick=${()=>{On.value=f.session_id}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${f.session_id}</strong>
                    <span class="status-badge ${f.status??"idle"}">${dn(f.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round(f.progress_pct??0)}%</span>
                    <span>${f.done_delta_total??0}건 완료</span>
                    <span>${(F=f.team_health)!=null&&F.status?dn(String(f.team_health.status)):"상태 확인 필요"}</span>
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
            ${p&&s?i`
              <div class="ops-log-list">
                ${s.attention_items.length>0?s.attention_items.map(f=>i`
                  <article key=${`${f.kind}:${f.target_id??"session"}`} class="ops-log-entry ${f.severity}">
                    <div class="ops-log-head">
                      <strong>${f.kind}</strong>
                      <span>${ds(f.target_type)}${f.target_id?` · ${f.target_id}`:""}</span>
                    </div>
                    <div class="ops-log-body">${f.summary}</div>
                  </article>
                `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
                ${s.worker_cards.length>0?s.worker_cards.map(f=>i`
                  <article key=${`${f.actor??f.spawn_role??"worker"}:${f.spawn_agent??f.runtime_pool??"runtime"}`} class="ops-log-entry">
                    <div class="ops-log-head">
                      <strong>${f.actor??f.spawn_role??"worker"}</strong>
                      <span>${dn(f.status)}</span>
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
              <${z} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>

            ${p?i`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${p.session_id}</div>
                <div class="ops-detail-meta">
                  <span>상태: ${dn(p.status)}</span>
                  <span>경과: ${p.elapsed_sec??0}초</span>
                  <span>남은 시간: ${p.remaining_sec??0}초</span>
                </div>
                ${p.recent_events&&p.recent_events.length>0?i`
                  <pre class="ops-code-block compact">${fo(p.recent_events.slice(-3))}</pre>
                `:null}
              </div>
            `:i`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

            <label class="control-label" for="ops-turn-kind">세션 액션</label>
            <div class="control-row ops-split-row">
              <select
                id="ops-turn-kind"
                class="control-input ops-select"
                value=${Ft.value}
                onChange=${f=>{Ft.value=f.target.value}}
                disabled=${Q.value||!p}
              >
                <option value="note">노트</option>
                <option value="broadcast">방송</option>
                <option value="task">작업</option>
              </select>
              <button class="control-btn" onClick=${()=>{Yv()}} disabled=${Q.value||!p}>
                적용
              </button>
            </div>
            <div class="ops-context-note">현재 선택: ${Hv(Ft.value)}</div>

            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="세션에 남길 메시지"
              value=${Fn.value}
              onInput=${f=>{Fn.value=f.target.value}}
              disabled=${Q.value||!p}
            ></textarea>

            ${Ft.value==="task"?i`
              <input
                class="control-input"
                type="text"
                placeholder="주입할 작업 제목"
                value=${qn.value}
                onInput=${f=>{qn.value=f.target.value}}
                disabled=${Q.value||!p}
              />
              <textarea
                class="control-textarea"
                rows=${2}
                placeholder="주입할 작업 설명"
                value=${Kn.value}
                onInput=${f=>{Kn.value=f.target.value}}
                disabled=${Q.value||!p}
              ></textarea>
              <select
                class="control-input ops-select"
                value=${Un.value}
                onChange=${f=>{Un.value=f.target.value}}
                disabled=${Q.value||!p}
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
                value=${Js.value}
                onInput=${f=>{Js.value=f.target.value}}
                disabled=${Q.value||!p}
              />
              <button class="control-btn ghost" onClick=${()=>{Xv()}} disabled=${Q.value||!p}>
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
              ${r.length===0?i`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:r.map(f=>i`
                <button
                  key=${f.name}
                  class="ops-entity-card ${(v==null?void 0:v.name)===f.name?"active":""}"
                  onClick=${()=>{Vs.value=f.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${f.name}</strong>
                    <span class="status-badge ${f.status??"idle"}">${dn(f.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${f.model??"model 확인 필요"}</span>
                    <span>${typeof f.context_ratio=="number"?`${Math.round(f.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                    <span>${Fv(f.last_turn_ago_s)}</span>
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
              value=${Ye.value}
              onInput=${f=>{Ye.value=f.target.value}}
              disabled=${Q.value||!v}
            ></textarea>
            <div class="control-row">
              <button class="control-btn" onClick=${()=>{Qv()}} disabled=${Q.value||!v||Ye.value.trim()===""}>
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
              ${u.length?u.map(f=>i`
                    <article key=${`${f.action_type}:${f.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${cs(f.action_type)}</strong>
                        <span>${ds(f.target_type)}</span>
                        <span>${$o(f.confirm_required)}</span>
                      </div>
                      <div class="ops-log-body">${f.description??"설명이 아직 없습니다."}</div>
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
              `:Ds.value.map(f=>i`
                <article key=${f.id} class="ops-log-entry ${f.outcome}">
                  <div class="ops-log-head">
                    <strong>${cs(f.action_type)}</strong>
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
  `}function e_({text:t}){if(!t)return null;const e=n_(t);return i`<div class="markdown-content">${e}</div>`}function n_(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(i`<pre><code class=${c?`language-${c}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&r.push(c),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const m=e[s].replace("</think>","").trim();m&&r.push(m),s++}const d=r.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${wa(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(i`<blockquote>${wa(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;o.push(r),s++}o.length>0&&n.push(i`<p>${wa(o.join(`
`))}</p>`)}return n}function wa(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&e.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Qr=[{id:"recent",label:"Latest"},{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],xs=_(null),Ss=_([]),en=_(!1),Ce=_(null),hn=_(""),yn=_(!1),Fe=_(!0);function s_(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const a_=_(s_());function i_(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function bo(t){return t.updated_at!==t.created_at}function o_(t){const e=`${t.title} ${t.tags.join(" ")} ${t.flair??""}`.toLowerCase();return/\b(test|smoke|harness|sandbox|dummy|sample|tmp|qa|e2e)\b/.test(e)||e.includes("테스트")||e.includes("실험")}function r_(t){if(t.post_kind)return t.post_kind==="automation";const e=(t.hearth??"").toLowerCase();return t.visibility!=="internal"||!t.expires_at||!e?!1:!!(e.startsWith("mdal")||e.includes("harness"))}function Zr(t){return Fe.value?t.filter(e=>r_(e)?!1:e.post_kind||e.hearth||e.visibility||e.expires_at?!0:!o_(e)):t}async function Ki(t){Ce.value=t,xs.value=null,Ss.value=[],en.value=!0;try{const e=await lc(t);if(Ce.value!==t)return;xs.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,post_kind:e.post_kind,flair:e.flair,hearth:e.hearth,visibility:e.visibility,expires_at:e.expires_at,hearth_count:e.hearth_count},Ss.value=e.comments??[]}catch{Ce.value===t&&(xs.value=null,Ss.value=[])}finally{Ce.value===t&&(en.value=!1)}}async function ko(t){const e=hn.value.trim();if(e){yn.value=!0;try{await cc(t,a_.value,e),hn.value="",M("Comment posted","success"),await Ki(t),Kt()}catch{M("Failed to post comment","error")}finally{yn.value=!1}}}function l_(){const t=Cn.value,e=Fe.value?"Hiding automation posts":"Show automation posts";return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Qr.map(n=>i`
          <button
            class="board-sort-btn ${t===n.id?"active":""}"
            onClick=${()=>{Cn.value=n.id,Kt()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Fe.value?"is-active":""}"
          onClick=${()=>{Fe.value=!Fe.value}}
        >
          ${e}
        </button>
        <button
          class="control-btn ghost ${ze.value?"is-active":""}"
          onClick=${()=>{ze.value=!ze.value,Kt()}}
        >
          ${ze.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${Kt} disabled=${wn.value}>
          ${wn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function Ta(){var s;const t=((s=Qr.find(a=>a.id===Cn.value))==null?void 0:s.label)??Cn.value,e=Zr(An.value),n=An.value.length-e.length;return i`
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
        <strong>${Fe.value?`automation ${n} hidden`:"full feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${ze.value?"Auto reports hidden":"Full memory feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${li.value?i`<${it} timestamp=${li.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function c_({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Ho(t.id,n),Kt()}catch{M("Failed to vote","error")}};return i`
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
                ${bo(t)?i`<span class="board-meta-chip">Updated</span>`:null}
                ${t.post_kind&&t.post_kind!=="human"?i`<span class="board-meta-chip">${t.post_kind}</span>`:null}
                ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${it} timestamp=${t.created_at} /></span>
            ${bo(t)?i`<span>Updated <${it} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${i_(t.content)}</div>
      </div>
    </div>
  `}function d_({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${it} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function u_({postId:t}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${hn.value}
        onInput=${e=>{hn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&ko(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${yn.value}
      />
      <button
        onClick=${()=>ko(t)}
        disabled=${yn.value||hn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${yn.value?"...":"Post"}
      </button>
    </div>
  `}function p_({post:t}){Ce.value!==t.id&&!en.value&&Ki(t.id);const e=async n=>{try{await Ho(t.id,n),Kt()}catch{M("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>$t("memory")}>← Back to Memory</button>
      <${N} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${e_} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${t.author}</span>
            <${it} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
          </div>
          ${t.post_kind&&t.post_kind!=="human"||t.hearth||t.visibility||t.expires_at?i`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${t.post_kind&&t.post_kind!=="human"?i`<span class="board-meta-chip">${t.post_kind}</span>`:null}
                  ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                  ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
                  ${t.expires_at?i`<span class="board-meta-chip">expires <${it} timestamp=${t.expires_at} /></span>`:null}
                </div>
              `:null}
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${N} title="Comments" semanticId="memory.feed">
        ${en.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${d_} comments=${Ss.value} />`}
        <${u_} postId=${t.id} />
      <//>
    </div>
  `}function m_(){const t=Zr(An.value),e=O.value.params.post??null,n=e?t.find(s=>s.id===e)??(Ce.value===e?xs.value:null):null;return e&&!n&&Ce.value!==e&&!en.value&&Ki(e),e?n?i`
          <${Ct} surfaceId="memory" />
          <${Ta} />
          <${p_} post=${n} />
        `:i`
          <div>
            <${Ct} surfaceId="memory" />
            <${Ta} />
            <button class="back-btn" onClick=${()=>$t("memory")}>← Back to Memory</button>
            ${en.value?i`<div class="loading-indicator">Loading post...</div>`:i`<div class="empty-state">Post not found</div>`}
          </div>
        `:i`
    <div>
      <${Ct} surfaceId="memory" />
      <${Ta} />
      <${l_} />
      ${wn.value?i`<div class="loading-indicator">Loading memory feed...</div>`:t.length===0?i`<div class="empty-state">No posts in durable memory right now</div>`:i`
              <${N} title="Posts / Comments" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.map(s=>i`<${c_} key=${s.id} post=${s} />`)}
                </div>
              <//>
            `}
    </div>
  `}function tl({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,o=2*Math.PI*s,r=o*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),i`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${c}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${o}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${c}">${Math.round(t*100)}%</span>
    </div>
  `}const Ia=600*1e3,v_=1200*1e3,xo=.8;function ae(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Le(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function __(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function f_(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function g_(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function $_(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function h_(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function y_(t){var d,m;const e=ra.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,s=n?Math.max(0,Date.now()-ae(n)):Number.POSITIVE_INFINITY,a=!!((d=t.current_task)!=null&&d.trim())||e.activeAssignedCount>0;let o="watching",r="ok",c="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",r="bad",c=n?"Offline or inactive":"No recent presence"):s>v_?(o="quiet",r="bad",c=a?"Working without a fresh signal":"No fresh agent signal"):a?(o="working",r=s>Ia?"warn":"ok",c=s>Ia?"Execution looks quiet for too long":"Task and live signal aligned"):s>Ia?(o="quiet",r="warn",c="Quiet but still reachable"):t.status==="idle"&&(o="watching",r="ok",c="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:r,focus:((m=t.current_task)==null?void 0:m.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:c}}function b_(t){const e=ud.value.get(t.name)??"idle",n=vd.value.has(t.name),s=t.context_ratio??0;let a="healthy",o="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(a="critical",o="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||s>=xo)&&(a="warning",o="warn",r=s>=xo?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:a,tone:o,focus:$_(t),note:r}}function un({label:t,value:e,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function k_({item:t}){const e=t.kind==="agent"?()=>ua(t.agent.name):()=>Ni(t.keeper);return i`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?i`<span><${it} timestamp=${t.timestamp} /></span>`:i`<span>No signal</span>`}
      </div>
    </button>
  `}function So({row:t}){const{agent:e,motion:n}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>ua(e.name)}>
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
        <${_e} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${__(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?i`<span>Signal <${it} timestamp=${t.lastSignalAt} /></span>`:i`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
        ${e.last_seen?i`<span>Seen <${it} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?i`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function x_({row:t}){const{keeper:e}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Ni(e)}>
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
        <${_e} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${f_(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?i`<span>Heartbeat <${it} timestamp=${e.last_heartbeat} /></span>`:i`<span>No heartbeat</span>`}
        <span>${h_(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${g_(e.context_ratio)}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?i`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function S_(){const t=[...wt.value].map(y_).sort((u,p)=>{const v=Le(p.tone)-Le(u.tone);if(v!==0)return v;const $=p.activeTaskCount-u.activeTaskCount;return $!==0?$:ae(p.lastSignalAt)-ae(u.lastSignalAt)}),e=[...te.value].map(b_).sort((u,p)=>{const v=Le(p.tone)-Le(u.tone);if(v!==0)return v;const $=(p.keeper.context_ratio??0)-(u.keeper.context_ratio??0);return $!==0?$:ae(p.keeper.last_heartbeat)-ae(u.keeper.last_heartbeat)}),n=t.filter(u=>u.state!=="offline"),s=t.filter(u=>u.state==="offline"),a=n.length,o=t.filter(u=>u.state==="working").length,r=t.filter(u=>u.lastSignalAt&&Date.now()-ae(u.lastSignalAt)<=12e4).length,c=t.filter(u=>u.tone!=="ok"),d=e.filter(u=>u.tone!=="ok"),m=[...d.map(u=>({kind:"keeper",key:`keeper-${u.keeper.name}`,tone:u.tone,title:u.keeper.name,subtitle:`${u.note} · ${u.focus}`,timestamp:u.keeper.last_heartbeat??null,keeper:u.keeper})),...c.map(u=>({kind:"agent",key:`agent-${u.agent.name}`,tone:u.tone,title:u.agent.name,subtitle:`${u.note} · ${u.focus}`,timestamp:u.lastSignalAt,agent:u.agent}))].sort((u,p)=>{const v=Le(p.tone)-Le(u.tone);return v!==0?v:ae(p.timestamp)-ae(u.timestamp)}).slice(0,8);return i`
    <div class="agents-monitor">
      <${Ct} surfaceId="execution" />
      <div class="stats-grid">
        <${un} label="Workers online" value=${a} color="#4ade80" caption="활성 + 대기 실행 actor" />
        <${un} label="Working now" value=${o} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${un} label="Fresh signals" value=${r} color="#22d3ee" caption="최근 2분 이내 신호" />
        <${un} label="Worker alerts" value=${c.length} color=${c.length>0?"#fb7185":"#4ade80"} caption="실행 actor 경고" />
        <${un} label="Continuity alerts" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="keeper 연속성 경고" />
      </div>

      <${N} title="Execution Priorities" class="section" semanticId="execution.priority_queue">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs execution attention right now</h2>
          <p class="monitor-subheadline">Worker drift and keeper continuity risk are ranked together here, but diagnosed in separate sections below.</p>
        </div>
        <div class="monitor-alert-list">
          ${m.length===0?i`<div class="empty-state">No execution alerts right now</div>`:m.map(u=>i`<${k_} key=${u.key} item=${u} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${N} title="Workers" class="section" semanticId="execution.workers">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Live workers stay grouped here so owner drift is visible before you scan offline history.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?i`<div class="empty-state">No active workers visible</div>`:n.map(u=>i`<${So} key=${u.agent.name} row=${u} />`)}
          </div>
        <//>

        <${N} title="Continuity" class="section" semanticId="execution.continuity">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper continuity</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and handoff state are isolated from worker execution drift.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?i`<div class="empty-state">No keepers active</div>`:e.map(u=>i`<${x_} key=${u.keeper.name} row=${u} />`)}
          </div>
        <//>

        <${N} title="Offline Workers" class="section" semanticId="execution.offline">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who dropped out of the live loop</h2>
            <p class="monitor-subheadline">Offline rows stay separate so they do not drown the active execution monitor.</p>
          </div>
          <div class="monitor-list">
            ${s.length===0?i`<div class="empty-state">No offline workers right now</div>`:s.map(u=>i`<${So} key=${u.agent.name} row=${u} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Ys=_("all"),Xs=_("all"),fi=_(new Set);function A_(t){const e=new Set(fi.value);e.has(t)?e.delete(t):e.add(t),fi.value=e}const el=Rt(()=>{let t=Ke.value;return Ys.value!=="all"&&(t=t.filter(e=>e.horizon===Ys.value)),Xs.value!=="all"&&(t=t.filter(e=>e.status===Xs.value)),t}),C_=Rt(()=>{const t={short:[],mid:[],long:[]};for(const e of el.value){const n=t[e.horizon];n&&n.push(e)}return t}),w_=Rt(()=>{const t=Array.from(Yo.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function T_(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Ui(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function As(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function I_(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Ao(t){return t.toFixed(4)}function Co(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function N_(t){switch(t){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function wo(t,e){return(t.priority??4)-(e.priority??4)}function R_(t,e){const n=t.updated_at??t.created_at??"";return(e.updated_at??e.created_at??"").localeCompare(n)}function P_(t,e){return t.length<=e?t:t.slice(0,e)+"..."}function L_({goal:t}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${As(t.horizon)}">
            ${Ui(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${T_(t.priority)}</span>
          ${t.metric?i`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?i`<span class="goal-due">Due: <${it} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?i`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${_e} status=${t.status} />
        <div class="goal-updated">
          <${it} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Na({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return i`
    <${N} title="${Ui(t)} Goals (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${L_} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function M_(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>i`
          <button
            class="goal-filter-btn ${Ys.value===t?"active":""}"
            onClick=${()=>{Ys.value=t}}
          >
            ${t==="all"?"All":Ui(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>i`
          <button
            class="goal-filter-btn ${Xs.value===t?"active":""}"
            onClick=${()=>{Xs.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function D_(){const t=Ke.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return i`
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
        <div class="goal-summary-value" style="color:${As("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${As("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${As("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function E_({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return i`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${_e} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Ao(t.baseline_metric)}</span>
          <span>Current ${Ao(t.current_metric)}</span>
          <span class=${Co(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Co(t)}
          </span>
          <span>Elapsed ${I_(t.elapsed_seconds)}</span>
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
  `}function Ra({task:t}){const e=t.priority??4,n=e<=1?"p1":e===2?"p2":e===3?"p3":"p4",s=fi.value.has(t.id),a=!!t.description;return i`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${N_(e)}</span>
        <div class="kanban-card-title">${t.title}</div>
      </div>
      ${a?i`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>A_(t.id)}
        >
          ${s?t.description:P_(t.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${t.created_at?i`<${it} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function z_(){const{todo:t,inProgress:e,done:n}=Qo.value,s=[...t].sort(wo),a=[...e].sort(wo),o=[...n].sort(R_);return i`
    <${N} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${s.length===0?i`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:s.map(r=>i`<${Ra} key=${r.id} task=${r} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${a.length===0?i`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:a.map(r=>i`<${Ra} key=${r.id} task=${r} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${o.length===0?i`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:o.slice(0,20).map(r=>i`<${Ra} key=${r.id} task=${r} />`)}
          ${o.length>20?i`<div class="empty-state" style="opacity: 0.5;">...and ${o.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function j_(){const{todo:t,inProgress:e,done:n}=Qo.value,s=t.length+e.length+n.length,a=[...t,...e].filter(u=>(u.priority??4)<=2).length,o=C_.value,r=w_.value,c=Ke.value.length>0,d=r.length>0,m=Ci.value;return i`
    <div>
      <${Ct} surfaceId="planning" />

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
          onClick=${()=>{Tn(),sr()}}
          disabled=${_n.value||fn.value}
        >
          ${_n.value||fn.value?"Refreshing...":"Refresh planning data"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${z_} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          Goal Pipeline
          <span class="monitor-pill">${Ke.value.length}</span>
        </summary>
        <div>
          ${c?i`
            <${D_} />
            <${M_} />
            ${_n.value&&Ke.value.length===0?i`<div class="loading-indicator">Loading goals...</div>`:el.value.length===0?i`<div class="empty-state">No goals match the current filters</div>`:i`
                    <${Na} horizon="short" items=${o.short??[]} />
                    <${Na} horizon="mid" items=${o.mid??[]} />
                    <${Na} horizon="long" items=${o.long??[]} />
                  `}
          `:i`
            <div class="empty-state">
              No goals defined. Use <code>masc_goal_upsert</code> to create goals.
            </div>
          `}
        </div>
      </details>

      <!-- MDAL Loops in collapsible details -->
      <details class="overview-section-collapsible" open=${d}>
        <summary>
          MDAL Loops
          <span class="monitor-pill">${r.length}</span>
        </summary>
        <div>
          ${fn.value&&r.length===0?i`<div class="loading-indicator">Loading MDAL loops...</div>`:r.length===0&&(m==="error"||Ue.value)?i`<div class="empty-state">MDAL snapshot could not be loaded${Ue.value?`: ${Ue.value}`:""}. Check backend health.</div>`:r.length===0?i`<div class="empty-state">No active loops. Use <code>masc_mdal_start</code> to start a loop.</div>`:i`
                  <div class="planning-loop-list">
                    ${r.map(u=>i`<${E_} key=${u.loop_id} loop=${u} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const bn=_("debates"),Qs=_([]),Zs=_([]),ta=_(!1),kn=_(!1),Hn=_(""),xn=_(""),ea=_(null),Mt=_(null),gi=_(!1);async function fa(){ta.value=!0,Hn.value="";try{const t=await Hl();Qs.value=Array.isArray(t.debates)?t.debates:[],Zs.value=Array.isArray(t.sessions)?t.sessions:[]}catch(t){Hn.value=t instanceof Error?t.message:"Failed to load governance state"}finally{ta.value=!1}}Id(fa);async function To(){const t=xn.value.trim();if(t){kn.value=!0;try{const e=await Ec(t);xn.value="",M(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await fa()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";M(n,"error")}finally{kn.value=!1}}}async function O_(t){ea.value=t,Mt.value=null,gi.value=!0;try{Mt.value=await zc(t)}catch(e){Hn.value=e instanceof Error?e.message:"Failed to load debate detail"}finally{gi.value=!1}}function F_(){return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${Qs.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Voting sessions</span>
        <strong>${Zs.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Active view</span>
        <strong>${bn.value==="debates"?"Debates":"Voting"}</strong>
      </div>
    </div>
  `}function q_({debate:t}){const e=ea.value===t.id;return i`
    <button class="council-row ${e?"selected":""}" onClick=${()=>O_(t.id)}>
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Arguments: ${t.argument_count}</span>
          ${t.created_at?i`<span><${it} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </button>
  `}function K_({session:t}){return i`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.created_at?i`<span><${it} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function U_(){const t=bn.value;return i`
    <div class="overview-sub-tabs" style="margin-bottom:12px;">
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{bn.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{bn.value="voting"}}>Voting</button>
    </div>
  `}function H_(){return i`
    <div>
      <${N} title="Start Debate" class="section" semanticId="governance.debates">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${xn.value}
            onInput=${t=>{xn.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&To()}}
            disabled=${kn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${To}
            disabled=${kn.value||xn.value.trim()===""}
          >
            ${kn.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${fa} disabled=${ta.value}>
            ${ta.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Hn.value?i`<div class="council-error">${Hn.value}</div>`:null}
      <//>

      <${N} title="Debates" class="section" semanticId="governance.debates">
        <div class="council-list">
          ${Qs.value.length===0?i`<div class="empty-state">No debates yet</div>`:Qs.value.map(t=>i`<${q_} key=${t.id} debate=${t} />`)}
        </div>
      <//>

      <${N} title=${ea.value?`Debate Detail (${ea.value})`:"Debate Detail"} class="section" semanticId="governance.debates">
        ${gi.value?i`<div class="loading-indicator">Loading debate detail...</div>`:Mt.value?i`
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Status: ${Mt.value.status}</span>
                  <span>Total arguments: ${Mt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Support: ${Mt.value.support_count}</span>
                  <span>Oppose: ${Mt.value.oppose_count}</span>
                  <span>Neutral: ${Mt.value.neutral_count}</span>
                </div>
                ${Mt.value.summary_text?i`<pre class="council-detail">${Mt.value.summary_text}</pre>`:null}
              `:i`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function W_(){return i`
    <${N} title="Voting Sessions" class="section" semanticId="governance.voting">
      <div class="council-list">
        ${Zs.value.length===0?i`<div class="empty-state">No active sessions</div>`:Zs.value.map(t=>i`<${K_} key=${t.id} session=${t} />`)}
      </div>
    <//>
  `}function B_(){return rt(()=>{fa()},[]),i`
    <div>
      <${Ct} surfaceId="governance" />
      <${F_} />
      <${U_} />
      ${bn.value==="debates"?i`<${H_} />`:i`<${W_} />`}
    </div>
  `}const De=_(""),Pa=_("ability_check"),La=_("10"),Ma=_("12"),us=_(""),ps=_("idle"),ie=_(""),ms=_("keeper-late"),Da=_("player"),Ea=_(""),xt=_("idle"),za=_(null),vs=_(""),ja=_(""),Oa=_("player"),Fa=_(""),qa=_(""),Ka=_(""),Sn=_("20"),Ua=_("20"),Ha=_(""),_s=_("idle"),$i=_(null),nl=_("overview"),Wa=_("all"),Ba=_("all"),Ga=_("all"),G_=12e4,ga=_(null),Io=_(Date.now());function J_(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function V_(t,e){return e>0?Math.round(t/e*100):0}const Y_={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},X_={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function fs(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Q_(t){const e=t.trim().toLowerCase();return Y_[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Z_(t){const e=t.trim().toLowerCase();return X_[e]??"상황에 따라 선택되는 전술 액션입니다."}function de(t){return typeof t=="object"&&t!==null}function yt(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function Dt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function Wn(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const tf=new Set(["str","dex","con","int","wis","cha"]);function ef(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!de(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const r=a.trim();if(r){if(typeof o=="number"&&Number.isFinite(o)){s[r]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const c=Number.parseFloat(o.trim());if(Number.isFinite(c)){s[r]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),s}function nf(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(Sn.value.trim(),10);Number.isFinite(s)&&s>n&&(Sn.value=String(n))}function hi(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function sf(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function af(t){nl.value=t}function sl(t){const e=ga.value;return e==null||e<=t}function of(t){const e=ga.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function na(){ga.value=null}function al(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function rf(t,e){al(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(ga.value=Date.now()+G_,M("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function Cs(t){return sl(t)?(M("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function yi(t,e,n){return al([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function lf({hp:t,max:e}){const n=V_(t,e),s=J_(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function cf({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function df({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function il({actor:t}){var d,m,u,p;const e=(d=t.archetype)==null?void 0:d.trim(),n=(m=t.persona)==null?void 0:m.trim(),s=(u=t.portrait)==null?void 0:u.trim(),a=(p=t.background)==null?void 0:p.trim(),o=t.traits??[],r=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([v,$])=>Number.isFinite($)).filter(([v])=>!tf.has(v.toLowerCase()));return i`
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
        <${_e} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${df} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${lf} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${cf} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${fs(e)}</div>`:null}
      ${a?i`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([v,$])=>i`
                <span class="trpg-custom-stat-chip">${fs(v)} ${$}</span>
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
                  <span class="trpg-annot-name">${fs(v)}</span>
                  <span class="trpg-annot-desc">${Q_(v)}</span>
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
                  <span class="trpg-annot-name">${fs(v)}</span>
                  <span class="trpg-annot-desc">${Z_(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function uf({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function ol({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?i`<div class="empty-state" style="font-size:13px">${e}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${sf(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${hi(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${it} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function pf({events:t}){const e="__none__",n=Wa.value,s=Ba.value,a=Ga.value,o=Array.from(new Set(t.map(hi).map(p=>p.trim()).filter(p=>p!==""))).sort((p,v)=>p.localeCompare(v)),r=Array.from(new Set(t.map(p=>(p.type??"").trim()).filter(p=>p!==""))).sort((p,v)=>p.localeCompare(v)),c=t.some(p=>(p.type??"").trim()===""),d=Array.from(new Set(t.map(p=>(p.phase??"").trim()).filter(p=>p!==""))).sort((p,v)=>p.localeCompare(v)),m=t.some(p=>(p.phase??"").trim()===""),u=t.filter(p=>{if(n!=="all"&&hi(p)!==n)return!1;const v=(p.type??"").trim(),$=(p.phase??"").trim();if(s===e){if(v!=="")return!1}else if(s!=="all"&&v!==s)return!1;if(a===e){if($!=="")return!1}else if(a!=="all"&&$!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${p=>{Wa.value=p.target.value}}>
          <option value="all">all</option>
          ${o.map(p=>i`<option value=${p}>${p}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${p=>{Ba.value=p.target.value}}>
          <option value="all">all</option>
          ${c?i`<option value=${e}>(none)</option>`:null}
          ${r.map(p=>i`<option value=${p}>${p}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${p=>{Ga.value=p.target.value}}>
          <option value="all">all</option>
          ${m?i`<option value=${e}>(none)</option>`:null}
          ${d.map(p=>i`<option value=${p}>${p}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Wa.value="all",Ba.value="all",Ga.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${u.length} / 전체 ${t.length}
      </span>
    </div>
    <${ol} events=${u.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function mf({outcome:t}){if(!t)return null;const e=o=>{const r=o.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
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
  `}function vf({state:t,nowMs:e}){var m;const n=Vt.value||((m=t.session)==null?void 0:m.room)||"",s=ps.value,a=t.party??[];if(!a.find(u=>u.id===De.value)&&a.length>0){const u=a[0];u&&(De.value=u.id)}const r=async()=>{var p,v;if(!n){M("Room ID가 비어 있습니다.","error");return}if(!Cs(e))return;const u=((p=t.current_round)==null?void 0:p.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(yi("라운드 실행",n,u)){ps.value="running";try{const $=await Ac(n);$i.value=$,ps.value="ok";const x=de($.summary)?$.summary:null,k=x?Wn(x,"advanced",!1):!1,C=x?yt(x,"progress_reason",""):"";M(k?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${C?`: ${C}`:""}`,k?"success":"warning"),Ut()}catch($){$i.value=null,ps.value="error";const x=$ instanceof Error?$.message:"라운드 실행에 실패했습니다.";M(x,"error")}finally{na()}}},c=async()=>{var p,v;if(!n||!Cs(e))return;const u=((p=t.current_round)==null?void 0:p.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(yi("턴 강제 진행",n,u))try{await Tc(n),M("턴을 다음 단계로 이동했습니다.","success"),Ut()}catch{M("턴 이동에 실패했습니다.","error")}finally{na()}},d=async()=>{if(!n||!Cs(e))return;const u=De.value.trim();if(!u){M("먼저 Actor를 선택하세요.","warning");return}const p=Number.parseInt(La.value,10),v=Number.parseInt(Ma.value,10);if(Number.isNaN(p)||Number.isNaN(v)){M("stat/dc는 숫자여야 합니다.","warning");return}const $=Number.parseInt(us.value,10),x=us.value.trim()===""||Number.isNaN($)?void 0:$;try{await wc({roomId:n,actorId:u,action:Pa.value.trim()||"ability_check",statValue:p,dc:v,rawD20:x}),M("주사위 판정을 기록했습니다.","success"),Ut()}catch{M("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${u=>{Vt.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${De.value}
            onChange=${u=>{De.value=u.target.value}}
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
              value=${Pa.value}
              onInput=${u=>{Pa.value=u.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${La.value}
              onInput=${u=>{La.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Ma.value}
              onInput=${u=>{Ma.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${us.value}
              onInput=${u=>{us.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&d()}}
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

      ${s!=="idle"?i`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function _f({state:t}){var a;const e=Vt.value||((a=t.session)==null?void 0:a.room)||"",n=_s.value,s=async()=>{if(!e){M("Room ID가 비어 있습니다.","warning");return}const o=vs.value.trim(),r=ja.value.trim();if(!r&&!o){M("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(Sn.value.trim(),10),d=Number.parseInt(Ua.value.trim(),10),m=Number.isFinite(d)?Math.max(1,d):20,u=Number.isFinite(c)?Math.max(0,Math.min(m,c)):m;let p={};try{p=ef(Ha.value)}catch(v){M(v instanceof Error?v.message:"능력치 JSON 오류","error");return}_s.value="spawning";try{const v=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,$=await Ic(e,{actor_id:o||void 0,name:r||void 0,role:Oa.value,idempotencyKey:v,portrait:qa.value.trim()||void 0,background:Ka.value.trim()||void 0,hp:u,max_hp:m,alive:u>0,stats:Object.keys(p).length>0?p:void 0}),x=typeof $.actor_id=="string"?$.actor_id.trim():"";if(!x)throw new Error("생성 응답에 actor_id가 없습니다.");const k=Fa.value.trim();k&&await Nc(e,x,k),De.value=x,ie.value=x,o||(vs.value=""),_s.value="ok",M(`Actor 생성 완료: ${x}`,"success"),await Ut()}catch(v){_s.value="error",M(v instanceof Error?v.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${ja.value}
            onInput=${o=>{ja.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Oa.value}
            onChange=${o=>{Oa.value=o.target.value}}
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
            value=${Fa.value}
            onInput=${o=>{Fa.value=o.target.value}}
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
              value=${vs.value}
              onInput=${o=>{vs.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${qa.value}
              onInput=${o=>{qa.value=o.target.value}}
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
              value=${Sn.value}
              onInput=${o=>{Sn.value=o.target.value}}
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
              value=${Ua.value}
              onInput=${o=>{const r=o.target.value;Ua.value=r,nf(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Ka.value}
              onInput=${o=>{Ka.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Ha.value}
              onInput=${o=>{Ha.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function ff({state:t,nowMs:e}){var v;const n=Vt.value||((v=t.session)==null?void 0:v.room)||"",s=t.join_gate,a=za.value,o=de(a)?a:null,r=(t.party??[]).filter($=>$.role!=="dm"),c=ie.value.trim(),d=r.some($=>$.id===c),m=d?c:c?"__manual__":"",u=async()=>{const $=ie.value.trim(),x=ms.value.trim();if(!n||!$){M("Room/Actor가 필요합니다.","warning");return}xt.value="checking";try{const k=await Rc(n,$,x||void 0);za.value=k,xt.value="ok",M("참가 가능 여부를 갱신했습니다.","success")}catch(k){xt.value="error";const C=k instanceof Error?k.message:"참가 가능 여부 확인에 실패했습니다.";M(C,"error")}},p=async()=>{var R,w;const $=ie.value.trim(),x=ms.value.trim(),k=Ea.value.trim();if(!n||!$||!x){M("Room/Actor/Keeper가 필요합니다.","warning");return}if(!Cs(e))return;const C=((R=t.current_round)==null?void 0:R.phase)??((w=t.session)==null?void 0:w.status)??"unknown";if(yi("Mid-Join 승인 요청",n,C)){xt.value="requesting";try{const E=await Pc({room_id:n,actor_id:$,keeper_name:x,role:Da.value,...k?{name:k}:{}});za.value=E;const P=de(E)?Wn(E,"granted",!1):!1,L=de(E)?yt(E,"reason_code",""):"";P?M("Mid-Join이 승인되었습니다.","success"):M(`Mid-Join이 거절되었습니다${L?`: ${L}`:""}`,"warning"),xt.value=P?"ok":"error",Ut()}catch(E){xt.value="error";const P=E instanceof Error?E.message:"Mid-Join 요청에 실패했습니다.";M(P,"error")}finally{na()}}};return i`
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
            onChange=${$=>{const x=$.target.value;if(x==="__manual__"){(d||!c)&&(ie.value="");return}ie.value=x}}
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
                value=${ie.value}
                onInput=${$=>{ie.value=$.target.value}}
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
            value=${ms.value}
            onInput=${$=>{ms.value=$.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Da.value}
            onChange=${$=>{Da.value=$.target.value}}
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
            value=${Ea.value}
            onInput=${$=>{Ea.value=$.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${u} disabled=${xt.value==="checking"||xt.value==="requesting"}>
              ${xt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${p} disabled=${xt.value==="checking"||xt.value==="requesting"}>
              ${xt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Wn(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Dt(o,"effective_score",0)}/${Dt(o,"required_points",0)}</span>
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
  `:null}function dl(){const t=$i.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=de(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(de).slice(-8),o=t.canon_check,r=de(o)?o:null,c=r&&Array.isArray(r.warnings)?r.warnings.filter(L=>typeof L=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(L=>typeof L=="string").slice(0,3):[],m=n?Wn(n,"advanced",!1):!1,u=n?yt(n,"progress_reason",""):"",p=n?yt(n,"progress_detail",""):"",v=n?Dt(n,"player_successes",0):0,$=n?Dt(n,"player_required_successes",0):0,x=n?Wn(n,"dm_success",!1):!1,k=n?Dt(n,"timeouts",0):0,C=n?Dt(n,"unavailable",0):0,R=n?Dt(n,"reprompts",0):0,w=n?Dt(n,"npc_attacks",0):0,E=n?Dt(n,"keeper_timeout_sec",0):0,P=n?Dt(n,"roll_audit_count",0):0;return i`
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
        ${u?i`<div style="margin-top:4px; font-size:12px;">${u}</div>`:null}
        ${p?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${p}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${R}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${w}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${E||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${P}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(L=>{const Y=yt(L,"status","unknown"),J=yt(L,"actor_id","-"),f=yt(L,"role","-"),F=yt(L,"reason",""),tt=yt(L,"action_type",""),B=yt(L,"reply","");return i`
                <div class="trpg-round-item ${Y.includes("fallback")||Y.includes("timeout")?"failed":"active"}">
                  <span>${J} (${f})</span>
                  <span style="margin-left:auto; font-size:11px;">${Y}</span>
                  ${tt?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${tt}</div>`:null}
                  ${F?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${F}</div>`:null}
                  ${B?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${B.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${yt(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(L=>i`<div>violation: ${L}</div>`)}
                </div>`:null}
            ${c.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(L=>i`<div>warning: ${L}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function gf({state:t,nowMs:e}){var r,c,d;const n=Vt.value||((r=t.session)==null?void 0:r.room)||"",s=((c=t.current_round)==null?void 0:c.phase)??((d=t.session)==null?void 0:d.status)??"unknown",a=sl(e),o=of(e);return i`
    <${N} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="lab.trpg">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${o}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>rf(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{na(),M("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function $f({active:t}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>af(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function hf({state:t}){const e=t.party??[],n=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${N} title="관전 가이드" semanticId="lab.trpg">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${N} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${ol} events=${n.slice(-20)} />
        <//>

        ${t.map?i`
            <${N} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${uf} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${N} title="현재 라운드" semanticId="lab.trpg">
          <${cl} state=${t} />
        <//>

        <${N} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${ll} state=${t} />
        <//>

        <${N} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>i`<${il} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?i`
            <${N} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${rl} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function yf({state:t}){const e=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${N} title=${`이벤트 타임라인 (${e.length})`}>
          <${pf} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${N} title="최근 라운드 결과" semanticId="lab.trpg">
          <${dl} />
        <//>

        <${N} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${cl} state=${t} />
        <//>
      </div>
    </div>
  `}function bf({state:t,nowMs:e}){const n=t.party??[];return i`
    <div>
      <${gf} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${N} title="조작 패널" semanticId="lab.trpg">
            <${vf} state=${t} nowMs=${e} />
          <//>

          <${N} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${_f} state=${t} />
          <//>

          <${N} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${ff} state=${t} nowMs=${e} />
          <//>

          <${N} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${dl} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${N} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${ll} state=${t} />
          <//>

          <${N} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${il} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?i`
              <${N} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${rl} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function kf(){var c,d,m,u,p;const t=Vo.value,e=ri.value;if(rt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const v=window.setInterval(()=>{Io.value=Date.now()},1e3);return()=>{window.clearInterval(v)}},[]),e&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Ut()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,o=nl.value,r=Io.value;return i`
    <div>
      <${Ct} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Vt.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((m=t.session)==null?void 0:m.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Ut()}>새로고침</button>
      </div>

      <${mf} outcome=${a} />

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

      <${$f} active=${o} />

      ${o==="overview"?i`<${hf} state=${t} />`:o==="timeline"?i`<${yf} state=${t} />`:i`<${bf} state=${t} nowMs=${r} />`}
    </div>
  `}function xf(){return i`
    <div>
      <${Ct} surfaceId="lab" />
      <${N} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${N} title="TRPG" class="section" semanticId="lab.trpg">
        <${kf} />
      <//>
    </div>
  `}const sa=_(new Set(["broadcast","tasks","keepers","system"]));function Sf(t){const e=new Set(sa.value);e.has(t)?e.delete(t):e.add(t),sa.value=e}const Hi=_(null);function ul(t){Hi.value=t}function Af(t){return t.kind==="board"?"broadcast":t.kind==="tasks"?"tasks":t.kind==="keepers"?"keepers":"system"}const Cf=Rt(()=>{const t=sa.value;return Ts.value.filter(e=>t.has(Af(e)))}),wf=12e4,Tf=Rt(()=>{const t=ra.value,e=Date.now();return wt.value.map(n=>{const s=n.name.trim().toLowerCase(),a=t.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const r=a==null?void 0:a.lastActivityAt;r?o=e-new Date(r).getTime()>wf?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),If=Rt(()=>{const t=ra.value;return wt.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle").map(e=>{const n=e.name.trim().toLowerCase(),s=t.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:e.name,emoji:e.emoji??"",koreanName:e.koreanName??null,currentTask:e.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((e,n)=>{const s={hot:0,normal:1,calm:2};return s[e.pressure]-s[n.pressure]})});function No(t){return t.kind==="board"?"live-event-broadcast":t.kind==="tasks"?"live-event-task":t.kind==="keepers"?"live-event-keeper":"live-event-system"}function Nf(t){const e=t.eventType;return e==="broadcast"?"broadcast":e==="agent_joined"?"joined":e==="agent_left"?"left":e==="task_update"?"task":e==="board_post"?"post":e==="board_comment"?"comment":e==="keeper_heartbeat"?"heartbeat":e==="keeper_handoff"?"handoff":e==="keeper_compaction"?"compact":e==="keeper_guardrail"?"guardrail":t.kind==="board"?"board":t.kind==="tasks"?"task":t.kind==="keepers"?"keeper":"system"}function Rf(t){switch(t){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function Pf(){const t=Tf.value,e=Hi.value;return t.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${t.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${Rf(n.state)} ${e===n.name?"pulse-selected":""}"
          onClick=${()=>ul(e===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const Lf=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function Mf(){const t=sa.value;return i`
    <div class="activity-filter-bar">
      ${Lf.map(e=>i`
        <button
          key=${e.kind}
          class="activity-filter-btn ${e.cssClass} ${t.has(e.kind)?"active":""}"
          onClick=${()=>Sf(e.kind)}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Df(){const t=Cf.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${t.length} events</span>
      </div>
      <${Mf} />
      <div class="activity-stream-list">
        ${t.length===0?i`<div class="activity-empty">No events matching filters</div>`:t.map((e,n)=>i`
            <div
              key=${`${e.timestamp}-${n}`}
              class="activity-item ${No(e)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${No(e)}">${Nf(e)}</span>
                <span class="activity-agent">${e.agent}</span>
                <span class="activity-time">${ir(e.timestamp)}</span>
              </div>
              <div class="activity-item-text">${e.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function Ef(t){switch(t){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function zf(t){switch(t){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function jf(){const t=If.value,e=Hi.value;return i`
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
                <span class="focus-pressure-badge ${Ef(n.pressure)}">
                  ${zf(n.pressure)}
                  ${n.assignedCount>0?i` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?i`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?i`<span class="focus-activity-text">${n.lastActivityText}</span>`:i`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?i`<${it} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function Of(){const t=ue.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>Live Monitor</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${t?"connected":"disconnected"}"></span>
            ${t?"Connected":"Offline"}
          </span>
          <span class="live-stat">${wt.value.length} agents</span>
          <span class="live-stat">${aa.value} events</span>
        </div>
      </div>

      <${Pf} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${Df} />
        </div>
        <div class="live-panel-side">
          <${jf} />
        </div>
      </div>
    </div>
  `}const Ro=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],bi=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"live",label:"Live",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}];function Ff(){const t=ue.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${aa.value} events</span>
    </div>
  `}function qf({currentTab:t,currentSectionLabel:e}){const n=ue.value;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>Snapshot</h3>
        <${z} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${n?"ok":"bad"}">${n?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agents</span>
          <strong>${wt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keepers</span>
          <strong>${te.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Tasks</span>
          <strong>${qt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Events</span>
          <strong>${aa.value}</strong>
        </div>
      </div>
      <div class="rail-snapshot-copy">
        <span>Connection ${n?"healthy":"recovering"}</span>
        <span>${e} workspace active</span>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Gn(),er(),t==="command"&&(oe(),re(),(G.value==="swarm"||G.value==="warroom")&&Ot(),G.value==="warroom"&&lt()),t==="mission"&&(bs(),In()),t==="execution"&&Jt(),t==="intervene"&&(lt(),Qt()),t==="memory"&&Kt(),t==="planning"&&Tn(),t==="lab"&&Ut()}}
        >
          Refresh Now
        </button>
        <button class="rail-secondary-btn" onClick=${()=>$t("intervene")}>
          Open Intervene
        </button>
      </div>
    </section>
  `}function Kf(){const t=Ht.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return i`
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
          onClick=${()=>{lt(),Qt()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>$t("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function Uf(){const t=O.value.tab,e=bi.find(s=>s.id===t),n=Ro.find(s=>s.id===(e==null?void 0:e.group));return i`
    <aside class="dashboard-rail">
      <${Ct} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          <${z} panelId="side_rail.navigate" compact=${!0} />
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${Ro.map(s=>i`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${bi.filter(a=>a.group===s.id).map(a=>i`
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

      <${qf} currentTab=${t} currentSectionLabel=${(n==null?void 0:n.label)??"Observe"} />
      <${Kf} />
    </aside>
  `}function Hf(){switch(O.value.tab){case"mission":return i`<${uo} />`;case"execution":return i`<${S_} />`;case"live":return i`<${Of} />`;case"memory":return i`<${m_} />`;case"governance":return i`<${B_} />`;case"planning":return i`<${j_} />`;case"intervene":return i`<${t_} />`;case"command":return i`<${zv} />`;case"lab":return i`<${xf} />`;default:return i`<${uo} />`}}function Wf(){rt(()=>{xl(),jo(),nr(),Jt(),er(),bs();const n=Pd();return Ld(),()=>{Rl(),n(),Md()}},[]),rt(()=>{const n=setInterval(()=>{const s=O.value.tab;s==="command"?(oe(),re(),(G.value==="swarm"||G.value==="warroom")&&Ot(),G.value==="warroom"&&lt()):s==="mission"?bs():s==="execution"?Jt():s==="intervene"?(lt(),Qt()):s==="memory"?Kt():s==="planning"?Tn():s==="lab"&&Ut()},15e3);return()=>{clearInterval(n)}},[]),rt(()=>{const n=O.value.tab;n==="command"&&(oe(),re(),(G.value==="swarm"||G.value==="warroom")&&Ot(),G.value==="warroom"&&lt()),n==="mission"&&(bs(),In()),n==="execution"&&Jt(),n==="intervene"&&(lt(),Qt()),n==="memory"&&Kt(),n==="planning"&&Tn(),n==="lab"&&Ut()},[O.value.tab]);const t=O.value.tab,e=bi.find(n=>n.id===t);return i`
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
          <${Ff} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${Uf} />
        <main class="dashboard-main">
          ${oi.value&&!ue.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${Hf} />`}
        </main>
      </div>

      <${qu} />
      <${ou} />
      <${Zd} />
    </div>
  `}const Po=document.getElementById("app");Po&&$l(i`<${Wf} />`,Po);export{Im as _};
