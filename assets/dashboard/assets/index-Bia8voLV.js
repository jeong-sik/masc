var al=Object.defineProperty;var il=(t,e,n)=>e in t?al(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var $e=(t,e,n)=>il(t,typeof e!="symbol"?e+"":e,n);import{e as ol,_ as rl,c as f,b as yt,y as Z,d as $o,A as ll,G as cl}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const l of o.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=ol.bind(rl);const dl=["mission","proof","execution","live","memory","governance","planning","intervene","command","lab"],ho={tab:"mission",params:{},postId:null};function Mi(t){return!!t&&dl.includes(t)}function Ma(t){try{return decodeURIComponent(t)}catch{return t}}function Da(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function ul(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function yo(t,e){if(t[0]==="chains"){const o={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(o.operation=Ma(t[2])),{tab:"command",params:o,postId:null}}if(t[0]==="lab"){const o={...e};return t[1]&&(o.surface=Ma(t[1])),{tab:"lab",params:o,postId:null}}const n=t[0],s=e.tab;return{tab:Mi(n)?n:Mi(s)?s:"mission",params:e,postId:null}}function _s(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return ho;const n=Ma(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=Da(a),l=ul(s);return yo(l,o)}function pl(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...ho,params:Da(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Da(e.replace(/^\?/,""));return yo(s,a)}function bo(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const M=f(_s(window.location.hash));window.addEventListener("hashchange",()=>{M.value=_s(window.location.hash)});function lt(t,e){const n={tab:t,params:e??{}};window.location.hash=bo(n)}function ml(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function vl(){if(window.location.hash&&window.location.hash!=="#"){M.value=_s(window.location.hash);return}const t=pl(window.location.pathname,window.location.search);if(t){M.value=t;const e=bo(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",M.value=_s(window.location.hash)}const Di="masc_dashboard_sse_session_id",_l=1e3,fl=15e3,Vt=f(!1),Ys=f(0),ko=f(null),fs=f([]);function gl(){let t=sessionStorage.getItem(Di);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Di,t)),t}const $l=200;function hl(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};fs.value=[a,...fs.value].slice(0,$l)}function za(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function zi(t,e){const n=za(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function $t(t,e,n,s,a={}){hl(t,e,n,{eventType:s,...a})}let Ct=null,Pe=null,Ea=0;function xo(){Pe&&(clearTimeout(Pe),Pe=null)}function yl(){if(Pe)return;Ea++;const t=Math.min(Ea,5),e=Math.min(fl,_l*Math.pow(2,t));Pe=setTimeout(()=>{Pe=null,So()},e)}function So(){xo(),Ct&&(Ct.close(),Ct=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",gl());const a=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(a);Ct=o,o.onopen=()=>{Ct===o&&(Ea=0,Vt.value=!0)},o.onerror=()=>{Ct===o&&(Vt.value=!1,o.close(),Ct=null,yl())},o.onmessage=l=>{try{const c=JSON.parse(l.data);Ys.value++,ko.value=c,bl(c)}catch{}}}function bl(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":$t(n,"Joined","system","agent_joined");break;case"agent_left":$t(n,"Left","system","agent_left");break;case"broadcast":$t(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":$t(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":$t(n,zi("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:za(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":$t(n,zi("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:za(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":$t(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":$t(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":$t(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":$t(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:$t(n,e,"system","unknown")}}function kl(){xo(),Ct&&(Ct.close(),Ct=null),Vt.value=!1}function _(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function r(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function d(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function O(t){return typeof t=="boolean"?t:void 0}function F(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function wt(t,e=[]){if(Array.isArray(t))return t;if(!_(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Fe(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Ao(){return new URLSearchParams(window.location.search)}function Co(){const t=Ao(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function wo(){return{...Co(),"Content-Type":"application/json"}}const xl=15e3,ri=3e4,Sl=6e4,Ei=new Set([408,425,429,500,502,503,504]);class En extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);$e(this,"method");$e(this,"path");$e(this,"status");$e(this,"statusText");$e(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function li(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const l=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new En({method:l,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function Al(){var e,n;const t=Ao();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function Q(t){const e=await li(t,{headers:Co()},xl);if(!e.ok)throw new En({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Cl(t){return new Promise(e=>setTimeout(e,t))}function wl(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function Tl(t){if(t instanceof En)return t.timeout||typeof t.status=="number"&&Ei.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=wl(t.message);return e!==null&&Ei.has(e)}async function To(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!Tl(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${o}ms`,a),await Cl(o),s+=1}}async function Rt(t,e,n,s=ri){const a=await li(t,{method:"POST",headers:{...wo(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new En({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function Il(t,e,n,s=ri){const a=await li(t,{method:"POST",headers:{...wo(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new En({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function Pl(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Rl(t){var e,n,s,a,o,l,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const p=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(p)}return((c=(l=(o=t.result)==null?void 0:o.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function Qt(t,e){const n=await Il("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Sl),s=Pl(n);return Rl(s)}function Ll(){return Q("/api/v1/dashboard/shell")}function Nl(){return Q("/api/v1/dashboard/execution")}function Ml(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),Q(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function Dl(){return Q("/api/v1/dashboard/governance")}function zl(){return Q("/api/v1/dashboard/semantics")}function El(){return Q("/api/v1/dashboard/mission")}function jl(t=!1){return Q(`/api/v1/dashboard/mission/briefing${t?"?force=1":""}`)}function Ol(t,e){const n=new URLSearchParams;t&&n.set("session_id",t),e&&n.set("operation_id",e);const s=n.toString();return Q(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function ql(){return Q("/api/v1/dashboard/planning")}function Fl(){return Q("/api/v1/operator")}function Io(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return Q(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Kl(){return Q("/api/v1/command-plane")}function Ul(){return Q("/api/v1/command-plane/summary")}function Bl(){return Q("/api/v1/chains/summary")}function Hl(t){return Q(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Wl(){return Q("/api/v1/command-plane/help")}function Gl(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return Q(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function Jl(t,e){return Rt(t,e)}function Vl(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return ri}}function Qs(t){return Rt("/api/v1/operator/action",t,void 0,Vl(t))}function Yl(t,e){return Rt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function ln(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function Ql(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Xl(t){if(!_(t))return null;const e=y(t.id,"").trim(),n=y(t.author,"").trim(),s=y(t.content,"").trim();if(!e||!n)return null;const a=K(t.score,0),o=K(t.votes_up,0),l=K(t.votes_down,0),c=K(t.votes,a||o-l),p=K(t.comment_count,K(t.reply_count,0)),m=(()=>{const x=t.flair;if(typeof x=="string"&&x.trim())return x.trim();if(_(x)){const C=y(x.name,"").trim();if(C)return C}return y(t.flair_name,"").trim()||void 0})(),u=y(t.created_at_iso,"").trim()||ln(t.created_at),v=y(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?ln(t.updated_at):u),$=y(t.title,"").trim()||Ql(s),b=Array.isArray(t.tags)?t.tags.filter(x=>typeof x=="string"&&x.trim()!==""):[];return{id:e,author:n,post_kind:(()=>{const x=y(t.post_kind,"").trim().toLowerCase();return x==="automation"||x==="system"||x==="human"?x:void 0})(),title:$,content:s,tags:b,votes:c,vote_balance:a,comment_count:p,created_at:u,updated_at:v,flair:m,hearth:y(t.hearth,"").trim()||null,visibility:y(t.visibility,"").trim()||void 0,expires_at:y(t.expires_at_iso,"").trim()||(t.expires_at!==void 0&&t.expires_at!==0?ln(t.expires_at):"")||null,hearth_count:K(t.hearth_count,0)}}function Zl(t){if(!_(t))return null;const e=y(t.id,"").trim(),n=y(t.post_id,"").trim(),s=y(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:y(t.content,""),created_at:ln(t.created_at)}}async function tc(t){return To("fetchBoardPost",async()=>{const e=await Q(`/api/v1/board/${t}?format=flat`),n=_(e.post)?e.post:e,s=Xl(n)??{id:t,author:"unknown",post_kind:"human",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},o=(Array.isArray(e.comments)?e.comments:[]).map(Zl).filter(l=>l!==null);return{...s,comments:o}})}function Po(t,e){return Rt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Al()})}function ec(t,e,n){return Rt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function nc(t){const e=y(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function at(...t){for(const e of t){const n=y(e,"");if(n.trim())return n.trim()}return""}function ji(t){const e=nc(at(t.outcome,t.result,t.result_code));if(!e)return;const n=at(t.reason,t.reason_code,t.description,t.detail),s=at(t.summary,t.summary_ko,t.summary_en,t.note),a=at(t.details,t.details_text,t.text,t.note),o=at(t.winner,t.winner_name,t.actor_winner,t.winner_actor),l=at(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=at(t.raw_reason,t.raw_reason_code,t.error_message),p=(()=>{const v=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof v=="string"?[v]:Array.isArray(v)?v.map(g=>{if(typeof g=="string")return g.trim();if(_(g)){const $=y(g.summary,"").trim();if($)return $;const b=y(g.text,"").trim();if(b)return b;const x=y(g.type,"").trim();return x||y(g.event_id,"").trim()}return""}).filter(g=>g.length>0):[]})(),m=(()=>{const v=K(t.turn,Number.NaN);if(Number.isFinite(v))return v;const g=K(t.turn_number,Number.NaN);if(Number.isFinite(g))return g;const $=K(t.current_turn,Number.NaN);if(Number.isFinite($))return $;const b=K(t.round,Number.NaN);return Number.isFinite(b)?b:void 0})(),u=at(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:l||void 0,evidence:p.length>0?p:void 0,raw_reason:c||void 0,turn:m,phase:u||void 0}}function sc(t,e){const n=_(t.state)?t.state:{};if(y(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(l=>_(l)?y(l.type,"")==="session.outcome":!1),o=_(n.session_outcome)?n.session_outcome:{};if(_(o)&&Object.keys(o).length>0){const l=ji(o);if(l)return l}if(_(a))return ji(_(a.payload)?a.payload:{})}function y(t,e=""){return typeof t=="string"?t:e}function K(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function ac(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function ja(t,e=!1){return typeof t=="boolean"?t:e}function tn(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(_(e)){const n=y(e.name,"").trim(),s=y(e.id,"").trim(),a=y(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function ic(t){const e={};if(!_(t)&&!Array.isArray(t))return e;if(_(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),o=y(s,"").trim();!a||!o||(e[a]=o)}),e;for(const n of t){if(!_(n))continue;const s=at(n.to,n.target,n.actor_id,n.name,n.id),a=at(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function oc(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function _t(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const rc=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function lc(t){const e=_(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const o=s.trim();o&&(rc.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function cc(t,e){if(t!=="dice.rolled")return;const n=K(e.raw_d20,0),s=K(e.total,0),a=K(e.bonus,0),o=y(e.action,"roll"),l=K(e.dc,0);return{notation:l>0?`${o} (DC ${l})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function dc(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function uc(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function pc(t,e,n,s){const a=n||e||y(s.actor_id,"")||y(s.actor_name,"");switch(t){case"turn.action.proposed":{const o=y(s.proposed_action,y(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=y(s.reply,y(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return y(s.reply,y(s.content,y(s.text,"Narration")));case"dice.rolled":{const o=y(s.action,"roll"),l=K(s.total,0),c=K(s.dc,0),p=y(s.label,""),m=a||"actor",u=c>0?` vs DC ${c}`:"",v=p?` (${p})`:"";return`${m} ${o}: ${l}${u}${v}`}case"turn.started":return`Turn ${K(s.turn,1)} started`;case"phase.changed":return`Phase: ${y(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${y(s.name,_(s.actor)?y(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${y(s.keeper_name,y(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${y(s.keeper_name,y(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${K(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${K(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||y(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||y(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${y(s.reason_code,"unknown")}`;case"memory.signal":{const o=_(s.entity_refs)?s.entity_refs:{},l=y(o.requested_tier,""),c=y(o.effective_tier,""),p=ja(o.guardrail_applied,!1),m=y(s.summary_en,y(s.summary_ko,"Memory signal"));if(!l&&!c)return m;const u=l&&c?`${l}->${c}`:c||l;return`${m} [${u}${p?" (guardrail)":""}]`}case"world.event":{if(y(s.event_type,"")==="canon.check"){const l=y(s.status,"unknown"),c=y(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return y(s.description,y(s.summary,"World event"))}case"combat.attack":return y(s.summary,y(s.result,"Attack resolved"));case"combat.defense":return y(s.summary,y(s.result,"Defense resolved"));case"session.outcome":return y(s.summary,y(s.outcome,"Session ended"));default:{const o=dc(s);return o?`${t}: ${o}`:t}}}function mc(t,e){const n=_(t)?t:{},s=y(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=y(n.actor_name,"").trim()||e[a]||y(_(n.payload)?n.payload.actor_name:"",""),l=_(n.payload)?n.payload:{},c=y(n.ts,y(n.timestamp,new Date().toISOString())),p=y(n.phase,y(l.phase,"")),m=y(n.category,"");return{type:s,actor:o||a||y(l.actor_name,""),actor_id:a||y(l.actor_id,""),actor_name:o,seq:n.seq,room_id:y(n.room_id,""),phase:p||void 0,category:m||uc(s),visibility:y(n.visibility,y(l.visibility,"public")),event_id:y(n.event_id,""),content:pc(s,a,o,l),dice_roll:cc(s,l),timestamp:c}}function vc(t,e,n){var tt,et;const s=y(t.room_id,"")||n||"default",a=_(t.state)?t.state:{},o=_(a.party)?a.party:{},l=_(a.actor_control)?a.actor_control:{},c=_(a.join_gate)?a.join_gate:{},p=_(a.contribution_ledger)?a.contribution_ledger:{},m=Object.entries(o).map(([q,Y])=>{const k=_(Y)?Y:{},kt=_t(k,"max_hp",void 0,10),jt=_t(k,"hp",void 0,kt),te=_t(k,"max_mp",void 0,0),ee=_t(k,"mp",void 0,0),z=_t(k,"level",void 0,1),xt=_t(k,"xp",void 0,0),ne=ja(k.alive,jt>0),Xe=l[q],Ze=typeof Xe=="string"?Xe:void 0,Hn=oc(k.role,q,Ze),Wn=ac(k.generation),Gn=at(k.joined_at,k.joinedAt,k.started_at,k.startedAt),Jn=at(k.claimed_at,k.claimedAt,k.assigned_at,k.assignedAt,k.assigned_time),j=at(k.last_seen,k.lastSeen,k.last_seen_at,k.lastSeenAt,k.last_active,k.lastActive),ge=at(k.scene,k.current_scene,k.currentScene,k.world_scene,k.scene_name,k.sceneName),sl=at(k.location,k.current_location,k.currentLocation,k.position,k.zone,k.area);return{id:q,name:y(k.name,q),role:Hn,keeper:Ze,archetype:y(k.archetype,""),persona:y(k.persona,""),portrait:y(k.portrait,"")||void 0,background:y(k.background,"")||void 0,traits:tn(k.traits),skills:tn(k.skills),stats_raw:lc(k),status:ne?"active":"dead",generation:Wn,joined_at:Gn||void 0,claimed_at:Jn||void 0,last_seen:j||void 0,scene:ge||void 0,location:sl||void 0,inventory:tn(k.inventory),notes:tn(k.notes),relationships:ic(k.relationships),stats:{hp:jt,max_hp:kt,mp:ee,max_mp:te,level:z,xp:xt,strength:_t(k,"strength","str",10),dexterity:_t(k,"dexterity","dex",10),constitution:_t(k,"constitution","con",10),intelligence:_t(k,"intelligence","int",10),wisdom:_t(k,"wisdom","wis",10),charisma:_t(k,"charisma","cha",10)}}}),u=m.filter(q=>q.status!=="dead"),v=sc(t,e),g={phase_open:ja(c.phase_open,!0),min_points:K(c.min_points,3),window:y(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},$=Object.entries(p).map(([q,Y])=>{const k=_(Y)?Y:{};return{actor_id:q,score:K(k.score,0),last_reason:y(k.last_reason,"")||null,reasons:tn(k.reasons)}}),b=m.reduce((q,Y)=>(q[Y.id]=Y.name,q),{}),x=e.map(q=>mc(q,b)),w=K(a.turn,1),C=y(a.phase,"round"),A=y(a.map,""),S=_(a.world)?a.world:{},I=A||y(S.ascii_map,y(S.map,"")),R=x.filter((q,Y)=>{const k=e[Y];if(!_(k))return!1;const kt=_(k.payload)?k.payload:{};return K(kt.turn,-1)===w}),W=(R.length>0?R:x).slice(-12),B=y(a.status,"active");return{session:{id:s,room:s,status:B==="ended"?"ended":B==="paused"?"paused":"active",round:w,actors:u,created_at:((tt=x[0])==null?void 0:tt.timestamp)??new Date().toISOString()},current_round:{round_number:w,phase:C,events:W,timestamp:((et=x[x.length-1])==null?void 0:et.timestamp)??new Date().toISOString()},map:I||void 0,join_gate:g,contribution_ledger:$,outcome:v,party:u,story_log:x,history:[]}}async function _c(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await Q(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function fc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([Q(`/api/v1/trpg/state${e}`),_c(t)]);return vc(n,s,t)}function gc(t){return Rt("/api/v1/trpg/rounds/run",{room_id:t})}function $c(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function hc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Rt("/api/v1/trpg/dice/roll",e)}function yc(t,e){const n=$c();return Rt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function bc(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Rt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function kc(t,e,n){return Rt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function xc(t,e,n){const s=await Qt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Sc(t){const e=await Qt("trpg.mid_join.request",t);return JSON.parse(e)}async function Ac(t,e){await Qt("masc_broadcast",{agent_name:t,message:e})}async function Cc(t=40){return(await Qt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function wc(t,e=20){return Qt("masc_task_history",{task_id:t,limit:e})}async function Tc(t){const e=await Qt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Ic(t){return To("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await Q(`/api/v1/council/debates/${e}/summary`);if(!_(n))return null;const s=y(n.id,"").trim();return s?{id:s,topic:y(n.topic,""),status:y(n.status,"open"),support_count:K(n.support_count,0),oppose_count:K(n.oppose_count,0),neutral_count:K(n.neutral_count,0),total_arguments:K(n.total_arguments,0),created_at:ln(n.created_at_iso??n.created_at),summary_text:y(n.summary_text,"")}:null})}function Pc(t,e,n){return Qt("masc_keeper_msg",{name:t,message:e})}const Rc=f(""),Dt=f({}),it=f({}),Oa=f({}),qa=f({}),Fa=f({}),Ka=f({}),zt=f({});function st(t,e,n){t.value={...t.value,[e]:n}}function Lc(t){var n;const e=(n=r(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Nc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function ia(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!_(s))continue;const a=r(s.name);if(!a)continue;const o=r(s[e]);e==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function Mc(t){if(!_(t))return null;const e=r(t.name);return e?{name:e,trigger:r(t.trigger),outcome:r(t.outcome),summary:r(t.summary),reason:r(t.reason)}:null}function Dc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function zc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Ro(t,e,n){return r(t)??zc(e,n)}function Lo(t,e){return typeof t=="boolean"?t:e==="recover"}function gs(t){if(!_(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:r(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:Fe(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:d(t.next_eligible_at_s)??null,recoverable:Lo(t.recoverable,n),summary:Ro(t.summary,e,r(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function No(t){return _(t)?{hour:d(t.hour),checked:d(t.checked)??0,acted:d(t.acted)??0,acted_names:F(t.acted_names),activity_report:r(t.activity_report),quiet_hours_overridden:O(t.quiet_hours_overridden),skipped_reason:r(t.skipped_reason),acted_rows:ia(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:ia(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:ia(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Mc).filter(e=>e!==null):[]}:null}function Ec(t){return _(t)?{enabled:O(t.enabled)??!1,interval_s:d(t.interval_s)??0,quiet_start:d(t.quiet_start),quiet_end:d(t.quiet_end),quiet_active:O(t.quiet_active),use_planner:O(t.use_planner),delegate_llm:O(t.delegate_llm),agent_count:d(t.agent_count),agents:F(t.agents),last_tick_ago_s:d(t.last_tick_ago_s)??null,last_tick_ago:r(t.last_tick_ago),total_ticks:d(t.total_ticks),total_checkins:d(t.total_checkins),last_skip_reason:r(t.last_skip_reason)??null,last_tick_result:No(t.last_tick_result),active_self_heartbeats:F(t.active_self_heartbeats)}:null}function jc(t){return _(t)?{status:t.status,diagnostic:gs(t.diagnostic)}:null}function Oc(t){return _(t)?{recovered:O(t.recovered)??!1,skipped_reason:r(t.skipped_reason)??null,before:gs(t.before),after:gs(t.after),down:t.down,up:t.up}:null}function qc(t,e){var A,S;if(!(t!=null&&t.name))return null;const n=r((A=t.agent)==null?void 0:A.status)??r(t.status)??"unknown",s=r((S=t.agent)==null?void 0:S.error)??null,a=t.presence_keepalive??!0,o=t.keepalive_running??!1,l=t.turn_count??0,c=t.last_turn_ago_s??null,p=t.proactive_enabled??!1,m=t.proactive_cooldown_sec??0,u=t.last_proactive_ago_s??null,v=p&&u!=null?Math.max(0,m-u):null,g=l<=0||c==null?"never":c>900?"stale":"fresh",$=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,b=s??(a&&!o?"keeper keepalive is not running":null),x=n==="offline"||n==="inactive"?"offline":b?"degraded":g==="stale"?"stale":g==="never"?"idle":"healthy",w=b?Dc(b):e!=null&&e.quiet_active&&g!=="fresh"?"quiet_hours":a&&!o?"disabled":l<=0?"never_started":v!=null&&v>0?"min_gap":g==="fresh"||g==="stale"?"no_recent_activity":"unknown",C=x==="offline"||x==="degraded"||x==="stale"?"recover":w==="quiet_hours"?"manual_lodge_poke":w==="unknown"?"probe":"direct_message";return{health_state:x,quiet_reason:w,next_action_path:C,last_reply_status:g,last_reply_at:$,last_reply_preview:null,last_error:b,next_eligible_at_s:v!=null&&v>0?v:null,recoverable:Lo(void 0,C),summary:Ro(void 0,x,w),keepalive_running:o}}function Fc(t,e){if(!_(t))return null;const n=Lc(t.role),s=r(t.content)??r(t.preview);if(!s)return null;const a=Fe(t.ts_unix)??Fe(t.timestamp);return{id:`${n}-${a??"entry"}-${e}`,role:n,label:Nc(n),text:s,timestamp:a,delivery:"history"}}function Kc(t,e,n){const s=_(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,l)=>Fc(o,l)).filter(o=>o!==null):[];return{name:t,diagnostic:gs(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function Oi(t,e){const n=it.value[t]??[];it.value={...it.value,[t]:[...n,e].slice(-50)}}function Uc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Bc(t,e){const s=(it.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(o=>Uc(a,o)));it.value={...it.value,[t]:[...e,...s].slice(-50)}}function Xs(t,e){Dt.value={...Dt.value,[t]:e},Bc(t,e.history)}function qi(t,e){const n=Dt.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Xs(t,{...n,diagnostic:{...s,...e}})}async function ci(){try{await jn()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Hc(t){Rc.value=t.trim()}async function Mo(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Dt.value[n])return Dt.value[n];st(Oa,n,!0),st(zt,n,null);try{const s=await Qt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=Kc(n,s,a);return Xs(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return st(zt,n,a),null}finally{st(Oa,n,!1)}}async function Wc(t,e){const n=t.trim(),s=e.trim();if(!n||!s)return;const a=`local-${Date.now()}`;Oi(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),st(qa,n,!0),st(zt,n,null);try{const o=await Pc(n,s);it.value={...it.value,[n]:(it.value[n]??[]).map(l=>l.id===a?{...l,delivery:"delivered"}:l)},Oi(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),qi(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await ci()}catch(o){const l=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw it.value={...it.value,[n]:(it.value[n]??[]).map(c=>c.id===a?{...c,delivery:"error",error:l}:c)},qi(n,{last_reply_status:"error",last_error:l}),st(zt,n,l),o}finally{st(qa,n,!1)}}async function Gc(t,e){const n=t.trim();if(!n)return null;st(Fa,n,!0),st(zt,n,null);try{const s=await Qs({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=jc(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const l=Dt.value[n];Xs(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??it.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ci(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw st(zt,n,a),s}finally{st(Fa,n,!1)}}async function Jc(t,e){const n=t.trim();if(!n)return null;st(Ka,n,!0),st(zt,n,null);try{const s=await Qs({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Oc(s.result),o=(a==null?void 0:a.after)??null;if(o){const l=Dt.value[n];Xs(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??it.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ci(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw st(zt,n,a),s}finally{st(Ka,n,!1)}}function se(t){return(t??"").trim().toLowerCase()}function ct(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function os(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Vn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function en(t){return t.last_heartbeat??Vn(t.last_turn_ago_s)??Vn(t.last_proactive_ago_s)??Vn(t.last_handoff_ago_s)??Vn(t.last_compaction_ago_s)}function Vc(t){const e=t.title.trim();return e||os(t.content)}function Yc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Qc(t,e,n,s,a={}){var S;const o=se(t),l=e.filter(I=>se(I.assignee)===o&&(I.status==="claimed"||I.status==="in_progress")).length,c=n.filter(I=>se(I.from)===o).sort((I,R)=>ct(R.timestamp)-ct(I.timestamp))[0],p=s.filter(I=>se(I.agent)===o||se(I.author)===o).sort((I,R)=>ct(R.timestamp)-ct(I.timestamp))[0],m=(a.boardPosts??[]).filter(I=>se(I.author)===o).sort((I,R)=>ct(R.updated_at||R.created_at)-ct(I.updated_at||I.created_at))[0],u=(a.keepers??[]).filter(I=>se(I.name)===o&&en(I)!==null).sort((I,R)=>ct(en(R)??0)-ct(en(I)??0))[0],v=c?ct(c.timestamp):0,g=p?ct(p.timestamp):0,$=m?ct(m.updated_at||m.created_at):0,b=u?ct(en(u)??0):0,x=a.lastSeen?ct(a.lastSeen):0,w=((S=a.currentTask)==null?void 0:S.trim())||(l>0?`${l} claimed tasks`:null);if(v===0&&g===0&&$===0&&b===0&&x===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:w};const A=[c?{timestamp:c.timestamp,ts:v,text:os(c.content)}:null,m?{timestamp:m.updated_at||m.created_at,ts:$,text:`Post: ${os(Vc(m))}`}:null,u?{timestamp:en(u),ts:b,text:Yc(u)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:g,text:os(p.text)}:null].filter(I=>I!==null).sort((I,R)=>R.ts-I.ts)[0];return A&&A.ts>=x?{activeAssignedCount:l,lastActivityAt:A.timestamp,lastActivityText:A.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:w??"Presence heartbeat"}}const bt=f([]),It=f([]),Ke=f([]),Et=f([]),gt=f(null),Xc=f(null),Ua=f(new Map),yn=f([]),bn=f("recent"),Se=f(!0),Do=f(null),Mt=f(""),Re=f([]),cn=f(!1),zo=f(new Map),di=f("unknown"),Le=f(null),Ba=f(!1),kn=f(!1),Ha=f(!1),dn=f(!1),ui=f(null),$s=f(!1),hs=f(null),Eo=f(null),Wa=f(null),Zc=f(null),td=f(null),ed=f(null);yt(()=>bt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const jo=yt(()=>{const t=It.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),pi=yt(()=>{const t=new Map,e=It.value,n=Ke.value,s=fs.value,a=yn.value,o=Et.value;for(const l of bt.value)t.set(l.name.trim().toLowerCase(),Qc(l.name,e,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:o}));return t});function nd(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const sd=yt(()=>{const t=new Map;for(const e of Et.value)t.set(e.name,nd(e));return t}),ad=12e4;function id(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}const od=yt(()=>{const t=Date.now(),e=new Set,n=Ua.value;for(const s of Et.value){const a=id(s,n);a!=null&&t-a>ad&&e.add(s.name)}return e});function rd(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function Oo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function ld(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function cd(t){if(!_(t))return null;const e=r(t.name);return e?{name:e,agent_type:r(t.agent_type),status:Oo(t.status),current_task:r(t.current_task)??null,joined_at:r(t.joined_at),last_seen:r(t.last_seen),capabilities:F(t.capabilities),emoji:r(t.emoji),koreanName:r(t.koreanName)??r(t.korean_name),model:r(t.model),traits:F(t.traits),interests:F(t.interests),activityLevel:d(t.activityLevel)??d(t.activity_level),primaryValue:r(t.primaryValue)??r(t.primary_value)}:null}function dd(t){if(!_(t))return null;const e=r(t.id),n=r(t.title);return!e||!n?null:{id:e,title:n,status:ld(t.status),priority:d(t.priority),assignee:r(t.assignee),description:r(t.description),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function ud(t){if(!_(t))return null;const e=r(t.from)??r(t.from_agent)??"system",n=r(t.content)??"",s=r(t.timestamp)??new Date().toISOString();return{id:r(t.id),seq:d(t.seq),from:e,content:n,timestamp:s,type:r(t.type)}}function Fi(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function pd(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>Fi(s)-Fi(a)).slice(-500)}function md(t){return Array.isArray(t)?t.map(e=>{if(!_(e))return null;const n=d(e.ts_unix);if(n==null)return null;const s=_(e.handoff)?e.handoff:null;return{ts:n,context_ratio:d(e.context_ratio)??0,context_tokens:d(e.context_tokens)??0,context_max:d(e.context_max)??0,latency_ms:d(e.latency_ms)??0,generation:d(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:d(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:d(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?d(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Ki(t){if(!_(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);if(!e||!n||!s)return null;const a=r(t.quiet_reason)??null,o=r(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:Fe(t.last_reply_at)??r(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:d(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function vd(t,e){return(Array.isArray(t)?t:_(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!_(s))return null;const a=_(s.agent)?s.agent:null,o=_(s.context)?s.context:null,l=_(s.metrics_window)?s.metrics_window:void 0,c=r(s.name);if(!c)return null;const p=d(s.context_ratio)??d(o==null?void 0:o.context_ratio),m=r(s.status)??r(a==null?void 0:a.status)??"offline",u=Oo(m),v=r(s.model)??r(s.active_model)??r(s.primary_model),g=F(s.skill_secondary),$=o?{source:r(o.source),context_ratio:d(o.context_ratio),context_tokens:d(o.context_tokens),context_max:d(o.context_max),message_count:d(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,b=a?{name:r(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:r(a.error),agent_type:r(a.agent_type),status:r(a.status),current_task:r(a.current_task)??null,joined_at:r(a.joined_at),last_seen:r(a.last_seen),last_seen_ago_s:d(a.last_seen_ago_s),capabilities:F(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,x=md(s.metrics_series),w={name:c,emoji:r(s.emoji),koreanName:r(s.koreanName)??r(s.korean_name),agent_name:r(s.agent_name),trace_id:r(s.trace_id),model:v,primary_model:r(s.primary_model),active_model:r(s.active_model),next_model_hint:r(s.next_model_hint)??null,status:u,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:d(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:d(s.proactive_idle_sec),proactive_cooldown_sec:d(s.proactive_cooldown_sec),last_heartbeat:r(s.last_heartbeat)??r(a==null?void 0:a.last_seen),generation:d(s.generation),turn_count:d(s.turn_count)??d(s.total_turns),keeper_age_s:d(s.keeper_age_s),last_turn_ago_s:d(s.last_turn_ago_s),last_handoff_ago_s:d(s.last_handoff_ago_s),last_compaction_ago_s:d(s.last_compaction_ago_s),last_proactive_ago_s:d(s.last_proactive_ago_s),last_proactive_preview:r(s.last_proactive_preview)??null,context_ratio:p,context_tokens:d(s.context_tokens)??d(o==null?void 0:o.context_tokens),context_max:d(s.context_max)??d(o==null?void 0:o.context_max),context_source:r(s.context_source)??r(o==null?void 0:o.source),context:$,traits:F(s.traits),interests:F(s.interests),primaryValue:r(s.primaryValue)??r(s.primary_value),activityLevel:d(s.activityLevel)??d(s.activity_level),memory_recent_note:r(s.memory_recent_note)??null,recent_input_preview:r(s.recent_input_preview)??null,recent_output_preview:r(s.recent_output_preview)??null,recent_tool_names:F(s.recent_tool_names)??[],conversation_tail_count:d(s.conversation_tail_count),k2k_count:d(s.k2k_count),handoff_count_total:d(s.handoff_count_total)??d(s.trace_history_count),compaction_count:d(s.compaction_count),last_compaction_saved_tokens:d(s.last_compaction_saved_tokens),diagnostic:Ki(s.diagnostic),skill_primary:r(s.skill_primary)??null,skill_secondary:g,skill_reason:r(s.skill_reason)??null,metrics_series:x.length>0?x:void 0,metrics_window:l,agent:b};return w.diagnostic=Ki(s.diagnostic)??qc(w,(e==null?void 0:e.lodge)??null),w}).filter(s=>s!==null)}function qo(t){return _(t)?{...t,lodge:Ec(t.lodge)??void 0}:null}function _d(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function fd(t){if(!_(t))return null;const e=d(t.iteration);if(e==null)return null;const n=d(t.metric_before)??0,s=d(t.metric_after)??n,a=_(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:d(t.delta)??s-n,changes:r(t.changes)??"",failed_attempts:r(t.failed_attempts)??"",next_suggestion:r(t.next_suggestion)??"",elapsed_ms:d(t.elapsed_ms)??0,cost_usd:d(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:d(a.tool_call_count)??0,tool_names:F(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function gd(t){var o,l;if(!_(t))return null;const e=r(t.loop_id);if(!e)return null;const n=d(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(fd).filter(c=>c!==null):[],a=d(t.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:r(t.profile)??"unknown",status:_d(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:r(t.error_message)??r(t.error_reason)??null,stop_reason:r(t.stop_reason)??r(t.reason)??null,current_iteration:d(t.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:d(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(t.target)??"",stagnation_streak:d(t.stagnation_streak)??0,stagnation_limit:d(t.stagnation_limit)??0,elapsed_seconds:d(t.elapsed_seconds)??0,updated_at:Fe(t.updated_at)??null,stopped_at:Fe(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:d(t.latest_tool_call_count)??0,latest_tool_names:F(t.latest_tool_names)??[],session_id:r(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function jn(){Ba.value=!0;try{await Promise.all([Ko(),re()]),Eo.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{Ba.value=!1}}async function Fo(){$s.value=!0,hs.value=null;try{const t=await zl();ui.value=t,ed.value=new Date().toISOString()}catch(t){hs.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{$s.value=!1}}function $d(t){var e;return((e=ui.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function hd(t){var n;const e=((n=ui.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(o=>o.id===t);if(a)return a}return null}function yd(t){var s,a;Re.value=(Array.isArray(t.goals)?t.goals:[]).map(o=>{if(!_(o))return null;const l=r(o.id),c=r(o.title),p=r(o.horizon),m=r(o.status),u=r(o.created_at),v=r(o.updated_at);return!l||!c||!p||!m||!u||!v?null:{id:l,horizon:p,title:c,metric:r(o.metric)??null,target_value:r(o.target_value)??null,due_date:r(o.due_date)??null,priority:d(o.priority)??3,status:m,parent_goal_id:r(o.parent_goal_id)??null,last_review_note:r(o.last_review_note)??null,last_review_at:r(o.last_review_at)??null,created_at:u,updated_at:v}}).filter(o=>o!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const o of n){const l=gd(o);l&&e.set(l.loop_id,l)}zo.value=e,Le.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,di.value=Le.value?"error":e.size===0?"idle":"ready"}async function Ko(){try{const t=await Ll(),e=qo(t.status);e&&(gt.value=e)}catch(t){console.error("Dashboard shell fetch error:",t)}}async function re(){var t;try{const e=await Nl(),n=qo(e.status),s=(t=gt.value)==null?void 0:t.room;n&&(gt.value=n);const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;bt.value=(Array.isArray(e.agents)?e.agents:[]).map(cd).filter(l=>l!==null),It.value=(Array.isArray(e.tasks)?e.tasks:[]).map(dd).filter(l=>l!==null);const o=(Array.isArray(e.messages)?e.messages:[]).map(ud).filter(l=>l!==null);Ke.value=a?o:pd(Ke.value,o),Et.value=vd(e.keepers,n??gt.value),Xc.value=null,Eo.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function Ht(){kn.value=!0;try{const t=await Ml(bn.value,{excludeSystem:Se.value});yn.value=t.posts??[],Wa.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{kn.value=!1}}async function Wt(){var t;Ha.value=!0;try{const e=Mt.value||((t=gt.value)==null?void 0:t.room)||"default";Mt.value||(Mt.value=e);const n=await fc(e);Do.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Ha.value=!1}}async function mi(){cn.value=!0,dn.value=!0;try{const t=await ql();yd(t),Zc.value=new Date().toISOString(),td.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),di.value="error",Le.value=t instanceof Error?t.message:String(t)}finally{cn.value=!1,dn.value=!1}}async function Uo(){return mi()}let rs=null;function bd(t){rs=t}let ls=null;function kd(t){ls=t}let cs=null;function xd(t){cs=t}const le={};let oa=null;function ae(t,e,n=500){le[t]&&clearTimeout(le[t]),le[t]=setTimeout(()=>{e(),delete le[t]},n)}function Sd(){const t=ko.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Ua.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Ua.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&ae("execution",re),rd(e.type)&&(oa||(oa=setTimeout(()=>{jn(),ls==null||ls(),cs==null||cs(),oa=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&ae("execution",re),e.type==="broadcast"&&ae("execution",re),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&ae("execution",re),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&ae("board",Ht),e.type.startsWith("decision_")&&ae("council",()=>rs==null?void 0:rs()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&ae("mdal",Uo,350)}});return()=>{t();for(const e of Object.keys(le))clearTimeout(le[e]),delete le[e]}}let un=null;function Ad(){un||(un=setInterval(()=>{Vt.value,jn()},1e4))}function Cd(){un&&(clearInterval(un),un=null)}function wd({metric:t}){return i`
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
  `}function Td({panel:t}){return i`
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
            ${t.metrics.map(e=>i`<${wd} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function N({panelId:t,compact:e=!1,label:n="Why"}){const s=hd(t);return s?i`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${Td} panel=${s} />
    </details>
  `:$s.value?i`<span class="semantic-inline-state">Loading semantics…</span>`:null}function pt({surfaceId:t,compact:e=!1}){const n=$d(t);return n?i`
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
  `:$s.value?i`<div class="semantic-surface-card ${e?"compact":""}">Loading semantics…</div>`:hs.value?i`<div class="semantic-surface-card ${e?"compact":""}">${hs.value}</div>`:null}function T({title:t,class:e,semanticId:n,children:s}){return i`
    <div class="card ${e??""}">
      ${t?i`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?i`<${N} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${s}
    </div>
  `}function vi(t){const e=t.indexOf("-");if(e<0)return{model:t,nickname:t,isKeeper:t==="keeper"};const n=t.slice(0,e),s=t.slice(e+1);return{model:n,nickname:s,isKeeper:n==="keeper"}}function Id(t){return t==="keeper"||t.startsWith("keeper-")}const _i=f(null),Ga=f(!1),ys=f(null),Bo=f(null),Ae=f(!1),oe=f(null);let Ne=null;function Ui(){Ne!==null&&(window.clearTimeout(Ne),Ne=null)}function Pd(t=1500){Ne===null&&(Ne=window.setTimeout(()=>{Ne=null,bs(!1)},t))}function E(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function h(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function D(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Me(t){return typeof t=="boolean"?t:void 0}function G(t,e=[]){if(Array.isArray(t))return t;if(!E(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Ve(t){if(!E(t))return null;const e=h(t.kind),n=h(t.summary),s=h(t.target_type);return!e||!n||!s?null:{kind:e,severity:h(t.severity)??"warn",summary:n,target_type:s,target_id:h(t.target_id)??null,actor:h(t.actor)??null,evidence:t.evidence}}function ve(t){if(!E(t))return null;const e=h(t.action_type),n=h(t.target_type),s=h(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:h(t.target_id)??null,severity:h(t.severity)??"warn",reason:s,confirm_required:Me(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Rd(t){if(!E(t))return null;const e=h(t.session_id);return e?{session_id:e,goal:h(t.goal),status:h(t.status),health:h(t.health),scale_profile:h(t.scale_profile),control_profile:h(t.control_profile),planned_worker_count:D(t.planned_worker_count),active_agent_count:D(t.active_agent_count),last_turn_age_sec:D(t.last_turn_age_sec)??null,attention_count:D(t.attention_count),recommended_action_count:D(t.recommended_action_count),top_attention:Ve(t.top_attention),top_recommendation:ve(t.top_recommendation)}:null}function Ld(t){if(!E(t))return null;const e=h(t.session_id);if(!e)return null;const n=E(t.status)?t.status:t,s=E(n.summary)?n.summary:void 0;return{session_id:e,status:h(t.status)??h(s==null?void 0:s.status)??(E(n.session)?h(n.session.status):void 0),progress_pct:D(t.progress_pct)??D(s==null?void 0:s.progress_pct),elapsed_sec:D(t.elapsed_sec)??D(s==null?void 0:s.elapsed_sec),remaining_sec:D(t.remaining_sec)??D(s==null?void 0:s.remaining_sec),done_delta_total:D(t.done_delta_total)??D(s==null?void 0:s.done_delta_total),summary:E(t.summary)?t.summary:s,team_health:E(t.team_health)?t.team_health:E(n.team_health)?n.team_health:void 0,communication_metrics:E(t.communication_metrics)?t.communication_metrics:E(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:E(t.orchestration_state)?t.orchestration_state:E(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:E(t.cascade_metrics)?t.cascade_metrics:E(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:E(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,o])=>{const l=h(o);return l?[a,l]:null}).filter(a=>a!==null)):E(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const l=h(o);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:E(t.session)?t.session:E(n.session)?n.session:void 0,recent_events:G(t.recent_events,["events"]).filter(E)}}function Nd(t){if(!E(t))return null;const e=h(t.name);return e?{name:e,agent_name:h(t.agent_name),status:h(t.status),autonomy_level:h(t.autonomy_level),context_ratio:D(t.context_ratio),generation:D(t.generation),active_goal_ids:G(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:h(t.last_autonomous_action_at)??null,last_turn_ago_s:D(t.last_turn_ago_s),model:h(t.model)}:null}function Md(t){if(!E(t))return null;const e=h(t.confirm_token)??h(t.token);return e?{confirm_token:e,actor:h(t.actor),action_type:h(t.action_type),target_type:h(t.target_type),target_id:h(t.target_id)??null,delegated_tool:h(t.delegated_tool),created_at:h(t.created_at),preview:t.preview}:null}function Dd(t){if(!E(t))return null;const e=h(t.action_type),n=h(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:h(t.description),confirm_required:Me(t.confirm_required)}}function zd(t){const e=E(t)?t:{};return{room_health:h(e.room_health),cluster:h(e.cluster),project:h(e.project),current_room:h(e.current_room)??null,paused:Me(e.paused),tempo_interval_s:D(e.tempo_interval_s),active_agents:D(e.active_agents),keeper_pressure:D(e.keeper_pressure),active_operations:D(e.active_operations),pending_approvals:D(e.pending_approvals),incident_count:D(e.incident_count),recommended_action_count:D(e.recommended_action_count),top_attention:Ve(e.top_attention),top_action:ve(e.top_action)}}function Ed(t){const e=E(t)?t:{},n=E(e.swarm_overview)?e.swarm_overview:{};return{health:h(e.health),active_operations:D(e.active_operations),pending_approvals:D(e.pending_approvals),swarm_overview:{active_lanes:D(n.active_lanes),moving_lanes:D(n.moving_lanes),stalled_lanes:D(n.stalled_lanes),projected_lanes:D(n.projected_lanes),last_movement_at:h(n.last_movement_at)??null},top_attention:Ve(e.top_attention),top_action:ve(e.top_action),session_cards:G(e.session_cards).map(Rd).filter(s=>s!==null)}}function jd(t){const e=E(t)?t:{};return{sessions:G(e.sessions,["items"]).map(Ld).filter(n=>n!==null),keepers:G(e.keepers,["items"]).map(Nd).filter(n=>n!==null),pending_confirms:G(e.pending_confirms).map(Md).filter(n=>n!==null),available_actions:G(e.available_actions).map(Dd).filter(n=>n!==null)}}function Od(t){if(!E(t))return null;const e=h(t.id),n=h(t.kind),s=h(t.summary),a=h(t.target_type);return!e||!n||!s||!a?null:{id:e,kind:n,severity:h(t.severity)??"warn",summary:s,target_type:a,target_id:h(t.target_id)??null,top_action:ve(t.top_action),related_session_ids:G(t.related_session_ids).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),related_agent_names:G(t.related_agent_names).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),evidence_preview:G(t.evidence_preview).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),last_seen_at:h(t.last_seen_at)??null}}function qd(t){if(!E(t))return null;const e=h(t.session_id),n=h(t.goal);return!e||!n?null:{session_id:e,goal:n,room:h(t.room)??null,status:h(t.status),health:h(t.health),member_names:G(t.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:h(t.started_at)??null,elapsed_sec:D(t.elapsed_sec)??null,last_event_at:h(t.last_event_at)??null,last_event_summary:h(t.last_event_summary)??null,communication_summary:h(t.communication_summary)??null,active_count:D(t.active_count),required_count:D(t.required_count),related_attention_count:D(t.related_attention_count)??0,top_attention:Ve(t.top_attention),top_recommendation:ve(t.top_recommendation)}}function Fd(t){if(!E(t))return null;const e=h(t.agent_name);return e?{agent_name:e,status:h(t.status),where:h(t.where)??null,with_whom:G(t.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:h(t.current_work)??null,related_session_id:h(t.related_session_id)??null,related_attention_count:D(t.related_attention_count)??0,recent_output_preview:h(t.recent_output_preview)??null,recent_input_preview:h(t.recent_input_preview)??null,recent_event:h(t.recent_event)??null,recent_tool_names:G(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean)}:null}function Kd(t){if(!E(t))return null;const e=h(t.name);return e?{name:e,agent_name:h(t.agent_name)??null,status:h(t.status),generation:D(t.generation),context_ratio:D(t.context_ratio)??null,last_turn_ago_s:D(t.last_turn_ago_s)??null,current_work:h(t.current_work)??null,last_autonomous_action_at:h(t.last_autonomous_action_at)??null}:null}function Ud(t){if(!E(t))return null;const e=h(t.id),n=h(t.signal_type),s=h(t.summary),a=h(t.target_type);return!e||!n||!s||!a?null:{id:e,signal_type:n==="action"?"action":"attention",severity:h(t.severity)??"warn",summary:s,target_type:a,target_id:h(t.target_id)??null,attention:Ve(t.attention),action:ve(t.action)}}function Bd(t){const e=E(t)?t:{};return{generated_at:h(e.generated_at),summary:zd(e.summary),incidents:G(e.incidents).map(Ve).filter(n=>n!==null),recommended_actions:G(e.recommended_actions).map(ve).filter(n=>n!==null),command_focus:Ed(e.command_focus),operator_targets:jd(e.operator_targets),attention_queue:G(e.attention_queue).map(Od).filter(n=>n!==null),session_briefs:G(e.session_briefs).map(qd).filter(n=>n!==null),agent_briefs:G(e.agent_briefs).map(Fd).filter(n=>n!==null),keeper_briefs:G(e.keeper_briefs).map(Kd).filter(n=>n!==null),internal_signals:G(e.internal_signals).map(Ud).filter(n=>n!==null)}}function Hd(t){if(!E(t))return null;const e=h(t.id),n=h(t.label),s=h(t.summary);if(!e||!n||!s)return null;const a=h(t.status)??"unclear";return{id:e,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:h(t.signal_class)==="metadata_gap"||h(t.signal_class)==="mixed"||h(t.signal_class)==="operational_risk"?h(t.signal_class):void 0,evidence_quality:h(t.evidence_quality)==="strong"||h(t.evidence_quality)==="partial"||h(t.evidence_quality)==="missing"?h(t.evidence_quality):void 0,evidence:G(t.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function Wd(t){if(!E(t))return null;const e=h(t.kind),n=h(t.summary),s=h(t.scope_type),a=h(t.severity);return!e||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:e,summary:n,scope_type:s,scope_id:h(t.scope_id)??null,severity:a}}function Gd(t){const e=E(t)?t:{},n=E(e.basis)?e.basis:{},s=h(e.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:h(e.generated_at),cached:Me(e.cached),stale:Me(e.stale),refreshing:Me(e.refreshing),status:a,summary:h(e.summary)??null,model:h(e.model)??null,ttl_sec:D(e.ttl_sec),criteria:G(e.criteria).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),basis:{current_room:h(n.current_room)??null,crew_count:D(n.crew_count),agent_count:D(n.agent_count),keeper_count:D(n.keeper_count)},metadata_gap_count:D(e.metadata_gap_count),metadata_gaps:G(e.metadata_gaps).map(Wd).filter(o=>o!==null),sections:G(e.sections).map(Hd).filter(o=>o!==null),error:h(e.error)??null,last_error:h(e.last_error)??null}}async function Ho(){Ga.value=!0,ys.value=null;try{const t=await El();_i.value=Bd(t)}catch(t){ys.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{Ga.value=!1}}async function bs(t=!1){Ae.value=!0,oe.value=null;try{const e=await jl(t),n=Gd(e);Bo.value=n,n.refreshing||n.status==="pending"?Pd():Ui()}catch(e){oe.value=e instanceof Error?e.message:"Failed to load mission briefing",Ui()}finally{Ae.value=!1}}const ks="masc_dashboard_workflow_context",Jd=900*1e3;function ht(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function Ot(t){const e=ht(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function Wo(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function Ja(t){return _(t)?t:null}function Vd(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function Yd(t){if(!t)return null;try{const e=JSON.parse(t);if(!_(e))return null;const n=ht(e.id),s=ht(e.source_surface),a=ht(e.source_label),o=ht(e.summary),l=ht(e.created_at);return!n||s!=="mission"||!a||!o||!l?null:{id:n,source_surface:"mission",source_label:a,action_type:ht(e.action_type),target_type:ht(e.target_type),target_id:ht(e.target_id),focus_kind:ht(e.focus_kind),summary:o,payload_preview:ht(e.payload_preview),suggested_payload:Ja(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:l}}catch{return null}}function fi(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=Jd}function Qd(){const t=Wo(),e=Yd((t==null?void 0:t.getItem(ks))??null);return e?fi(e)?e:(t==null||t.removeItem(ks),null):null}const Go=f(Qd());function Xd(t){const e=t&&fi(t)?t:null;Go.value=e;const n=Wo();if(!n)return;if(!e){n.removeItem(ks);return}const s=Vd(e);s&&n.setItem(ks,s)}function Zd(t){if(!t)return null;const e=Ja(t.suggested_payload);if(e)return e;if(_(t.preview)){const n=Ja(t.preview.payload);if(n)return n}return null}function tu(t){if(!t)return null;const e=Ot(t.message);if(e)return e;const n=Ot(t.task_title)??Ot(t.title),s=Ot(t.task_description)??Ot(t.description),a=Ot(t.reason),o=Ot(t.priority)??Ot(t.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function Jo(t,e,n,s,a,o){return["mission",t,e??"action",n??"target",s??"room",a??"focus",o].join(":")}function Ye(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=Zd(t),o=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,l=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,c=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,p=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:Jo(n,(t==null?void 0:t.action_type)??null,o,l,c,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:o,target_id:l,focus_kind:c,summary:p,payload_preview:tu(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function eu(t,e){return e.source==="mission"&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)}function On(t){const{params:e}=t;if(e.source!=="mission")return null;const n=Go.value;if(n&&fi(n)&&eu(n,e))return n;const s=new Date().toISOString();return{id:Jo("상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,s),source_surface:"mission",source_label:"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,summary:e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function nu(t){return{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function Vo(t){const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.target_type==="room"?"summary":"swarm"}function su(t){return{source:"mission",surface:Vo(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function gi(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function Zs(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";default:return(t==null?void 0:t.trim())||"추천 액션"}}function au(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}const Ut=f(null),Nt=f(null);function J(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function ot(t){return t==="bad"||t==="offline"||t==="critical"||t==="risk"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"||t==="watch"?"warn":"ok"}function pe(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:n<86400?`${Math.round(n/3600)}h 전`:`${Math.round(n/86400)}d 전`}function iu(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:t<86400?`${Math.round(t/3600)}h`:`${Math.round(t/86400)}d`}function ou(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function ru(t){return gi(t?Ye(t,null,"상황판 추천 액션"):null)}function ta(t,e=Ye()){Xd(e),lt(t,t==="intervene"?nu(e):su(e))}function Yo(t){ta("intervene",Ye(null,t,"상황판 incident"))}function Qo(t){ta("command",Ye(null,t,"상황판 incident"))}function $i(t,e,n="상황판 추천 액션"){ta("intervene",Ye(t,e,n))}function Xo(t,e,n="상황판 추천 액션"){ta("command",Ye(t,e,n))}function Bi(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),lt(t,n)}function lu(t){return{kind:t.kind,severity:t.severity,summary:t.summary,target_type:t.target_type,target_id:t.target_id??null,actor:null,evidence:t.evidence_preview}}function Zo(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>(s.from??"").trim().toLowerCase()===n).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function cu(t){return t.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")}function du(t,e){if(!e)return!1;const n=cu(e);return new RegExp(`(?:^|[^a-z0-9_])@${n}(?![a-z0-9_-])`,"i").test(t)}function uu(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>{if((s.from??"").trim().toLowerCase()===n)return!1;const o=(s.content??"").trim().toLowerCase();return du(o,n)}).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function pu(t){return Et.value.find(e=>e.agent_name===t||e.name===t)??null}function tr(t){return bt.value.find(e=>e.name===t)??null}function er(t,e){const n=J(t,100);if(!n)return null;const s=e.find(o=>o.id===n);if(s)return`${s.id} · ${J(s.title,92)}`;const a=e.find(o=>o.title===n);return a?`${a.id} · ${J(a.title,92)}`:n}function mu(t){var c,p;const e=tr(t.agent_name),n=pu(t.agent_name),s=Zo(t.agent_name,Ke.value),a=uu(t.agent_name,Ke.value),o=vi(t.agent_name),l=(n==null?void 0:n.skill_primary)??(e!=null&&e.capabilities&&e.capabilities.length>0?e.capabilities.slice(0,3).join(", "):null)??o.model??(e==null?void 0:e.agent_type)??null;return{brief:t,agent:e,keeper:n,where:t.where??"room",withWhom:t.with_whom,currentWork:t.current_work??er((e==null?void 0:e.current_task)??null,It.value)??"명시된 current task 없음",how:l,recentInput:J(t.recent_input_preview,120)??J(a==null?void 0:a.content,120)??J(n==null?void 0:n.recent_input_preview,120)??null,recentOutput:J(t.recent_output_preview,120)??J(s==null?void 0:s.content,120)??J(n==null?void 0:n.recent_output_preview,120)??J((c=n==null?void 0:n.diagnostic)==null?void 0:c.last_reply_preview,120)??null,recentEvent:J(t.recent_event,120)??J((p=n==null?void 0:n.diagnostic)==null?void 0:p.summary,120)??null,recentTools:t.recent_tool_names.length>0?t.recent_tool_names:(n==null?void 0:n.recent_tool_names)??[]}}function vu(t){var n,s;const e=Et.value.find(a=>a.name===t.name||a.agent_name===t.agent_name)??null;return{brief:t,keeper:e,currentWork:J(t.current_work,110)??J(e==null?void 0:e.skill_primary,110)??J(e==null?void 0:e.last_proactive_reason,110)??"명시된 keeper focus 없음",recentInput:J(e==null?void 0:e.recent_input_preview,120)??null,recentOutput:J(e==null?void 0:e.recent_output_preview,120)??J((n=e==null?void 0:e.diagnostic)==null?void 0:n.last_reply_preview,120)??J(e==null?void 0:e.last_proactive_preview,120)??null,recentEvent:J(e==null?void 0:e.last_proactive_reason,120)??J((s=e==null?void 0:e.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(e==null?void 0:e.recent_tool_names)??[]}}function _u(){const t=_i.value;return t?new Map(t.session_briefs.map(e=>[e.session_id,e])):new Map}function fu(t){const e=tr(t),n=Zo(t,Ke.value),s=vi(t);return{name:t,model:s.model,nickname:s.nickname,currentTask:er((e==null?void 0:e.current_task)??null,It.value)??"agent snapshot 없음",output:J(n==null?void 0:n.content,96)}}function gu(t){Ut.value=Ut.value===t?null:t,Nt.value=null}function nr(t){Nt.value=Nt.value===t?null:t}function $u(){Ut.value=null,Nt.value=null}function Xt({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function sr(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const o=Math.floor(a/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function X({timestamp:t}){const e=sr(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return i`<span class="time-ago" title=${n}>${e}</span>`}let hu=0;const ce=f([]);function P(t,e="success",n=4e3){const s=++hu;ce.value=[...ce.value,{id:s,message:t,type:e}],setTimeout(()=>{ce.value=ce.value.filter(a=>a.id!==s)},n)}function yu(t){ce.value=ce.value.filter(e=>e.id!==t)}function bu(){const t=ce.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>yu(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const ku="masc_dashboard_agent_name",Qe=f(null),xs=f(!1),xn=f(""),Ss=f([]),Sn=f([]),De=f(""),pn=f(!1);function Ue(t){Qe.value=t,hi()}function Hi(){Qe.value=null,xn.value="",Ss.value=[],Sn.value=[],De.value=""}function xu(){const t=Qe.value;return t?bt.value.find(e=>e.name===t)??null:null}function ar(t){return t?It.value.filter(e=>e.assignee===t):[]}function ir(t){return t?Et.value.find(e=>e.agent_name===t||e.name===t)??null:null}function Su(t){if(!t)return[];const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Au(t){const e=ir(t);return e?e.recent_tool_names&&e.recent_tool_names.length>0?e.recent_tool_names:[]:[]}async function hi(){const t=Qe.value;if(t){xs.value=!0,xn.value="",Ss.value=[],Sn.value=[];try{const e=await Cc(80);Ss.value=e.filter(a=>a.includes(t)).slice(0,20);const n=ar(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await wc(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const l=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));Sn.value=s}catch(e){xn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{xs.value=!1}}}async function Wi(){var s;const t=Qe.value,e=De.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(ku))==null?void 0:s.trim())||"dashboard";pn.value=!0;try{await Ac(n,`@${t} ${e}`),De.value="",P(`Mention sent to ${t}`,"success"),hi()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";P(o,"error")}finally{pn.value=!1}}function Cu({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Xt} status=${t.status} />
    </div>
  `}function wu({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Tu(){var v,g,$,b,x,w,C;const t=Qe.value;if(!t)return null;const e=xu(),n=ir(t),s=ar(t),a=Ss.value,o=Au(t),l=Su(n),c=(e==null?void 0:e.capabilities)??[],p=((v=gt.value)==null?void 0:v.room)??"default",m=((g=gt.value)==null?void 0:g.project)??"확인 없음",u=(($=gt.value)==null?void 0:$.cluster)??"확인 없음";return i`
    <div
      class="agent-detail-overlay"
      onClick=${A=>{A.target.classList.contains("agent-detail-overlay")&&Hi()}}
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
            ${(((b=e==null?void 0:e.traits)==null?void 0:b.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(x=e==null?void 0:e.traits)==null?void 0:x.map(A=>i`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${A}</span>`)}
              </div>
            `:""}
            ${(((w=e==null?void 0:e.interests)==null?void 0:w.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(C=e==null?void 0:e.interests)==null?void 0:C.map(A=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${A}</span>`)}
              </div>
            `:""}
            ${c.length>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${c.map(A=>i`<span style="font-size:0.7rem;background:#183153;color:#7dd3fc;padding:2px 8px;border-radius:10px">${A}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?i`
                    ${e.current_task?i`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?i`<span>Last seen: <${X} timestamp=${e.last_seen} /></span>`:null}
                    <span>Room: ${p}</span>
                    <span>Project: ${m}</span>
                    <span>Cluster: ${u}</span>
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{hi()}} disabled=${xs.value}>
              ${xs.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Hi}>Close</button>
          </div>
        </div>

        ${xn.value?i`<div class="council-error">${xn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${T} title="Assigned Tasks">
            ${s.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${s.map(A=>i`<${Cu} key=${A.id} task=${A} />`)}</div>`}
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
                ${c.length>0?c.map(A=>i`<span class="pill">${A}</span>`):i`<span class="empty-state" style="font-size:12px;">No capability metadata</span>`}
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
          ${Sn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${Sn.value.map(A=>i`<${wu} key=${A.taskId} row=${A} />`)}</div>`}
        <//>

        <${T} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${De.value}
              onInput=${A=>{De.value=A.target.value}}
              onKeyDown=${A=>{A.key==="Enter"&&Wi()}}
              disabled=${pn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Wi()}}
              disabled=${pn.value||De.value.trim()===""}
            >
              ${pn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const mt=f(null),yi=f(null),Pt=f(null),An=f(!1),Yt=f(null),Cn=f(!1),Be=f(null),H=f(!1),As=f([]);let Iu=1;function Pu(t){return _(t)?{id:r(t.id),seq:d(t.seq),from:r(t.from)??r(t.from_agent)??"system",content:r(t.content)??"",timestamp:r(t.timestamp)??new Date().toISOString(),type:r(t.type)}:null}function Ru(t){return _(t)?{room_id:r(t.room_id),current_room:r(t.current_room)??r(t.room),project:r(t.project),cluster:r(t.cluster),paused:O(t.paused),pause_reason:r(t.pause_reason)??null,paused_by:r(t.paused_by)??null,paused_at:r(t.paused_at)??null}:{}}function Gi(t){if(!_(t))return;const e=Object.entries(t).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function or(t){if(!_(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function rr(t){if(!_(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:O(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Lu(t){return _(t)?{actor:r(t.actor)??null,spawn_agent:r(t.spawn_agent)??null,spawn_role:r(t.spawn_role)??null,spawn_model:r(t.spawn_model)??null,worker_class:r(t.worker_class)??null,parent_actor:r(t.parent_actor)??null,capsule_mode:r(t.capsule_mode)??null,runtime_pool:r(t.runtime_pool)??null,lane_id:r(t.lane_id)??null,controller_level:r(t.controller_level)??null,control_domain:r(t.control_domain)??null,supervisor_actor:r(t.supervisor_actor)??null,model_tier:r(t.model_tier)??null,task_profile:r(t.task_profile)??null,risk_level:r(t.risk_level)??null,routing_confidence:d(t.routing_confidence)??null,routing_reason:r(t.routing_reason)??null,status:r(t.status)??"unknown",turn_count:d(t.turn_count)??0,empty_note_turn_count:d(t.empty_note_turn_count)??0,has_turn:O(t.has_turn)??!1,last_turn_ts_iso:r(t.last_turn_ts_iso)??null}:null}function Nu(t){if(!_(t))return null;const e=r(t.session_id);return e?{session_id:e,goal:r(t.goal),status:r(t.status),health:r(t.health),scale_profile:r(t.scale_profile),control_profile:r(t.control_profile),planned_worker_count:d(t.planned_worker_count),active_agent_count:d(t.active_agent_count),last_turn_age_sec:d(t.last_turn_age_sec)??null,attention_count:d(t.attention_count),recommended_action_count:d(t.recommended_action_count),top_attention:or(t.top_attention),top_recommendation:rr(t.top_recommendation)}:null}function lr(t){const e=_(t)?t:{};return{trace_id:r(e.trace_id),target_type:r(e.target_type)??"room",target_id:r(e.target_id)??null,health:r(e.health),swarm_status:_(e.swarm_status)?e.swarm_status:void 0,attention_items:wt(e.attention_items).map(or).filter(n=>n!==null),recommended_actions:wt(e.recommended_actions).map(rr).filter(n=>n!==null),session_cards:wt(e.session_cards).map(Nu).filter(n=>n!==null),worker_cards:wt(e.worker_cards).map(Lu).filter(n=>n!==null)}}function Mu(t){if(!_(t))return null;const e=_(t.status)?t.status:void 0,n=_(t.summary)?t.summary:_(e==null?void 0:e.summary)?e.summary:void 0,s=_(t.session)?t.session:_(e==null?void 0:e.session)?e.session:void 0,a=r(t.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const o=Gi(t.report_paths)??Gi(e==null?void 0:e.report_paths),l=wt(t.recent_events,["events"]).filter(_);return{session_id:a,status:r(t.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:d(t.progress_pct)??d(n==null?void 0:n.progress_pct),elapsed_sec:d(t.elapsed_sec)??d(n==null?void 0:n.elapsed_sec),remaining_sec:d(t.remaining_sec)??d(n==null?void 0:n.remaining_sec),done_delta_total:d(t.done_delta_total)??d(n==null?void 0:n.done_delta_total),summary:n,team_health:_(t.team_health)?t.team_health:_(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:_(t.communication_metrics)?t.communication_metrics:_(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:_(t.orchestration_state)?t.orchestration_state:_(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:_(t.cascade_metrics)?t.cascade_metrics:_(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:s,recent_events:l}}function Du(t){if(!_(t))return null;const e=r(t.name);if(!e)return null;const n=_(t.context)?t.context:void 0;return{name:e,agent_name:r(t.agent_name),status:r(t.status),autonomy_level:r(t.autonomy_level),context_ratio:d(t.context_ratio)??d(n==null?void 0:n.context_ratio),generation:d(t.generation),active_goal_ids:F(t.active_goal_ids),last_autonomous_action_at:r(t.last_autonomous_action_at)??null,last_turn_ago_s:d(t.last_turn_ago_s),model:r(t.model)??r(t.active_model)??r(t.primary_model)}}function zu(t){if(!_(t))return null;const e=r(t.confirm_token)??r(t.token);return e?{confirm_token:e,actor:r(t.actor),action_type:r(t.action_type),target_type:r(t.target_type),target_id:r(t.target_id)??null,delegated_tool:r(t.delegated_tool),created_at:r(t.created_at),preview:t.preview}:null}function Eu(t){const e=_(t)?t:{};return{room:Ru(e.room),sessions:wt(e.sessions,["items","sessions"]).map(Mu).filter(n=>n!==null),keepers:wt(e.keepers,["items","keepers"]).map(Du).filter(n=>n!==null),recent_messages:wt(e.recent_messages,["messages"]).map(Pu).filter(n=>n!==null),pending_confirms:wt(e.pending_confirms,["items","confirms"]).map(zu).filter(n=>n!==null),available_actions:wt(e.available_actions,["actions"]).filter(_).map(n=>({action_type:r(n.action_type)??"unknown",target_type:r(n.target_type)??"unknown",description:r(n.description),confirm_required:O(n.confirm_required)}))}}function Yn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Ji(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Cs(t){As.value=[{...t,id:Iu++,at:new Date().toISOString()},...As.value].slice(0,20)}function cr(t){return t.confirm_required?Yn(t.preview)||"Confirmation required":Yn(t.result)||Yn(t.executed_action)||Yn(t.delegated_tool_result)||t.status}async function ut(){An.value=!0,Yt.value=null;try{const t=await Fl();mt.value=Eu(t)}catch(t){Yt.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{An.value=!1}}async function me(){Cn.value=!0,Be.value=null;try{const t=await Io({targetType:"room"});yi.value=lr(t)}catch(t){Be.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{Cn.value=!1}}async function He(t){if(!t){Pt.value=null;return}Cn.value=!0,Be.value=null;try{const e=await Io({targetType:"team_session",targetId:t,includeWorkers:!0});Pt.value=lr(e)}catch(e){Be.value=e instanceof Error?e.message:"Failed to load session digest"}finally{Cn.value=!1}}async function ju(t){var e;H.value=!0,Yt.value=null;try{const n=await Qs(t);return Cs({actor:t.actor,action_type:t.action_type,target_label:Ji(t),outcome:n.confirm_required?"preview":"executed",message:cr(n),delegated_tool:n.delegated_tool}),await ut(),await me(),(e=Pt.value)!=null&&e.target_id&&await He(Pt.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw Yt.value=s,Cs({actor:t.actor,action_type:t.action_type,target_label:Ji(t),outcome:"error",message:s}),n}finally{H.value=!1}}async function Ou(t,e){var n;H.value=!0,Yt.value=null;try{const s=await Yl(t,e);return Cs({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:cr(s),delegated_tool:s.delegated_tool}),await ut(),await me(),(n=Pt.value)!=null&&n.target_id&&await He(Pt.value.target_id),s}catch(s){const a=s instanceof Error?s.message:"Operator confirmation failed";throw Yt.value=a,Cs({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),s}finally{H.value=!1}}xd(()=>{var t;ut(),me(),(t=Pt.value)!=null&&t.target_id&&He(Pt.value.target_id)});function qu(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Fu(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Ku(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Vi(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function dr(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Uu(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function ur(t){if(!t)return null;const e=Dt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function Bu({keeper:t,showRawStatus:e=!1}){if(Z(()=>{t!=null&&t.name&&Mo(t.name)},[t==null?void 0:t.name]),!t)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Dt.value[t.name],s=ur(t),a=Oa.value[t.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${qu(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Fu((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?i` · ${dr(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?i` · next eligible ${Uu(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Hu({keeperName:t,placeholder:e}){const[n,s]=$o("");Z(()=>{t&&Mo(t)},[t]);const a=it.value[t]??[],o=qa.value[t]??!1,l=zt.value[t],c=async()=>{const p=n.trim();if(!(!t||!p)){s("");try{await Wc(t,p)}catch(m){const u=m instanceof Error?m.message:`Failed to message ${t}`;P(u,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(p=>i`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Vi(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${Vi(p)}`}>${Ku(p)}</span>
                  ${p.timestamp?i`<span class="keeper-conversation-time">${dr(p.timestamp)}</span>`:null}
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
            onClick=${()=>{c()}}
            disabled=${o||n.trim()===""||!t}
          >
            ${o?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${l?i`<div class="control-status-copy control-error-copy">${l}</div>`:null}
      </div>
    </div>
  `}function Wu({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=ur(e),a=Fa.value[e.name]??!1,o=Ka.value[e.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{Gc(e.name,t).catch(p=>{const m=p instanceof Error?p.message:`Failed to probe ${e.name}`;P(m,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{Jc(e.name,t).catch(p=>{const m=p instanceof Error?p.message:`Failed to recover ${e.name}`;P(m,"error")})}}
        disabled=${o||!c||!t.trim()}
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
  `}const bi=f(null);function ki(t){bi.value=t,Hc(t.name)}function Yi(){bi.value=null}const be=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Gu(t){if(!t)return 0;const e=be.findIndex(n=>n.level===t);return e>=0?e:0}function Ju({keeper:t}){const e=Gu(t.autonomy_level),n=be[e]??be[0];if(!n)return null;const s=(e+1)/be.length*100;return i`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${be.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${be.map((a,o)=>i`
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
  `}function ds(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Vu(t){switch(t){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(t==null?void 0:t.trim())||"action"}}function Yu(t){return t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]}function Qu(t){const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Xu({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${ds(t.context_tokens)}</div>
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
  `}function Zu({keeper:t}){var u,v;const e=t.metrics_series??[];if(e.length<2){const g=(((u=t.context)==null?void 0:u.context_ratio)??0)*100,$=g>85?"#ef4444":g>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${g.toFixed(1)}%;background:${$}"></div>
        </div>
        <span class="chart-pct">${g.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=e.length,l=e.map((g,$)=>{const b=a+$/(o-1)*(n-2*a),x=s-a-(g.context_ratio??0)*(s-2*a);return{x:b,y:x,p:g}}),c=l.map(({x:g,y:$})=>`${g.toFixed(1)},${$.toFixed(1)}`).join(" "),p=(((v=e[e.length-1])==null?void 0:v.context_ratio)??0)*100,m=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:g})=>g.is_handoff).map(({x:g})=>i`
          <line x1="${g.toFixed(1)}" y1="${a}" x2="${g.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${m}" stroke-width="1.5"/>
        ${l.filter(({p:g})=>g.is_compaction).map(({x:g,y:$})=>i`
          <circle cx="${g.toFixed(1)}" cy="${$.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}const ra=f("");function tp({keeper:t}){var a,o,l,c;const e=ra.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],s=e?n.filter(p=>p.title.toLowerCase().includes(e)||p.key.includes(e)||p.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${ra.value}
        onInput=${p=>{ra.value=p.target.value}}
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
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${ds(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${ds(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${ds(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function ep({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
  `}function np({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function sp({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Qi({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function la(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function ap({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:la(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:la(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:la(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(s=>i`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function ip({keeper:t}){var m,u,v,g,$,b,x;const e=((m=mt.value)==null?void 0:m.room)??{},n=(((u=mt.value)==null?void 0:u.available_actions)??[]).filter(w=>w.target_type==="keeper"||w.target_type==="room").slice(0,8),s=Yu(t),a=Qu(t),o=((v=t.agent)==null?void 0:v.capabilities)??[],l=e.current_room??e.room_id??((g=gt.value)==null?void 0:g.room)??"default",c=e.project??(($=gt.value)==null?void 0:$.project)??"확인 없음",p=e.cluster??((b=gt.value)==null?void 0:b.cluster)??"확인 없음";return i`
    <div class="keeper-signal-list">
      <div class="keeper-signal-row">
        <span>Room</span>
        <strong>${l}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Project</span>
        <strong>${c}</strong>
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
          ${s.length>0?s.map(w=>i`<span class="pill">${w}</span>`):i`<span style="font-size:12px; color:#888;">도구 텔레메트리 없음</span>`}
        </div>
      </div>
      ${s.length===0&&a.length>0?i`
            <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
              <span style="font-size:12px; color:#888;">Window top tools</span>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${a.map(w=>i`<span class="pill">${w}</span>`)}
              </div>
            </div>
          `:null}
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Capabilities</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${o.length>0?o.map(w=>i`<span class="pill">${w}</span>`):i`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(w=>i`<span class="pill">${Vu(w.action_type)}</span>`):i`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function pr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function op(){try{const t=await Qs({actor:pr(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=No(t.result);await jn(),e!=null&&e.skipped_reason?P(e.skipped_reason,"warning"):P(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";P(e,"error")}}function rp({keeper:t}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Bu} keeper=${t} />
          <${Wu}
            actor=${pr()}
            keeper=${t}
            onPokeLodge=${()=>{op()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Hu}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function lp(){var e,n,s;const t=bi.value;return t?i`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Yi()}}
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
            onClick=${()=>Yi()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Xu} keeper=${t} />

        ${""}
        <${Zu} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${T} title="Field Dictionary">
            <${tp} keeper=${t} />
          <//>

          ${""}
          <${T} title="Profile">
            <${Qi} traits=${t.traits??[]} label="Traits" />
            <${Qi} traits=${t.interests??[]} label="Interests" />
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
              <${T} title="Autonomy">
                <${Ju} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?i`
              <${T} title="TRPG Stats">
                <${ep} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${T} title="Equipment (${t.inventory.length})">
                <${np} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${T} title="Relationships (${Object.keys(t.relationships).length})">
                <${sp} rels=${t.relationships} />
              <//>
            `:null}

          <${T} title="Runtime Signals">
            <${ap} keeper=${t} />
          <//>

          <${T} title="Neighborhood & Tools">
            <${ip} keeper=${t} />
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
        <${rp} keeper=${t} />
      </div>
    </div>
  `:null}function cp({cluster:t,project:e,room:n,generatedAt:s}){return i`
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
        <strong>${s?pe(s):"fresh"}</strong>
      </div>
    </div>
  `}function he({label:t,value:e,detail:n,tone:s}){return i`
    <article class="mission-stat-card ${ot(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function dp(){const t=Bo.value,e=ot((t==null?void 0:t.status)??(oe.value?"bad":"warn")),n=(t==null?void 0:t.status)==="error"||(t==null?void 0:t.status)==="unavailable"&&!(t!=null&&t.cached);return i`
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
        ${t!=null&&t.generated_at?i`<span class="command-chip">${pe(t.generated_at)}</span>`:null}
        ${t!=null&&t.cached?i`<span class="command-chip">cached</span>`:null}
        ${t!=null&&t.stale?i`<span class="command-chip warn">stale</span>`:null}
      </div>

      ${oe.value?i`<div class="empty-state error">${oe.value}</div>`:null}
      ${t!=null&&t.error?i`<div class="empty-state error">${t.error}</div>`:null}
      ${t!=null&&t.summary?i`<div class="mission-inline-note">${t.summary}</div>`:null}

      ${t&&t.sections.length>0?i`
            <div class="mission-briefing-grid">
              ${t.sections.slice(0,3).map(s=>i`
                <article class="mission-briefing-section ${ot(s.status)}">
                  <div class="mission-card-head">
                    <strong>${s.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${ot(s.status)}">${s.status}</span>
                      ${s.signal_class==="metadata_gap"?i`<span class="command-chip">metadata gap</span>`:s.signal_class==="mixed"?i`<span class="command-chip warn">mixed</span>`:null}
                      ${s.evidence_quality?i`<span class="command-chip">${s.evidence_quality}</span>`:null}
                    </div>
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
          `:!Ae.value&&!oe.value?i`<div class="empty-state">판단 레이어 결과가 아직 없습니다.</div>`:null}

      ${t&&t.metadata_gaps.length>0?i`
            <details class="mission-card-disclosure compact mission-briefing-gaps">
              <summary>Observability Gaps (${t.metadata_gap_count??t.metadata_gaps.length})</summary>
              <div class="mission-list-stack">
                ${t.metadata_gaps.map(s=>i`
                  <article class="mission-briefing-gap ${s.severity==="watch"?"warn":""}">
                    <div class="mission-card-head">
                      <strong>${s.scope_type}${s.scope_id?` · ${s.scope_id}`:""}</strong>
                      <span class="command-chip ${s.severity==="watch"?"warn":""}">${s.severity}</span>
                    </div>
                    <p>${s.summary}</p>
                  </article>
                `)}
              </div>
            </details>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{bs(n)}} disabled=${Ae.value}>
          ${Ae.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{bs(!0)}} disabled=${Ae.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function up({item:t,selected:e,sessionLookup:n}){const s=lu(t),a=t.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),o=t.top_action??null;return i`
    <article class="mission-attention-card ${ot((o==null?void 0:o.severity)??t.severity)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>gu(t.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.summary}</strong>
            <div class="mission-card-target">${t.kind}${t.target_id?` · ${t.target_id}`:""}</div>
          </div>
          <span class="command-chip ${ot((o==null?void 0:o.severity)??t.severity)}">${o?ou(o):t.severity}</span>
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
            <strong>${t.last_seen_at?pe(t.last_seen_at):"n/a"}</strong>
            <small>${t.target_type}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${o?Zs(o.action_type):"판단 필요"}</strong>
            <small>${o?ru(o):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${o?i`<div class="mission-inline-note">${o.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?i`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>i`
                  <button class="mission-link-row" onClick=${()=>nr(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${l.status??"unknown"} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:i`<div class="empty-state">직접 연결된 session이 아직 없습니다.</div>`}

        ${t.related_agent_names.length>0?i`
              <div class="mission-pill-row">
                ${t.related_agent_names.slice(0,8).map(l=>i`
                  <button class="mission-pill action" onClick=${()=>Ue(l)}>${l}</button>
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
              <button class="control-btn ghost" onClick=${()=>$i(o,s,"Mission attention")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>Xo(o,s,"Mission attention")}>
                원인 보기
              </button>
            `:i`
              <button class="control-btn ghost" onClick=${()=>Yo(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Qo(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function pp({brief:t,selected:e}){var o,l;const n=t.member_names.slice(0,6).map(fu),s=t.top_recommendation??null,a=t.top_attention??null;return i`
    <article class="mission-crew-card ${ot(((o=t.top_attention)==null?void 0:o.severity)??t.health??t.status)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>nr(t.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.goal}</strong>
            <div class="mission-card-target">${t.session_id}${t.room?` · ${t.room}`:""}</div>
          </div>
          <span class="command-chip ${ot(((l=t.top_attention)==null?void 0:l.severity)??t.health??t.status)}">${t.status??"unknown"}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${t.member_names.length}</strong>
            <small>${t.member_names.slice(0,3).join(", ")||"n/a"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${iu(t.elapsed_sec)}</strong>
            <small>${t.started_at?`${pe(t.started_at)} 시작`:"시작 시각 없음"}</small>
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
        <small>${t.last_event_at?pe(t.last_event_at):"시각 없음"}</small>
      </div>

      ${t.top_attention?i`<div class="mission-inline-note">attention: ${t.top_attention.summary}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>session detail</summary>
        ${n.length>0?i`
              <div class="mission-pill-row">
                ${n.map(c=>i`
                  <button class="mission-pill action" onClick=${()=>Ue(c.name)}>
                    ${c.model!==c.nickname?`${c.model} · `:""}${c.nickname}
                  </button>
                `)}
              </div>
            `:null}

        ${n.length>0?i`
              <details class="mission-card-disclosure compact">
                <summary>member output preview</summary>
                <div class="mission-link-list">
                  ${n.map(c=>i`
                    <button class="mission-link-row" onClick=${()=>Ue(c.name)}>
                      <strong>${c.nickname}</strong>
                      <span>${c.currentTask}</span>
                      <small>${c.output??"최근 출력 없음"}</small>
                    </button>
                  `)}
                </div>
              </details>
            `:null}
      </details>

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Bi("intervene",t.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Bi("command",t.session_id)}>세션 원인 보기</button>
        ${s?i`<button class="control-btn ghost" onClick=${()=>$i(s,a,"Mission session brief")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function mp({row:t}){var s,a,o,l,c;const e=vi(t.brief.agent_name),n=t.withWhom.length>0?t.withWhom.slice(0,3).join(", "):"단독 또는 room-level";return i`
    <article class="mission-activity-card ${ot(t.brief.status??((s=t.agent)==null?void 0:s.status))}">
      <button class="mission-card-select" onClick=${()=>Ue(t.brief.agent_name)}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((a=t.agent)==null?void 0:a.emoji)??((o=t.keeper)==null?void 0:o.emoji)??""}</span>
            <div>
              <strong>${t.brief.agent_name}</strong>
              <span>${e.model!==e.nickname?`${e.model} · `:""}${e.nickname}</span>
            </div>
          </div>
          <span class="command-chip ${ot(t.brief.status??((l=t.agent)==null?void 0:l.status))}">${t.brief.status??((c=t.agent)==null?void 0:c.status)??"unknown"}</span>
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
  `}function vp({row:t}){var n,s,a,o,l,c,p,m,u,v;const e=[`gen ${t.brief.generation??((n=t.keeper)==null?void 0:n.generation)??0}`,t.brief.context_ratio!=null?`ctx ${Math.round(t.brief.context_ratio*100)}%`:((s=t.keeper)==null?void 0:s.context_ratio)!=null?`ctx ${Math.round(t.keeper.context_ratio*100)}%`:null,t.brief.last_turn_ago_s!=null?`last turn ${Math.round(t.brief.last_turn_ago_s)}s`:null].filter(g=>g!==null).join(" · ");return i`
    <article class="mission-activity-card ${ot(t.brief.status??((a=t.keeper)==null?void 0:a.status))}">
      <button class="mission-card-select" onClick=${()=>{t.keeper&&ki(t.keeper)}}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((o=t.keeper)==null?void 0:o.emoji)??""}</span>
            <div>
              <strong>${t.brief.name}</strong>
              ${(l=t.keeper)!=null&&l.koreanName?i`<span>${t.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <span class="command-chip ${ot(t.brief.status??((c=t.keeper)==null?void 0:c.status))}">${t.brief.status??((p=t.keeper)==null?void 0:p.status)??"unknown"}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 heartbeat · ${(m=t.keeper)!=null&&m.last_heartbeat?pe(t.keeper.last_heartbeat):"n/a"}</span>
          <span>${e||"continuity 정보 없음"}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${t.currentWork}</strong>
          ${(u=t.keeper)!=null&&u.skill_reason?i`<small>판단 요약 · ${J(t.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>continuity detail</summary>
        <div class="mission-activity-foot">
          <span>agent · ${t.brief.agent_name??((v=t.keeper)==null?void 0:v.agent_name)??"n/a"}</span>
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
  `}function _p({item:t}){const e=t.action??null,n=t.attention??null;return i`
    <article class="mission-action-card ${ot(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${ot(t.severity)}">
          ${t.signal_type==="action"&&e?Zs(e.action_type):(n==null?void 0:n.kind)??"signal"}
        </span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      ${e?i`<div class="mission-action-preview">${e.reason}</div>`:null}
      <div class="mission-card-actions">
        ${e?i`
              <button class="control-btn ghost" onClick=${()=>$i(e,n,"Mission internal signal")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Xo(e,n,"Mission internal signal")}>이 이슈의 원인 보기</button>
            `:n?i`
                <button class="control-btn ghost" onClick=${()=>Yo(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>Qo(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function Xi(){var g,$,b,x,w,C,A;const t=_i.value;if(Ga.value&&!t)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(ys.value&&!t)return i`<div class="empty-state error">${ys.value}</div>`;if(!t)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;Ut.value&&!t.attention_queue.some(S=>S.id===Ut.value)&&(Ut.value=null),Nt.value&&!t.session_briefs.some(S=>S.session_id===Nt.value)&&(Nt.value=null);const e=t.attention_queue.find(S=>S.id===Ut.value)??null,n=Nt.value,s=_u(),a=e?new Set(e.related_session_ids):null,o=e?new Set(e.related_agent_names):null,l=(a?t.session_briefs.filter(S=>a.has(S.session_id)):t.session_briefs).slice(0,e?8:6),c=t.agent_briefs.filter(S=>!Id(S.agent_name)).filter(S=>n?S.related_session_id===n:o&&a?o.has(S.agent_name)||(S.related_session_id?a.has(S.related_session_id):!1):!0).slice(0,n||e?10:8).map(mu),p=t.keeper_briefs.slice(0,6).map(vu),m=t.attention_queue.slice(0,6),u=t.internal_signals.slice(0,3),v=c.filter(S=>S.recentOutput).length+p.filter(S=>S.recentOutput).length;return i`
    <section class="dashboard-panel mission-view">
      <${pt} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>원인 분석과 개입 판단을 먼저 보는 landing 입니다. 문제 → 영향 session → 관련 actor 순서로 좁혀서 읽습니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${ot(t.summary.room_health)}">${t.summary.room_health??"ok"}</span>
          <span class="command-chip">${t.summary.project??"room"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?pe(t.generated_at):"fresh"}</span>
        </div>
      </div>

      <${cp}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <${dp} />

      <div class="mission-stat-grid">
        <${he} label="주의 큐" value=${m.length} detail="개입 판단이 필요한 issue" tone=${((g=m[0])==null?void 0:g.severity)??"ok"} />
        <${he} label="영향 session" value=${l.length} detail="현재 선택 기준으로 좁힌 흐름" tone=${((b=($=l[0])==null?void 0:$.top_attention)==null?void 0:b.severity)??((x=l[0])==null?void 0:x.health)??"ok"} />
        <${he} label="영향 agent" value=${c.length} detail="선택된 흐름에 연결된 actor" tone=${((w=c[0])==null?void 0:w.brief.status)??"ok"} />
        <${he} label="Keeper watch" value=${p.length} detail="continuity lane 관찰 대상" tone=${((C=p[0])==null?void 0:C.brief.status)??"ok"} />
        <${he} label="최근 output" value=${v} detail="선택된 영역에서 바로 읽을 수 있는 출력 수" tone=${v>0?"ok":"warn"} />
        <${he} label="내부 신호" value=${u.length} detail="room/system 진단은 하단 보조 lane" tone=${((A=u[0])==null?void 0:A.severity)??"ok"} />
      </div>

      ${e||n?i`
            <div class="mission-selection-bar">
              <span>현재 drill-down · ${e?e.summary:"session 선택"}${n?` · ${n}`:""}</span>
              <button class="control-btn ghost" onClick=${$u}>선택 해제</button>
            </div>
          `:null}

      <${T} title="Attention Queue" class="mission-list-card" semanticId="mission.attention_queue">
        <div class="mission-section-head">
          <h3>이슈에서 시작</h3>
          <p>문제와 경고를 먼저 보고, 여기서 session과 agent로 좁혀갑니다.</p>
        </div>
        <div class="mission-lane-stack">
          ${m.length>0?m.map(S=>i`<${up} key=${S.id} item=${S} selected=${Ut.value===S.id} sessionLookup=${s} />`):i`<div class="empty-state">지금 Mission attention queue가 비어 있습니다.</div>`}
        </div>
      <//>

      <div class="mission-human-grid">
        <${T} title="Affected Sessions" class="mission-list-card" semanticId="mission.session_briefs">
          <div class="mission-section-head">
            <h3>영향받는 session</h3>
            <p>attention과 직접 연결된 흐름만 먼저 보여주고, member preview는 한 단계 더 열었을 때만 보여줍니다.</p>
          </div>
          <div class="mission-list-stack">
            ${l.length>0?l.map(S=>i`<${pp} key=${S.session_id} brief=${S} selected=${Nt.value===S.session_id} />`):i`<div class="empty-state">현재 선택과 연결된 session이 없습니다.</div>`}
          </div>
        <//>

        <${T} title="Impacted Agents" class="mission-list-card" semanticId="mission.agent_activity">
          <div class="mission-section-head">
            <h3>관련 agent</h3>
            <p>선택된 incident 또는 session과 연결된 actor만 보여주고, input-output은 접어서 둡니다.</p>
          </div>
          <div class="mission-activity-list">
            ${c.length>0?c.map(S=>i`<${mp} key=${S.brief.agent_name} row=${S} />`):i`<div class="empty-state">현재 선택과 연결된 agent가 없습니다.</div>`}
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
            ${p.length>0?p.map(S=>i`<${vp} key=${S.brief.name} row=${S} />`):i`<div class="empty-state">지금 보이는 keeper가 없습니다.</div>`}
          </div>
        <//>

        <${T} title="Internal Signals" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>room / system 보조 신호</h3>
            <p>artifact scope drift 같은 시스템 진단은 메인 판단 근거가 아니라 보조 lane으로만 유지합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${u.length>0?u.map(S=>i`<${_p} key=${S.id} item=${S} />`):i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>lt("execution")}>실행 관찰면 보기</button>
            <button class="control-btn ghost" onClick=${()=>lt("command")}>지휘 진단면 보기</button>
          </div>
        <//>
      </div>
    </section>
  `}const mr=f(null),Va=f(!1),Ce=f(null);async function vr(t,e){Va.value=!0,Ce.value=null;try{mr.value=await Ol(t,e)}catch(n){Ce.value=n instanceof Error?n.message:String(n)}finally{Va.value=!1}}const fp="modulepreload",gp=function(t){return"/dashboard/"+t},Zi={},$p=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(m){return Promise.all(m.map(u=>Promise.resolve(u).then(v=>({status:"fulfilled",value:v}),v=>({status:"rejected",reason:v}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),p=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(m=>{if(m=gp(m),m in Zi)return;Zi[m]=!0;const u=m.endsWith(".css"),v=u?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${m}"]${v}`))return;const g=document.createElement("link");if(g.rel=u?"stylesheet":fp,u||(g.as="script"),g.crossOrigin="",g.href=m,p&&g.setAttribute("nonce",p),document.head.appendChild(g),u)return new Promise(($,b)=>{g.addEventListener("load",$),g.addEventListener("error",()=>b(new Error(`Unable to preload CSS for ${m}`)))})}))}function o(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&o(c.reason);return e().catch(o)})},xi=f(null),Lt=f(null),ws=f(!1),Ts=f(!1),Is=f(null),Ps=f(null),Ya=f(null),Rs=f(null),V=f("warroom"),qn=f(null),Qa=f(!1),Ls=f(null),_e=f(null),Ns=f(!1),Ms=f(null),Fn=f(null),Xa=f(!1),Ds=f(null),wn=f(null),zs=f(!1),Tn=f(null),ze=f(null);let an=null;function Si(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"}function _r(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function hp(){const e=_r().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function yp(){const e=_r().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function bp(t){if(_(t))return{policy_class:r(t.policy_class),approval_class:r(t.approval_class),tool_allowlist:F(t.tool_allowlist),model_allowlist:F(t.model_allowlist),requires_human_for:F(t.requires_human_for),autonomy_level:r(t.autonomy_level),escalation_timeout_sec:d(t.escalation_timeout_sec),kill_switch:O(t.kill_switch),frozen:O(t.frozen)}}function kp(t){if(_(t))return{headcount_cap:d(t.headcount_cap),active_operation_cap:d(t.active_operation_cap),max_cost_usd:d(t.max_cost_usd),max_tokens:d(t.max_tokens)}}function Ai(t){if(!_(t))return null;const e=r(t.unit_id),n=r(t.label),s=r(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:r(t.parent_unit_id)??null,leader_id:r(t.leader_id)??null,roster:F(t.roster),capability_profile:F(t.capability_profile),source:r(t.source),created_at:r(t.created_at),updated_at:r(t.updated_at),policy:bp(t.policy),budget:kp(t.budget)}}function fr(t){if(!_(t))return null;const e=Ai(t.unit);return e?{unit:e,leader_status:r(t.leader_status),roster_total:d(t.roster_total),roster_live:d(t.roster_live),active_operation_count:d(t.active_operation_count),health:r(t.health),reasons:F(t.reasons),children:Array.isArray(t.children)?t.children.map(fr).filter(n=>n!==null):[]}:null}function xp(t){if(_(t))return{total_units:d(t.total_units),company_count:d(t.company_count),platoon_count:d(t.platoon_count),squad_count:d(t.squad_count),leaf_agent_unit_count:d(t.leaf_agent_unit_count),live_agent_count:d(t.live_agent_count),managed_unit_count:d(t.managed_unit_count),active_operation_count:d(t.active_operation_count)}}function gr(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),source:r(e.source),summary:xp(e.summary),units:Array.isArray(e.units)?e.units.map(fr).filter(n=>n!==null):[]}}function Sp(t){if(!_(t))return null;const e=r(t.kind),n=r(t.status);return!e||!n?null:{kind:e,chain_id:r(t.chain_id)??null,goal:r(t.goal)??null,run_id:r(t.run_id)??null,status:n,viewer_path:r(t.viewer_path)??null,last_sync_at:r(t.last_sync_at)??null}}function ea(t){if(!_(t))return null;const e=r(t.operation_id),n=r(t.objective),s=r(t.assigned_unit_id),a=r(t.trace_id),o=r(t.status);return!e||!n||!s||!a||!o?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:r(t.autonomy_level),policy_class:r(t.policy_class),budget_class:r(t.budget_class),detachment_session_id:r(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(t.checkpoint_ref)??null,active_goal_ids:F(t.active_goal_ids),note:r(t.note)??null,created_by:r(t.created_by),source:r(t.source),status:o,chain:Sp(t.chain),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function Ap(t){if(!_(t))return null;const e=ea(t.operation);return e?{operation:e,assigned_unit_label:r(t.assigned_unit_label)}:null}function nn(t){if(_(t))return{tone:r(t.tone),pending_ops:d(t.pending_ops),blocked_ops:d(t.blocked_ops),in_flight_ops:d(t.in_flight_ops),pipeline_stalls:d(t.pipeline_stalls),bus_traffic:d(t.bus_traffic),l1_hit_rate:d(t.l1_hit_rate),invalidation_count:d(t.invalidation_count),current_pending:d(t.current_pending),current_in_flight:d(t.current_in_flight),cdb_wakeups:d(t.cdb_wakeups),total_stolen:d(t.total_stolen),avg_best_score:d(t.avg_best_score),avg_candidate_count:d(t.avg_candidate_count),best_first_operations:d(t.best_first_operations),active_sessions:d(t.active_sessions),commit_rate:d(t.commit_rate),total_speculations:d(t.total_speculations)}}function Cp(t){if(!_(t))return;const e=_(t.pipeline)?t.pipeline:void 0,n=_(t.cache)?t.cache:void 0,s=_(t.ooo)?t.ooo:void 0,a=_(t.speculative)?t.speculative:void 0,o=_(t.search_fabric)?t.search_fabric:void 0,l=_(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:d(e.total_ops),completed_ops:d(e.completed_ops),stalled_cycles:d(e.stalled_cycles),hazards_detected:d(e.hazards_detected),forwarding_used:d(e.forwarding_used),pipeline_flushes:d(e.pipeline_flushes),ipc:d(e.ipc)}:void 0,cache:n?{total_reads:d(n.total_reads),total_writes:d(n.total_writes),l1_hit_rate:d(n.l1_hit_rate),invalidation_count:d(n.invalidation_count),writeback_count:d(n.writeback_count),bus_traffic:d(n.bus_traffic)}:void 0,ooo:s?{agent_count:d(s.agent_count),total_added:d(s.total_added),total_issued:d(s.total_issued),total_completed:d(s.total_completed),total_stolen:d(s.total_stolen),cdb_wakeups:d(s.cdb_wakeups),stall_cycles:d(s.stall_cycles),global_cdb_events:d(s.global_cdb_events),current_pending:d(s.current_pending),current_in_flight:d(s.current_in_flight)}:void 0,speculative:a?{total_speculations:d(a.total_speculations),total_commits:d(a.total_commits),total_aborts:d(a.total_aborts),commit_rate:d(a.commit_rate),total_fast_calls:d(a.total_fast_calls),total_cost_usd:d(a.total_cost_usd),active_sessions:d(a.active_sessions)}:void 0,search_fabric:o?{total_operations:d(o.total_operations),best_first_operations:d(o.best_first_operations),legacy_operations:d(o.legacy_operations),blocked_operations:d(o.blocked_operations),ready_operations:d(o.ready_operations),research_pipeline_operations:d(o.research_pipeline_operations),avg_candidate_count:d(o.avg_candidate_count),avg_best_score:d(o.avg_best_score),top_stage:r(o.top_stage)??null}:void 0,signals:l?{issue_pressure:nn(l.issue_pressure),cache_contention:nn(l.cache_contention),scheduler_efficiency:nn(l.scheduler_efficiency),routing_confidence:nn(l.routing_confidence),speculative_posture:nn(l.speculative_posture)}:void 0}}function $r(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),active:d(n.active),paused:d(n.paused),managed:d(n.managed),projected:d(n.projected)}:void 0,microarch:Cp(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(Ap).filter(s=>s!==null):[]}}function hr(t){if(!_(t))return null;const e=r(t.detachment_id),n=r(t.operation_id),s=r(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:r(t.leader_id)??null,roster:F(t.roster),session_id:r(t.session_id)??null,checkpoint_ref:r(t.checkpoint_ref)??null,runtime_kind:r(t.runtime_kind)??null,runtime_ref:r(t.runtime_ref)??null,source:r(t.source),status:r(t.status),last_event_at:r(t.last_event_at)??null,last_progress_at:r(t.last_progress_at)??null,heartbeat_deadline:r(t.heartbeat_deadline)??null,created_at:r(t.created_at),updated_at:r(t.updated_at)}}function wp(t){if(!_(t))return null;const e=hr(t.detachment);return e?{detachment:e,assigned_unit_label:r(t.assigned_unit_label),operation:ea(t.operation)}:null}function yr(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),active:d(n.active),projected:d(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(wp).filter(s=>s!==null):[]}}function Tp(t){if(!_(t))return null;const e=r(t.decision_id),n=r(t.trace_id),s=r(t.requested_action),a=r(t.scope_type),o=r(t.scope_id);return!e||!n||!s||!a||!o?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:r(t.operation_id)??null,target_unit_id:r(t.target_unit_id)??null,requested_by:r(t.requested_by),status:r(t.status),reason:r(t.reason)??null,source:r(t.source),detail:t.detail,created_at:r(t.created_at),decided_at:r(t.decided_at)??null,expires_at:r(t.expires_at)??null}}function br(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),pending:d(n.pending),approved:d(n.approved),denied:d(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(Tp).filter(s=>s!==null):[]}}function Ip(t){if(!_(t))return null;const e=Ai(t.unit);return e?{unit:e,roster_total:d(t.roster_total),roster_live:d(t.roster_live),headcount_cap:d(t.headcount_cap),active_operations:d(t.active_operations),active_operation_cap:d(t.active_operation_cap),utilization:d(t.utilization)}:null}function Pp(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(Ip).filter(n=>n!==null):[]}}function Rp(t){if(!_(t))return null;const e=r(t.alert_id);return e?{alert_id:e,severity:r(t.severity),kind:r(t.kind),scope_type:r(t.scope_type),scope_id:r(t.scope_id),title:r(t.title),detail:r(t.detail),timestamp:r(t.timestamp)}:null}function kr(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),bad:d(n.bad),warn:d(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(Rp).filter(s=>s!==null):[]}}function xr(t){if(!_(t))return null;const e=r(t.event_id),n=r(t.trace_id),s=r(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:r(t.operation_id)??null,unit_id:r(t.unit_id)??null,actor:r(t.actor)??null,source:r(t.source),timestamp:r(t.timestamp),detail:t.detail}}function Lp(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),events:Array.isArray(e.events)?e.events.map(xr).filter(n=>n!==null):[]}}function Np(t){if(!_(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function Mp(t){if(!_(t))return null;const e=r(t.lane_id),n=r(t.label),s=r(t.kind),a=r(t.phase),o=r(t.motion_state),l=r(t.source_of_truth),c=r(t.movement_reason),p=r(t.current_step);if(!e||!n||!s||!a||!o||!l||!c||!p)return null;const m=_(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:O(t.present)??!1,phase:a,motion_state:o,source_of_truth:l,last_movement_at:r(t.last_movement_at)??null,movement_reason:c,current_step:p,blockers:F(t.blockers),counts:{operations:d(m.operations),detachments:d(m.detachments),workers:d(m.workers),approvals:d(m.approvals),alerts:d(m.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(Np).filter(u=>u!==null):[]}}function Dp(t){if(!_(t))return null;const e=r(t.event_id),n=r(t.lane_id),s=r(t.kind),a=r(t.timestamp),o=r(t.title),l=r(t.detail),c=r(t.tone),p=r(t.source);return!e||!n||!s||!a||!o||!l||!c||!p?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:o,detail:l,tone:c,source:p}}function zp(t){if(!_(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,lane_ids:F(t.lane_ids),count:d(t.count)??0}}function Sr(t){if(!_(t))return;const e=_(t.overview)?t.overview:{},n=_(t.gaps)?t.gaps:{},s=_(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:r(t.generated_at),overview:{active_lanes:d(e.active_lanes),moving_lanes:d(e.moving_lanes),stalled_lanes:d(e.stalled_lanes),projected_lanes:d(e.projected_lanes),last_movement_at:r(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(Mp).filter(a=>a!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(Dp).filter(a=>a!==null):[],gaps:{count:d(n.count),items:Array.isArray(n.items)?n.items.map(zp).filter(a=>a!==null):[]},recommended_next_action:s?{tool:r(s.tool)??"masc_operator_snapshot",label:r(s.label)??"Observe operator state",reason:r(s.reason)??"",lane_id:r(s.lane_id)??null}:void 0}}function Ep(t){if(!_(t))return;const e=_(t.workers)?t.workers:{},n=O(t.pass);return{status:r(t.status)??"missing",source:r(t.source)??"none",run_id:r(t.run_id)??null,captured_at:r(t.captured_at)??null,...n!==void 0?{pass:n}:{},...d(t.peak_hot_slots)!=null?{peak_hot_slots:d(t.peak_hot_slots)}:{},...d(t.ctx_per_slot)!=null?{ctx_per_slot:d(t.ctx_per_slot)}:{},workers:{expected:d(e.expected),joined:d(e.joined),current_task_bound:d(e.current_task_bound),fresh_heartbeats:d(e.fresh_heartbeats),done:d(e.done),final:d(e.final)},artifact_ref:r(t.artifact_ref)??null,missing_reason:r(t.missing_reason)??null}}function jp(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),topology:gr(e.topology),operations:$r(e.operations),detachments:yr(e.detachments),alerts:kr(e.alerts),decisions:br(e.decisions),capacity:Pp(e.capacity),traces:Lp(e.traces),swarm_status:Sr(e.swarm_status)}}function Op(t){const e=_(t)?t:{},n=gr(e.topology),s=$r(e.operations),a=yr(e.detachments),o=kr(e.alerts),l=br(e.decisions);return{version:r(e.version),generated_at:r(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:Sr(e.swarm_status),swarm_proof:Ep(e.swarm_proof)}}function qp(t){return _(t)?{chain_id:r(t.chain_id)??null,started_at:d(t.started_at)??null,progress:d(t.progress)??null,elapsed_sec:d(t.elapsed_sec)??null}:null}function Ar(t){if(!_(t))return null;const e=r(t.event);return e?{event:e,chain_id:r(t.chain_id)??null,timestamp:r(t.timestamp)??null,duration_ms:d(t.duration_ms)??null,message:r(t.message)??null,tokens:d(t.tokens)??null}:null}function Fp(t){if(!_(t))return null;const e=ea(t.operation);return e?{operation:e,runtime:qp(t.runtime),history:Ar(t.history),mermaid:r(t.mermaid)??null,preview_run:Cr(t.preview_run)}:null}function Kp(t){const e=_(t)?t:{};return{status:r(e.status)??"disconnected",base_url:r(e.base_url)??null,message:r(e.message)??null}}function Up(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),connection:Kp(e.connection),summary:n?{linked_operations:d(n.linked_operations),active_chains:d(n.active_chains),running_operations:d(n.running_operations),recent_failures:d(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(Fp).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(Ar).filter(s=>s!==null):[]}}function Bp(t){if(!_(t))return null;const e=r(t.id);return e?{id:e,type:r(t.type),status:r(t.status),duration_ms:d(t.duration_ms)??null,error:r(t.error)??null}:null}function Cr(t){if(!_(t))return null;const e=r(t.run_id),n=r(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:d(t.duration_ms),success:O(t.success),mermaid:r(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(Bp).filter(s=>s!==null):[]}:null}function Hp(t){const e=_(t)?t:{};return{run:Cr(e.run)}}function Wp(t){if(!_(t))return null;const e=r(t.title),n=r(t.path);return!e||!n?null:{title:e,path:n}}function Gp(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function Jp(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.tool),a=r(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:F(t.success_signals),pitfalls:F(t.pitfalls)}}function Vp(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary),a=r(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(Jp).filter(o=>o!==null):[]}}function Yp(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:F(t.tools)}}function Qp(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.symptom),a=r(t.why),o=r(t.fix_tool),l=r(t.fix_summary);return!e||!n||!s||!a||!o||!l?null:{id:e,title:n,symptom:s,why:a,fix_tool:o,fix_summary:l}}function Xp(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.path_id),a=r(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:F(t.notes)}}function Zp(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(Wp).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(Gp).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(Vp).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Yp).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Qp).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Xp).filter(n=>n!==null):[]}}function tm(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.status),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{id:e,title:n,status:s,detail:a,next_tool:o}}function em(t){if(!_(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.title),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{code:e,severity:n,title:s,detail:a,next_tool:o}}function nm(t){if(!_(t))return null;const e=r(t.from),n=r(t.content),s=r(t.timestamp),a=d(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function sm(t){if(!_(t))return null;const e=r(t.name),n=r(t.role),s=r(t.lane),a=r(t.status),o=r(t.claim_marker),l=r(t.done_marker),c=r(t.final_marker);if(!e||!n||!s||!a||!o||!l||!c)return null;const p=(()=>{if(!_(t.last_message))return null;const m=d(t.last_message.seq),u=r(t.last_message.content),v=r(t.last_message.timestamp);return m==null||!u||!v?null:{seq:m,content:u,timestamp:v}})();return{name:e,role:n,lane:s,joined:O(t.joined)??!1,live_presence:O(t.live_presence)??!1,completed:O(t.completed)??!1,status:a,current_task:r(t.current_task)??null,bound_task_id:r(t.bound_task_id)??null,bound_task_title:r(t.bound_task_title)??null,bound_task_status:r(t.bound_task_status)??null,current_task_matches_run:O(t.current_task_matches_run)??!1,squad_member:O(t.squad_member)??!1,detachment_member:O(t.detachment_member)??!1,last_seen:r(t.last_seen)??null,heartbeat_age_sec:d(t.heartbeat_age_sec)??null,heartbeat_fresh:O(t.heartbeat_fresh)??!1,claim_marker_seen:O(t.claim_marker_seen)??!1,done_marker_seen:O(t.done_marker_seen)??!1,final_marker_seen:O(t.final_marker_seen)??!1,claim_marker:o,done_marker:l,final_marker:c,last_message:p}}function am(t){if(!_(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!_(n))return null;const s=r(n.timestamp),a=d(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:r(t.slot_url)??null,provider_base_url:r(t.provider_base_url)??null,provider_reachable:O(t.provider_reachable)??null,provider_status_code:d(t.provider_status_code)??null,provider_model_id:r(t.provider_model_id)??null,actual_model_id:r(t.actual_model_id)??null,expected_slots:d(t.expected_slots),actual_slots:d(t.actual_slots),expected_ctx:d(t.expected_ctx),actual_ctx:d(t.actual_ctx),slot_reachable:O(t.slot_reachable)??null,slot_status_code:d(t.slot_status_code)??null,runtime_blocker:r(t.runtime_blocker)??null,detail:r(t.detail)??null,checked_at:r(t.checked_at)??null,total_slots:d(t.total_slots),ctx_per_slot:d(t.ctx_per_slot),active_slots_now:d(t.active_slots_now),peak_active_slots:d(t.peak_active_slots),sample_count:d(t.sample_count),last_sample_at:r(t.last_sample_at)??null,timeline:e}}function im(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),run_id:r(e.run_id),room_id:r(e.room_id),operation_id:r(e.operation_id)??null,recommended_next_tool:r(e.recommended_next_tool),summary:n?{expected_workers:d(n.expected_workers),joined_workers:d(n.joined_workers),live_workers:d(n.live_workers),squad_roster_size:d(n.squad_roster_size),detachment_roster_size:d(n.detachment_roster_size),current_task_bound:d(n.current_task_bound),fresh_heartbeats:d(n.fresh_heartbeats),claim_markers_seen:d(n.claim_markers_seen),done_markers_seen:d(n.done_markers_seen),final_markers_seen:d(n.final_markers_seen),completed_workers:d(n.completed_workers),peak_hot_slots:d(n.peak_hot_slots),hot_window_ok:O(n.hot_window_ok),pass_hot_concurrency:O(n.pass_hot_concurrency),pass_end_to_end:O(n.pass_end_to_end),pending_decisions:d(n.pending_decisions),pass:O(n.pass)}:void 0,provider:am(e.provider),operation:ea(e.operation),squad:Ai(e.squad),detachment:hr(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(sm).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(tm).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(em).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(nm).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(xr).filter(s=>s!==null):[],truth_notes:F(e.truth_notes)}}function ue(t){V.value=t,Si(t)&&om()}async function wr(){ws.value=!0,Is.value=null;try{const t=await Ul();xi.value=Op(t)}catch(t){Is.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{ws.value=!1}}function Ci(t){ze.value=t}async function wi(){Ts.value=!0,Ps.value=null;try{const t=await Kl();Lt.value=jp(t)}catch(t){Ps.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{Ts.value=!1}}async function om(){Lt.value||Ts.value||await wi()}async function we(){await wr(),Si(V.value)&&await wi()}async function Ee(){var t;Xa.value=!0,Ds.value=null;try{const e=await Bl(),n=Up(e);Fn.value=n;const s=ze.value;n.operations.length===0?ze.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(ze.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Ds.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{Xa.value=!1}}function rm(){an=null,wn.value=null,zs.value=!1,Tn.value=null}async function lm(t){an=t,zs.value=!0,Tn.value=null;try{const e=await Hl(t);if(an!==t)return;wn.value=Hp(e)}catch(e){if(an!==t)return;wn.value=null,Tn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{an===t&&(zs.value=!1)}}async function cm(){Qa.value=!0,Ls.value=null;try{const t=await Wl();qn.value=Zp(t)}catch(t){Ls.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Qa.value=!1}}async function Bt(t=hp(),e=yp()){Ns.value=!0,Ms.value=null;try{const n=await Gl(t,e);_e.value=im(n)}catch(n){Ms.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{Ns.value=!1}}async function Zt(t,e,n){Ya.value=t,Rs.value=null;try{await Jl(e,n),await wr(),(Lt.value||Si(V.value))&&await wi(),await Bt(),await Ee()}catch(s){throw Rs.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{Ya.value=null}}function dm(t){return Zt(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function um(t){return Zt(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function pm(t){return Zt(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function mm(t={}){return Zt("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function vm(t){return Zt(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function _m(t){return Zt(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function fm(t,e){return Zt(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function gm(t,e){return Zt(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}kd(()=>{we(),Ee(),(V.value==="swarm"||V.value==="warroom"||_e.value!==null)&&Bt(),V.value==="warroom"&&ut()});function Es(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function U(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function $m(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Tr(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function L(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let to=!1,hm=0;function ym(){return++hm}let ca=null;async function bm(){ca||(ca=$p(()=>import("./mermaid.core-CsNP_nXj.js").then(e=>e.bE),[]).then(e=>e.default));const t=await ca;return to||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),to=!0),t}function Gt(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Kn(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function on(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function Un(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function ie(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:Un(t/e*100)}function km(t,e){const n=Un(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function Ir(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const xm=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],Pr=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],Sm=Pr.map(t=>t.id),Am=["chain_start","node_start","node_complete","chain_complete","chain_error"],Cm={warroom:{title:"라이브 워룸",description:"실제 run, worker, message, trace를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function eo(t){return!!t&&Sm.includes(t)}function wm(){const t=M.value.params;return t.source!=="mission"?{}:{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function Rr(t){const e=wm();if(t==="operations")return e;if(t==="chains"){const n=ze.value;return n?{...e,surface:t,operation:n}:{...e,surface:t}}return{...e,surface:t}}function Tm(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function Im(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function nt(t){return Ya.value===t}function Bn(){return xi.value}function Pm(t){var a,o,l,c,p,m,u;const e=xi.value,n=_e.value,s=Fn.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"live run, worker, message, trace를 한 화면에서 보고 필요한 detail 표면으로 바로 점프합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(o=e==null?void 0:e.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((p=(c=e==null?void 0:e.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:p.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(u=(m=s==null?void 0:s.operations[0])==null?void 0:m.preview_run)!=null&&u.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function Rm(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function Lm(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function Nm(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Lr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function Mm(){const e=Lr().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Nr(){const e=Lr().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Dm(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function zm(t){return t.status==="claimed"||t.status==="in_progress"}function Em(t){const e=qn.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function da(t){var e;return((e=qn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function jm(t){const e=qn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function Jt(t){try{await t()}catch{}}function Ti(t){return(t==null?void 0:t.trim().toLowerCase())??""}function Te(t){const e=Ti(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function ua(t){const e=Ti(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function Om(){var e,n,s;const t=_e.value;return t?!!(t.run_id||(e=t.operation)!=null&&e.operation_id||(n=t.detachment)!=null&&n.detachment_id||(((s=t.summary)==null?void 0:s.expected_workers)??0)>0||t.workers.length>0||t.recent_messages.length>0||t.recent_trace_events.length>0):!1}function qm(t){const e=Ti(t.status);return e==="active"||e==="running"}function Fm(){var o,l,c,p;const t=((o=mt.value)==null?void 0:o.sessions)??[],e=_e.value,n=((l=e==null?void 0:e.detachment)==null?void 0:l.session_id)??null;if(n){const m=t.find(u=>u.session_id===n);if(m)return m}const s=((c=e==null?void 0:e.operation)==null?void 0:c.operation_id)??Nr();if(s){const m=t.find(u=>u.command_plane_operation_id===s);if(m)return m}const a=((p=e==null?void 0:e.detachment)==null?void 0:p.detachment_id)??null;if(a){const m=t.find(u=>u.command_plane_detachment_id===a);if(m)return m}return t.find(qm)??t[0]??null}function Km(t){return t==="proven"?"ok":t==="partial"?"warn":"bad"}function mn(t){return Array.isArray(t)?t:[]}function Um({item:t}){return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${t.summary??t.event_type??"event"}</strong>
          <div class="command-meta-line">
            <span>${t.source??"source"}</span>
            <span>${t.event_type??"event"}</span>
            <span>${t.actor??"system"}</span>
          </div>
        </div>
        <span class="command-chip">${U(t.timestamp)}</span>
      </div>
    </article>
  `}function Bm({item:t}){return i`
    <article class="mission-activity-row">
      <div class="mission-activity-head">
        <div>
          <strong>${t.actor}</strong>
          <div class="mission-activity-meta">
            <span>${t.role??"participant"}</span>
            <span>${t.last_active_at?U(t.last_active_at):"n/a"}</span>
          </div>
        </div>
        <span class="command-chip ${t.interaction_count&&t.interaction_count>0?"warn":"ok"}">
          ${t.interaction_count??0} interactions
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>turns ${t.turn_count??0}</span>
        <span>spawn ${t.spawn_count??0}</span>
        <span>tool evidence ${t.tool_evidence_count??0}</span>
      </div>
      ${t.recent_input_preview?i`<div class="mission-activity-preview"><strong>Input</strong><span>${t.recent_input_preview}</span></div>`:null}
      ${t.recent_output_preview?i`<div class="mission-activity-preview"><strong>Output</strong><span>${t.recent_output_preview}</span></div>`:null}
      ${mn(t.recent_tool_names).length>0?i`<div class="semantic-tag-row">
            ${mn(t.recent_tool_names).map(e=>i`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
      ${t.recent_event_summary?i`<div class="mission-activity-copy"><span>${t.recent_event_summary}</span></div>`:null}
    </article>
  `}function Hm({item:t}){return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${t.kind}</strong>
          <div class="command-meta-line">
            <span>${t.path}</span>
          </div>
        </div>
        <span class="command-chip ${t.exists?"ok":"warn"}">${t.exists?"present":"missing"}</span>
      </div>
    </article>
  `}function Wm(){var v,g,$;const t=M.value.params,e=t.session_id??null,n=t.operation_id??null;Z(()=>{vr(e,n)},[e,n]);const s=mr.value;if(Va.value&&!s)return i`<section class="dashboard-panel"><div class="loading-indicator">Loading proof…</div></section>`;if(Ce.value&&!s)return i`<section class="dashboard-panel"><div class="error-card">${Ce.value}</div></section>`;const a=s==null?void 0:s.summary,o=mn(s==null?void 0:s.timeline),l=mn(s==null?void 0:s.actor_contributions),c=mn(s==null?void 0:s.artifacts),p=(s==null?void 0:s.proof_verdict)??"insufficient",m=(s==null?void 0:s.cp_backing_evidence)??null,u=Array.isArray((v=m==null?void 0:m.traces)==null?void 0:v.events)?(($=(g=m.traces)==null?void 0:g.events)==null?void 0:$.length)??0:0;return i`
    <section class="dashboard-panel mission-view">
      <${pt} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>Proof</h2>
          <p>협업, 대화, 도구 사용, backing evidence를 한 화면에서 증명하는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${Km(p)}">${p}</span>
          ${s!=null&&s.session_id?i`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?i`<span class="command-chip">${U(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${Ce.value?i`<div class="error-card">${Ce.value}</div>`:null}

      <div class="mission-stat-grid">
        <div class="summary-stat-card">
          <span>Actors</span>
          <strong>${(a==null?void 0:a.actors_count)??l.length}</strong>
          <small>proof lane participants</small>
        </div>
        <div class="summary-stat-card">
          <span>Interactions</span>
          <strong>${(a==null?void 0:a.interaction_count)??0}</strong>
          <small>cross-actor evidence</small>
        </div>
        <div class="summary-stat-card">
          <span>Evidence</span>
          <strong>${(a==null?void 0:a.evidence_count)??0}</strong>
          <small>tool / deliverable / checkpoint</small>
        </div>
        <div class="summary-stat-card">
          <span>CP Traces</span>
          <strong>${(a==null?void 0:a.cp_trace_count)??u}</strong>
          <small>managed backing events</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${T} title="3-Line Proof Summary" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
          </div>
          <div class="mission-list-stack">
            <div class="command-card">
              <div class="command-card-head">
                <div>
                  <strong>${(a==null?void 0:a.headline)??"No collaboration proof selected."}</strong>
                  <div class="command-meta-line">
                    <span>${(a==null?void 0:a.detail)??"Provide session_id or open the latest team session."}</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        <//>

        <${T} title="Goal Binding" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>목표 연결</h3>
          </div>
          <pre class="command-json-block">${Es((s==null?void 0:s.goal_binding)??{})}</pre>
        <//>
      </div>

      <div class="mission-human-grid">
        <${T} title="Collaboration Timeline" class="mission-list-card" semanticId="proof.timeline">
          <div class="mission-section-head">
            <h3>협업 타임라인</h3>
            <p>session events와 command-plane traces를 한 흐름으로 읽습니다.</p>
          </div>
          <div class="mission-list-stack">
            ${o.length>0?o.slice(0,24).map(b=>i`<${Um} key=${b.id} item=${b} />`):i`<div class="empty-state">표시할 timeline evidence가 없습니다.</div>`}
          </div>
        <//>

        <${T} title="Actor Contributions" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>actor 기여</h3>
            <p>누가 무엇을 했고 어떤 input/output을 남겼는지 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${l.length>0?l.map(b=>i`<${Bm} key=${b.actor} item=${b} />`):i`<div class="empty-state">표시할 actor contribution이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${T} title="Backing Evidence" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>CPv2 backing evidence</h3>
          </div>
          <pre class="command-json-block">${Es(m??{})}</pre>
        <//>

        <${T} title="Artifacts" class="mission-list-card" semanticId="proof.artifacts">
          <div class="mission-section-head">
            <h3>생성 산출물</h3>
          </div>
          <div class="mission-list-stack">
            ${c.length>0?c.map(b=>i`<${Hm} key=${b.path} item=${b} />`):i`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function Gm(){const t=On(M.value);return t?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${Zs(t.action_type)}</span>
        <span class="command-chip">${gi(t)}</span>
        <span class="command-chip">${au(M.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?i`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function Jm(){const t=V.value,e=Cm[t],n=Pm(t);return i`
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
      <div class="command-gauge-ring" style=${km(s,a)}>
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
  `}function Vm(){var tt,et,q,Y;const t=Bn(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,o=t==null?void 0:t.alerts.summary,l=(tt=t==null?void 0:t.swarm_status)==null?void 0:tt.overview,c=t==null?void 0:t.swarm_proof,p=t==null?void 0:t.operations.microarch,m=(e==null?void 0:e.managed_unit_count)??0,u=(e==null?void 0:e.total_units)??0,v=(n==null?void 0:n.active)??0,g=(s==null?void 0:s.active)??0,$=(l==null?void 0:l.moving_lanes)??0,b=(l==null?void 0:l.active_lanes)??0,x=(c==null?void 0:c.workers.done)??0,w=(c==null?void 0:c.workers.expected)??0,C=(o==null?void 0:o.bad)??0,A=(o==null?void 0:o.warn)??0,S=(a==null?void 0:a.pending)??0,I=(a==null?void 0:a.total)??0,R=v+g,W=((et=p==null?void 0:p.cache)==null?void 0:et.l1_hit_rate)??((Y=(q=p==null?void 0:p.signals)==null?void 0:q.cache_contention)==null?void 0:Y.l1_hit_rate)??0,B=v>0||g>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",vt=v>0||$>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${B}</h3>
        <p>${vt}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${L(v>0?"ok":"warn")}">활성 작전 ${v}</span>
          <span class="command-chip ${L($>0?"ok":(b>0,"warn"))}">이동 레인 ${$}/${Math.max(b,$)}</span>
          <span class="command-chip ${L(C>0?"bad":A>0?"warn":"ok")}">치명 알림 ${C}</span>
          <span class="command-chip ${L(S>0?"warn":"ok")}">승인 대기 ${S}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${Qn}
          label="관리 단위 범위"
          value=${`${m}/${Math.max(u,m)}`}
          subtext=${u>0?`${u-m}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${ie(m,Math.max(u,m))}
          color="#67e8f9"
        />
        <${Qn}
          label="실행 열도"
          value=${String(R)}
          subtext=${`${v}개 작전 + ${g}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${ie(R,Math.max(m,R||1))}
          color="#4ade80"
        />
        <${Qn}
          label="스웜 이동감"
          value=${`${$}/${Math.max(b,$)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${U(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${ie($,Math.max(b,$||1))}
          color="#fbbf24"
        />
        <${Qn}
          label="증거 수집률"
          value=${`${x}/${Math.max(w,x)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${ie(x,Math.max(w,x||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${Xn}
        label="승인 대기열"
        value=${`${S}건 대기`}
        detail=${`현재 정책 창에서 ${I}개 결정을 추적 중입니다`}
        percent=${ie(S,Math.max(I,S||1))}
        tone=${S>0?"warn":"ok"}
      />
      <${Xn}
        label="알림 압력"
        value=${`${C} bad / ${A} warn`}
        detail=${C>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${ie(C*2+A,Math.max((C+A)*2,1))}
        tone=${C>0?"bad":A>0?"warn":"ok"}
      />
      <${Xn}
        label="디스패치 점유"
          value=${`${g}개 가동`}
        detail=${m>0?`${m}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${ie(g,Math.max(m,g||1))}
        tone=${g>0?"ok":"warn"}
      />
      <${Xn}
        label="캐시 신뢰도"
        value=${W?Kn(W):"n/a"}
        detail=${W?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Un((W??0)*100)}
        tone=${W>=.75?"ok":W>=.4?"warn":"bad"}
      />
    </div>
  `}function Ym(){var g,$,b,x,w;const t=Bn(),e=Fn.value,n=On(M.value),s=Rm(n),a=t==null?void 0:t.topology.summary,o=t==null?void 0:t.operations.summary,l=(g=t==null?void 0:t.swarm_status)==null?void 0:g.overview,c=t==null?void 0:t.operations.microarch,p=t==null?void 0:t.decisions.summary,m=t==null?void 0:t.alerts.summary,u=($=c==null?void 0:c.signals)==null?void 0:$.issue_pressure,v=c==null?void 0:c.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((b=t==null?void 0:t.detachments.summary)==null?void 0:b.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(p==null?void 0:p.pending)??0}</strong><small>${(p==null?void 0:p.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(m==null?void 0:m.bad)??0}</strong><small>${(m==null?void 0:m.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((x=e==null?void 0:e.summary)==null?void 0:x.active_chains)??0}</strong><small>${((w=e==null?void 0:e.summary)==null?void 0:w.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${U(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(u==null?void 0:u.pending_ops)??0}</strong><small>${(v==null?void 0:v.l1_hit_rate)!=null?`${Kn(v.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(u==null?void 0:u.tone)??"n/a"}</small></div>
    </div>
  `}function Qm(){var tt,et,q,Y,k,kt,jt,te,ee;const t=Bn(),e=Lt.value,n=gt.value,s=Nm(),a=s?bt.value.find(z=>z.name===s)??null:null,o=s?It.value.filter(z=>z.assignee===s&&zm(z)):[],l=((tt=t==null?void 0:t.operations.summary)==null?void 0:tt.active)??0,c=((et=t==null?void 0:t.detachments.summary)==null?void 0:et.total)??0,p=((q=t==null?void 0:t.decisions.summary)==null?void 0:q.pending)??0,m=e==null?void 0:e.detachments.detachments.find(z=>{const xt=z.detachment.heartbeat_deadline,ne=xt?Date.parse(xt):Number.NaN;return z.detachment.status==="stalled"||!Number.isNaN(ne)&&ne<=Date.now()}),u=e==null?void 0:e.alerts.alerts.find(z=>z.severity==="bad"),v=!!(n!=null&&n.room||n!=null&&n.project),g=(a==null?void 0:a.current_task)??null,$=Dm(a==null?void 0:a.last_seen),b=$!=null?$<=120:null,x=[v?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:It.value.length>0?"masc_claim":"masc_add_task"}:g?b===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${g} 이지만 heartbeat가 stale 합니다 (${$}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${g}${$!=null?` · 마지막 활동 ${$}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((Y=t.topology.summary)==null?void 0:Y.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((k=t.topology.summary)==null?void 0:k.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((kt=t.topology.summary)==null?void 0:kt.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},p>0?{title:"디스패치 준비도",tone:"warn",detail:`${p}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:m||u?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${m?` · detachment ${m.detachment.detachment_id} 가 stalled 상태입니다`:""}${u?` · alert ${u.title??u.alert_id}`:""}${!e&&!m&&!u?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],w=v?!s||!a?"masc_join":o.length===0?It.value.length>0?"masc_claim":"masc_add_task":g?b===!1?"masc_heartbeat":!t||(((jt=t.topology.summary)==null?void 0:jt.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":p>0?"masc_policy_approve":l>0&&c===0||m||u?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",C=Em(w),S=jm(w==="masc_set_room"?["repo-root-room"]:w==="masc_plan_set_task"?["claimed-not-current"]:w==="masc_heartbeat"?["heartbeat-stale"]:w==="masc_dispatch_tick"?["no-detachments"]:w==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),I=da("room_task_hygiene"),R=da("cpv2_benchmark"),W=da("supervisor_session"),B=((te=qn.value)==null?void 0:te.docs)??[],vt=[I,R,W].filter(z=>z!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${N} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(C==null?void 0:C.title)??w}</strong>
            <span class="command-chip ok">${w}</span>
          </div>
          <p>${(C==null?void 0:C.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(ee=C==null?void 0:C.success_signals)!=null&&ee.length?i`<div class="command-tag-row">
                ${C.success_signals.map(z=>i`<span class="command-tag ok">${z}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${x.map(z=>i`
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

        ${S.length>0?i`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${S.length}</span>
                </div>
                <div class="command-guide-list">
                  ${S.map(z=>i`
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
          <${N} panelId="command.summary" compact=${!0} />
        </div>
        ${Qa.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:Ls.value?i`<div class="empty-state error">${Ls.value}</div>`:i`
                <div class="command-path-grid">
                  ${vt.map(z=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${z.title}</strong>
                        <span class="command-chip">${z.id}</span>
                      </div>
                      <p>${z.summary}</p>
                      <div class="command-card-sub">${z.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${z.steps.slice(0,4).map(xt=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${xt.tool}</span>
                            <span>${xt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${B.length>0?i`<div class="command-doc-links">
                      ${B.map(z=>i`<span class="command-tag">${z.title}: ${z.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Xm(){return i`
    <${Vm} />
    <${Ym} />
    <${Qm} />
  `}function Zm(){return Ts.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:Ps.value?i`<div class="empty-state error">${Ps.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function Mr({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,o=t.unit.policy;return i`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${Im(t.unit.kind)}</span>
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
            ${t.children.map(l=>i`<${Mr} node=${l} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function tv({alert:t}){return i`
    <article class="command-alert ${L(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${L(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${U(t.timestamp)}</span>
      </div>
      ${t.detail?i`<p>${t.detail}</p>`:null}
    </article>
  `}function Ii({event:t}){return i`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${U(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${Es(t.detail)}</pre>
    </article>
  `}function ev(){const t=Lt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${N} panelId="command.topology" compact=${!0} />
      </div>
      ${t&&t.topology.units.length>0?i`${t.topology.units.map(e=>i`<${Mr} node=${e} />`)}`:i`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function nv(){const t=Lt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${N} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>i`<${tv} alert=${e} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function sv(){const t=Lt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${N} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?i`<div class="command-trace-stack">
            ${t.traces.events.map(e=>i`<${Ii} event=${e} />`)}
          </div>`:i`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function Dr(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function zr({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const o=a.motion_state;o in e?e[o]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return i`
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
  `}function av({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${a.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?i`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function iv({lane:t}){const e=t.counts??{},n=Dr(t),s=e.workers??0,a=e.operations??0,o=e.detachments??0,l=a+o,c=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return i`
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
          <span class="command-chip">${U(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${L(n)}" style=${`width:${c}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${s>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${av} total=${s} />
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
              ${t.hard_flags.map(p=>i`<span class="command-chip ${L(p.severity)}">${p.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Er({lanes:t}){const e=t.slice(0,4);return e.length===0?null:i`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=Dr(n),a=n.counts.workers??0,o=n.counts.operations??0,l=n.counts.detachments??0;return i`
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
  `}function ov({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${L(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?i`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function rv({gap:t}){return i`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${L(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function lv({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${L(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${L(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?i`
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${U(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.artifact_ref?i`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?i`<p>${t.missing_reason}</p>`:null}
          `:i`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function cv(){const t=Bn(),e=On(M.value),n=Lm(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,o=(s==null?void 0:s.lanes.filter(v=>v.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],p=s==null?void 0:s.overview,m=s==null?void 0:s.recommended_next_action,u=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${N} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${Er} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(p==null?void 0:p.active_lanes)??0}</strong><small>${(p==null?void 0:p.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(p==null?void 0:p.stalled_lanes)??0}</strong><small>${(p==null?void 0:p.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${U(p==null?void 0:p.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${U(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong><small>${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${zr} lanes=${o} />`:null}

            <div class="command-swarm-layout ${u?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(v=>i`<${iv} lane=${v} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${lv} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${L(l.some(v=>v.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?i`<div class="swarm-event-rail">${l.slice(0,4).map(v=>i`<${rv} gap=${v} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?i`<div class="swarm-event-rail">${c.map(v=>i`<${ov} event=${v} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function dv({item:t}){return i`
    <article class="command-guide-card ${L(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${L(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function jr({blocker:t}){return i`
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
  `}function uv({worker:t}){return i`
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
      ${t.last_message?i`<div class="command-card-foot">${U(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function pv(){var p,m,u,v,g,$,b,x,w,C,A,S,I,R,W,B,vt,tt,et,q,Y;const t=_e.value,e=Mm(),n=Nr(),s=(p=t==null?void 0:t.provider)!=null&&p.runtime_blocker?"blocked":(m=t==null?void 0:t.provider)!=null&&m.provider_reachable?"ready":"check",a=((u=t==null?void 0:t.provider)==null?void 0:u.actual_slots)??((v=t==null?void 0:t.provider)==null?void 0:v.total_slots)??0,o=((g=t==null?void 0:t.provider)==null?void 0:g.expected_slots)??"n/a",l=(($=t==null?void 0:t.provider)==null?void 0:$.actual_ctx)??((b=t==null?void 0:t.provider)==null?void 0:b.ctx_per_slot)??0,c=((x=t==null?void 0:t.provider)==null?void 0:x.expected_ctx)??"n/a";return i`
    <div class="command-section-stack">
      <${cv} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${N} panelId="command.swarm" compact=${!0} />
          </div>
          ${Ns.value?i`<div class="empty-state">Loading swarm live state…</div>`:Ms.value?i`<div class="empty-state error">${Ms.value}</div>`:t?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((w=t.summary)==null?void 0:w.joined_workers)??0}/${((C=t.summary)==null?void 0:C.expected_workers)??0}</strong><small>${((A=t.summary)==null?void 0:A.live_workers)??0}개 가동 · ${((S=t.summary)==null?void 0:S.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${o} · ctx ${l}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(I=t.summary)!=null&&I.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((R=t.provider)==null?void 0:R.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(W=t.summary)!=null&&W.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((B=t.operation)==null?void 0:B.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((vt=t.squad)==null?void 0:vt.label)??"없음"}</span>
                      <span>실행체</span><span>${((tt=t.detachment)==null?void 0:tt.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((et=t.summary)==null?void 0:et.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((q=t.summary)==null?void 0:q.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((Y=t.provider)==null?void 0:Y.runtime_blocker)??"없음"}</span>
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
            <${N} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?i`<div class="command-card-stack">
                ${t.checklist.map(k=>i`<${dv} item=${k} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${N} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?i`<div class="command-card-stack">
                ${t.workers.map(k=>i`<${uv} worker=${k} />`)}
              </div>`:i`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${N} panelId="command.swarm" compact=${!0} />
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
                  <span>Last Sample</span><span>${t.provider.last_sample_at?U(t.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${t.provider.checked_at?U(t.provider.checked_at):"n/a"}</span>
                </div>
                ${t.provider.detail?i`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?i`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(k=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${k.active_slots} active</strong>
                              <span class="command-chip">${U(k.timestamp)}</span>
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
            <${N} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?i`<div class="command-card-stack">
                ${t.blockers.map(k=>i`<${jr} blocker=${k} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${N} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?i`<div class="command-trace-stack">
                ${t.recent_messages.map(k=>i`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${k.from}</strong>
                        <span class="command-chip">${U(k.timestamp)}</span>
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
            <${N} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${t.recent_trace_events.map(k=>i`<${Ii} event=${k} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function mv(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"none",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}s`:t.heartbeat_fresh?"clean":"n/a",detail:[t.bound_task_status??null,t.detachment_member?"detachment":null,t.squad_member?"squad":null].filter(Boolean).join(" · ")||"live swarm worker",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function vv(t,e){const n=t.actor??t.spawn_role??`worker-${e+1}`,s=t.spawn_role??t.worker_class??t.spawn_agent??"worker",a=t.lane_id??t.capsule_mode??t.control_domain??"session",o=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:s,lane:a,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"session lane",heartbeat:t.last_turn_ts_iso?U(t.last_turn_ts_iso):"n/a",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?Kn(t.routing_confidence):null].filter(Boolean).join(" · ")||"session worker",markers:o,note:t.routing_reason??null}}function no(t){return L(t.severity)}function _v({worker:t}){return i`
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
  `}function qt({label:t,surface:e,params:n={}}){return i`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(e){ue(e),lt("command",{...Rr(e),...n});return}lt("intervene")}}
    >
      ${t}
    </button>
  `}function fv(){var B,vt,tt,et,q,Y,k,kt,jt,te,ee,z,xt,ne,Xe,Ze,Hn,Wn,Gn,Jn;const t=Bn(),e=_e.value,n=mt.value,s=Pt.value,a=Fm(),o=e!=null&&e.operation?((B=Fn.value)==null?void 0:B.operations.find(j=>{var ge;return j.operation.operation_id===((ge=e.operation)==null?void 0:ge.operation_id)}))??null:null,l=(e==null?void 0:e.workers)??[],c=(s==null?void 0:s.worker_cards)??[],p=l.length>0?l.map(mv):c.map(vv),m=Om(),u=((vt=t==null?void 0:t.decisions.summary)==null?void 0:vt.pending)??0,v=(n==null?void 0:n.pending_confirms)??[],g=(e==null?void 0:e.blockers)??[],$=(s==null?void 0:s.recommended_actions)??[],b=(s==null?void 0:s.attention_items)??[],x=((tt=e==null?void 0:e.recent_messages[0])==null?void 0:tt.timestamp)??null,w=((et=e==null?void 0:e.recent_trace_events[0])==null?void 0:et.timestamp)??null,C=x??w??null,A=a==null?void 0:a.summary,S=((q=e==null?void 0:e.summary)==null?void 0:q.expected_workers)??(typeof(A==null?void 0:A.planned_worker_count)=="number"?A.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,I=((Y=e==null?void 0:e.summary)==null?void 0:Y.joined_workers)??(typeof(A==null?void 0:A.active_agent_count)=="number"?A.active_agent_count:void 0)??p.length,R=g.length>0||u>0||v.length>0?"warn":m||a?"ok":"warn",W=((k=t==null?void 0:t.swarm_status)==null?void 0:k.lanes.filter(j=>j.present))??[];return Z(()=>{ut()},[]),Z(()=>{a!=null&&a.session_id&&He(a.session_id)},[a==null?void 0:a.session_id,n,(kt=e==null?void 0:e.detachment)==null?void 0:kt.session_id]),!m&&!a?Ns.value||An.value?i`<div class="empty-state">live war room 불러오는 중…</div>`:i`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">라이브 워룸</div>
          <${N} panelId="command.warroom" compact=${!0} />
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
      <section class="command-warroom-strip ${L(R)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">Live War Room</span>
            <strong>${((jt=e==null?void 0:e.operation)==null?void 0:jt.objective)??(a==null?void 0:a.session_id)??"active run"}</strong>
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
              params=${{...(z=e==null?void 0:e.operation)!=null&&z.operation_id?{operation_id:e.operation.operation_id}:{},...e!=null&&e.run_id?{run_id:e.run_id}:{}}}
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
            <small>${((xt=e==null?void 0:e.summary)==null?void 0:xt.completed_workers)??0} 완료 · ${p.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>Runtime</span>
            <strong>${(ne=e==null?void 0:e.provider)!=null&&ne.runtime_blocker?"blocked":(Xe=e==null?void 0:e.provider)!=null&&Xe.provider_reachable?"ready":a?ua(a.status):"check"}</strong>
            <small>slots ${((Ze=e==null?void 0:e.provider)==null?void 0:Ze.active_slots_now)??0}/${((Hn=e==null?void 0:e.provider)==null?void 0:Hn.actual_slots)??((Wn=e==null?void 0:e.provider)==null?void 0:Wn.total_slots)??0} · ctx ${((Gn=e==null?void 0:e.provider)==null?void 0:Gn.actual_ctx)??((Jn=e==null?void 0:e.provider)==null?void 0:Jn.ctx_per_slot)??0}</small>
          </div>
          <div class="monitor-stat-card ${L(g.length>0||u>0?"warn":"ok")}">
            <span>Pressure</span>
            <strong>${g.length+u+v.length}</strong>
            <small>blockers ${g.length} · approvals ${u} · confirms ${v.length}</small>
          </div>
          <div class="monitor-stat-card">
            <span>Last signal</span>
            <strong>${U(C)}</strong>
            <small>${x?"message":w?"trace":"waiting"}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${N} panelId="command.warroom" compact=${!0} />
            </div>
            ${W.length>0?i`
                  <${Er} lanes=${W} />
                  <${zr} lanes=${W} />
                `:a?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${L(Te(a.status))}">${ua(a.status)}</span>
                      </div>
                      <p>command-plane live run은 아직 옅지만, session 쪽 worker와 digest를 기준으로 워룸을 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${on(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${on(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:i`<div class="empty-state">보이는 lane이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Worker Roster</div>
              <${N} panelId="command.warroom" compact=${!0} />
            </div>
            ${p.length>0?i`<div class="command-card-stack">
                  ${p.map(j=>i`<${_v} worker=${j} />`)}
                </div>`:i`<div class="empty-state">활성 worker 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Live Feed</div>
              <${N} panelId="command.warroom" compact=${!0} />
            </div>
            ${e&&e.recent_messages.length>0?i`<div class="command-trace-stack">
                  ${e.recent_messages.map(j=>i`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${j.from}</strong>
                          <span class="command-chip">${U(j.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${j.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${j.content}</pre>
                    </article>
                  `)}
                </div>`:$.length>0||b.length>0?i`<div class="command-card-stack">
                    ${$.slice(0,4).map(j=>i`
                      <article class="command-guide-card ${no(j)}">
                        <div class="command-guide-head">
                          <strong>${j.action_type}</strong>
                          <span class="command-chip ${no(j)}">${j.target_type}</span>
                        </div>
                        <p>${j.reason}</p>
                      </article>
                    `)}
                    ${b.slice(0,3).map(j=>i`
                      <article class="command-alert ${L(j.severity)}">
                        <div class="command-card-head">
                          <strong>${j.kind}</strong>
                          <span class="command-chip ${L(j.severity)}">${j.severity}</span>
                        </div>
                        <p>${j.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?i`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((j,ge)=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>session-event-${ge+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${Es(j)}</pre>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">메시지나 attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Trace Feed</div>
              <${N} panelId="command.trace" compact=${!0} />
            </div>
            ${e&&e.recent_trace_events.length>0?i`<div class="command-trace-stack">
                  ${e.recent_trace_events.map(j=>i`<${Ii} event=${j} />`)}
                </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Pressure</div>
              <${N} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${g.length>0?g.map(j=>i`<${jr} blocker=${j} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${u>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending approvals</strong>
                        <span class="command-chip warn">${u}</span>
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
              <${N} panelId="command.warroom" compact=${!0} />
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
                        <span>Updated</span><span>${U(e.operation.updated_at)}</span>
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
                        <span>Heartbeat</span><span>${Tr(e.detachment.heartbeat_deadline)}</span>
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
                        <span class="command-chip ${L(Te(a.status))}">${ua(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${on(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${on(a.remaining_sec)}</span>
                        <span>Done delta</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function gv({source:t}){const e=ll(null),[n,s]=$o(null);return Z(()=>{let a=!1;const o=e.current;return o?(o.innerHTML="",s(null),(async()=>{try{const c=await bm(),{svg:p}=await c.render(`command-chain-${ym()}`,t);if(a||!e.current)return;e.current.innerHTML=p}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid render failed")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function $v({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return i`
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
        ${a?i`<span class="command-tag ${Gt(s==null?void 0:s.status)}">${Kn(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${Ir(t.history)}</div>
    </button>
  `}function hv({item:t}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${Gt(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${U(t.timestamp)}</div>
      <div class="command-card-sub">${Ir(t)}</div>
    </article>
  `}function yv({node:t}){return i`
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
  `}function bv({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,o=e.chain,l=(o==null?void 0:o.run_id)??null;return i`
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
        <span>Updated</span><span>${U(e.updated_at)}</span>
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
          onClick=${()=>{ue("swarm"),lt("command",{surface:"swarm",operation_id:e.operation_id,...l?{run_id:l}:{}})}}
        >
          Swarm Live
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{Ci(e.operation_id),ue("chains"),lt("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?i`
              <button class="control-btn ghost" disabled=${nt(n)} onClick=${()=>Jt(()=>dm(e.operation_id))}>
                ${nt(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${nt(a)} onClick=${()=>Jt(()=>pm(e.operation_id))}>
                ${nt(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?i`
              <button class="control-btn ghost" disabled=${nt(s)} onClick=${()=>Jt(()=>um(e.operation_id))}>
                ${nt(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function kv({card:t}){var n;const e=t.detachment;return i`
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
        <span>Progress</span><span>${U(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Tr(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${U(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?i`<span class="command-tag ${$m(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function xv(){const t=Lt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${N} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?i`<div class="command-card-stack">
              ${t.operations.operations.map(e=>i`<${bv} card=${e} />`)}
            </div>`:i`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${N} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>i`<${kv} card=${e} />`)}
            </div>`:i`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function Sv(){var c,p,m,u,v,g,$,b,x,w,C,A,S,I,R,W;const t=Fn.value,e=(t==null?void 0:t.operations)??[],n=ze.value,s=e.find(B=>B.operation.operation_id===n)??e[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,o=((p=wn.value)==null?void 0:p.run)??(s==null?void 0:s.preview_run)??null,l=!((m=wn.value)!=null&&m.run)&&!!(s!=null&&s.preview_run);return Z(()=>{a?lm(a):rm()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${N} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${Gt(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${Gt(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(t==null?void 0:t.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((u=t==null?void 0:t.summary)==null?void 0:u.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((v=t==null?void 0:t.summary)==null?void 0:v.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((g=t==null?void 0:t.summary)==null?void 0:g.recent_failures)??0}</span>
            <span>Last Event</span><span>${U(($=t==null?void 0:t.summary)==null?void 0:$.last_history_event_at)}</span>
          </div>
        </article>

        ${Ds.value?i`<div class="empty-state error">${Ds.value}</div>`:null}

        ${Xa.value&&!t?i`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?i`
                <div class="command-chain-list">
                  ${e.map(B=>i`
                    <${$v}
                      overlay=${B}
                      selected=${(s==null?void 0:s.operation.operation_id)===B.operation.operation_id}
                      onSelect=${()=>Ci(B.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(B=>i`<${hv} item=${B} />`)}
                </div>
              `:i`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chain Detail</div>
          <${N} panelId="command.chains" compact=${!0} />
        </div>
        ${s?i`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${Gt((b=s.operation.chain)==null?void 0:b.status)}">
                    ${((x=s.operation.chain)==null?void 0:x.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((w=s.operation.chain)==null?void 0:w.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((C=s.operation.chain)==null?void 0:C.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${Kn((A=s.runtime)==null?void 0:A.progress)}</span>
                  <span>Elapsed</span><span>${on((S=s.runtime)==null?void 0:S.elapsed_sec)}</span>
                  <span>Updated</span><span>${U(((I=s.operation.chain)==null?void 0:I.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(R=s.operation.chain)!=null&&R.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((W=s.operation.chain)==null?void 0:W.chain_id)??"graph"}</span>
                      </div>
                      <${gv} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"failed":l?"preview":"captured":"pending"}
                  </span>
                </div>
                ${zs.value?i`<div class="empty-state">Loading run detail…</div>`:Tn.value?i`<div class="empty-state error">${Tn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${o.chain_id}</span>
                            <span>Run</span><span>${o.run_id??"preview only"}</span>
                            <span>Duration</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${o.nodes.length}</span>
                          </div>
                          ${l?i`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(B=>i`<${yv} node=${B} />`)}
                          </div>
                        `:i`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:i`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function Av({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return i`
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
        <span>Created</span><span>${U(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!s?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${nt(e)} onClick=${()=>Jt(()=>vm(t.decision_id))}>
                ${nt(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${nt(n)} onClick=${()=>Jt(()=>_m(t.decision_id))}>
                ${nt(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function Cv({row:t}){var c,p,m;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((c=e.policy)!=null&&c.frozen),o=!!((p=e.policy)!=null&&p.kill_switch),l=Math.round((t.utilization??0)*100);return i`
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
        <span>Autonomy</span><span>${((m=e.policy)==null?void 0:m.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${a?"yes":"no"}</span>
        <span>Kill Switch</span><span>${o?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${nt(n)} onClick=${()=>Jt(()=>fm(e.unit_id,!a))}>
          ${nt(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${nt(s)} onClick=${()=>Jt(()=>gm(e.unit_id,!o))}>
          ${nt(s)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function wv(){const t=Lt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${N} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>i`<${Av} decision=${e} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${N} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>i`<${Cv} row=${e} />`)}
            </div>`:i`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function Tv(){return i`
    <div class="command-surface-tabs grouped">
      ${xm.map(t=>i`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${Pr.filter(e=>e.group===t.id).map(e=>i`
                <button
                  class="command-surface-tab ${V.value===e.id?"active":""}"
                  onClick=${()=>{ue(e.id),lt("command",Rr(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function Iv(){if(V.value==="warroom")return i`<${fv} />`;if(V.value==="summary")return i`<${Xm} />`;if(V.value==="swarm")return i`<${pv} />`;if(!Lt.value)return i`<${Zm} />`;switch(V.value){case"chains":return i`<${Sv} />`;case"topology":return i`<${ev} />`;case"alerts":return i`<${nv} />`;case"trace":return i`<${sv} />`;case"control":return i`<${wv} />`;case"operations":default:return i`<${xv} />`}}function Pv(){return Z(()=>{we(),Ee(),cm(),Bt()},[]),Z(()=>{if(M.value.tab!=="command")return;const t=M.value.params.surface,e=M.value.params.operation,n=On(M.value);if(eo(t))ue(t);else if(n){const s=Vo(n);eo(s)&&ue(s)}else t||ue("warroom");e&&Ci(e),(t==="swarm"||t==="warroom"||V.value==="warroom")&&Bt(),(t==="warroom"||V.value==="warroom")&&ut()},[M.value.tab,M.value.params.surface,M.value.params.operation,M.value.params.operation_id,M.value.params.run_id,M.value.params.source,M.value.params.action_type,M.value.params.target_type,M.value.params.target_id,M.value.params.focus_kind]),Z(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,we(),Ee(),(V.value==="swarm"||V.value==="warroom")&&Bt(),V.value==="warroom"&&ut()},250))},n=new EventSource(Tm()),s=Am.map(a=>{const o=()=>e();return n.addEventListener(a,o),{type:a,handler:o}});return n.onerror=()=>{e()},()=>{s.forEach(({type:a,handler:o})=>{n.removeEventListener(a,o)}),n.close(),t&&window.clearTimeout(t)}},[]),Z(()=>{const t=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const e=V.value;e!=="swarm"&&e!=="warroom"||(we(),Bt(),e==="warroom"&&ut())},5e3);return()=>{window.clearInterval(t)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Jt(()=>mm())}}
            disabled=${nt("dispatch:tick")}
          >
            ${nt("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{we(),Ee(),Bt(),V.value==="warroom"&&ut()}}
            disabled=${ws.value}
          >
            ${ws.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Is.value?i`<div class="empty-state error">${Is.value}</div>`:null}
      ${Rs.value?i`<div class="empty-state error">${Rs.value}</div>`:null}
      <${pt} surfaceId="command" />
      <${Gm} />
      ${V.value==="warroom"?null:i`<${Jm} />`}
      <${Tv} />
      <${Iv} />
    </section>
  `}const Or="masc_dashboard_agent_name";function Rv(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Or))==null?void 0:s.trim())||"dashboard"}const na=f(Rv()),je=f(""),Za=f("운영 점검"),Oe=f(""),In=f(""),Pn=f("2"),We=f(""),Tt=f("note"),Rn=f(""),Ln=f(""),Nn=f(""),Mn=f("2"),js=f("운영자 중지 요청"),Os=f(""),qe=f(""),Zn=f(null);function Lv(t){const e=t.trim()||"dashboard";na.value=e,localStorage.setItem(Or,e)}function qr(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Nv(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function Ge(t){return typeof t=="string"?t.trim().toLowerCase():""}function Mv(t){var s;const e=Ge(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=Ge((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function pa(t){const e=Ge(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function so(t){return t.some(e=>Ge(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function Dv(t){return t.target_type==="team_session"}function zv(t){return t.target_type==="keeper"}function qs(t){switch(t){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";case"keeper_msg":return"keeper 메시지";default:return(t==null?void 0:t.trim())||"액션"}}function Fs(t){switch(t){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";default:return(t==null?void 0:t.trim())||"target"}}function rn(t){switch(Ge(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Fr(t){return t?"확인 후 실행":"즉시 실행"}function Ev(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";default:return t}}function rt(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function jv(t){if(t.action_type==="team_task_inject")return"task";if(t.action_type==="team_broadcast")return"broadcast";if(t.action_type==="team_note")return"note";if(t.action_type==="team_turn"){const e=rt(t.suggested_payload,"turn_kind");if(e==="broadcast"||e==="task")return e}return"note"}function Ov(t){const e=t.suggested_payload;if(t.target_type==="room"){if(t.action_type==="broadcast"){je.value=rt(e,"message")??t.summary;return}t.action_type==="task_inject"&&(Oe.value=rt(e,"title")??"운영자 주입 작업",In.value=rt(e,"description")??t.summary,Pn.value=rt(e,"priority")??Pn.value);return}if(t.target_type==="team_session"){if(t.target_id&&(We.value=t.target_id),t.action_type==="team_stop"){js.value=rt(e,"reason")??t.summary;return}Tt.value=jv(t);const n=rt(e,"message");n&&(Rn.value=n),Tt.value==="task"&&(Ln.value=rt(e,"task_title")??rt(e,"title")??"운영자 주입 작업",Nn.value=rt(e,"task_description")??rt(e,"description")??t.summary,Mn.value=rt(e,"task_priority")??rt(e,"priority")??Mn.value);return}t.target_type==="keeper"&&(t.target_id&&(Os.value=t.target_id),qe.value=rt(e,"message")??t.summary)}function qv(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function fe(t){const e=na.value.trim()||"dashboard";try{const n=await ju({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?P("확인 대기열에 올렸습니다","warning"):P(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return P(s,"error"),null}}async function ao(){const t=je.value.trim();if(!t)return;await fe({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(je.value="")}async function Fv(){await fe({action_type:"room_pause",target_type:"room",payload:{reason:Za.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function Kr(){await fe({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function Kv(){const t=Oe.value.trim();if(!t)return;await fe({action_type:"task_inject",target_type:"room",payload:{title:t,description:In.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(Pn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(Oe.value="",In.value="")}async function Uv(){var l;const t=mt.value,e=We.value||((l=t==null?void 0:t.sessions[0])==null?void 0:l.session_id)||"";if(!e){P("먼저 세션을 고르세요","warning");return}const n={},s=Rn.value.trim();s&&(n.message=s);let a="team_note";Tt.value==="broadcast"?a="team_broadcast":Tt.value==="task"&&(a="team_task_inject"),Tt.value==="task"&&(n.task_title=Ln.value.trim()||"운영자 주입 작업",n.task_description=Nn.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(Mn.value,10)||2),await fe({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Rn.value="",Tt.value==="task"&&(Ln.value="",Nn.value=""))}async function Bv(){var n;const t=mt.value,e=We.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){P("먼저 세션을 고르세요","warning");return}await fe({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:js.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function Hv(){var a;const t=mt.value,e=Os.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=qe.value.trim();if(!e){P("먼저 keeper를 고르세요","warning");return}if(!n)return;await fe({action_type:"keeper_message",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`${e}에게 메시지를 보냈습니다`})&&(qe.value="")}async function Wv(t){const e=na.value.trim()||"dashboard";try{await Ou(e,t),P("확인 실행을 완료했습니다","success")}catch(n){const s=n instanceof Error?n.message:"확인 실행에 실패했습니다";P(s,"error")}}function Gv(){const t=mt.value,e=yi.value,n=(t==null?void 0:t.room)??{},s=(t==null?void 0:t.pending_confirms)??[],a=(t==null?void 0:t.recent_messages)??[],o=(e==null?void 0:e.recommended_actions)??[],l=a.slice(0,5);return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Room 개입</div>
          <${N} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">전체 room에 영향 주는 액션입니다. 방송, 정지/재개, 작업 주입을 여기서 처리합니다.</p>

        <div class="ops-stat-grid">
          <div class="ops-stat">
            <span>Room</span>
            <strong>${n.current_room??n.room_id??"default"}</strong>
          </div>
          <div class="ops-stat">
            <span>프로젝트</span>
            <strong>${n.project??"확인 없음"}</strong>
          </div>
          <div class="ops-stat">
            <span>클러스터</span>
            <strong>${n.cluster??"확인 없음"}</strong>
          </div>
          <div class="ops-stat ${n.paused?"warn":"ok"}">
            <span>상태</span>
            <strong>${n.paused?"일시정지":"진행 중"}</strong>
          </div>
        </div>

        <label class="control-label" for="ops-broadcast">Room 방송</label>
        <div class="control-row">
          <input
            id="ops-broadcast"
            class="control-input"
            type="text"
            placeholder="@agent 또는 room 전체 공지"
            value=${je.value}
            onInput=${c=>{je.value=c.target.value}}
            onKeyDown=${c=>{c.key==="Enter"&&ao()}}
            disabled=${H.value}
          />
          <button class="control-btn" onClick=${()=>{ao()}} disabled=${H.value||je.value.trim()===""}>
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
            onInput=${c=>{Za.value=c.target.value}}
            disabled=${H.value}
          />
          <button class="control-btn ghost" onClick=${()=>{Fv()}} disabled=${H.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{Kr()}} disabled=${H.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${Oe.value}
          onInput=${c=>{Oe.value=c.target.value}}
          disabled=${H.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${In.value}
          onInput=${c=>{In.value=c.target.value}}
          disabled=${H.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${Pn.value}
            onChange=${c=>{Pn.value=c.target.value}}
            disabled=${H.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{Kv()}} disabled=${H.value||Oe.value.trim()===""}>
            주입
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">추천 개입</div>
          <${N} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
        ${Cn.value&&!e?i`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:o.length>0?i`
          <div class="ops-log-list">
            ${o.map(c=>i`
              <article key=${`${c.action_type}:${c.target_type}:${c.target_id??"room"}`} class="ops-log-entry ${c.severity}">
                <div class="ops-log-head">
                  <strong>${qs(c.action_type)}</strong>
                  <span>${Fs(c.target_type)}${c.target_id?` · ${c.target_id}`:""}</span>
                  <span>${Fr(c.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${c.reason}</div>
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
          <${N} panelId="intervene.pending_confirmations" compact=${!0} />
        </div>
        <p class="ops-context-note">미리보기만 끝났고 아직 사람이 눌러줘야 하는 액션만 남깁니다.</p>
        ${s.length>0?i`
          <div class="ops-confirmation-list">
            ${s.map(c=>i`
              <article key=${c.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${qs(c.action_type)}</strong>
                  <span>${Fs(c.target_type)}${c.target_id?` · ${c.target_id}`:""}</span>
                  <span>${c.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${c.preview?i`<pre class="ops-code-block compact">${qr(c.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{Wv(c.confirm_token)}} disabled=${H.value}>
                    실행
                  </button>
                  <span class="ops-token">${c.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        `:i`<div class="ops-empty">지금 승인 대기는 없습니다.</div>`}
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 Room 메시지</div>
          <${N} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
        ${l.length>0?i`
          <div class="ops-feed-list">
            ${l.map(c=>i`
              <article key=${c.seq??c.id??c.timestamp} class="ops-feed-item">
                <div class="ops-feed-meta">
                  <strong>${c.from}</strong>
                  <span>${c.timestamp}</span>
                </div>
                <div class="ops-feed-content">${c.content}</div>
              </article>
            `)}
          </div>
        `:i`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
      </section>
    </div>
  `}function Jv(){const t=mt.value,e=Pt.value,n=(t==null?void 0:t.sessions)??[],s=n.find(a=>a.session_id===We.value)??n[0]??null;return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${N} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map(a=>{var o;return i`
            <button
              key=${a.session_id}
              class="ops-entity-card ${(s==null?void 0:s.session_id)===a.session_id?"active":""}"
              onClick=${()=>{We.value=a.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${a.session_id}</strong>
                <span class="status-badge ${a.status??"idle"}">${rn(a.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(a.progress_pct??0)}%</span>
                <span>${a.done_delta_total??0}건 완료</span>
                <span>${(o=a.team_health)!=null&&o.status?rn(String(a.team_health.status)):"상태 확인 필요"}</span>
              </div>
            </button>
          `})}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Session 요약</div>
          <${N} panelId="intervene.session_digest" compact=${!0} />
        </div>
        <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
        ${s&&e?i`
          <div class="ops-log-list">
            ${e.attention_items.length>0?e.attention_items.map(a=>i`
              <article key=${`${a.kind}:${a.target_id??"session"}`} class="ops-log-entry ${a.severity}">
                <div class="ops-log-head">
                  <strong>${a.kind}</strong>
                  <span>${Fs(a.target_type)}${a.target_id?` · ${a.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${a.summary}</div>
              </article>
            `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${e.worker_cards.length>0?e.worker_cards.map(a=>i`
              <article key=${`${a.actor??a.spawn_role??"worker"}:${a.spawn_agent??a.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${a.actor??a.spawn_role??"worker"}</strong>
                  <span>${rn(a.status)}</span>
                  <span>${a.spawn_agent??a.runtime_pool??"runtime 확인 필요"}</span>
                </div>
                <div class="ops-log-body">
                  ${a.worker_class??"worker"}${a.lane_id?` · ${a.lane_id}`:""}${a.routing_reason?` · ${a.routing_reason}`:""}
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
          <${N} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>

        ${s?i`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${s.session_id}</div>
            <div class="ops-detail-meta">
              <span>상태: ${rn(s.status)}</span>
              <span>경과: ${s.elapsed_sec??0}초</span>
              <span>남은 시간: ${s.remaining_sec??0}초</span>
            </div>
            ${s.recent_events&&s.recent_events.length>0?i`
              <pre class="ops-code-block compact">${qr(s.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:i`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row ops-split-row">
          <select
            id="ops-turn-kind"
            class="control-input ops-select"
            value=${Tt.value}
            onChange=${a=>{Tt.value=a.target.value}}
            disabled=${H.value||!s}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
          </select>
          <button class="control-btn" onClick=${()=>{Uv()}} disabled=${H.value||!s}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${Ev(Tt.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${Rn.value}
          onInput=${a=>{Rn.value=a.target.value}}
          disabled=${H.value||!s}
        ></textarea>

        ${Tt.value==="task"?i`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${Ln.value}
            onInput=${a=>{Ln.value=a.target.value}}
            disabled=${H.value||!s}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${Nn.value}
            onInput=${a=>{Nn.value=a.target.value}}
            disabled=${H.value||!s}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${Mn.value}
            onChange=${a=>{Mn.value=a.target.value}}
            disabled=${H.value||!s}
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
            value=${js.value}
            onInput=${a=>{js.value=a.target.value}}
            disabled=${H.value||!s}
          />
          <button class="control-btn ghost" onClick=${()=>{Bv()}} disabled=${H.value||!s}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function Vv(){var a;const t=mt.value,e=(t==null?void 0:t.keepers)??[],n=(t==null?void 0:t.available_actions)??[],s=e.find(o=>o.name===Os.value)??e[0]??null;return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${N} panelId="intervene.keeper_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${e.length===0?i`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:e.map(o=>i`
            <button
              key=${o.name}
              class="ops-entity-card ${(s==null?void 0:s.name)===o.name?"active":""}"
              onClick=${()=>{Os.value=o.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${o.name}</strong>
                <span class="status-badge ${o.status??"idle"}">${rn(o.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${o.model??"model 확인 필요"}</span>
                <span>${typeof o.context_ratio=="number"?`${Math.round(o.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${Nv(o.last_turn_ago_s)}</span>
              </div>
            </button>
          `)}
        </div>
      </section>

      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Keeper 액션</div>
          <${N} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 keeper에만 직접 메시지를 보내서 probe, 수정, 재지시를 합니다.</p>

        ${s?i`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${s.name}</div>
            <div class="ops-detail-meta">
              <span>자율성: ${s.autonomy_level??"확인 없음"}</span>
              <span>세대: ${s.generation??0}</span>
              <span>활성 목표: ${((a=s.active_goal_ids)==null?void 0:a.length)??0}</span>
            </div>
          </div>
        `:i`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

        <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
        <textarea
          id="ops-keeper-message"
          class="control-textarea"
          rows=${6}
          placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
          value=${qe.value}
          onInput=${o=>{qe.value=o.target.value}}
          disabled=${H.value||!s}
        ></textarea>
        <div class="control-row">
          <button class="control-btn" onClick=${()=>{Hv()}} disabled=${H.value||!s||qe.value.trim()===""}>
            keeper에 보내기
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">가능한 액션 목록</div>
          <${N} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
        <div class="ops-log-list">
          ${n.length?n.map(o=>i`
                <article key=${`${o.action_type}:${o.target_type}`} class="ops-log-entry">
                  <div class="ops-log-head">
                    <strong>${qs(o.action_type)}</strong>
                    <span>${Fs(o.target_type)}</span>
                    <span>${Fr(o.confirm_required)}</span>
                  </div>
                  <div class="ops-log-body">${o.description??"설명이 아직 없습니다."}</div>
                </article>
              `):i`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 개입 로그</div>
          <${N} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <div class="ops-log-list">
          ${As.value.length===0?i`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:As.value.map(o=>i`
            <article key=${o.id} class="ops-log-entry ${o.outcome}">
              <div class="ops-log-head">
                <strong>${qs(o.action_type)}</strong>
                <span>${o.target_label}</span>
                <span>${o.at}</span>
              </div>
              <div class="ops-log-body">${o.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function Yv(){var x,w;const t=mt.value,e=M.value.tab==="intervene"?On(M.value):null,n=yi.value,s=(t==null?void 0:t.room)??{},a=(t==null?void 0:t.sessions)??[],o=(t==null?void 0:t.keepers)??[],l=(t==null?void 0:t.pending_confirms)??[],c=a.find(C=>C.session_id===We.value)??a[0]??null,p=(n==null?void 0:n.attention_items)??[],m=p.filter(Dv),u=p.filter(zv),v=a.filter(C=>Mv(C)!=="ok"),g=o.filter(C=>pa(C)!=="ok"),$=qv(e,a,o);Z(()=>{me()},[]),Z(()=>{if(M.value.tab!=="intervene"){Zn.value=null;return}if(!e){Zn.value=null;return}Zn.value!==e.id&&(Zn.value=e.id,Ov(e))},[M.value.tab,M.value.params.source,M.value.params.action_type,M.value.params.target_type,M.value.params.target_id,M.value.params.focus_kind,e==null?void 0:e.id]),Z(()=>{const C=(c==null?void 0:c.session_id)??null;He(C)},[c==null?void 0:c.session_id]);const b=[{key:"room",label:"Room 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:l.length,detail:l.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:l.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:m.length>0?m.length:a.length,detail:m.length>0?((x=m[0])==null?void 0:x.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:m.length>0?so(m):a.length===0?"warn":v.some(C=>Ge(C.status)==="paused")?"bad":v.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:u.length>0?u.length:g.length,detail:u.length>0?((w=u[0])==null?void 0:w.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":g.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:u.length>0?so(u):g.some(C=>pa(C)==="bad")?"bad":g.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${pt} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">Intervene</div>
            <${N} panelId="intervene.action_studio" compact=${!0} />
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
            value=${na.value}
            onInput=${C=>Lv(C.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{ut(),me(),He((c==null?void 0:c.session_id)??null)}}
            disabled=${An.value||H.value}
          >
            ${An.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Yt.value?i`<section class="ops-banner error">${Yt.value}</section>`:null}
      ${Be.value?i`<section class="ops-banner error">${Be.value}</section>`:null}
      ${e?i`
        <section class="ops-banner ${$?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${Zs(e.action_type)}</span>
            <span>${gi(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?i`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${$?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const C=[];if(l.length>0&&C.push({label:`확인 대기 ${l.length}건 처리`,desc:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:"bad",onClick:()=>{const A=document.querySelector(".ops-pending-section");A==null||A.scrollIntoView({behavior:"smooth"})}}),s.paused&&C.push({label:"Room 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void Kr()}),g.length>0){const A=g.filter(S=>pa(S)==="bad");C.push({label:A.length>0?`Keeper ${A.length}개 오프라인`:`Keeper ${g.length}개 점검 필요`,desc:A.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:A.length>0?"bad":"warn",onClick:()=>{const S=document.querySelector(".ops-keeper-section");S==null||S.scrollIntoView({behavior:"smooth"})}})}return C.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${C.slice(0,3).map(A=>i`
                <button class="ops-action-guide-item ${A.tone}" onClick=${A.onClick}>
                  <strong>${A.label}</strong>
                  <span>${A.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `})()}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${N} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 room인지, session인지, keeper인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${b.map(C=>i`
            <div key=${C.key} class="ops-priority-card ${C.tone}">
              <span class="ops-priority-label">${C.label}</span>
              <strong>${C.value}</strong>
              <div class="ops-priority-detail">${C.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${Gv} />
        <${Jv} />
        <${Vv} />
      </div>
    </section>
  `}function Qv({text:t}){if(!t)return null;const e=Xv(t);return i`<div class="markdown-content">${e}</div>`}function Xv(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),p=[];for(s++;s<e.length&&!e[s].startsWith(l);)p.push(e[s]),s++;s++,n.push(i`<pre><code class=${c?`language-${c}`:""}>${p.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<e.length&&!e[s].includes("</think>");)l.push(e[s]),s++;if(s<e.length){const m=e[s].replace("</think>","").trim();m&&l.push(m),s++}const p=l.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${ma(p)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<e.length&&e[s].startsWith("> ");)l.push(e[s].slice(2)),s++;n.push(i`<blockquote>${ma(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<e.length;){const l=e[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;o.push(l),s++}o.length>0&&n.push(i`<p>${ma(o.join(`
`))}</p>`)}return n}function ma(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&e.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Ur=[{id:"recent",label:"Latest"},{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],us=f(null),ps=f([]),Je=f(!1),de=f(null),vn=f(""),_n=f(!1),Ie=f(!0),Pi=20,ke=f(Pi);function Zv(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const t_=f(Zv());function e_(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function io(t){return t.updated_at!==t.created_at}function n_(t){const e=`${t.title} ${t.author} ${t.tags.join(" ")} ${t.flair??""}`.toLowerCase();return/\b(test|smoke|harness|sandbox|dummy|sample|tmp|qa|e2e)\b/.test(e)||e.includes("테스트")||e.includes("실험")}function s_(t){if(t.post_kind)return t.post_kind==="automation";const e=(t.hearth??"").toLowerCase();return t.visibility!=="internal"||!t.expires_at||!e?!1:!!(e.startsWith("mdal")||e.includes("harness"))}function Br(t){return Ie.value?t.filter(e=>s_(e)?!1:e.post_kind||e.hearth||e.visibility||e.expires_at?!0:!n_(e)):t}async function Ri(t){de.value=t,us.value=null,ps.value=[],Je.value=!0;try{const e=await tc(t);if(de.value!==t)return;us.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,post_kind:e.post_kind,flair:e.flair,hearth:e.hearth,visibility:e.visibility,expires_at:e.expires_at,hearth_count:e.hearth_count},ps.value=e.comments??[]}catch{de.value===t&&(us.value=null,ps.value=[])}finally{de.value===t&&(Je.value=!1)}}async function oo(t){const e=vn.value.trim();if(e){_n.value=!0;try{await ec(t,t_.value,e),vn.value="",P("Comment posted","success"),await Ri(t),Ht()}catch{P("Failed to post comment","error")}finally{_n.value=!1}}}function a_(){const t=bn.value,e=Ie.value?"Hiding automation posts":"Show automation posts";return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Ur.map(n=>i`
          <button
            class="board-sort-btn ${t===n.id?"active":""}"
            onClick=${()=>{bn.value=n.id,ke.value=Pi,Ht()}}
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
          class="control-btn ghost ${Se.value?"is-active":""}"
          onClick=${()=>{Se.value=!Se.value,Ht()}}
        >
          ${Se.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${Ht} disabled=${kn.value}>
          ${kn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function va(){var s;const t=((s=Ur.find(a=>a.id===bn.value))==null?void 0:s.label)??bn.value,e=Br(yn.value),n=yn.value.length-e.length;return i`
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
        <strong>${Se.value?"Auto reports hidden":"Full memory feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Wa.value?i`<${X} timestamp=${Wa.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function i_({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Po(t.id,n),Ht()}catch{P("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>ml(t.id)}>
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
                ${io(t)?i`<span class="board-meta-chip">Updated</span>`:null}
                ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${X} timestamp=${t.created_at} /></span>
            ${io(t)?i`<span>Updated <${X} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${e_(t.content)}</div>
      </div>
    </div>
  `}function o_({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${X} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function r_({postId:t}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${vn.value}
        onInput=${e=>{vn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&oo(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${_n.value}
      />
      <button
        onClick=${()=>oo(t)}
        disabled=${_n.value||vn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${_n.value?"...":"Post"}
      </button>
    </div>
  `}function l_({post:t}){de.value!==t.id&&!Je.value&&Ri(t.id);const e=async n=>{try{await Po(t.id,n),Ht()}catch{P("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>lt("memory")}>← Back to Memory</button>
      <${T} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${Qv} text=${t.content} />
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

      <${T} title="Comments" semanticId="memory.feed">
        ${Je.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${o_} comments=${ps.value} />`}
        <${r_} postId=${t.id} />
      <//>
    </div>
  `}function c_(){const t=Br(yn.value),e=M.value.params.post??null,n=e?t.find(s=>s.id===e)??(de.value===e?us.value:null):null;return e&&!n&&de.value!==e&&!Je.value&&Ri(e),e?n?i`
          <${pt} surfaceId="memory" />
          <${va} />
          <${l_} post=${n} />
        `:i`
          <div>
            <${pt} surfaceId="memory" />
            <${va} />
            <button class="back-btn" onClick=${()=>lt("memory")}>← Back to Memory</button>
            ${Je.value?i`<div class="loading-indicator">Loading post...</div>`:i`<div class="empty-state">Post not found</div>`}
          </div>
        `:i`
    <div>
      <${pt} surfaceId="memory" />
      <${va} />
      <${a_} />
      ${kn.value?i`<div class="loading-indicator">Loading memory feed...</div>`:t.length===0?i`<div class="empty-state">No posts in durable memory right now</div>`:i`
              <${T} title="Posts / Comments" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.slice(0,ke.value).map(s=>i`<${i_} key=${s.id} post=${s} />`)}
                </div>
                ${t.length>ke.value?i`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{ke.value=ke.value+Pi}}
                    >
                      Show more (${t.length-ke.value} remaining)
                    </button>
                  </div>
                `:null}
              <//>
            `}
    </div>
  `}function Hr({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,o=2*Math.PI*s,l=o*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),i`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${c}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${o}" 
          stroke-dashoffset="${l}" 
        />
      </svg>
      <span class="mitosis-text ${c}">${Math.round(t*100)}%</span>
    </div>
  `}const _a=600*1e3,d_=1200*1e3,ro=.8;function Ft(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ye(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function u_(t){switch(t){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function p_(t){switch(t){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function m_(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function v_(t){var e,n,s,a;return((n=(e=t.agent)==null?void 0:e.current_task)==null?void 0:n.trim())||((s=t.skill_primary)==null?void 0:s.trim())||((a=t.last_proactive_reason)==null?void 0:a.trim())||"현재 포커스 없음"}function __(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function f_(t){var p,m;const e=pi.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,s=n?Math.max(0,Date.now()-Ft(n)):Number.POSITIVE_INFINITY,a=!!((p=t.current_task)!=null&&p.trim())||e.activeAssignedCount>0;let o="watching",l="ok",c="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",l="bad",c=n?"Offline or inactive":"No recent presence"):s>d_?(o="quiet",l="bad",c=a?"Working without a fresh signal":"No fresh agent signal"):a?(o="working",l=s>_a?"warn":"ok",c=s>_a?"Execution looks quiet for too long":"Task and live signal aligned"):s>_a?(o="quiet",l="warn",c="Quiet but still reachable"):t.status==="idle"&&(o="watching",l="ok",c="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:l,focus:((m=t.current_task)==null?void 0:m.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:c}}function g_(t){const e=sd.value.get(t.name)??"idle",n=od.value.has(t.name),s=t.context_ratio??0;let a="healthy",o="ok",l="하트비트와 컨텍스트 상태가 안정적입니다";return t.status==="offline"||n||e==="handoff-imminent"?(a="critical",o="bad",l=n?"하트비트 지연":e==="handoff-imminent"?"핸드오프 임박":"keeper 오프라인"):(e==="preparing"||e==="compacting"||s>=ro)&&(a="warning",o="warn",l=s>=ro?"컨텍스트 압력이 높습니다":e==="compacting"?"컴팩팅 진행 중":"핸드오프 준비 중"),{keeper:t,lifecycle:e,state:a,tone:o,focus:v_(t),note:l}}function sn({label:t,value:e,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function $_({item:t}){const e=t.kind==="agent"?()=>Ue(t.agent.name):()=>ki(t.keeper);return i`
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
  `}function lo({row:t}){const{agent:e,motion:n}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Ue(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Hr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Xt} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${u_(t.state)}</span>
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
  `}function h_({row:t}){const{keeper:e}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>ki(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Hr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Xt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${p_(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?i`<span>하트비트 <${X} timestamp=${e.last_heartbeat} /></span>`:i`<span>하트비트 없음</span>`}
        <span>${__(e)}</span>
        <span>라이프사이클 ${t.lifecycle}</span>
        <span>컨텍스트 ${m_(e.context_ratio)}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?i`<div class="monitor-footnote">스킬 라우팅: ${e.skill_reason}</div>`:null}
    </button>
  `}function y_(){const t=[...bt.value].map(f_).sort((u,v)=>{const g=ye(v.tone)-ye(u.tone);if(g!==0)return g;const $=v.activeTaskCount-u.activeTaskCount;return $!==0?$:Ft(v.lastSignalAt)-Ft(u.lastSignalAt)}),e=[...Et.value].map(g_).sort((u,v)=>{const g=ye(v.tone)-ye(u.tone);if(g!==0)return g;const $=(v.keeper.context_ratio??0)-(u.keeper.context_ratio??0);return $!==0?$:Ft(v.keeper.last_heartbeat)-Ft(u.keeper.last_heartbeat)}),n=t.filter(u=>u.state!=="offline"),s=t.filter(u=>u.state==="offline"),a=n.length,o=t.filter(u=>u.state==="working").length,l=t.filter(u=>u.lastSignalAt&&Date.now()-Ft(u.lastSignalAt)<=12e4).length,c=t.filter(u=>u.tone!=="ok"),p=e.filter(u=>u.tone!=="ok"),m=[...p.map(u=>({kind:"keeper",key:`keeper-${u.keeper.name}`,tone:u.tone,title:u.keeper.name,subtitle:`${u.note} · ${u.focus}`,timestamp:u.keeper.last_heartbeat??null,keeper:u.keeper})),...c.map(u=>({kind:"agent",key:`agent-${u.agent.name}`,tone:u.tone,title:u.agent.name,subtitle:`${u.note} · ${u.focus}`,timestamp:u.lastSignalAt,agent:u.agent}))].sort((u,v)=>{const g=ye(v.tone)-ye(u.tone);return g!==0?g:Ft(v.timestamp)-Ft(u.timestamp)}).slice(0,8);return i`
    <div class="agents-monitor">
      <${pt} surfaceId="execution" />
      <div class="stats-grid">
        <${sn} label="온라인 worker" value=${a} color="#4ade80" caption="활성 + 대기 실행 주체" />
        <${sn} label="지금 작업 중" value=${o} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${sn} label="신선한 신호" value=${l} color="#22d3ee" caption="최근 2분 이내 신호" />
        <${sn} label="worker 경고" value=${c.length} color=${c.length>0?"#fb7185":"#4ade80"} caption="실행 주체 경고" />
        <${sn} label="연속성 경고" value=${p.length} color=${p.length>0?"#fb7185":"#4ade80"} caption="keeper 연속성 경고" />
      </div>

      <${T} title="Execution Priorities" class="section" semanticId="execution.priority_queue">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">지금 실행 관점에서 먼저 봐야 할 대상</h2>
          <p class="monitor-subheadline">worker 드리프트와 keeper 연속성 위험은 여기서 함께 우선순위를 매기고, 아래 섹션에서 각각 따로 진단합니다.</p>
        </div>
        <div class="monitor-alert-list">
          ${m.length===0?i`<div class="empty-state">지금은 실행 경고가 없습니다</div>`:m.map(u=>i`<${$_} key=${u.key} item=${u} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${T} title="Workers" class="section" semanticId="execution.workers">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">단기 실행 모니터</h2>
            <p class="monitor-subheadline">현재 살아 있는 worker를 먼저 묶어서, 누가 일을 잃었는지 오프라인 이력보다 먼저 보이게 합니다.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?i`<div class="empty-state">보이는 활성 worker가 없습니다</div>`:n.map(u=>i`<${lo} key=${u.agent.name} row=${u} />`)}
          </div>
        <//>

        <${T} title="Continuity" class="section" semanticId="execution.continuity">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">장기 keeper 연속성</h2>
            <p class="monitor-subheadline">하트비트, 컨텍스트 압력, 핸드오프 상태를 worker 실행 드리프트와 분리해서 봅니다.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?i`<div class="empty-state">활성 keeper가 없습니다</div>`:e.map(u=>i`<${h_} key=${u.keeper.name} row=${u} />`)}
          </div>
        <//>

        <${T} title="Offline Workers" class="section" semanticId="execution.offline">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">라이브 루프에서 빠진 worker</h2>
            <p class="monitor-subheadline">오프라인 row를 분리해서, 활성 실행 모니터가 묻히지 않게 합니다.</p>
          </div>
          <div class="monitor-list">
            ${s.length===0?i`<div class="empty-state">지금은 오프라인 worker가 없습니다</div>`:s.map(u=>i`<${lo} key=${u.agent.name} row=${u} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Ks=f("all"),Us=f("all"),ti=f(new Set);function b_(t){const e=new Set(ti.value);e.has(t)?e.delete(t):e.add(t),ti.value=e}const Wr=yt(()=>{let t=Re.value;return Ks.value!=="all"&&(t=t.filter(e=>e.horizon===Ks.value)),Us.value!=="all"&&(t=t.filter(e=>e.status===Us.value)),t}),k_=yt(()=>{const t={short:[],mid:[],long:[]};for(const e of Wr.value){const n=t[e.horizon];n&&n.push(e)}return t}),x_=yt(()=>{const t=Array.from(zo.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function S_(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Li(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function ms(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function A_(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function co(t){return t.toFixed(4)}function uo(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function C_(t){switch(t){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function po(t,e){return(t.priority??4)-(e.priority??4)}function w_(t,e){const n=t.updated_at??t.created_at??"";return(e.updated_at??e.created_at??"").localeCompare(n)}function T_(t,e){return t.length<=e?t:t.slice(0,e)+"..."}function I_({goal:t}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ms(t.horizon)}">
            ${Li(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${S_(t.priority)}</span>
          ${t.metric?i`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?i`<span class="goal-due">Due: <${X} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?i`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${Xt} status=${t.status} />
        <div class="goal-updated">
          <${X} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function fa({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return i`
    <${T} title="${Li(t)} Goals (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${I_} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function P_(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>i`
          <button
            class="goal-filter-btn ${Ks.value===t?"active":""}"
            onClick=${()=>{Ks.value=t}}
          >
            ${t==="all"?"All":Li(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>i`
          <button
            class="goal-filter-btn ${Us.value===t?"active":""}"
            onClick=${()=>{Us.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function R_(){const t=Re.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return i`
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
        <div class="goal-summary-value" style="color:${ms("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ms("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ms("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function L_({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return i`
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
          <span>Baseline ${co(t.baseline_metric)}</span>
          <span>Current ${co(t.current_metric)}</span>
          <span class=${uo(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${uo(t)}
          </span>
          <span>Elapsed ${A_(t.elapsed_seconds)}</span>
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
  `}function ga({task:t}){const e=t.priority??4,n=e<=1?"p1":e===2?"p2":e===3?"p3":"p4",s=ti.value.has(t.id),a=!!t.description;return i`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${C_(e)}</span>
        <div class="kanban-card-title">${t.title}</div>
      </div>
      ${a?i`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>b_(t.id)}
        >
          ${s?t.description:T_(t.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${t.created_at?i`<${X} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function N_(){const{todo:t,inProgress:e,done:n}=jo.value,s=[...t].sort(po),a=[...e].sort(po),o=[...n].sort(w_);return i`
    <${T} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${s.length===0?i`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:s.map(l=>i`<${ga} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${a.length===0?i`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:a.map(l=>i`<${ga} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${o.length===0?i`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:o.slice(0,20).map(l=>i`<${ga} key=${l.id} task=${l} />`)}
          ${o.length>20?i`<div class="empty-state" style="opacity: 0.5;">...and ${o.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function M_(){const{todo:t,inProgress:e,done:n}=jo.value,s=t.length+e.length+n.length,a=[...t,...e].filter(u=>(u.priority??4)<=2).length,o=k_.value,l=x_.value,c=Re.value.length>0,p=l.length>0,m=di.value;return i`
    <div>
      <${pt} surfaceId="planning" />

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
          onClick=${()=>{mi(),Uo()}}
          disabled=${cn.value||dn.value}
        >
          ${cn.value||dn.value?"Refreshing...":"Refresh planning data"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${N_} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          Goal Pipeline
          <span class="monitor-pill">${Re.value.length}</span>
        </summary>
        <div>
          ${c?i`
            <${R_} />
            <${P_} />
            ${cn.value&&Re.value.length===0?i`<div class="loading-indicator">Loading goals...</div>`:Wr.value.length===0?i`<div class="empty-state">No goals match the current filters</div>`:i`
                    <${fa} horizon="short" items=${o.short??[]} />
                    <${fa} horizon="mid" items=${o.mid??[]} />
                    <${fa} horizon="long" items=${o.long??[]} />
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
          ${dn.value&&l.length===0?i`<div class="loading-indicator">Loading MDAL loops...</div>`:l.length===0&&(m==="error"||Le.value)?i`<div class="empty-state">MDAL snapshot could not be loaded${Le.value?`: ${Le.value}`:""}. Check backend health.</div>`:l.length===0?i`<div class="empty-state">No active loops. Use <code>masc_mdal_start</code> to start a loop.</div>`:i`
                  <div class="planning-loop-list">
                    ${l.map(u=>i`<${L_} key=${u.loop_id} loop=${u} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const fn=f("debates"),Bs=f([]),Hs=f([]),Ws=f(!1),gn=f(!1),Dn=f(""),$n=f(""),Gs=f(null),St=f(null),ei=f(!1);async function sa(){Ws.value=!0,Dn.value="";try{const t=await Dl();Bs.value=Array.isArray(t.debates)?t.debates:[],Hs.value=Array.isArray(t.sessions)?t.sessions:[]}catch(t){Dn.value=t instanceof Error?t.message:"Failed to load governance state"}finally{Ws.value=!1}}bd(sa);async function mo(){const t=$n.value.trim();if(t){gn.value=!0;try{const e=await Tc(t);$n.value="",P(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await sa()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";P(n,"error")}finally{gn.value=!1}}}async function D_(t){Gs.value=t,St.value=null,ei.value=!0;try{St.value=await Ic(t)}catch(e){Dn.value=e instanceof Error?e.message:"Failed to load debate detail"}finally{ei.value=!1}}function z_(){return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${Bs.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Voting sessions</span>
        <strong>${Hs.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Active view</span>
        <strong>${fn.value==="debates"?"Debates":"Voting"}</strong>
      </div>
    </div>
  `}function E_({debate:t}){const e=Gs.value===t.id;return i`
    <button class="council-row ${e?"selected":""}" onClick=${()=>D_(t.id)}>
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
  `}function j_({session:t}){return i`
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
  `}function O_(){const t=fn.value;return i`
    <div class="overview-sub-tabs" style="margin-bottom:12px;">
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{fn.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{fn.value="voting"}}>Voting</button>
    </div>
  `}function q_(){return i`
    <div>
      <${T} title="Start Debate" class="section" semanticId="governance.debates">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${$n.value}
            onInput=${t=>{$n.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&mo()}}
            disabled=${gn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${mo}
            disabled=${gn.value||$n.value.trim()===""}
          >
            ${gn.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${sa} disabled=${Ws.value}>
            ${Ws.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Dn.value?i`<div class="council-error">${Dn.value}</div>`:null}
      <//>

      <${T} title="Debates" class="section" semanticId="governance.debates">
        <div class="council-list">
          ${Bs.value.length===0?i`<div class="empty-state">No debates yet</div>`:Bs.value.map(t=>i`<${E_} key=${t.id} debate=${t} />`)}
        </div>
      <//>

      <${T} title=${Gs.value?`Debate Detail (${Gs.value})`:"Debate Detail"} class="section" semanticId="governance.debates">
        ${ei.value?i`<div class="loading-indicator">Loading debate detail...</div>`:St.value?i`
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Status: ${St.value.status}</span>
                  <span>Total arguments: ${St.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Support: ${St.value.support_count}</span>
                  <span>Oppose: ${St.value.oppose_count}</span>
                  <span>Neutral: ${St.value.neutral_count}</span>
                </div>
                ${St.value.summary_text?i`<pre class="council-detail">${St.value.summary_text}</pre>`:null}
              `:i`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function F_(){return i`
    <${T} title="Voting Sessions" class="section" semanticId="governance.voting">
      <div class="council-list">
        ${Hs.value.length===0?i`<div class="empty-state">No active sessions</div>`:Hs.value.map(t=>i`<${j_} key=${t.id} session=${t} />`)}
      </div>
    <//>
  `}function K_(){return Z(()=>{sa()},[]),i`
    <div>
      <${pt} surfaceId="governance" />
      <${z_} />
      <${O_} />
      ${fn.value==="debates"?i`<${q_} />`:i`<${F_} />`}
    </div>
  `}const xe=f(""),$a=f("ability_check"),ha=f("10"),ya=f("12"),ts=f(""),es=f("idle"),Kt=f(""),ns=f("keeper-late"),ba=f("player"),ka=f(""),ft=f("idle"),xa=f(null),ss=f(""),Sa=f(""),Aa=f("player"),Ca=f(""),wa=f(""),Ta=f(""),hn=f("20"),Ia=f("20"),Pa=f(""),as=f("idle"),ni=f(null),Gr=f("overview"),Ra=f("all"),La=f("all"),Na=f("all"),U_=12e4,aa=f(null),vo=f(Date.now());function B_(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function H_(t,e){return e>0?Math.round(t/e*100):0}const W_={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},G_={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function is(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function J_(t){const e=t.trim().toLowerCase();return W_[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function V_(t){const e=t.trim().toLowerCase();return G_[e]??"상황에 따라 선택되는 전술 액션입니다."}function dt(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function At(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function zn(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const Y_=new Set(["str","dex","con","int","wis","cha"]);function Q_(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!_(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const l=a.trim();if(l){if(typeof o=="number"&&Number.isFinite(o)){s[l]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const c=Number.parseFloat(o.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function X_(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(hn.value.trim(),10);Number.isFinite(s)&&s>n&&(hn.value=String(n))}function si(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Z_(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function tf(t){Gr.value=t}function Jr(t){const e=aa.value;return e==null||e<=t}function ef(t){const e=aa.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Js(){aa.value=null}function Vr(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function nf(t,e){Vr(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(aa.value=Date.now()+U_,P("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function vs(t){return Jr(t)?(P("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function ai(t,e,n){return Vr([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function sf({hp:t,max:e}){const n=H_(t,e),s=B_(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function af({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function of({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Yr({actor:t}){var p,m,u,v;const e=(p=t.archetype)==null?void 0:p.trim(),n=(m=t.persona)==null?void 0:m.trim(),s=(u=t.portrait)==null?void 0:u.trim(),a=(v=t.background)==null?void 0:v.trim(),o=t.traits??[],l=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([g,$])=>Number.isFinite($)).filter(([g])=>!Y_.has(g.toLowerCase()));return i`
    <div class="trpg-actor">
      ${s?i`
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
        <${Xt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${of} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${sf} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${af} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${is(e)}</div>`:null}
      ${a?i`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([g,$])=>i`
                <span class="trpg-custom-stat-chip">${is(g)} ${$}</span>
              `)}
            </div>
          </div>
        `:null}
      ${o.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${o.map(g=>i`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${is(g)}</span>
                  <span class="trpg-annot-desc">${J_(g)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${l.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${l.map(g=>i`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${is(g)}</span>
                  <span class="trpg-annot-desc">${V_(g)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function rf({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function Qr({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?i`<div class="empty-state" style="font-size:13px">${e}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Z_(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${si(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${X} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function lf({events:t}){const e="__none__",n=Ra.value,s=La.value,a=Na.value,o=Array.from(new Set(t.map(si).map(v=>v.trim()).filter(v=>v!==""))).sort((v,g)=>v.localeCompare(g)),l=Array.from(new Set(t.map(v=>(v.type??"").trim()).filter(v=>v!==""))).sort((v,g)=>v.localeCompare(g)),c=t.some(v=>(v.type??"").trim()===""),p=Array.from(new Set(t.map(v=>(v.phase??"").trim()).filter(v=>v!==""))).sort((v,g)=>v.localeCompare(g)),m=t.some(v=>(v.phase??"").trim()===""),u=t.filter(v=>{if(n!=="all"&&si(v)!==n)return!1;const g=(v.type??"").trim(),$=(v.phase??"").trim();if(s===e){if(g!=="")return!1}else if(s!=="all"&&g!==s)return!1;if(a===e){if($!=="")return!1}else if(a!=="all"&&$!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${v=>{Ra.value=v.target.value}}>
          <option value="all">all</option>
          ${o.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${v=>{La.value=v.target.value}}>
          <option value="all">all</option>
          ${c?i`<option value=${e}>(none)</option>`:null}
          ${l.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${v=>{Na.value=v.target.value}}>
          <option value="all">all</option>
          ${m?i`<option value=${e}>(none)</option>`:null}
          ${p.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Ra.value="all",La.value="all",Na.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${u.length} / 전체 ${t.length}
      </span>
    </div>
    <${Qr} events=${u.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function cf({outcome:t}){if(!t)return null;const e=o=>{const l=o.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function Xr({state:t}){const e=t.history??[];return e.length===0?null:i`
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
  `}function df({state:t,nowMs:e}){var m;const n=Mt.value||((m=t.session)==null?void 0:m.room)||"",s=es.value,a=t.party??[];if(!a.find(u=>u.id===xe.value)&&a.length>0){const u=a[0];u&&(xe.value=u.id)}const l=async()=>{var v,g;if(!n){P("Room ID가 비어 있습니다.","error");return}if(!vs(e))return;const u=((v=t.current_round)==null?void 0:v.phase)??((g=t.session)==null?void 0:g.status)??"unknown";if(ai("라운드 실행",n,u)){es.value="running";try{const $=await gc(n);ni.value=$,es.value="ok";const b=_($.summary)?$.summary:null,x=b?zn(b,"advanced",!1):!1,w=b?dt(b,"progress_reason",""):"";P(x?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${w?`: ${w}`:""}`,x?"success":"warning"),Wt()}catch($){ni.value=null,es.value="error";const b=$ instanceof Error?$.message:"라운드 실행에 실패했습니다.";P(b,"error")}finally{Js()}}},c=async()=>{var v,g;if(!n||!vs(e))return;const u=((v=t.current_round)==null?void 0:v.phase)??((g=t.session)==null?void 0:g.status)??"unknown";if(ai("턴 강제 진행",n,u))try{await yc(n),P("턴을 다음 단계로 이동했습니다.","success"),Wt()}catch{P("턴 이동에 실패했습니다.","error")}finally{Js()}},p=async()=>{if(!n||!vs(e))return;const u=xe.value.trim();if(!u){P("먼저 Actor를 선택하세요.","warning");return}const v=Number.parseInt(ha.value,10),g=Number.parseInt(ya.value,10);if(Number.isNaN(v)||Number.isNaN(g)){P("stat/dc는 숫자여야 합니다.","warning");return}const $=Number.parseInt(ts.value,10),b=ts.value.trim()===""||Number.isNaN($)?void 0:$;try{await hc({roomId:n,actorId:u,action:$a.value.trim()||"ability_check",statValue:v,dc:g,rawD20:b}),P("주사위 판정을 기록했습니다.","success"),Wt()}catch{P("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${u=>{Mt.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${xe.value}
            onChange=${u=>{xe.value=u.target.value}}
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
              value=${$a.value}
              onInput=${u=>{$a.value=u.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${ha.value}
              onInput=${u=>{ha.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${ya.value}
              onInput=${u=>{ya.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${ts.value}
              onInput=${u=>{ts.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&p()}}
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
            <button class="trpg-run-btn secondary" onClick=${c}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${s!=="idle"?i`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function uf({state:t}){var a;const e=Mt.value||((a=t.session)==null?void 0:a.room)||"",n=as.value,s=async()=>{if(!e){P("Room ID가 비어 있습니다.","warning");return}const o=ss.value.trim(),l=Sa.value.trim();if(!l&&!o){P("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(hn.value.trim(),10),p=Number.parseInt(Ia.value.trim(),10),m=Number.isFinite(p)?Math.max(1,p):20,u=Number.isFinite(c)?Math.max(0,Math.min(m,c)):m;let v={};try{v=Q_(Pa.value)}catch(g){P(g instanceof Error?g.message:"능력치 JSON 오류","error");return}as.value="spawning";try{const g=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,$=await bc(e,{actor_id:o||void 0,name:l||void 0,role:Aa.value,idempotencyKey:g,portrait:wa.value.trim()||void 0,background:Ta.value.trim()||void 0,hp:u,max_hp:m,alive:u>0,stats:Object.keys(v).length>0?v:void 0}),b=typeof $.actor_id=="string"?$.actor_id.trim():"";if(!b)throw new Error("생성 응답에 actor_id가 없습니다.");const x=Ca.value.trim();x&&await kc(e,b,x),xe.value=b,Kt.value=b,o||(ss.value=""),as.value="ok",P(`Actor 생성 완료: ${b}`,"success"),await Wt()}catch(g){as.value="error",P(g instanceof Error?g.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Sa.value}
            onInput=${o=>{Sa.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Aa.value}
            onChange=${o=>{Aa.value=o.target.value}}
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
            value=${Ca.value}
            onInput=${o=>{Ca.value=o.target.value}}
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
              value=${ss.value}
              onInput=${o=>{ss.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${wa.value}
              onInput=${o=>{wa.value=o.target.value}}
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
              value=${hn.value}
              onInput=${o=>{hn.value=o.target.value}}
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
              value=${Ia.value}
              onInput=${o=>{const l=o.target.value;Ia.value=l,X_(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Ta.value}
              onInput=${o=>{Ta.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Pa.value}
              onInput=${o=>{Pa.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function pf({state:t,nowMs:e}){var g;const n=Mt.value||((g=t.session)==null?void 0:g.room)||"",s=t.join_gate,a=xa.value,o=_(a)?a:null,l=(t.party??[]).filter($=>$.role!=="dm"),c=Kt.value.trim(),p=l.some($=>$.id===c),m=p?c:c?"__manual__":"",u=async()=>{const $=Kt.value.trim(),b=ns.value.trim();if(!n||!$){P("Room/Actor가 필요합니다.","warning");return}ft.value="checking";try{const x=await xc(n,$,b||void 0);xa.value=x,ft.value="ok",P("참가 가능 여부를 갱신했습니다.","success")}catch(x){ft.value="error";const w=x instanceof Error?x.message:"참가 가능 여부 확인에 실패했습니다.";P(w,"error")}},v=async()=>{var C,A;const $=Kt.value.trim(),b=ns.value.trim(),x=ka.value.trim();if(!n||!$||!b){P("Room/Actor/Keeper가 필요합니다.","warning");return}if(!vs(e))return;const w=((C=t.current_round)==null?void 0:C.phase)??((A=t.session)==null?void 0:A.status)??"unknown";if(ai("Mid-Join 승인 요청",n,w)){ft.value="requesting";try{const S=await Sc({room_id:n,actor_id:$,keeper_name:b,role:ba.value,...x?{name:x}:{}});xa.value=S;const I=_(S)?zn(S,"granted",!1):!1,R=_(S)?dt(S,"reason_code",""):"";I?P("Mid-Join이 승인되었습니다.","success"):P(`Mid-Join이 거절되었습니다${R?`: ${R}`:""}`,"warning"),ft.value=I?"ok":"error",Wt()}catch(S){ft.value="error";const I=S instanceof Error?S.message:"Mid-Join 요청에 실패했습니다.";P(I,"error")}finally{Js()}}};return i`
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
            onChange=${$=>{const b=$.target.value;if(b==="__manual__"){(p||!c)&&(Kt.value="");return}Kt.value=b}}
          >
            <option value="">Actor 선택</option>
            ${l.map($=>i`
              <option value=${$.id}>${$.name} (${$.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${m==="__manual__"?i`
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
            value=${ns.value}
            onInput=${$=>{ns.value=$.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${ba.value}
            onChange=${$=>{ba.value=$.target.value}}
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
            value=${ka.value}
            onInput=${$=>{ka.value=$.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${u} disabled=${ft.value==="checking"||ft.value==="requesting"}>
              ${ft.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${v} disabled=${ft.value==="checking"||ft.value==="requesting"}>
              ${ft.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${zn(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${At(o,"effective_score",0)}/${At(o,"required_points",0)}</span>
            ${dt(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${dt(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Zr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function tl({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function el(){const t=ni.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=_(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(_).slice(-8),o=t.canon_check,l=_(o)?o:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(R=>typeof R=="string").slice(0,3):[],p=l&&Array.isArray(l.violations)?l.violations.filter(R=>typeof R=="string").slice(0,3):[],m=n?zn(n,"advanced",!1):!1,u=n?dt(n,"progress_reason",""):"",v=n?dt(n,"progress_detail",""):"",g=n?At(n,"player_successes",0):0,$=n?At(n,"player_required_successes",0):0,b=n?zn(n,"dm_success",!1):!1,x=n?At(n,"timeouts",0):0,w=n?At(n,"unavailable",0):0,C=n?At(n,"reprompts",0):0,A=n?At(n,"npc_attacks",0):0,S=n?At(n,"keeper_timeout_sec",0):0,I=n?At(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${m?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${m?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${b?"DM ok":"DM stalled"} / players ${g}/${$}
          </span>
        </div>
        ${u?i`<div style="margin-top:4px; font-size:12px;">${u}</div>`:null}
        ${v?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${v}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${w}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${S||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${I}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(R=>{const W=dt(R,"status","unknown"),B=dt(R,"actor_id","-"),vt=dt(R,"role","-"),tt=dt(R,"reason",""),et=dt(R,"action_type",""),q=dt(R,"reply","");return i`
                <div class="trpg-round-item ${W.includes("fallback")||W.includes("timeout")?"failed":"active"}">
                  <span>${B} (${vt})</span>
                  <span style="margin-left:auto; font-size:11px;">${W}</span>
                  ${et?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${et}</div>`:null}
                  ${tt?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${tt}</div>`:null}
                  ${q?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${q.slice(0,120)}</div>`:null}
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
                  ${p.map(R=>i`<div>violation: ${R}</div>`)}
                </div>`:null}
            ${c.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(R=>i`<div>warning: ${R}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function mf({state:t,nowMs:e}){var l,c,p;const n=Mt.value||((l=t.session)==null?void 0:l.room)||"",s=((c=t.current_round)==null?void 0:c.phase)??((p=t.session)==null?void 0:p.status)??"unknown",a=Jr(e),o=ef(e);return i`
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
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>nf(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{Js(),P("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function vf({active:t}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>tf(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function _f({state:t}){const e=t.party??[],n=t.story_log??[];return i`
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
          <${Qr} events=${n.slice(-20)} />
        <//>

        ${t.map?i`
            <${T} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${rf} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${T} title="현재 라운드" semanticId="lab.trpg">
          <${tl} state=${t} />
        <//>

        <${T} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${Zr} state=${t} />
        <//>

        <${T} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>i`<${Yr} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?i`
            <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${Xr} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function ff({state:t}){const e=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${T} title=${`이벤트 타임라인 (${e.length})`}>
          <${lf} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${T} title="최근 라운드 결과" semanticId="lab.trpg">
          <${el} />
        <//>

        <${T} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${tl} state=${t} />
        <//>
      </div>
    </div>
  `}function gf({state:t,nowMs:e}){const n=t.party??[];return i`
    <div>
      <${mf} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${T} title="조작 패널" semanticId="lab.trpg">
            <${df} state=${t} nowMs=${e} />
          <//>

          <${T} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${uf} state=${t} />
          <//>

          <${T} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${pf} state=${t} nowMs=${e} />
          <//>

          <${T} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${el} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${T} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${Zr} state=${t} />
          <//>

          <${T} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${Yr} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?i`
              <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${Xr} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function $f(){var c,p,m,u,v;const t=Do.value,e=Ha.value;if(Z(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const g=window.setInterval(()=>{vo.value=Date.now()},1e3);return()=>{window.clearInterval(g)}},[]),e&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Wt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,o=Gr.value,l=vo.value;return i`
    <div>
      <${pt} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Mt.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((p=t.current_round)==null?void 0:p.phase)??((m=t.session)==null?void 0:m.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Wt()}>새로고침</button>
      </div>

      <${cf} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((u=t.session)==null?void 0:u.status)??"active"}</div>
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

      <${vf} active=${o} />

      ${o==="overview"?i`<${_f} state=${t} />`:o==="timeline"?i`<${ff} state=${t} />`:i`<${gf} state=${t} nowMs=${l} />`}
    </div>
  `}function hf(){return i`
    <div>
      <${pt} surfaceId="lab" />
      <${T} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${T} title="TRPG" class="section" semanticId="lab.trpg">
        <${$f} />
      <//>
    </div>
  `}const Vs=f(new Set(["broadcast","tasks","keepers","system"]));function yf(t){const e=new Set(Vs.value);e.has(t)?e.delete(t):e.add(t),Vs.value=e}const Ni=f(null);function nl(t){Ni.value=t}function bf(t){return t.kind==="board"?"broadcast":t.kind==="tasks"?"tasks":t.kind==="keepers"?"keepers":"system"}const kf=yt(()=>{const t=Vs.value;return fs.value.filter(e=>t.has(bf(e)))}),xf=12e4,Sf=yt(()=>{const t=pi.value,e=Date.now();return bt.value.map(n=>{const s=n.name.trim().toLowerCase(),a=t.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?o=e-new Date(l).getTime()>xf?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),Af=yt(()=>{const t=pi.value;return bt.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle").map(e=>{const n=e.name.trim().toLowerCase(),s=t.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:e.name,emoji:e.emoji??"",koreanName:e.koreanName??null,currentTask:e.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((e,n)=>{const s={hot:0,normal:1,calm:2};return s[e.pressure]-s[n.pressure]})});function _o(t){return t.kind==="board"?"live-event-broadcast":t.kind==="tasks"?"live-event-task":t.kind==="keepers"?"live-event-keeper":"live-event-system"}function Cf(t){const e=t.eventType;return e==="broadcast"?"broadcast":e==="agent_joined"?"joined":e==="agent_left"?"left":e==="task_update"?"task":e==="board_post"?"post":e==="board_comment"?"comment":e==="keeper_heartbeat"?"heartbeat":e==="keeper_handoff"?"handoff":e==="keeper_compaction"?"compact":e==="keeper_guardrail"?"guardrail":t.kind==="board"?"board":t.kind==="tasks"?"task":t.kind==="keepers"?"keeper":"system"}function wf(t){switch(t){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function Tf(){const t=Sf.value,e=Ni.value;return t.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${t.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${wf(n.state)} ${e===n.name?"pulse-selected":""}"
          onClick=${()=>nl(e===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const If=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function Pf(){const t=Vs.value;return i`
    <div class="activity-filter-bar">
      ${If.map(e=>i`
        <button
          key=${e.kind}
          class="activity-filter-btn ${e.cssClass} ${t.has(e.kind)?"active":""}"
          onClick=${()=>yf(e.kind)}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Rf(){const t=kf.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${t.length} events</span>
      </div>
      <${Pf} />
      <div class="activity-stream-list">
        ${t.length===0?i`<div class="activity-empty">No events matching filters</div>`:t.map((e,n)=>i`
            <div
              key=${`${e.timestamp}-${n}`}
              class="activity-item ${_o(e)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${_o(e)}">${Cf(e)}</span>
                <span class="activity-agent">${e.agent}</span>
                <span class="activity-time">${sr(e.timestamp)}</span>
              </div>
              <div class="activity-item-text">${e.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function Lf(t){switch(t){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function Nf(t){switch(t){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function Mf(){const t=Af.value,e=Ni.value;return i`
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
              onClick=${()=>nl(e===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?i`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${Lf(n.pressure)}">
                  ${Nf(n.pressure)}
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
  `}function Df(){const t=Vt.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>Live Monitor</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${t?"connected":"disconnected"}"></span>
            ${t?"Connected":"Offline"}
          </span>
          <span class="live-stat">${bt.value.length} agents</span>
          <span class="live-stat">${Ys.value} events</span>
        </div>
      </div>

      <${Tf} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${Rf} />
        </div>
        <div class="live-panel-side">
          <${Mf} />
        </div>
      </div>
    </div>
  `}const fo=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],ii=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"proof",label:"Proof",icon:"🔍",group:"observe",description:"협업, 대화, 도구, backing evidence를 증명 중심으로 읽는 표면"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"live",label:"Live",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}];function zf(){const t=Vt.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"재연결 중..."}</span>
      <span class="event-count">${Ys.value} events</span>
    </div>
  `}function oi(t){t==="command"&&(we(),Ee(),(V.value==="swarm"||V.value==="warroom")&&Bt(),V.value==="warroom"&&ut()),t==="mission"&&(Ho(),bs()),t==="proof"&&vr(M.value.params.session_id,M.value.params.operation_id),t==="execution"&&re(),t==="intervene"&&(ut(),me()),t==="memory"&&Ht(),t==="planning"&&mi(),t==="lab"&&Wt()}function Ef({currentTab:t}){const e=Vt.value;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${N} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${e?"ok":"bad"}">${e?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agent</span>
          <strong>${bt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keeper</span>
          <strong>${Et.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Task</span>
          <strong>${It.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Event</span>
          <strong>${Ys.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{jn(),Fo(),oi(t)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>lt("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function jf(){const t=mt.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${N} panelId="side_rail.quick_actions" compact=${!0} />
        <span class="rail-section-chip ${e>0?"warn":"ok"}">${e>0?"확인 필요":"정상"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>확인 대기</span>
          <strong>${e}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Session</span>
          <strong>${n}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keeper</span>
          <strong>${s}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{ut(),me()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>lt("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function Of(){const t=M.value.tab,e=ii.find(s=>s.id===t),n=fo.find(s=>s.id===(e==null?void 0:e.group));return i`
    <aside class="dashboard-rail">
      <${pt} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${N} panelId="side_rail.navigate" compact=${!0} />
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${fo.map(s=>i`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${ii.filter(a=>a.group===s.id).map(a=>i`
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
          <div class="rail-view-note-label">현재 화면</div>
          <strong>${(e==null?void 0:e.label)??t}</strong>
          <p>${(e==null?void 0:e.description)??"운영 화면"}</p>
        </div>
      </section>

      <${Ef} currentTab=${t} />
      <${jf} />
    </aside>
  `}function qf(){switch(M.value.tab){case"mission":return i`<${Xi} />`;case"proof":return i`<${Wm} />`;case"execution":return i`<${y_} />`;case"live":return i`<${Df} />`;case"memory":return i`<${c_} />`;case"governance":return i`<${K_} />`;case"planning":return i`<${M_} />`;case"intervene":return i`<${Yv} />`;case"command":return i`<${Pv} />`;case"lab":return i`<${hf} />`;default:return i`<${Xi} />`}}function Ff(){Z(()=>{vl(),So(),Ko(),re(),Fo(),Ho();const n=Sd();return Ad(),()=>{kl(),n(),Cd()}},[]),Z(()=>{const n=setInterval(()=>{oi(M.value.tab)},15e3);return()=>{clearInterval(n)}},[]),Z(()=>{oi(M.value.tab)},[M.value.tab]);const t=M.value.tab,e=ii.find(n=>n.id===t);return i`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">${(e==null?void 0:e.description)??"운영자 의사결정 및 실행 콘솔"}</p>
        </div>
        <div class="header-right">
          <${zf} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${Of} />
        <main class="dashboard-main">
          ${Ba.value&&!Vt.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${qf} />`}
        </main>
      </div>

      <${lp} />
      <${Tu} />
      <${bu} />
    </div>
  `}const go=document.getElementById("app");go&&cl(i`<${Ff} />`,go);export{$p as _};
