var $l=Object.defineProperty;var hl=(t,e,n)=>e in t?$l(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var be=(t,e,n)=>hl(t,typeof e!="symbol"?e+"":e,n);import{e as yl,_ as bl,c as v,b as yt,y as Z,d as ko,A as kl,G as xl}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const l of o.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=yl.bind(bl);const Sl=["mission","proof","execution","live","memory","governance","planning","intervene","command","lab"],xo={tab:"mission",params:{},postId:null};function Ei(t){return!!t&&Sl.includes(t)}function Da(t){try{return decodeURIComponent(t)}catch{return t}}function Ea(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Cl(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function So(t,e){if(t[0]==="chains"){const o={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(o.operation=Da(t[2])),{tab:"command",params:o,postId:null}}if(t[0]==="lab"){const o={...e};return t[1]&&(o.surface=Da(t[1])),{tab:"lab",params:o,postId:null}}const n=t[0],s=e.tab;return{tab:Ei(n)?n:Ei(s)?s:"mission",params:e,postId:null}}function gs(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return xo;const n=Da(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=Ea(a),l=Cl(s);return So(l,o)}function Al(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...xo,params:Ea(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Ea(e.replace(/^\?/,""));return So(s,a)}function Co(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const N=v(gs(window.location.hash));window.addEventListener("hashchange",()=>{N.value=gs(window.location.hash)});function rt(t,e){const n={tab:t,params:e??{}};window.location.hash=Co(n)}function Il(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function Tl(){if(window.location.hash&&window.location.hash!=="#"){N.value=gs(window.location.hash);return}const t=Al(window.location.pathname,window.location.search);if(t){N.value=t;const e=Co(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",N.value=gs(window.location.hash)}const ji="masc_dashboard_sse_session_id",wl=1e3,Pl=15e3,Qt=v(!1),Xs=v(0),Ao=v(null),$s=v([]);function Rl(){let t=sessionStorage.getItem(ji);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(ji,t)),t}const Ll=200;function Ml(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};$s.value=[a,...$s.value].slice(0,Ll)}function ja(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Oi(t,e){const n=ja(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function ht(t,e,n,s,a={}){Ml(t,e,n,{eventType:s,...a})}let Ct=null,Me=null,Oa=0;function Io(){Me&&(clearTimeout(Me),Me=null)}function Nl(){if(Me)return;Oa++;const t=Math.min(Oa,5),e=Math.min(Pl,wl*Math.pow(2,t));Me=setTimeout(()=>{Me=null,To()},e)}function To(){Io(),Ct&&(Ct.close(),Ct=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Rl());const a=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(a);Ct=o,o.onopen=()=>{Ct===o&&(Oa=0,Qt.value=!0)},o.onerror=()=>{Ct===o&&(Qt.value=!1,o.close(),Ct=null,Nl())},o.onmessage=l=>{try{const c=JSON.parse(l.data);Xs.value++,Ao.value=c,zl(c)}catch{}}}function zl(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":ht(n,"Joined","system","agent_joined");break;case"agent_left":ht(n,"Left","system","agent_left");break;case"broadcast":ht(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":ht(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":ht(n,Oi("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:ja(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":ht(n,Oi("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:ja(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":ht(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":ht(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":ht(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":ht(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:ht(n,e,"system","unknown")}}function Dl(){Io(),Ct&&(Ct.close(),Ct=null),Qt.value=!1}function m(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function r(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function d(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function O(t){return typeof t=="boolean"?t:void 0}function q(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function At(t,e=[]){if(Array.isArray(t))return t;if(!m(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Ue(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function wo(){return new URLSearchParams(window.location.search)}function Po(){const t=wo(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function Ro(){return{...Po(),"Content-Type":"application/json"}}const El=15e3,ci=3e4,jl=6e4,qi=new Set([408,425,429,500,502,503,504]);class On extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);be(this,"method");be(this,"path");be(this,"status");be(this,"statusText");be(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function di(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const l=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new On({method:l,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function Ol(){var e,n;const t=wo();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function X(t){const e=await di(t,{headers:Po()},El);if(!e.ok)throw new On({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function ql(t){return new Promise(e=>setTimeout(e,t))}function Fl(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function Kl(t){if(t instanceof On)return t.timeout||typeof t.status=="number"&&qi.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=Fl(t.message);return e!==null&&qi.has(e)}async function Lo(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!Kl(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${o}ms`,a),await ql(o),s+=1}}async function Pt(t,e,n,s=ci){const a=await di(t,{method:"POST",headers:{...Ro(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new On({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function Bl(t,e,n,s=ci){const a=await di(t,{method:"POST",headers:{...Ro(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new On({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function Ul(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Hl(t){var e,n,s,a,o,l,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const u=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(u)}return((c=(l=(o=t.result)==null?void 0:o.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function Zt(t,e){const n=await Bl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},jl),s=Ul(n);return Hl(s)}function Wl(){return X("/api/v1/dashboard/shell")}function Gl(){return X("/api/v1/dashboard/execution")}function Jl(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),X(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function Vl(){return X("/api/v1/dashboard/governance")}function Yl(){return X("/api/v1/dashboard/semantics")}function Ql(){return X("/api/v1/dashboard/mission")}function Xl(t=!1){return X(`/api/v1/dashboard/mission/briefing${t?"?force=1":""}`)}function Zl(t,e){const n=new URLSearchParams;t&&n.set("session_id",t),e&&n.set("operation_id",e);const s=n.toString();return X(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function tc(){return X("/api/v1/dashboard/planning")}function ec(){return X("/api/v1/operator")}function Mo(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return X(`/api/v1/operator/digest${n?`?${n}`:""}`)}function nc(){return X("/api/v1/command-plane")}function sc(){return X("/api/v1/command-plane/summary")}function ac(){return X("/api/v1/chains/summary")}function ic(t){return X(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function oc(){return X("/api/v1/command-plane/help")}function rc(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return X(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function lc(t,e){return Pt(t,e)}function cc(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return ci}}function Zs(t){return Pt("/api/v1/operator/action",t,void 0,cc(t))}function dc(t,e){return Pt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function cn(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function uc(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function pc(t){if(!m(t))return null;const e=b(t.id,"").trim(),n=b(t.author,"").trim(),s=b(t.content,"").trim();if(!e||!n)return null;const a=K(t.score,0),o=K(t.votes_up,0),l=K(t.votes_down,0),c=K(t.votes,a||o-l),u=K(t.comment_count,K(t.reply_count,0)),p=(()=>{const $=t.flair;if(typeof $=="string"&&$.trim())return $.trim();if(m($)){const I=b($.name,"").trim();if(I)return I}return b(t.flair_name,"").trim()||void 0})(),f=b(t.created_at_iso,"").trim()||cn(t.created_at),_=b(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?cn(t.updated_at):f),h=b(t.title,"").trim()||uc(s),k=Array.isArray(t.tags)?t.tags.filter($=>typeof $=="string"&&$.trim()!==""):[];return{id:e,author:n,post_kind:(()=>{const $=b(t.post_kind,"").trim().toLowerCase();return $==="automation"||$==="system"||$==="human"?$:void 0})(),title:h,content:s,tags:k,votes:c,vote_balance:a,comment_count:u,created_at:f,updated_at:_,flair:p,hearth:b(t.hearth,"").trim()||null,visibility:b(t.visibility,"").trim()||void 0,expires_at:b(t.expires_at_iso,"").trim()||(t.expires_at!==void 0&&t.expires_at!==0?cn(t.expires_at):"")||null,hearth_count:K(t.hearth_count,0)}}function mc(t){if(!m(t))return null;const e=b(t.id,"").trim(),n=b(t.post_id,"").trim(),s=b(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:b(t.content,""),created_at:cn(t.created_at)}}async function vc(t){return Lo("fetchBoardPost",async()=>{const e=await X(`/api/v1/board/${t}?format=flat`),n=m(e.post)?e.post:e,s=pc(n)??{id:t,author:"unknown",post_kind:"human",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},o=(Array.isArray(e.comments)?e.comments:[]).map(mc).filter(l=>l!==null);return{...s,comments:o}})}function No(t,e){return Pt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Ol()})}function _c(t,e,n){return Pt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function fc(t){const e=b(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function at(...t){for(const e of t){const n=b(e,"");if(n.trim())return n.trim()}return""}function Fi(t){const e=fc(at(t.outcome,t.result,t.result_code));if(!e)return;const n=at(t.reason,t.reason_code,t.description,t.detail),s=at(t.summary,t.summary_ko,t.summary_en,t.note),a=at(t.details,t.details_text,t.text,t.note),o=at(t.winner,t.winner_name,t.actor_winner,t.winner_actor),l=at(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=at(t.raw_reason,t.raw_reason_code,t.error_message),u=(()=>{const _=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof _=="string"?[_]:Array.isArray(_)?_.map(g=>{if(typeof g=="string")return g.trim();if(m(g)){const h=b(g.summary,"").trim();if(h)return h;const k=b(g.text,"").trim();if(k)return k;const $=b(g.type,"").trim();return $||b(g.event_id,"").trim()}return""}).filter(g=>g.length>0):[]})(),p=(()=>{const _=K(t.turn,Number.NaN);if(Number.isFinite(_))return _;const g=K(t.turn_number,Number.NaN);if(Number.isFinite(g))return g;const h=K(t.current_turn,Number.NaN);if(Number.isFinite(h))return h;const k=K(t.round,Number.NaN);return Number.isFinite(k)?k:void 0})(),f=at(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:l||void 0,evidence:u.length>0?u:void 0,raw_reason:c||void 0,turn:p,phase:f||void 0}}function gc(t,e){const n=m(t.state)?t.state:{};if(b(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(l=>m(l)?b(l.type,"")==="session.outcome":!1),o=m(n.session_outcome)?n.session_outcome:{};if(m(o)&&Object.keys(o).length>0){const l=Fi(o);if(l)return l}if(m(a))return Fi(m(a.payload)?a.payload:{})}function b(t,e=""){return typeof t=="string"?t:e}function K(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function $c(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function qa(t,e=!1){return typeof t=="boolean"?t:e}function nn(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(m(e)){const n=b(e.name,"").trim(),s=b(e.id,"").trim(),a=b(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function hc(t){const e={};if(!m(t)&&!Array.isArray(t))return e;if(m(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),o=b(s,"").trim();!a||!o||(e[a]=o)}),e;for(const n of t){if(!m(n))continue;const s=at(n.to,n.target,n.actor_id,n.name,n.id),a=at(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function yc(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function ft(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const bc=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function kc(t){const e=m(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const o=s.trim();o&&(bc.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function xc(t,e){if(t!=="dice.rolled")return;const n=K(e.raw_d20,0),s=K(e.total,0),a=K(e.bonus,0),o=b(e.action,"roll"),l=K(e.dc,0);return{notation:l>0?`${o} (DC ${l})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function Sc(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Cc(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Ac(t,e,n,s){const a=n||e||b(s.actor_id,"")||b(s.actor_name,"");switch(t){case"turn.action.proposed":{const o=b(s.proposed_action,b(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=b(s.reply,b(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return b(s.reply,b(s.content,b(s.text,"Narration")));case"dice.rolled":{const o=b(s.action,"roll"),l=K(s.total,0),c=K(s.dc,0),u=b(s.label,""),p=a||"actor",f=c>0?` vs DC ${c}`:"",_=u?` (${u})`:"";return`${p} ${o}: ${l}${f}${_}`}case"turn.started":return`Turn ${K(s.turn,1)} started`;case"phase.changed":return`Phase: ${b(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${b(s.name,m(s.actor)?b(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${b(s.keeper_name,b(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${b(s.keeper_name,b(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${K(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${K(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||b(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||b(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${b(s.reason_code,"unknown")}`;case"memory.signal":{const o=m(s.entity_refs)?s.entity_refs:{},l=b(o.requested_tier,""),c=b(o.effective_tier,""),u=qa(o.guardrail_applied,!1),p=b(s.summary_en,b(s.summary_ko,"Memory signal"));if(!l&&!c)return p;const f=l&&c?`${l}->${c}`:c||l;return`${p} [${f}${u?" (guardrail)":""}]`}case"world.event":{if(b(s.event_type,"")==="canon.check"){const l=b(s.status,"unknown"),c=b(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return b(s.description,b(s.summary,"World event"))}case"combat.attack":return b(s.summary,b(s.result,"Attack resolved"));case"combat.defense":return b(s.summary,b(s.result,"Defense resolved"));case"session.outcome":return b(s.summary,b(s.outcome,"Session ended"));default:{const o=Sc(s);return o?`${t}: ${o}`:t}}}function Ic(t,e){const n=m(t)?t:{},s=b(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=b(n.actor_name,"").trim()||e[a]||b(m(n.payload)?n.payload.actor_name:"",""),l=m(n.payload)?n.payload:{},c=b(n.ts,b(n.timestamp,new Date().toISOString())),u=b(n.phase,b(l.phase,"")),p=b(n.category,"");return{type:s,actor:o||a||b(l.actor_name,""),actor_id:a||b(l.actor_id,""),actor_name:o,seq:n.seq,room_id:b(n.room_id,""),phase:u||void 0,category:p||Cc(s),visibility:b(n.visibility,b(l.visibility,"public")),event_id:b(n.event_id,""),content:Ac(s,a,o,l),dice_roll:xc(s,l),timestamp:c}}function Tc(t,e,n){var tt,et;const s=b(t.room_id,"")||n||"default",a=m(t.state)?t.state:{},o=m(a.party)?a.party:{},l=m(a.actor_control)?a.actor_control:{},c=m(a.join_gate)?a.join_gate:{},u=m(a.contribution_ledger)?a.contribution_ledger:{},p=Object.entries(o).map(([F,Y])=>{const x=m(Y)?Y:{},bt=ft(x,"max_hp",void 0,10),qt=ft(x,"hp",void 0,bt),ne=ft(x,"max_mp",void 0,0),se=ft(x,"mp",void 0,0),D=ft(x,"level",void 0,1),kt=ft(x,"xp",void 0,0),ae=qa(x.alive,qt>0),tn=l[F],en=typeof tn=="string"?tn:void 0,Gn=yc(x.role,F,en),Jn=$c(x.generation),Vn=at(x.joined_at,x.joinedAt,x.started_at,x.startedAt),Yn=at(x.claimed_at,x.claimedAt,x.assigned_at,x.assignedAt,x.assigned_time),j=at(x.last_seen,x.lastSeen,x.last_seen_at,x.lastSeenAt,x.last_active,x.lastActive),ye=at(x.scene,x.current_scene,x.currentScene,x.world_scene,x.scene_name,x.sceneName),gl=at(x.location,x.current_location,x.currentLocation,x.position,x.zone,x.area);return{id:F,name:b(x.name,F),role:Gn,keeper:en,archetype:b(x.archetype,""),persona:b(x.persona,""),portrait:b(x.portrait,"")||void 0,background:b(x.background,"")||void 0,traits:nn(x.traits),skills:nn(x.skills),stats_raw:kc(x),status:ae?"active":"dead",generation:Jn,joined_at:Vn||void 0,claimed_at:Yn||void 0,last_seen:j||void 0,scene:ye||void 0,location:gl||void 0,inventory:nn(x.inventory),notes:nn(x.notes),relationships:hc(x.relationships),stats:{hp:qt,max_hp:bt,mp:se,max_mp:ne,level:D,xp:kt,strength:ft(x,"strength","str",10),dexterity:ft(x,"dexterity","dex",10),constitution:ft(x,"constitution","con",10),intelligence:ft(x,"intelligence","int",10),wisdom:ft(x,"wisdom","wis",10),charisma:ft(x,"charisma","cha",10)}}}),f=p.filter(F=>F.status!=="dead"),_=gc(t,e),g={phase_open:qa(c.phase_open,!0),min_points:K(c.min_points,3),window:b(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},h=Object.entries(u).map(([F,Y])=>{const x=m(Y)?Y:{};return{actor_id:F,score:K(x.score,0),last_reason:b(x.last_reason,"")||null,reasons:nn(x.reasons)}}),k=p.reduce((F,Y)=>(F[Y.id]=Y.name,F),{}),$=e.map(F=>Ic(F,k)),A=K(a.turn,1),I=b(a.phase,"round"),C=b(a.map,""),S=m(a.world)?a.world:{},w=C||b(S.ascii_map,b(S.map,"")),R=$.filter((F,Y)=>{const x=e[Y];if(!m(x))return!1;const bt=m(x.payload)?x.payload:{};return K(bt.turn,-1)===A}),W=(R.length>0?R:$).slice(-12),U=b(a.status,"active");return{session:{id:s,room:s,status:U==="ended"?"ended":U==="paused"?"paused":"active",round:A,actors:f,created_at:((tt=$[0])==null?void 0:tt.timestamp)??new Date().toISOString()},current_round:{round_number:A,phase:I,events:W,timestamp:((et=$[$.length-1])==null?void 0:et.timestamp)??new Date().toISOString()},map:w||void 0,join_gate:g,contribution_ledger:h,outcome:_,party:f,story_log:$,history:[]}}async function wc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await X(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Pc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([X(`/api/v1/trpg/state${e}`),wc(t)]);return Tc(n,s,t)}function Rc(t){return Pt("/api/v1/trpg/rounds/run",{room_id:t})}function Lc(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Mc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Pt("/api/v1/trpg/dice/roll",e)}function Nc(t,e){const n=Lc();return Pt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function zc(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Pt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function Dc(t,e,n){return Pt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Ec(t,e,n){const s=await Zt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function jc(t){const e=await Zt("trpg.mid_join.request",t);return JSON.parse(e)}async function Oc(t,e){await Zt("masc_broadcast",{agent_name:t,message:e})}async function qc(t=40){return(await Zt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Fc(t,e=20){return Zt("masc_task_history",{task_id:t,limit:e})}async function Kc(t){const e=await Zt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Bc(t){return Lo("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await X(`/api/v1/council/debates/${e}/summary`);if(!m(n))return null;const s=b(n.id,"").trim();return s?{id:s,topic:b(n.topic,""),status:b(n.status,"open"),support_count:K(n.support_count,0),oppose_count:K(n.oppose_count,0),neutral_count:K(n.neutral_count,0),total_arguments:K(n.total_arguments,0),created_at:cn(n.created_at_iso??n.created_at),summary_text:b(n.summary_text,"")}:null})}function Uc(t,e,n){return Zt("masc_keeper_msg",{name:t,message:e})}const Hc=v(""),Et=v({}),it=v({}),Fa=v({}),Ka=v({}),Ba=v({}),Ua=v({}),jt=v({});function st(t,e,n){t.value={...t.value,[e]:n}}function Wc(t){var n;const e=(n=r(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Gc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function la(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!m(s))continue;const a=r(s.name);if(!a)continue;const o=r(s[e]);e==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function Jc(t){if(!m(t))return null;const e=r(t.name);return e?{name:e,trigger:r(t.trigger),outcome:r(t.outcome),summary:r(t.summary),reason:r(t.reason)}:null}function Vc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Yc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function zo(t,e,n){return r(t)??Yc(e,n)}function Do(t,e){return typeof t=="boolean"?t:e==="recover"}function hs(t){if(!m(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:r(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:Ue(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:d(t.next_eligible_at_s)??null,recoverable:Do(t.recoverable,n),summary:zo(t.summary,e,r(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Eo(t){return m(t)?{hour:d(t.hour),checked:d(t.checked)??0,acted:d(t.acted)??0,acted_names:q(t.acted_names),activity_report:r(t.activity_report),quiet_hours_overridden:O(t.quiet_hours_overridden),skipped_reason:r(t.skipped_reason),acted_rows:la(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:la(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:la(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Jc).filter(e=>e!==null):[]}:null}function Qc(t){return m(t)?{enabled:O(t.enabled)??!1,interval_s:d(t.interval_s)??0,quiet_start:d(t.quiet_start),quiet_end:d(t.quiet_end),quiet_active:O(t.quiet_active),use_planner:O(t.use_planner),delegate_llm:O(t.delegate_llm),agent_count:d(t.agent_count),agents:q(t.agents),last_tick_ago_s:d(t.last_tick_ago_s)??null,last_tick_ago:r(t.last_tick_ago),total_ticks:d(t.total_ticks),total_checkins:d(t.total_checkins),last_skip_reason:r(t.last_skip_reason)??null,last_tick_result:Eo(t.last_tick_result),active_self_heartbeats:q(t.active_self_heartbeats)}:null}function Xc(t){return m(t)?{status:t.status,diagnostic:hs(t.diagnostic)}:null}function Zc(t){return m(t)?{recovered:O(t.recovered)??!1,skipped_reason:r(t.skipped_reason)??null,before:hs(t.before),after:hs(t.after),down:t.down,up:t.up}:null}function td(t,e){var C,S;if(!(t!=null&&t.name))return null;const n=r((C=t.agent)==null?void 0:C.status)??r(t.status)??"unknown",s=r((S=t.agent)==null?void 0:S.error)??null,a=t.presence_keepalive??!0,o=t.keepalive_running??!1,l=t.turn_count??0,c=t.last_turn_ago_s??null,u=t.proactive_enabled??!1,p=t.proactive_cooldown_sec??0,f=t.last_proactive_ago_s??null,_=u&&f!=null?Math.max(0,p-f):null,g=l<=0||c==null?"never":c>900?"stale":"fresh",h=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,k=s??(a&&!o?"keeper keepalive is not running":null),$=n==="offline"||n==="inactive"?"offline":k?"degraded":g==="stale"?"stale":g==="never"?"idle":"healthy",A=k?Vc(k):e!=null&&e.quiet_active&&g!=="fresh"?"quiet_hours":a&&!o?"disabled":l<=0?"never_started":_!=null&&_>0?"min_gap":g==="fresh"||g==="stale"?"no_recent_activity":"unknown",I=$==="offline"||$==="degraded"||$==="stale"?"recover":A==="quiet_hours"?"manual_lodge_poke":A==="unknown"?"probe":"direct_message";return{health_state:$,quiet_reason:A,next_action_path:I,last_reply_status:g,last_reply_at:h,last_reply_preview:null,last_error:k,next_eligible_at_s:_!=null&&_>0?_:null,recoverable:Do(void 0,I),summary:zo(void 0,$,A),keepalive_running:o}}function ed(t,e){if(!m(t))return null;const n=Wc(t.role),s=r(t.content)??r(t.preview);if(!s)return null;const a=Ue(t.ts_unix)??Ue(t.timestamp);return{id:`${n}-${a??"entry"}-${e}`,role:n,label:Gc(n),text:s,timestamp:a,delivery:"history"}}function nd(t,e,n){const s=m(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,l)=>ed(o,l)).filter(o=>o!==null):[];return{name:t,diagnostic:hs(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function Ki(t,e){const n=it.value[t]??[];it.value={...it.value,[t]:[...n,e].slice(-50)}}function sd(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function ad(t,e){const s=(it.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(o=>sd(a,o)));it.value={...it.value,[t]:[...e,...s].slice(-50)}}function ta(t,e){Et.value={...Et.value,[t]:e},ad(t,e.history)}function Bi(t,e){const n=Et.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};ta(t,{...n,diagnostic:{...s,...e}})}async function ui(){try{await qn()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function id(t){Hc.value=t.trim()}async function jo(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Et.value[n])return Et.value[n];st(Fa,n,!0),st(jt,n,null);try{const s=await Zt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=nd(n,s,a);return ta(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return st(jt,n,a),null}finally{st(Fa,n,!1)}}async function od(t,e){const n=t.trim(),s=e.trim();if(!n||!s)return;const a=`local-${Date.now()}`;Ki(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),st(Ka,n,!0),st(jt,n,null);try{const o=await Uc(n,s);it.value={...it.value,[n]:(it.value[n]??[]).map(l=>l.id===a?{...l,delivery:"delivered"}:l)},Ki(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Bi(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await ui()}catch(o){const l=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw it.value={...it.value,[n]:(it.value[n]??[]).map(c=>c.id===a?{...c,delivery:"error",error:l}:c)},Bi(n,{last_reply_status:"error",last_error:l}),st(jt,n,l),o}finally{st(Ka,n,!1)}}async function rd(t,e){const n=t.trim();if(!n)return null;st(Ba,n,!0),st(jt,n,null);try{const s=await Zs({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=Xc(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const l=Et.value[n];ta(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??it.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ui(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw st(jt,n,a),s}finally{st(Ba,n,!1)}}async function ld(t,e){const n=t.trim();if(!n)return null;st(Ua,n,!0),st(jt,n,null);try{const s=await Zs({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Zc(s.result),o=(a==null?void 0:a.after)??null;if(o){const l=Et.value[n];ta(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??it.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ui(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw st(jt,n,a),s}finally{st(Ua,n,!1)}}function ie(t){return(t??"").trim().toLowerCase()}function ct(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ls(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Qn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function sn(t){return t.last_heartbeat??Qn(t.last_turn_ago_s)??Qn(t.last_proactive_ago_s)??Qn(t.last_handoff_ago_s)??Qn(t.last_compaction_ago_s)}function cd(t){const e=t.title.trim();return e||ls(t.content)}function dd(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function ud(t,e,n,s,a={}){var S;const o=ie(t),l=e.filter(w=>ie(w.assignee)===o&&(w.status==="claimed"||w.status==="in_progress")).length,c=n.filter(w=>ie(w.from)===o).sort((w,R)=>ct(R.timestamp)-ct(w.timestamp))[0],u=s.filter(w=>ie(w.agent)===o||ie(w.author)===o).sort((w,R)=>ct(R.timestamp)-ct(w.timestamp))[0],p=(a.boardPosts??[]).filter(w=>ie(w.author)===o).sort((w,R)=>ct(R.updated_at||R.created_at)-ct(w.updated_at||w.created_at))[0],f=(a.keepers??[]).filter(w=>ie(w.name)===o&&sn(w)!==null).sort((w,R)=>ct(sn(R)??0)-ct(sn(w)??0))[0],_=c?ct(c.timestamp):0,g=u?ct(u.timestamp):0,h=p?ct(p.updated_at||p.created_at):0,k=f?ct(sn(f)??0):0,$=a.lastSeen?ct(a.lastSeen):0,A=((S=a.currentTask)==null?void 0:S.trim())||(l>0?`${l} claimed tasks`:null);if(_===0&&g===0&&h===0&&k===0&&$===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:A};const C=[c?{timestamp:c.timestamp,ts:_,text:ls(c.content)}:null,p?{timestamp:p.updated_at||p.created_at,ts:h,text:`Post: ${ls(cd(p))}`}:null,f?{timestamp:sn(f),ts:k,text:dd(f)}:null,u?{timestamp:new Date(u.timestamp).toISOString(),ts:g,text:ls(u.text)}:null].filter(w=>w!==null).sort((w,R)=>R.ts-w.ts)[0];return C&&C.ts>=$?{activeAssignedCount:l,lastActivityAt:C.timestamp,lastActivityText:C.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:A??"Presence heartbeat"}}const Rt=v([]),Tt=v([]),He=v([]),Ot=v([]),$t=v(null),pd=v(null),Oo=v(null),qo=v([]),Fo=v([]),Ko=v([]),Bo=v([]),Uo=v([]),Ho=v([]),Ha=v(new Map),bn=v([]),kn=v("recent"),Ie=v(!0),Wo=v(null),Dt=v(""),Ne=v([]),dn=v(!1),Go=v(new Map),pi=v("unknown"),ze=v(null),Wa=v(!1),xn=v(!1),Ga=v(!1),un=v(!1),mi=v(null),ys=v(!1),bs=v(null),Jo=v(null),Ja=v(null),md=v(null),vd=v(null),_d=v(null);yt(()=>Rt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const Vo=yt(()=>{const t=Tt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Yo=yt(()=>{const t=new Map,e=Tt.value,n=He.value,s=$s.value,a=bn.value,o=Ot.value;for(const l of Rt.value)t.set(l.name.trim().toLowerCase(),ud(l.name,e,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:o}));return t});function fd(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}yt(()=>{const t=new Map;for(const e of Ot.value)t.set(e.name,fd(e));return t});const gd=12e4;function $d(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}yt(()=>{const t=Date.now(),e=new Set,n=Ha.value;for(const s of Ot.value){const a=$d(s,n);a!=null&&t-a>gd&&e.add(s.name)}return e});function hd(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function Qo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function yd(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function bd(t){if(!m(t))return null;const e=r(t.name);return e?{name:e,agent_type:r(t.agent_type),status:Qo(t.status),current_task:r(t.current_task)??null,joined_at:r(t.joined_at),last_seen:r(t.last_seen),capabilities:q(t.capabilities),emoji:r(t.emoji),koreanName:r(t.koreanName)??r(t.korean_name),model:r(t.model),traits:q(t.traits),interests:q(t.interests),activityLevel:d(t.activityLevel)??d(t.activity_level),primaryValue:r(t.primaryValue)??r(t.primary_value)}:null}function kd(t){if(!m(t))return null;const e=r(t.id),n=r(t.title);return!e||!n?null:{id:e,title:n,status:yd(t.status),priority:d(t.priority),assignee:r(t.assignee),description:r(t.description),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function xd(t){if(!m(t))return null;const e=r(t.from)??r(t.from_agent)??"system",n=r(t.content)??"",s=r(t.timestamp)??new Date().toISOString();return{id:r(t.id),seq:d(t.seq),from:e,content:n,timestamp:s,type:r(t.type)}}function vi(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="ok"||e==="warn"||e==="bad"?e:"ok"}function Sd(t){return m(t)?{active_sessions:d(t.active_sessions),blocked_sessions:d(t.blocked_sessions),active_operations:d(t.active_operations),blocked_operations:d(t.blocked_operations),runtime_pressure:d(t.runtime_pressure),worker_alerts:d(t.worker_alerts),continuity_alerts:d(t.continuity_alerts),priority_items:d(t.priority_items),todo_tasks:d(t.todo_tasks),claimed_tasks:d(t.claimed_tasks),running_tasks:d(t.running_tasks),done_tasks:d(t.done_tasks),cancelled_tasks:d(t.cancelled_tasks),keepers:d(t.keepers)}:null}function Wt(t){if(!m(t))return null;const e=r(t.surface),n=r(t.label),s=r(t.target_type),a=r(t.target_id),o=r(t.focus_kind);return!e||!n||!s||!a||!o?null:{surface:e==="command"?"command":"intervene",label:n,target_type:s,target_id:a,focus_kind:o,operation_id:r(t.operation_id)??null,command_surface:r(t.command_surface)??null}}function Cd(t){if(!m(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.summary),a=r(t.target_type),o=r(t.target_id);return!e||!s||!a||!o||n!=="session"&&n!=="operation"?null:{id:e,kind:n,severity:vi(t.severity),status:r(t.status),summary:s,target_type:a,target_id:o,linked_session_id:r(t.linked_session_id)??null,linked_operation_id:r(t.linked_operation_id)??null,last_seen_at:r(t.last_seen_at)??null,top_handoff:Wt(t.top_handoff),intervene_handoff:Wt(t.intervene_handoff),command_handoff:Wt(t.command_handoff)}}function Ad(t){if(!m(t))return null;const e=r(t.session_id),n=r(t.goal);return!e||!n?null:{session_id:e,goal:n,room:r(t.room)??null,status:r(t.status),health:r(t.health),member_names:q(t.member_names),linked_operation_id:r(t.linked_operation_id)??null,linked_detachment_id:r(t.linked_detachment_id)??null,runtime_blocker:r(t.runtime_blocker)??null,worker_gap_summary:r(t.worker_gap_summary)??null,last_activity_at:r(t.last_activity_at)??null,last_activity_summary:r(t.last_activity_summary)??null,communication_summary:r(t.communication_summary)??null,active_count:d(t.active_count),required_count:d(t.required_count),top_handoff:Wt(t.top_handoff),intervene_handoff:Wt(t.intervene_handoff),command_handoff:Wt(t.command_handoff)}}function Id(t){if(!m(t))return null;const e=r(t.operation_id),n=r(t.objective);return!e||!n?null:{operation_id:e,objective:n,status:r(t.status),stage:r(t.stage)??null,assigned_unit_id:r(t.assigned_unit_id)??null,assigned_unit_label:r(t.assigned_unit_label)??null,linked_session_id:r(t.linked_session_id)??null,linked_detachment_id:r(t.linked_detachment_id)??null,blocker_summary:r(t.blocker_summary)??null,search_status:r(t.search_status)??null,next_tool:r(t.next_tool)??null,updated_at:r(t.updated_at)??null,top_handoff:Wt(t.top_handoff),command_handoff:Wt(t.command_handoff)}}function Ui(t){if(!m(t))return null;const e=r(t.name)??r(t.agent_name),n=r(t.note),s=r(t.focus),a=r(t.state);return!e||!n||!s||a!=="working"&&a!=="watching"&&a!=="quiet"&&a!=="offline"?null:{name:e,agent_name:r(t.agent_name),status:r(t.status),tone:vi(t.tone),state:a,note:n,focus:s,last_signal_at:r(t.last_signal_at)??null,active_task_count:d(t.active_task_count),related_session_id:r(t.related_session_id)??null,related_operation_id:r(t.related_operation_id)??null,emoji:r(t.emoji),korean_name:r(t.korean_name),model:r(t.model)??null,recent_output_preview:r(t.recent_output_preview)??null,recent_event:r(t.recent_event)??null}}function Td(t){if(!m(t))return null;const e=r(t.name),n=r(t.note),s=r(t.focus),a=r(t.state);return!e||!n||!s||a!=="healthy"&&a!=="warning"&&a!=="critical"?null:{name:e,agent_name:r(t.agent_name)??null,status:r(t.status),tone:vi(t.tone),state:a,note:n,focus:s,last_signal_at:r(t.last_signal_at)??null,last_autonomous_action_at:r(t.last_autonomous_action_at)??null,generation:d(t.generation),turn_count:d(t.turn_count),context_ratio:d(t.context_ratio)??null,continuity:r(t.continuity)??null,lifecycle:r(t.lifecycle)??null,related_session_id:r(t.related_session_id)??null,model:r(t.model)??null,emoji:r(t.emoji),korean_name:r(t.korean_name),skill_reason:r(t.skill_reason)??null}}function Hi(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function wd(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>Hi(s)-Hi(a)).slice(-500)}function Pd(t){return Array.isArray(t)?t.map(e=>{if(!m(e))return null;const n=d(e.ts_unix);if(n==null)return null;const s=m(e.handoff)?e.handoff:null;return{ts:n,context_ratio:d(e.context_ratio)??0,context_tokens:d(e.context_tokens)??0,context_max:d(e.context_max)??0,latency_ms:d(e.latency_ms)??0,generation:d(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:d(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:d(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?d(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Wi(t){if(!m(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);if(!e||!n||!s)return null;const a=r(t.quiet_reason)??null,o=r(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:Ue(t.last_reply_at)??r(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:d(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Rd(t,e){return(Array.isArray(t)?t:m(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!m(s))return null;const a=m(s.agent)?s.agent:null,o=m(s.context)?s.context:null,l=m(s.metrics_window)?s.metrics_window:void 0,c=r(s.name);if(!c)return null;const u=d(s.context_ratio)??d(o==null?void 0:o.context_ratio),p=r(s.status)??r(a==null?void 0:a.status)??"offline",f=Qo(p),_=r(s.model)??r(s.active_model)??r(s.primary_model),g=q(s.skill_secondary),h=o?{source:r(o.source),context_ratio:d(o.context_ratio),context_tokens:d(o.context_tokens),context_max:d(o.context_max),message_count:d(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,k=a?{name:r(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:r(a.error),agent_type:r(a.agent_type),status:r(a.status),current_task:r(a.current_task)??null,joined_at:r(a.joined_at),last_seen:r(a.last_seen),last_seen_ago_s:d(a.last_seen_ago_s),capabilities:q(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,$=Pd(s.metrics_series),A={name:c,emoji:r(s.emoji),koreanName:r(s.koreanName)??r(s.korean_name),agent_name:r(s.agent_name),trace_id:r(s.trace_id),model:_,primary_model:r(s.primary_model),active_model:r(s.active_model),next_model_hint:r(s.next_model_hint)??null,status:f,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:d(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:d(s.proactive_idle_sec),proactive_cooldown_sec:d(s.proactive_cooldown_sec),last_heartbeat:r(s.last_heartbeat)??r(a==null?void 0:a.last_seen),generation:d(s.generation),turn_count:d(s.turn_count)??d(s.total_turns),keeper_age_s:d(s.keeper_age_s),last_turn_ago_s:d(s.last_turn_ago_s),last_handoff_ago_s:d(s.last_handoff_ago_s),last_compaction_ago_s:d(s.last_compaction_ago_s),last_proactive_ago_s:d(s.last_proactive_ago_s),last_proactive_preview:r(s.last_proactive_preview)??null,context_ratio:u,context_tokens:d(s.context_tokens)??d(o==null?void 0:o.context_tokens),context_max:d(s.context_max)??d(o==null?void 0:o.context_max),context_source:r(s.context_source)??r(o==null?void 0:o.source),context:h,traits:q(s.traits),interests:q(s.interests),primaryValue:r(s.primaryValue)??r(s.primary_value),activityLevel:d(s.activityLevel)??d(s.activity_level),memory_recent_note:r(s.memory_recent_note)??null,recent_input_preview:r(s.recent_input_preview)??null,recent_output_preview:r(s.recent_output_preview)??null,recent_tool_names:q(s.recent_tool_names)??[],conversation_tail_count:d(s.conversation_tail_count),k2k_count:d(s.k2k_count),handoff_count_total:d(s.handoff_count_total)??d(s.trace_history_count),compaction_count:d(s.compaction_count),last_compaction_saved_tokens:d(s.last_compaction_saved_tokens),diagnostic:Wi(s.diagnostic),skill_primary:r(s.skill_primary)??null,skill_secondary:g,skill_reason:r(s.skill_reason)??null,metrics_series:$.length>0?$:void 0,metrics_window:l,agent:k};return A.diagnostic=Wi(s.diagnostic)??td(A,(e==null?void 0:e.lodge)??null),A}).filter(s=>s!==null)}function Xo(t){return m(t)?{...t,lodge:Qc(t.lodge)??void 0}:null}function Ld(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function Md(t){if(!m(t))return null;const e=d(t.iteration);if(e==null)return null;const n=d(t.metric_before)??0,s=d(t.metric_after)??n,a=m(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:d(t.delta)??s-n,changes:r(t.changes)??"",failed_attempts:r(t.failed_attempts)??"",next_suggestion:r(t.next_suggestion)??"",elapsed_ms:d(t.elapsed_ms)??0,cost_usd:d(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:d(a.tool_call_count)??0,tool_names:q(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function Nd(t){var o,l;if(!m(t))return null;const e=r(t.loop_id);if(!e)return null;const n=d(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(Md).filter(c=>c!==null):[],a=d(t.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:r(t.profile)??"unknown",status:Ld(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:r(t.error_message)??r(t.error_reason)??null,stop_reason:r(t.stop_reason)??r(t.reason)??null,current_iteration:d(t.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:d(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(t.target)??"",stagnation_streak:d(t.stagnation_streak)??0,stagnation_limit:d(t.stagnation_limit)??0,elapsed_seconds:d(t.elapsed_seconds)??0,updated_at:Ue(t.updated_at)??null,stopped_at:Ue(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:d(t.latest_tool_call_count)??0,latest_tool_names:q(t.latest_tool_names)??[],session_id:r(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function qn(){Wa.value=!0;try{await Promise.all([tr(),de()]),Jo.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{Wa.value=!1}}async function Zo(){ys.value=!0,bs.value=null;try{const t=await Yl();mi.value=t,_d.value=new Date().toISOString()}catch(t){bs.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{ys.value=!1}}function zd(t){var e;return((e=mi.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function Dd(t){var n;const e=((n=mi.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(o=>o.id===t);if(a)return a}return null}function Ed(t){var s,a;Ne.value=(Array.isArray(t.goals)?t.goals:[]).map(o=>{if(!m(o))return null;const l=r(o.id),c=r(o.title),u=r(o.horizon),p=r(o.status),f=r(o.created_at),_=r(o.updated_at);return!l||!c||!u||!p||!f||!_?null:{id:l,horizon:u,title:c,metric:r(o.metric)??null,target_value:r(o.target_value)??null,due_date:r(o.due_date)??null,priority:d(o.priority)??3,status:p,parent_goal_id:r(o.parent_goal_id)??null,last_review_note:r(o.last_review_note)??null,last_review_at:r(o.last_review_at)??null,created_at:f,updated_at:_}}).filter(o=>o!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const o of n){const l=Nd(o);l&&e.set(l.loop_id,l)}Go.value=e,ze.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,pi.value=ze.value?"error":e.size===0?"idle":"ready"}async function tr(){try{const t=await Wl(),e=Xo(t.status);e&&($t.value=e)}catch(t){console.error("Dashboard shell fetch error:",t)}}async function de(){var t;try{const e=await Gl(),n=Xo(e.status),s=(t=$t.value)==null?void 0:t.room;n&&($t.value=n);const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;Rt.value=(Array.isArray(e.agents)?e.agents:[]).map(bd).filter(l=>l!==null),Tt.value=(Array.isArray(e.tasks)?e.tasks:[]).map(kd).filter(l=>l!==null);const o=(Array.isArray(e.messages)?e.messages:[]).map(xd).filter(l=>l!==null);He.value=a?o:wd(He.value,o),Ot.value=Rd(e.keepers,n??$t.value),Oo.value=Sd(e.summary),qo.value=(Array.isArray(e.execution_queue)?e.execution_queue:Array.isArray(e.priority_queue)?e.priority_queue:[]).map(Cd).filter(l=>l!==null),Fo.value=(Array.isArray(e.session_briefs)?e.session_briefs:[]).map(Ad).filter(l=>l!==null),Ko.value=(Array.isArray(e.operation_briefs)?e.operation_briefs:[]).map(Id).filter(l=>l!==null),Bo.value=(Array.isArray(e.worker_support_briefs)?e.worker_support_briefs:Array.isArray(e.worker_briefs)?e.worker_briefs:[]).map(Ui).filter(l=>l!==null),Uo.value=(Array.isArray(e.continuity_briefs)?e.continuity_briefs:[]).map(Td).filter(l=>l!==null),Ho.value=(Array.isArray(e.offline_worker_briefs)?e.offline_worker_briefs:[]).map(Ui).filter(l=>l!==null),pd.value=null,Jo.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function Gt(){xn.value=!0;try{const t=await Jl(kn.value,{excludeSystem:Ie.value});bn.value=t.posts??[],Ja.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{xn.value=!1}}async function Jt(){var t;Ga.value=!0;try{const e=Dt.value||((t=$t.value)==null?void 0:t.room)||"default";Dt.value||(Dt.value=e);const n=await Pc(e);Wo.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Ga.value=!1}}async function _i(){dn.value=!0,un.value=!0;try{const t=await tc();Ed(t),md.value=new Date().toISOString(),vd.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),pi.value="error",ze.value=t instanceof Error?t.message:String(t)}finally{dn.value=!1,un.value=!1}}async function er(){return _i()}let cs=null;function jd(t){cs=t}let ds=null;function Od(t){ds=t}let us=null;function qd(t){us=t}const ue={};let ca=null;function oe(t,e,n=500){ue[t]&&clearTimeout(ue[t]),ue[t]=setTimeout(()=>{e(),delete ue[t]},n)}function Fd(){const t=Ao.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Ha.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Ha.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&oe("execution",de),hd(e.type)&&(ca||(ca=setTimeout(()=>{qn(),ds==null||ds(),us==null||us(),ca=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&oe("execution",de),e.type==="broadcast"&&oe("execution",de),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&oe("execution",de),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&oe("board",Gt),e.type.startsWith("decision_")&&oe("council",()=>cs==null?void 0:cs()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&oe("mdal",er,350)}});return()=>{t();for(const e of Object.keys(ue))clearTimeout(ue[e]),delete ue[e]}}let pn=null;function Kd(){pn||(pn=setInterval(()=>{Qt.value,qn()},1e4))}function Bd(){pn&&(clearInterval(pn),pn=null)}function Ud({metric:t}){return i`
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
  `}function Hd({panel:t}){return i`
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
            ${t.metrics.map(e=>i`<${Ud} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function M({panelId:t,compact:e=!1,label:n="Why"}){const s=Dd(t);return s?i`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${Hd} panel=${s} />
    </details>
  `:ys.value?i`<span class="semantic-inline-state">Loading semantics…</span>`:null}function mt({surfaceId:t,compact:e=!1}){const n=zd(t);return n?i`
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
  `:ys.value?i`<div class="semantic-surface-card ${e?"compact":""}">Loading semantics…</div>`:bs.value?i`<div class="semantic-surface-card ${e?"compact":""}">${bs.value}</div>`:null}function T({title:t,class:e,semanticId:n,testId:s,children:a}){return i`
    <div class="card ${e??""}" data-testid=${s}>
      ${t?i`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?i`<${M} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}function fi(t){const e=t.indexOf("-");if(e<0)return{model:t,nickname:t,isKeeper:t==="keeper"};const n=t.slice(0,e),s=t.slice(e+1);return{model:n,nickname:s,isKeeper:n==="keeper"}}function Wd(t){return t==="keeper"||t.startsWith("keeper-")}const gi=v(null),Va=v(!1),ks=v(null),nr=v(null),Te=v(!1),ce=v(null);let De=null;function Gi(){De!==null&&(window.clearTimeout(De),De=null)}function Gd(t=1500){De===null&&(De=window.setTimeout(()=>{De=null,xs(!1)},t))}function E(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function y(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function z(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ee(t){return typeof t=="boolean"?t:void 0}function G(t,e=[]){if(Array.isArray(t))return t;if(!E(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Qe(t){if(!E(t))return null;const e=y(t.kind),n=y(t.summary),s=y(t.target_type);return!e||!n||!s?null:{kind:e,severity:y(t.severity)??"warn",summary:n,target_type:s,target_id:y(t.target_id)??null,actor:y(t.actor)??null,evidence:t.evidence}}function ge(t){if(!E(t))return null;const e=y(t.action_type),n=y(t.target_type),s=y(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:y(t.target_id)??null,severity:y(t.severity)??"warn",reason:s,confirm_required:Ee(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Jd(t){if(!E(t))return null;const e=y(t.session_id);return e?{session_id:e,goal:y(t.goal),status:y(t.status),health:y(t.health),scale_profile:y(t.scale_profile),control_profile:y(t.control_profile),planned_worker_count:z(t.planned_worker_count),active_agent_count:z(t.active_agent_count),last_turn_age_sec:z(t.last_turn_age_sec)??null,attention_count:z(t.attention_count),recommended_action_count:z(t.recommended_action_count),top_attention:Qe(t.top_attention),top_recommendation:ge(t.top_recommendation)}:null}function Vd(t){if(!E(t))return null;const e=y(t.session_id);if(!e)return null;const n=E(t.status)?t.status:t,s=E(n.summary)?n.summary:void 0;return{session_id:e,status:y(t.status)??y(s==null?void 0:s.status)??(E(n.session)?y(n.session.status):void 0),progress_pct:z(t.progress_pct)??z(s==null?void 0:s.progress_pct),elapsed_sec:z(t.elapsed_sec)??z(s==null?void 0:s.elapsed_sec),remaining_sec:z(t.remaining_sec)??z(s==null?void 0:s.remaining_sec),done_delta_total:z(t.done_delta_total)??z(s==null?void 0:s.done_delta_total),summary:E(t.summary)?t.summary:s,team_health:E(t.team_health)?t.team_health:E(n.team_health)?n.team_health:void 0,communication_metrics:E(t.communication_metrics)?t.communication_metrics:E(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:E(t.orchestration_state)?t.orchestration_state:E(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:E(t.cascade_metrics)?t.cascade_metrics:E(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:E(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,o])=>{const l=y(o);return l?[a,l]:null}).filter(a=>a!==null)):E(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const l=y(o);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:E(t.session)?t.session:E(n.session)?n.session:void 0,recent_events:G(t.recent_events,["events"]).filter(E)}}function Yd(t){if(!E(t))return null;const e=y(t.name);return e?{name:e,agent_name:y(t.agent_name),status:y(t.status),autonomy_level:y(t.autonomy_level),context_ratio:z(t.context_ratio),generation:z(t.generation),active_goal_ids:G(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:y(t.last_autonomous_action_at)??null,last_turn_ago_s:z(t.last_turn_ago_s),model:y(t.model)}:null}function Qd(t){if(!E(t))return null;const e=y(t.confirm_token)??y(t.token);return e?{confirm_token:e,actor:y(t.actor),action_type:y(t.action_type),target_type:y(t.target_type),target_id:y(t.target_id)??null,delegated_tool:y(t.delegated_tool),created_at:y(t.created_at),preview:t.preview}:null}function Xd(t){if(!E(t))return null;const e=y(t.action_type),n=y(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:y(t.description),confirm_required:Ee(t.confirm_required)}}function Zd(t){const e=E(t)?t:{};return{room_health:y(e.room_health),cluster:y(e.cluster),project:y(e.project),current_room:y(e.current_room)??null,paused:Ee(e.paused),tempo_interval_s:z(e.tempo_interval_s),active_agents:z(e.active_agents),keeper_pressure:z(e.keeper_pressure),active_operations:z(e.active_operations),pending_approvals:z(e.pending_approvals),incident_count:z(e.incident_count),recommended_action_count:z(e.recommended_action_count),top_attention:Qe(e.top_attention),top_action:ge(e.top_action)}}function tu(t){const e=E(t)?t:{},n=E(e.swarm_overview)?e.swarm_overview:{};return{health:y(e.health),active_operations:z(e.active_operations),pending_approvals:z(e.pending_approvals),swarm_overview:{active_lanes:z(n.active_lanes),moving_lanes:z(n.moving_lanes),stalled_lanes:z(n.stalled_lanes),projected_lanes:z(n.projected_lanes),last_movement_at:y(n.last_movement_at)??null},top_attention:Qe(e.top_attention),top_action:ge(e.top_action),session_cards:G(e.session_cards).map(Jd).filter(s=>s!==null)}}function eu(t){const e=E(t)?t:{};return{sessions:G(e.sessions,["items"]).map(Vd).filter(n=>n!==null),keepers:G(e.keepers,["items"]).map(Yd).filter(n=>n!==null),pending_confirms:G(e.pending_confirms).map(Qd).filter(n=>n!==null),available_actions:G(e.available_actions).map(Xd).filter(n=>n!==null)}}function nu(t){if(!E(t))return null;const e=y(t.id),n=y(t.kind),s=y(t.summary),a=y(t.target_type);return!e||!n||!s||!a?null:{id:e,kind:n,severity:y(t.severity)??"warn",summary:s,target_type:a,target_id:y(t.target_id)??null,top_action:ge(t.top_action),related_session_ids:G(t.related_session_ids).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),related_agent_names:G(t.related_agent_names).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),evidence_preview:G(t.evidence_preview).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),last_seen_at:y(t.last_seen_at)??null}}function su(t){if(!E(t))return null;const e=y(t.session_id),n=y(t.goal);return!e||!n?null:{session_id:e,goal:n,room:y(t.room)??null,status:y(t.status),health:y(t.health),member_names:G(t.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:y(t.started_at)??null,elapsed_sec:z(t.elapsed_sec)??null,last_event_at:y(t.last_event_at)??null,last_event_summary:y(t.last_event_summary)??null,communication_summary:y(t.communication_summary)??null,active_count:z(t.active_count),required_count:z(t.required_count),related_attention_count:z(t.related_attention_count)??0,top_attention:Qe(t.top_attention),top_recommendation:ge(t.top_recommendation)}}function au(t){if(!E(t))return null;const e=y(t.agent_name);return e?{agent_name:e,status:y(t.status),where:y(t.where)??null,with_whom:G(t.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:y(t.current_work)??null,related_session_id:y(t.related_session_id)??null,related_attention_count:z(t.related_attention_count)??0,recent_output_preview:y(t.recent_output_preview)??null,recent_input_preview:y(t.recent_input_preview)??null,recent_event:y(t.recent_event)??null,recent_tool_names:G(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean)}:null}function iu(t){if(!E(t))return null;const e=y(t.name);return e?{name:e,agent_name:y(t.agent_name)??null,status:y(t.status),generation:z(t.generation),context_ratio:z(t.context_ratio)??null,last_turn_ago_s:z(t.last_turn_ago_s)??null,current_work:y(t.current_work)??null,last_autonomous_action_at:y(t.last_autonomous_action_at)??null}:null}function ou(t){if(!E(t))return null;const e=y(t.id),n=y(t.signal_type),s=y(t.summary),a=y(t.target_type);return!e||!n||!s||!a?null:{id:e,signal_type:n==="action"?"action":"attention",severity:y(t.severity)??"warn",summary:s,target_type:a,target_id:y(t.target_id)??null,attention:Qe(t.attention),action:ge(t.action)}}function ru(t){const e=E(t)?t:{};return{generated_at:y(e.generated_at),summary:Zd(e.summary),incidents:G(e.incidents).map(Qe).filter(n=>n!==null),recommended_actions:G(e.recommended_actions).map(ge).filter(n=>n!==null),command_focus:tu(e.command_focus),operator_targets:eu(e.operator_targets),attention_queue:G(e.attention_queue).map(nu).filter(n=>n!==null),session_briefs:G(e.session_briefs).map(su).filter(n=>n!==null),agent_briefs:G(e.agent_briefs).map(au).filter(n=>n!==null),keeper_briefs:G(e.keeper_briefs).map(iu).filter(n=>n!==null),internal_signals:G(e.internal_signals).map(ou).filter(n=>n!==null)}}function lu(t){if(!E(t))return null;const e=y(t.id),n=y(t.label),s=y(t.summary);if(!e||!n||!s)return null;const a=y(t.status)??"unclear";return{id:e,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:y(t.signal_class)==="metadata_gap"||y(t.signal_class)==="mixed"||y(t.signal_class)==="operational_risk"?y(t.signal_class):void 0,evidence_quality:y(t.evidence_quality)==="strong"||y(t.evidence_quality)==="partial"||y(t.evidence_quality)==="missing"?y(t.evidence_quality):void 0,evidence:G(t.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function cu(t){if(!E(t))return null;const e=y(t.kind),n=y(t.summary),s=y(t.scope_type),a=y(t.severity);return!e||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:e,summary:n,scope_type:s,scope_id:y(t.scope_id)??null,severity:a}}function du(t){const e=E(t)?t:{},n=E(e.basis)?e.basis:{},s=y(e.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:y(e.generated_at),cached:Ee(e.cached),stale:Ee(e.stale),refreshing:Ee(e.refreshing),status:a,summary:y(e.summary)??null,model:y(e.model)??null,ttl_sec:z(e.ttl_sec),criteria:G(e.criteria).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),basis:{current_room:y(n.current_room)??null,crew_count:z(n.crew_count),agent_count:z(n.agent_count),keeper_count:z(n.keeper_count)},metadata_gap_count:z(e.metadata_gap_count),metadata_gaps:G(e.metadata_gaps).map(cu).filter(o=>o!==null),sections:G(e.sections).map(lu).filter(o=>o!==null),error:y(e.error)??null,last_error:y(e.last_error)??null}}async function sr(){Va.value=!0,ks.value=null;try{const t=await Ql();gi.value=ru(t)}catch(t){ks.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{Va.value=!1}}async function xs(t=!1){Te.value=!0,ce.value=null;try{const e=await Xl(t),n=du(e);nr.value=n,n.refreshing||n.status==="pending"?Gd():Gi()}catch(e){ce.value=e instanceof Error?e.message:"Failed to load mission briefing",Gi()}finally{Te.value=!1}}const Ss="masc_dashboard_workflow_context",uu=900*1e3;function dt(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function Ft(t){const e=dt(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function ar(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function Ya(t){return m(t)?t:null}function pu(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function mu(t){if(!t)return null;try{const e=JSON.parse(t);if(!m(e))return null;const n=dt(e.id),s=dt(e.source_surface),a=dt(e.source_label),o=dt(e.summary),l=dt(e.created_at);return!n||s!=="mission"&&s!=="execution"||!a||!o||!l?null:{id:n,source_surface:s,source_label:a,action_type:dt(e.action_type),target_type:dt(e.target_type),target_id:dt(e.target_id),focus_kind:dt(e.focus_kind),operation_id:dt(e.operation_id),command_surface:dt(e.command_surface),summary:o,payload_preview:dt(e.payload_preview),suggested_payload:Ya(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:l}}catch{return null}}function $i(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=uu}function vu(){const t=ar(),e=mu((t==null?void 0:t.getItem(Ss))??null);return e?$i(e)?e:(t==null||t.removeItem(Ss),null):null}const ir=v(vu());function or(t){const e=t&&$i(t)?t:null;ir.value=e;const n=ar();if(!n)return;if(!e){n.removeItem(Ss);return}const s=pu(e);s&&n.setItem(Ss,s)}function _u(t){if(!t)return null;const e=Ya(t.suggested_payload);if(e)return e;if(m(t.preview)){const n=Ya(t.preview.payload);if(n)return n}return null}function fu(t){if(!t)return null;const e=Ft(t.message);if(e)return e;const n=Ft(t.task_title)??Ft(t.title),s=Ft(t.task_description)??Ft(t.description),a=Ft(t.reason),o=Ft(t.priority)??Ft(t.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function hi(t,e,n,s,a,o,l,c){return[t,e,n??"action",s??"target",a??"room",o??"focus",l??"operation",c].join(":")}function Xe(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=_u(t),o=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,l=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,c=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,u=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:hi("mission",n,(t==null?void 0:t.action_type)??null,o,l,c,null,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:o,target_id:l,focus_kind:c,operation_id:null,command_surface:null,summary:u,payload_preview:fu(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function gu({targetType:t,targetId:e,focusKind:n,sourceLabel:s="Execution 진단",summary:a,operationId:o=null,commandSurface:l=null}){const c=new Date().toISOString();return{id:hi("execution",s,null,t,e,n,o,c),source_surface:"execution",source_label:s,action_type:null,target_type:t,target_id:e,focus_kind:n,operation_id:o,command_surface:l,summary:a,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:c}}function $u(t,e){return(e.source==="mission"||e.source==="execution")&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)&&(e.operation_id??null)===(t.operation_id??null)}function Fn(t){const{params:e}=t;if(e.source!=="mission"&&e.source!=="execution")return null;const n=ir.value;if(n&&$i(n)&&$u(n,e))return n;const s=new Date().toISOString(),a=e.source==="execution"?"execution":"mission";return{id:hi(a,a==="execution"?"Execution 이어보기":"상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,e.operation_id??null,s),source_surface:a,source_label:a==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,operation_id:e.operation_id??null,command_surface:e.surface??null,summary:a==="execution"?e.focus_kind?`${e.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function rr(t){return{source:t.source_surface,...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function lr(t){if(t.command_surface)return t.command_surface;const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.focus_kind==="operation"||t.target_type==="operation"?"operations":t.target_type==="room"?"summary":"swarm"}function cr(t){return{source:t.source_surface,surface:lr(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function hu(t){return rr(t)}function yu(t){return cr(t)}function yi(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function ea(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";default:return(t==null?void 0:t.trim())||"추천 액션"}}function bu(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}const Ut=v(null),zt=v(null);function J(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function ot(t){return t==="bad"||t==="offline"||t==="critical"||t==="risk"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"||t==="watch"?"warn":"ok"}function _e(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:n<86400?`${Math.round(n/3600)}h 전`:`${Math.round(n/86400)}d 전`}function ku(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:t<86400?`${Math.round(t/3600)}h`:`${Math.round(t/86400)}d`}function xu(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function Su(t){return yi(t?Xe(t,null,"상황판 추천 액션"):null)}function na(t,e=Xe()){or(e),rt(t,t==="intervene"?hu(e):yu(e))}function dr(t){na("intervene",Xe(null,t,"상황판 incident"))}function ur(t){na("command",Xe(null,t,"상황판 incident"))}function bi(t,e,n="상황판 추천 액션"){na("intervene",Xe(t,e,n))}function pr(t,e,n="상황판 추천 액션"){na("command",Xe(t,e,n))}function Ji(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),rt(t,n)}function Cu(t){return{kind:t.kind,severity:t.severity,summary:t.summary,target_type:t.target_type,target_id:t.target_id??null,actor:null,evidence:t.evidence_preview}}function mr(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>(s.from??"").trim().toLowerCase()===n).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function Au(t){return t.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")}function Iu(t,e){if(!e)return!1;const n=Au(e);return new RegExp(`(?:^|[^a-z0-9_])@${n}(?![a-z0-9_-])`,"i").test(t)}function Tu(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>{if((s.from??"").trim().toLowerCase()===n)return!1;const o=(s.content??"").trim().toLowerCase();return Iu(o,n)}).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function wu(t){return Ot.value.find(e=>e.agent_name===t||e.name===t)??null}function vr(t){return Rt.value.find(e=>e.name===t)??null}function _r(t,e){const n=J(t,100);if(!n)return null;const s=e.find(o=>o.id===n);if(s)return`${s.id} · ${J(s.title,92)}`;const a=e.find(o=>o.title===n);return a?`${a.id} · ${J(a.title,92)}`:n}function Pu(t){var c,u;const e=vr(t.agent_name),n=wu(t.agent_name),s=mr(t.agent_name,He.value),a=Tu(t.agent_name,He.value),o=fi(t.agent_name),l=(n==null?void 0:n.skill_primary)??(e!=null&&e.capabilities&&e.capabilities.length>0?e.capabilities.slice(0,3).join(", "):null)??o.model??(e==null?void 0:e.agent_type)??null;return{brief:t,agent:e,keeper:n,where:t.where??"room",withWhom:t.with_whom,currentWork:t.current_work??_r((e==null?void 0:e.current_task)??null,Tt.value)??"명시된 current task 없음",how:l,recentInput:J(t.recent_input_preview,120)??J(a==null?void 0:a.content,120)??J(n==null?void 0:n.recent_input_preview,120)??null,recentOutput:J(t.recent_output_preview,120)??J(s==null?void 0:s.content,120)??J(n==null?void 0:n.recent_output_preview,120)??J((c=n==null?void 0:n.diagnostic)==null?void 0:c.last_reply_preview,120)??null,recentEvent:J(t.recent_event,120)??J((u=n==null?void 0:n.diagnostic)==null?void 0:u.summary,120)??null,recentTools:t.recent_tool_names.length>0?t.recent_tool_names:(n==null?void 0:n.recent_tool_names)??[]}}function Ru(t){var n,s;const e=Ot.value.find(a=>a.name===t.name||a.agent_name===t.agent_name)??null;return{brief:t,keeper:e,currentWork:J(t.current_work,110)??J(e==null?void 0:e.skill_primary,110)??J(e==null?void 0:e.last_proactive_reason,110)??"명시된 keeper focus 없음",recentInput:J(e==null?void 0:e.recent_input_preview,120)??null,recentOutput:J(e==null?void 0:e.recent_output_preview,120)??J((n=e==null?void 0:e.diagnostic)==null?void 0:n.last_reply_preview,120)??J(e==null?void 0:e.last_proactive_preview,120)??null,recentEvent:J(e==null?void 0:e.last_proactive_reason,120)??J((s=e==null?void 0:e.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(e==null?void 0:e.recent_tool_names)??[]}}function Lu(){const t=gi.value;return t?new Map(t.session_briefs.map(e=>[e.session_id,e])):new Map}function Mu(t){const e=vr(t),n=mr(t,He.value),s=fi(t);return{name:t,model:s.model,nickname:s.nickname,currentTask:_r((e==null?void 0:e.current_task)??null,Tt.value)??"agent snapshot 없음",output:J(n==null?void 0:n.content,96)}}function Nu(t){Ut.value=Ut.value===t?null:t,zt.value=null}function fr(t){zt.value=zt.value===t?null:t}function zu(){Ut.value=null,zt.value=null}function te({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function gr(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const o=Math.floor(a/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function Q({timestamp:t}){const e=gr(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return i`<span class="time-ago" title=${n}>${e}</span>`}let Du=0;const pe=v([]);function P(t,e="success",n=4e3){const s=++Du;pe.value=[...pe.value,{id:s,message:t,type:e}],setTimeout(()=>{pe.value=pe.value.filter(a=>a.id!==s)},n)}function Eu(t){pe.value=pe.value.filter(e=>e.id!==t)}function ju(){const t=pe.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Eu(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Ou="masc_dashboard_agent_name",Ze=v(null),Cs=v(!1),Sn=v(""),As=v([]),Cn=v([]),je=v(""),mn=v(!1);function An(t){Ze.value=t,ki()}function Vi(){Ze.value=null,Sn.value="",As.value=[],Cn.value=[],je.value=""}function qu(){const t=Ze.value;return t?Rt.value.find(e=>e.name===t)??null:null}function $r(t){return t?Tt.value.filter(e=>e.assignee===t):[]}function hr(t){return t?Ot.value.find(e=>e.agent_name===t||e.name===t)??null:null}function Fu(t){if(!t)return[];const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Ku(t){const e=hr(t);return e?e.recent_tool_names&&e.recent_tool_names.length>0?e.recent_tool_names:[]:[]}async function ki(){const t=Ze.value;if(t){Cs.value=!0,Sn.value="",As.value=[],Cn.value=[];try{const e=await qc(80);As.value=e.filter(a=>a.includes(t)).slice(0,20);const n=$r(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await Fc(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const l=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));Cn.value=s}catch(e){Sn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Cs.value=!1}}}async function Yi(){var s;const t=Ze.value,e=je.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Ou))==null?void 0:s.trim())||"dashboard";mn.value=!0;try{await Oc(n,`@${t} ${e}`),je.value="",P(`Mention sent to ${t}`,"success"),ki()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";P(o,"error")}finally{mn.value=!1}}function Bu({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${te} status=${t.status} />
    </div>
  `}function Uu({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Hu(){var _,g,h,k,$,A,I;const t=Ze.value;if(!t)return null;const e=qu(),n=hr(t),s=$r(t),a=As.value,o=Ku(t),l=Fu(n),c=(e==null?void 0:e.capabilities)??[],u=((_=$t.value)==null?void 0:_.room)??"default",p=((g=$t.value)==null?void 0:g.project)??"확인 없음",f=((h=$t.value)==null?void 0:h.cluster)??"확인 없음";return i`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${C=>{C.target.classList.contains("agent-detail-overlay")&&Vi()}}
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
                        <${te} status=${e.status} />
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
                ${($=e==null?void 0:e.traits)==null?void 0:$.map(C=>i`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${C}</span>`)}
              </div>
            `:""}
            ${(((A=e==null?void 0:e.interests)==null?void 0:A.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(I=e==null?void 0:e.interests)==null?void 0:I.map(C=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${C}</span>`)}
              </div>
            `:""}
            ${c.length>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${c.map(C=>i`<span style="font-size:0.7rem;background:#183153;color:#7dd3fc;padding:2px 8px;border-radius:10px">${C}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?i`
                    ${e.current_task?i`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?i`<span>Last seen: <${Q} timestamp=${e.last_seen} /></span>`:null}
                    <span>Room: ${u}</span>
                    <span>Project: ${p}</span>
                    <span>Cluster: ${f}</span>
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{ki()}} disabled=${Cs.value}>
              ${Cs.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Vi}>Close</button>
          </div>
        </div>

        ${Sn.value?i`<div class="council-error">${Sn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${T} title="Assigned Tasks">
            ${s.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${s.map(C=>i`<${Bu} key=${C.id} task=${C} />`)}</div>`}
          <//>

          <${T} title="Recent Activity">
            ${a.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${a.map((C,S)=>i`<div key=${S} class="agent-activity-line">${C}</div>`)}</div>`}
          <//>
        </div>

        <${T} title="Capabilities & Tools">
          <div style="display:flex; flex-direction:column; gap:12px;">
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Capabilities</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${c.length>0?c.map(C=>i`<span class="pill">${C}</span>`):i`<span class="empty-state" style="font-size:12px;">No capability metadata</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Recent tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${o.length>0?o.map(C=>i`<span class="pill">${C}</span>`):i`<span class="empty-state" style="font-size:12px;">No tool telemetry</span>`}
              </div>
            </div>
            ${o.length===0&&l.length>0?i`
                  <div>
                    <div style="font-size:12px; color:#888; margin-bottom:6px;">Window top tools</div>
                    <div style="display:flex; flex-wrap:wrap; gap:6px;">
                      ${l.map(C=>i`<span class="pill">${C}</span>`)}
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
          ${Cn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${Cn.value.map(C=>i`<${Uu} key=${C.taskId} row=${C} />`)}</div>`}
        <//>

        <${T} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${je.value}
              onInput=${C=>{je.value=C.target.value}}
              onKeyDown=${C=>{C.key==="Enter"&&Yi()}}
              disabled=${mn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Yi()}}
              disabled=${mn.value||je.value.trim()===""}
            >
              ${mn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const vt=v(null),xi=v(null),wt=v(null),In=v(!1),Xt=v(null),Tn=v(!1),We=v(null),H=v(!1),Is=v([]);let Wu=1;function Gu(t){return m(t)?{id:r(t.id),seq:d(t.seq),from:r(t.from)??r(t.from_agent)??"system",content:r(t.content)??"",timestamp:r(t.timestamp)??new Date().toISOString(),type:r(t.type)}:null}function Ju(t){return m(t)?{room_id:r(t.room_id),current_room:r(t.current_room)??r(t.room),project:r(t.project),cluster:r(t.cluster),paused:O(t.paused),pause_reason:r(t.pause_reason)??null,paused_by:r(t.paused_by)??null,paused_at:r(t.paused_at)??null}:{}}function Qi(t){if(!m(t))return;const e=Object.entries(t).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function yr(t){if(!m(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function br(t){if(!m(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:O(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Vu(t){return m(t)?{actor:r(t.actor)??null,spawn_agent:r(t.spawn_agent)??null,spawn_role:r(t.spawn_role)??null,spawn_model:r(t.spawn_model)??null,worker_class:r(t.worker_class)??null,parent_actor:r(t.parent_actor)??null,capsule_mode:r(t.capsule_mode)??null,runtime_pool:r(t.runtime_pool)??null,lane_id:r(t.lane_id)??null,controller_level:r(t.controller_level)??null,control_domain:r(t.control_domain)??null,supervisor_actor:r(t.supervisor_actor)??null,model_tier:r(t.model_tier)??null,task_profile:r(t.task_profile)??null,risk_level:r(t.risk_level)??null,routing_confidence:d(t.routing_confidence)??null,routing_reason:r(t.routing_reason)??null,status:r(t.status)??"unknown",turn_count:d(t.turn_count)??0,empty_note_turn_count:d(t.empty_note_turn_count)??0,has_turn:O(t.has_turn)??!1,last_turn_ts_iso:r(t.last_turn_ts_iso)??null}:null}function Yu(t){if(!m(t))return null;const e=r(t.session_id);return e?{session_id:e,goal:r(t.goal),status:r(t.status),health:r(t.health),scale_profile:r(t.scale_profile),control_profile:r(t.control_profile),planned_worker_count:d(t.planned_worker_count),active_agent_count:d(t.active_agent_count),last_turn_age_sec:d(t.last_turn_age_sec)??null,attention_count:d(t.attention_count),recommended_action_count:d(t.recommended_action_count),top_attention:yr(t.top_attention),top_recommendation:br(t.top_recommendation)}:null}function kr(t){const e=m(t)?t:{};return{trace_id:r(e.trace_id),target_type:r(e.target_type)??"room",target_id:r(e.target_id)??null,health:r(e.health),swarm_status:m(e.swarm_status)?e.swarm_status:void 0,attention_items:At(e.attention_items).map(yr).filter(n=>n!==null),recommended_actions:At(e.recommended_actions).map(br).filter(n=>n!==null),session_cards:At(e.session_cards).map(Yu).filter(n=>n!==null),worker_cards:At(e.worker_cards).map(Vu).filter(n=>n!==null)}}function Qu(t){if(!m(t))return null;const e=m(t.status)?t.status:void 0,n=m(t.summary)?t.summary:m(e==null?void 0:e.summary)?e.summary:void 0,s=m(t.session)?t.session:m(e==null?void 0:e.session)?e.session:void 0,a=r(t.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const o=Qi(t.report_paths)??Qi(e==null?void 0:e.report_paths),l=At(t.recent_events,["events"]).filter(m);return{session_id:a,status:r(t.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:d(t.progress_pct)??d(n==null?void 0:n.progress_pct),elapsed_sec:d(t.elapsed_sec)??d(n==null?void 0:n.elapsed_sec),remaining_sec:d(t.remaining_sec)??d(n==null?void 0:n.remaining_sec),done_delta_total:d(t.done_delta_total)??d(n==null?void 0:n.done_delta_total),summary:n,team_health:m(t.team_health)?t.team_health:m(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:m(t.communication_metrics)?t.communication_metrics:m(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:m(t.orchestration_state)?t.orchestration_state:m(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:m(t.cascade_metrics)?t.cascade_metrics:m(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:s,recent_events:l}}function Xu(t){if(!m(t))return null;const e=r(t.name);if(!e)return null;const n=m(t.context)?t.context:void 0;return{name:e,agent_name:r(t.agent_name),status:r(t.status),autonomy_level:r(t.autonomy_level),context_ratio:d(t.context_ratio)??d(n==null?void 0:n.context_ratio),generation:d(t.generation),active_goal_ids:q(t.active_goal_ids),last_autonomous_action_at:r(t.last_autonomous_action_at)??null,last_turn_ago_s:d(t.last_turn_ago_s),model:r(t.model)??r(t.active_model)??r(t.primary_model)}}function Zu(t){if(!m(t))return null;const e=r(t.confirm_token)??r(t.token);return e?{confirm_token:e,actor:r(t.actor),action_type:r(t.action_type),target_type:r(t.target_type),target_id:r(t.target_id)??null,delegated_tool:r(t.delegated_tool),created_at:r(t.created_at),preview:t.preview}:null}function tp(t){const e=m(t)?t:{};return{room:Ju(e.room),sessions:At(e.sessions,["items","sessions"]).map(Qu).filter(n=>n!==null),keepers:At(e.keepers,["items","keepers"]).map(Xu).filter(n=>n!==null),recent_messages:At(e.recent_messages,["messages"]).map(Gu).filter(n=>n!==null),pending_confirms:At(e.pending_confirms,["items","confirms"]).map(Zu).filter(n=>n!==null),available_actions:At(e.available_actions,["actions"]).filter(m).map(n=>({action_type:r(n.action_type)??"unknown",target_type:r(n.target_type)??"unknown",description:r(n.description),confirm_required:O(n.confirm_required)}))}}function Xn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Xi(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Ts(t){Is.value=[{...t,id:Wu++,at:new Date().toISOString()},...Is.value].slice(0,20)}function xr(t){return t.confirm_required?Xn(t.preview)||"Confirmation required":Xn(t.result)||Xn(t.executed_action)||Xn(t.delegated_tool_result)||t.status}async function pt(){In.value=!0,Xt.value=null;try{const t=await ec();vt.value=tp(t)}catch(t){Xt.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{In.value=!1}}async function fe(){Tn.value=!0,We.value=null;try{const t=await Mo({targetType:"room"});xi.value=kr(t)}catch(t){We.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{Tn.value=!1}}async function Ge(t){if(!t){wt.value=null;return}Tn.value=!0,We.value=null;try{const e=await Mo({targetType:"team_session",targetId:t,includeWorkers:!0});wt.value=kr(e)}catch(e){We.value=e instanceof Error?e.message:"Failed to load session digest"}finally{Tn.value=!1}}async function ep(t){var e;H.value=!0,Xt.value=null;try{const n=await Zs(t);return Ts({actor:t.actor,action_type:t.action_type,target_label:Xi(t),outcome:n.confirm_required?"preview":"executed",message:xr(n),delegated_tool:n.delegated_tool}),await pt(),await fe(),(e=wt.value)!=null&&e.target_id&&await Ge(wt.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw Xt.value=s,Ts({actor:t.actor,action_type:t.action_type,target_label:Xi(t),outcome:"error",message:s}),n}finally{H.value=!1}}async function np(t,e){var n;H.value=!0,Xt.value=null;try{const s=await dc(t,e);return Ts({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:xr(s),delegated_tool:s.delegated_tool}),await pt(),await fe(),(n=wt.value)!=null&&n.target_id&&await Ge(wt.value.target_id),s}catch(s){const a=s instanceof Error?s.message:"Operator confirmation failed";throw Xt.value=a,Ts({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),s}finally{H.value=!1}}qd(()=>{var t;pt(),fe(),(t=wt.value)!=null&&t.target_id&&Ge(wt.value.target_id)});function sp(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function ap(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function ip(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Zi(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function Sr(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function op(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Cr(t){if(!t)return null;const e=Et.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function rp({keeper:t,showRawStatus:e=!1}){if(Z(()=>{t!=null&&t.name&&jo(t.name)},[t==null?void 0:t.name]),!t)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Et.value[t.name],s=Cr(t),a=Fa.value[t.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${sp(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${ap((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?i` · ${Sr(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?i` · next eligible ${op(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function lp({keeperName:t,placeholder:e}){const[n,s]=ko("");Z(()=>{t&&jo(t)},[t]);const a=it.value[t]??[],o=Ka.value[t]??!1,l=jt.value[t],c=async()=>{const u=n.trim();if(!(!t||!u)){s("");try{await od(t,u)}catch(p){const f=p instanceof Error?p.message:`Failed to message ${t}`;P(f,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(u=>i`
              <div class="keeper-conversation-item" key=${u.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Zi(u)}`}>${u.label}</span>
                  <span class=${`keeper-role-chip ${Zi(u)}`}>${ip(u)}</span>
                  ${u.timestamp?i`<span class="keeper-conversation-time">${Sr(u.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${u.text}</div>
                ${u.error?i`<div class="keeper-conversation-error">${u.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${e}
          value=${n}
          onInput=${u=>{s(u.target.value)}}
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
  `}function cp({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=Cr(e),a=Ba.value[e.name]??!1,o=Ua.value[e.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{rd(e.name,t).catch(u=>{const p=u instanceof Error?u.message:`Failed to probe ${e.name}`;P(p,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{ld(e.name,t).catch(u=>{const p=u instanceof Error?u.message:`Failed to recover ${e.name}`;P(p,"error")})}}
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
  `}const Si=v(null);function Ar(t){Si.value=t,id(t.name)}function to(){Si.value=null}const Se=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function dp(t){if(!t)return 0;const e=Se.findIndex(n=>n.level===t);return e>=0?e:0}function up({keeper:t}){const e=dp(t.autonomy_level),n=Se[e]??Se[0];if(!n)return null;const s=(e+1)/Se.length*100;return i`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${Se.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Se.map((a,o)=>i`
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
  `}function ps(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function pp(t){switch(t){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(t==null?void 0:t.trim())||"action"}}function mp(t){return t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]}function vp(t){const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function _p({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${ps(t.context_tokens)}</div>
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
  `}function fp({keeper:t}){var f,_;const e=t.metrics_series??[];if(e.length<2){const g=(((f=t.context)==null?void 0:f.context_ratio)??0)*100,h=g>85?"#ef4444":g>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${g.toFixed(1)}%;background:${h}"></div>
        </div>
        <span class="chart-pct">${g.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=e.length,l=e.map((g,h)=>{const k=a+h/(o-1)*(n-2*a),$=s-a-(g.context_ratio??0)*(s-2*a);return{x:k,y:$,p:g}}),c=l.map(({x:g,y:h})=>`${g.toFixed(1)},${h.toFixed(1)}`).join(" "),u=(((_=e[e.length-1])==null?void 0:_.context_ratio)??0)*100,p=u>85?"#ef4444":u>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:g})=>g.is_handoff).map(({x:g})=>i`
          <line x1="${g.toFixed(1)}" y1="${a}" x2="${g.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${p}" stroke-width="1.5"/>
        ${l.filter(({p:g})=>g.is_compaction).map(({x:g,y:h})=>i`
          <circle cx="${g.toFixed(1)}" cy="${h.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${u.toFixed(1)}%</span>
    </div>`}const da=v("");function gp({keeper:t}){var a,o,l,c;const e=da.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],s=e?n.filter(u=>u.title.toLowerCase().includes(e)||u.key.includes(e)||u.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${da.value}
        onInput=${u=>{da.value=u.target.value}}
      />
      ${s.map(u=>i`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${u.title}</span>
          <span class="keeper-field-key">${u.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${u.value}</span>
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
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${ps(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${ps(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${ps(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function $p({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
  `}function hp({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function yp({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function eo({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function ua(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function bp({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:ua(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:ua(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:ua(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(s=>i`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function kp({keeper:t}){var p,f,_,g,h,k,$;const e=((p=vt.value)==null?void 0:p.room)??{},n=(((f=vt.value)==null?void 0:f.available_actions)??[]).filter(A=>A.target_type==="keeper"||A.target_type==="room").slice(0,8),s=mp(t),a=vp(t),o=((_=t.agent)==null?void 0:_.capabilities)??[],l=e.current_room??e.room_id??((g=$t.value)==null?void 0:g.room)??"default",c=e.project??((h=$t.value)==null?void 0:h.project)??"확인 없음",u=e.cluster??((k=$t.value)==null?void 0:k.cluster)??"확인 없음";return i`
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
        <strong>${u}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Current task</span>
        <strong>${(($=t.agent)==null?void 0:$.current_task)??"없음"}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Skill route</span>
        <strong>${t.skill_primary??"미확인"}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Recent tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${s.length>0?s.map(A=>i`<span class="pill">${A}</span>`):i`<span style="font-size:12px; color:#888;">도구 텔레메트리 없음</span>`}
        </div>
      </div>
      ${s.length===0&&a.length>0?i`
            <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
              <span style="font-size:12px; color:#888;">Window top tools</span>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${a.map(A=>i`<span class="pill">${A}</span>`)}
              </div>
            </div>
          `:null}
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Capabilities</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${o.length>0?o.map(A=>i`<span class="pill">${A}</span>`):i`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(A=>i`<span class="pill">${pp(A.action_type)}</span>`):i`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function Ir(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function xp(){try{const t=await Zs({actor:Ir(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Eo(t.result);await qn(),e!=null&&e.skipped_reason?P(e.skipped_reason,"warning"):P(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";P(e,"error")}}function Sp({keeper:t}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${rp} keeper=${t} />
          <${cp}
            actor=${Ir()}
            keeper=${t}
            onPokeLodge=${()=>{xp()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${lp}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function Cp(){var e,n,s;const t=Si.value;return t?i`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&to()}}
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
            <${te} status=${t.status} />
            ${t.model?i`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>to()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${_p} keeper=${t} />

        ${""}
        <${fp} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${T} title="Field Dictionary">
            <${gp} keeper=${t} />
          <//>

          ${""}
          <${T} title="Profile">
            <${eo} traits=${t.traits??[]} label="Traits" />
            <${eo} traits=${t.interests??[]} label="Interests" />
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
                <${up} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?i`
              <${T} title="TRPG Stats">
                <${$p} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${T} title="Equipment (${t.inventory.length})">
                <${hp} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${T} title="Relationships (${Object.keys(t.relationships).length})">
                <${yp} rels=${t.relationships} />
              <//>
            `:null}

          <${T} title="Runtime Signals">
            <${bp} keeper=${t} />
          <//>

          <${T} title="Neighborhood & Tools">
            <${kp} keeper=${t} />
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
        <${Sp} keeper=${t} />
      </div>
    </div>
  `:null}function Ap({cluster:t,project:e,room:n,generatedAt:s}){return i`
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
  `}function ke({label:t,value:e,detail:n,tone:s}){return i`
    <article class="mission-stat-card ${ot(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function Ip(){const t=nr.value,e=ot((t==null?void 0:t.status)??(ce.value?"bad":"warn")),n=(t==null?void 0:t.status)==="error"||(t==null?void 0:t.status)==="unavailable"&&!(t!=null&&t.cached);return i`
    <${T} title="LLM 판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>heuristic 대신 별도 판단 계층</h3>
        <p>핵심 해석 3줄만 먼저 보여주고, 근거는 접어서 둡니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${e}">
          ${(t==null?void 0:t.status)??(ce.value?"error":"loading")}
        </span>
        ${t!=null&&t.model?i`<span class="command-chip">${t.model}</span>`:null}
        ${t!=null&&t.generated_at?i`<span class="command-chip">${_e(t.generated_at)}</span>`:null}
        ${t!=null&&t.cached?i`<span class="command-chip">cached</span>`:null}
        ${t!=null&&t.stale?i`<span class="command-chip warn">stale</span>`:null}
      </div>

      ${ce.value?i`<div class="empty-state error">${ce.value}</div>`:null}
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
          `:!Te.value&&!ce.value?i`<div class="empty-state">판단 레이어 결과가 아직 없습니다.</div>`:null}

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
        <button class="control-btn ghost" onClick=${()=>{xs(n)}} disabled=${Te.value}>
          ${Te.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{xs(!0)}} disabled=${Te.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function Tp({item:t,selected:e,sessionLookup:n}){const s=Cu(t),a=t.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),o=t.top_action??null;return i`
    <article class="mission-attention-card ${ot((o==null?void 0:o.severity)??t.severity)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Nu(t.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.summary}</strong>
            <div class="mission-card-target">${t.kind}${t.target_id?` · ${t.target_id}`:""}</div>
          </div>
          <span class="command-chip ${ot((o==null?void 0:o.severity)??t.severity)}">${o?xu(o):t.severity}</span>
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
            <strong>${o?ea(o.action_type):"판단 필요"}</strong>
            <small>${o?Su(o):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${o?i`<div class="mission-inline-note">${o.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?i`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>i`
                  <button class="mission-link-row" onClick=${()=>fr(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${l.status??"unknown"} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:i`<div class="empty-state">직접 연결된 session이 아직 없습니다.</div>`}

        ${t.related_agent_names.length>0?i`
              <div class="mission-pill-row">
                ${t.related_agent_names.slice(0,8).map(l=>i`
                  <button class="mission-pill action" onClick=${()=>An(l)}>${l}</button>
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
              <button class="control-btn ghost" onClick=${()=>bi(o,s,"Mission attention")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>pr(o,s,"Mission attention")}>
                원인 보기
              </button>
            `:i`
              <button class="control-btn ghost" onClick=${()=>dr(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>ur(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function wp({brief:t,selected:e}){var o,l;const n=t.member_names.slice(0,6).map(Mu),s=t.top_recommendation??null,a=t.top_attention??null;return i`
    <article class="mission-crew-card ${ot(((o=t.top_attention)==null?void 0:o.severity)??t.health??t.status)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>fr(t.session_id)}>
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
            <strong>${ku(t.elapsed_sec)}</strong>
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
                ${n.map(c=>i`
                  <button class="mission-pill action" onClick=${()=>An(c.name)}>
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
                    <button class="mission-link-row" onClick=${()=>An(c.name)}>
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
        <button class="control-btn ghost" onClick=${()=>Ji("intervene",t.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Ji("command",t.session_id)}>세션 원인 보기</button>
        ${s?i`<button class="control-btn ghost" onClick=${()=>bi(s,a,"Mission session brief")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function Pp({row:t}){var s,a,o,l,c;const e=fi(t.brief.agent_name),n=t.withWhom.length>0?t.withWhom.slice(0,3).join(", "):"단독 또는 room-level";return i`
    <article class="mission-activity-card ${ot(t.brief.status??((s=t.agent)==null?void 0:s.status))}">
      <button class="mission-card-select" onClick=${()=>An(t.brief.agent_name)}>
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
  `}function Rp({row:t}){var n,s,a,o,l,c,u,p,f,_;const e=[`gen ${t.brief.generation??((n=t.keeper)==null?void 0:n.generation)??0}`,t.brief.context_ratio!=null?`ctx ${Math.round(t.brief.context_ratio*100)}%`:((s=t.keeper)==null?void 0:s.context_ratio)!=null?`ctx ${Math.round(t.keeper.context_ratio*100)}%`:null,t.brief.last_turn_ago_s!=null?`last turn ${Math.round(t.brief.last_turn_ago_s)}s`:null].filter(g=>g!==null).join(" · ");return i`
    <article class="mission-activity-card ${ot(t.brief.status??((a=t.keeper)==null?void 0:a.status))}">
      <button class="mission-card-select" onClick=${()=>{t.keeper&&Ar(t.keeper)}}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((o=t.keeper)==null?void 0:o.emoji)??""}</span>
            <div>
              <strong>${t.brief.name}</strong>
              ${(l=t.keeper)!=null&&l.koreanName?i`<span>${t.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <span class="command-chip ${ot(t.brief.status??((c=t.keeper)==null?void 0:c.status))}">${t.brief.status??((u=t.keeper)==null?void 0:u.status)??"unknown"}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 heartbeat · ${(p=t.keeper)!=null&&p.last_heartbeat?_e(t.keeper.last_heartbeat):"n/a"}</span>
          <span>${e||"continuity 정보 없음"}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${t.currentWork}</strong>
          ${(f=t.keeper)!=null&&f.skill_reason?i`<small>판단 요약 · ${J(t.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>continuity detail</summary>
        <div class="mission-activity-foot">
          <span>agent · ${t.brief.agent_name??((_=t.keeper)==null?void 0:_.agent_name)??"n/a"}</span>
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
  `}function Lp({item:t}){const e=t.action??null,n=t.attention??null;return i`
    <article class="mission-action-card ${ot(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${ot(t.severity)}">
          ${t.signal_type==="action"&&e?ea(e.action_type):(n==null?void 0:n.kind)??"signal"}
        </span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      ${e?i`<div class="mission-action-preview">${e.reason}</div>`:null}
      <div class="mission-card-actions">
        ${e?i`
              <button class="control-btn ghost" onClick=${()=>bi(e,n,"Mission internal signal")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>pr(e,n,"Mission internal signal")}>이 이슈의 원인 보기</button>
            `:n?i`
                <button class="control-btn ghost" onClick=${()=>dr(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>ur(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function no(){var g,h,k,$,A,I,C;const t=gi.value;if(Va.value&&!t)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(ks.value&&!t)return i`<div class="empty-state error">${ks.value}</div>`;if(!t)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;Ut.value&&!t.attention_queue.some(S=>S.id===Ut.value)&&(Ut.value=null),zt.value&&!t.session_briefs.some(S=>S.session_id===zt.value)&&(zt.value=null);const e=t.attention_queue.find(S=>S.id===Ut.value)??null,n=zt.value,s=Lu(),a=e?new Set(e.related_session_ids):null,o=e?new Set(e.related_agent_names):null,l=(a?t.session_briefs.filter(S=>a.has(S.session_id)):t.session_briefs).slice(0,e?8:6),c=t.agent_briefs.filter(S=>!Wd(S.agent_name)).filter(S=>n?S.related_session_id===n:o&&a?o.has(S.agent_name)||(S.related_session_id?a.has(S.related_session_id):!1):!0).slice(0,n||e?10:8).map(Pu),u=t.keeper_briefs.slice(0,6).map(Ru),p=t.attention_queue.slice(0,6),f=t.internal_signals.slice(0,3),_=c.filter(S=>S.recentOutput).length+u.filter(S=>S.recentOutput).length;return i`
    <section class="dashboard-panel mission-view">
      <${mt} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>원인 분석과 개입 판단을 먼저 보는 landing 입니다. 문제 → 영향 session → 관련 actor 순서로 좁혀서 읽습니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${ot(t.summary.room_health)}">${t.summary.room_health??"ok"}</span>
          <span class="command-chip">${t.summary.project??"room"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?_e(t.generated_at):"fresh"}</span>
        </div>
      </div>

      <${Ap}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <${Ip} />

      <div class="mission-stat-grid">
        <${ke} label="주의 큐" value=${p.length} detail="개입 판단이 필요한 issue" tone=${((g=p[0])==null?void 0:g.severity)??"ok"} />
        <${ke} label="영향 session" value=${l.length} detail="현재 선택 기준으로 좁힌 흐름" tone=${((k=(h=l[0])==null?void 0:h.top_attention)==null?void 0:k.severity)??(($=l[0])==null?void 0:$.health)??"ok"} />
        <${ke} label="영향 agent" value=${c.length} detail="선택된 흐름에 연결된 actor" tone=${((A=c[0])==null?void 0:A.brief.status)??"ok"} />
        <${ke} label="Keeper watch" value=${u.length} detail="continuity lane 관찰 대상" tone=${((I=u[0])==null?void 0:I.brief.status)??"ok"} />
        <${ke} label="최근 output" value=${_} detail="선택된 영역에서 바로 읽을 수 있는 출력 수" tone=${_>0?"ok":"warn"} />
        <${ke} label="내부 신호" value=${f.length} detail="room/system 진단은 하단 보조 lane" tone=${((C=f[0])==null?void 0:C.severity)??"ok"} />
      </div>

      ${e||n?i`
            <div class="mission-selection-bar">
              <span>현재 drill-down · ${e?e.summary:"session 선택"}${n?` · ${n}`:""}</span>
              <button class="control-btn ghost" onClick=${zu}>선택 해제</button>
            </div>
          `:null}

      <${T} title="Attention Queue" class="mission-list-card" semanticId="mission.attention_queue">
        <div class="mission-section-head">
          <h3>이슈에서 시작</h3>
          <p>문제와 경고를 먼저 보고, 여기서 session과 agent로 좁혀갑니다.</p>
        </div>
        <div class="mission-lane-stack">
          ${p.length>0?p.map(S=>i`<${Tp} key=${S.id} item=${S} selected=${Ut.value===S.id} sessionLookup=${s} />`):i`<div class="empty-state">지금 Mission attention queue가 비어 있습니다.</div>`}
        </div>
      <//>

      <div class="mission-human-grid">
        <${T} title="Affected Sessions" class="mission-list-card" semanticId="mission.session_briefs">
          <div class="mission-section-head">
            <h3>영향받는 session</h3>
            <p>attention과 직접 연결된 흐름만 먼저 보여주고, member preview는 한 단계 더 열었을 때만 보여줍니다.</p>
          </div>
          <div class="mission-list-stack">
            ${l.length>0?l.map(S=>i`<${wp} key=${S.session_id} brief=${S} selected=${zt.value===S.session_id} />`):i`<div class="empty-state">현재 선택과 연결된 session이 없습니다.</div>`}
          </div>
        <//>

        <${T} title="Impacted Agents" class="mission-list-card" semanticId="mission.agent_activity">
          <div class="mission-section-head">
            <h3>관련 agent</h3>
            <p>선택된 incident 또는 session과 연결된 actor만 보여주고, input-output은 접어서 둡니다.</p>
          </div>
          <div class="mission-activity-list">
            ${c.length>0?c.map(S=>i`<${Pp} key=${S.brief.agent_name} row=${S} />`):i`<div class="empty-state">현재 선택과 연결된 agent가 없습니다.</div>`}
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
            ${u.length>0?u.map(S=>i`<${Rp} key=${S.brief.name} row=${S} />`):i`<div class="empty-state">지금 보이는 keeper가 없습니다.</div>`}
          </div>
        <//>

        <${T} title="Internal Signals" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>room / system 보조 신호</h3>
            <p>artifact scope drift 같은 시스템 진단은 메인 판단 근거가 아니라 보조 lane으로만 유지합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${f.length>0?f.map(S=>i`<${Lp} key=${S.id} item=${S} />`):i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>rt("execution")}>실행 관찰면 보기</button>
            <button class="control-btn ghost" onClick=${()=>rt("command")}>지휘 진단면 보기</button>
          </div>
        <//>
      </div>
    </section>
  `}const Tr=v(null),Qa=v(!1),we=v(null);async function wr(t,e){Qa.value=!0,we.value=null;try{Tr.value=await Zl(t,e)}catch(n){we.value=n instanceof Error?n.message:String(n)}finally{Qa.value=!1}}const Mp="modulepreload",Np=function(t){return"/dashboard/"+t},so={},zp=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(p){return Promise.all(p.map(f=>Promise.resolve(f).then(_=>({status:"fulfilled",value:_}),_=>({status:"rejected",reason:_}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),u=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(p=>{if(p=Np(p),p in so)return;so[p]=!0;const f=p.endsWith(".css"),_=f?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${p}"]${_}`))return;const g=document.createElement("link");if(g.rel=f?"stylesheet":Mp,f||(g.as="script"),g.crossOrigin="",g.href=p,u&&g.setAttribute("nonce",u),document.head.appendChild(g),f)return new Promise((h,k)=>{g.addEventListener("load",h),g.addEventListener("error",()=>k(new Error(`Unable to preload CSS for ${p}`)))})}))}function o(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&o(c.reason);return e().catch(o)})},Ci=v(null),Lt=v(null),ws=v(!1),Ps=v(!1),Rs=v(null),Ls=v(null),Xa=v(null),Ms=v(null),V=v("warroom"),Kn=v(null),Za=v(!1),Ns=v(null),$e=v(null),zs=v(!1),Ds=v(null),Bn=v(null),ti=v(!1),Es=v(null),wn=v(null),js=v(!1),Pn=v(null),Oe=v(null);let on=null;function Ai(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"}function Pr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function Dp(){const e=Pr().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Ep(){const e=Pr().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function jp(t){if(m(t))return{policy_class:r(t.policy_class),approval_class:r(t.approval_class),tool_allowlist:q(t.tool_allowlist),model_allowlist:q(t.model_allowlist),requires_human_for:q(t.requires_human_for),autonomy_level:r(t.autonomy_level),escalation_timeout_sec:d(t.escalation_timeout_sec),kill_switch:O(t.kill_switch),frozen:O(t.frozen)}}function Op(t){if(m(t))return{headcount_cap:d(t.headcount_cap),active_operation_cap:d(t.active_operation_cap),max_cost_usd:d(t.max_cost_usd),max_tokens:d(t.max_tokens)}}function Ii(t){if(!m(t))return null;const e=r(t.unit_id),n=r(t.label),s=r(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:r(t.parent_unit_id)??null,leader_id:r(t.leader_id)??null,roster:q(t.roster),capability_profile:q(t.capability_profile),source:r(t.source),created_at:r(t.created_at),updated_at:r(t.updated_at),policy:jp(t.policy),budget:Op(t.budget)}}function Rr(t){if(!m(t))return null;const e=Ii(t.unit);return e?{unit:e,leader_status:r(t.leader_status),roster_total:d(t.roster_total),roster_live:d(t.roster_live),active_operation_count:d(t.active_operation_count),health:r(t.health),reasons:q(t.reasons),children:Array.isArray(t.children)?t.children.map(Rr).filter(n=>n!==null):[]}:null}function qp(t){if(m(t))return{total_units:d(t.total_units),company_count:d(t.company_count),platoon_count:d(t.platoon_count),squad_count:d(t.squad_count),leaf_agent_unit_count:d(t.leaf_agent_unit_count),live_agent_count:d(t.live_agent_count),managed_unit_count:d(t.managed_unit_count),active_operation_count:d(t.active_operation_count)}}function Lr(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),source:r(e.source),summary:qp(e.summary),units:Array.isArray(e.units)?e.units.map(Rr).filter(n=>n!==null):[]}}function Fp(t){if(!m(t))return null;const e=r(t.kind),n=r(t.status);return!e||!n?null:{kind:e,chain_id:r(t.chain_id)??null,goal:r(t.goal)??null,run_id:r(t.run_id)??null,status:n,viewer_path:r(t.viewer_path)??null,last_sync_at:r(t.last_sync_at)??null}}function sa(t){if(!m(t))return null;const e=r(t.operation_id),n=r(t.objective),s=r(t.assigned_unit_id),a=r(t.trace_id),o=r(t.status);return!e||!n||!s||!a||!o?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:r(t.autonomy_level),policy_class:r(t.policy_class),budget_class:r(t.budget_class),detachment_session_id:r(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(t.checkpoint_ref)??null,active_goal_ids:q(t.active_goal_ids),note:r(t.note)??null,created_by:r(t.created_by),source:r(t.source),status:o,chain:Fp(t.chain),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function Kp(t){if(!m(t))return null;const e=sa(t.operation);return e?{operation:e,assigned_unit_label:r(t.assigned_unit_label)}:null}function an(t){if(m(t))return{tone:r(t.tone),pending_ops:d(t.pending_ops),blocked_ops:d(t.blocked_ops),in_flight_ops:d(t.in_flight_ops),pipeline_stalls:d(t.pipeline_stalls),bus_traffic:d(t.bus_traffic),l1_hit_rate:d(t.l1_hit_rate),invalidation_count:d(t.invalidation_count),current_pending:d(t.current_pending),current_in_flight:d(t.current_in_flight),cdb_wakeups:d(t.cdb_wakeups),total_stolen:d(t.total_stolen),avg_best_score:d(t.avg_best_score),avg_candidate_count:d(t.avg_candidate_count),best_first_operations:d(t.best_first_operations),active_sessions:d(t.active_sessions),commit_rate:d(t.commit_rate),total_speculations:d(t.total_speculations)}}function Bp(t){if(!m(t))return;const e=m(t.pipeline)?t.pipeline:void 0,n=m(t.cache)?t.cache:void 0,s=m(t.ooo)?t.ooo:void 0,a=m(t.speculative)?t.speculative:void 0,o=m(t.search_fabric)?t.search_fabric:void 0,l=m(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:d(e.total_ops),completed_ops:d(e.completed_ops),stalled_cycles:d(e.stalled_cycles),hazards_detected:d(e.hazards_detected),forwarding_used:d(e.forwarding_used),pipeline_flushes:d(e.pipeline_flushes),ipc:d(e.ipc)}:void 0,cache:n?{total_reads:d(n.total_reads),total_writes:d(n.total_writes),l1_hit_rate:d(n.l1_hit_rate),invalidation_count:d(n.invalidation_count),writeback_count:d(n.writeback_count),bus_traffic:d(n.bus_traffic)}:void 0,ooo:s?{agent_count:d(s.agent_count),total_added:d(s.total_added),total_issued:d(s.total_issued),total_completed:d(s.total_completed),total_stolen:d(s.total_stolen),cdb_wakeups:d(s.cdb_wakeups),stall_cycles:d(s.stall_cycles),global_cdb_events:d(s.global_cdb_events),current_pending:d(s.current_pending),current_in_flight:d(s.current_in_flight)}:void 0,speculative:a?{total_speculations:d(a.total_speculations),total_commits:d(a.total_commits),total_aborts:d(a.total_aborts),commit_rate:d(a.commit_rate),total_fast_calls:d(a.total_fast_calls),total_cost_usd:d(a.total_cost_usd),active_sessions:d(a.active_sessions)}:void 0,search_fabric:o?{total_operations:d(o.total_operations),best_first_operations:d(o.best_first_operations),legacy_operations:d(o.legacy_operations),blocked_operations:d(o.blocked_operations),ready_operations:d(o.ready_operations),research_pipeline_operations:d(o.research_pipeline_operations),avg_candidate_count:d(o.avg_candidate_count),avg_best_score:d(o.avg_best_score),top_stage:r(o.top_stage)??null}:void 0,signals:l?{issue_pressure:an(l.issue_pressure),cache_contention:an(l.cache_contention),scheduler_efficiency:an(l.scheduler_efficiency),routing_confidence:an(l.routing_confidence),speculative_posture:an(l.speculative_posture)}:void 0}}function Mr(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),active:d(n.active),paused:d(n.paused),managed:d(n.managed),projected:d(n.projected)}:void 0,microarch:Bp(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(Kp).filter(s=>s!==null):[]}}function Nr(t){if(!m(t))return null;const e=r(t.detachment_id),n=r(t.operation_id),s=r(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:r(t.leader_id)??null,roster:q(t.roster),session_id:r(t.session_id)??null,checkpoint_ref:r(t.checkpoint_ref)??null,runtime_kind:r(t.runtime_kind)??null,runtime_ref:r(t.runtime_ref)??null,source:r(t.source),status:r(t.status),last_event_at:r(t.last_event_at)??null,last_progress_at:r(t.last_progress_at)??null,heartbeat_deadline:r(t.heartbeat_deadline)??null,created_at:r(t.created_at),updated_at:r(t.updated_at)}}function Up(t){if(!m(t))return null;const e=Nr(t.detachment);return e?{detachment:e,assigned_unit_label:r(t.assigned_unit_label),operation:sa(t.operation)}:null}function zr(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),active:d(n.active),projected:d(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(Up).filter(s=>s!==null):[]}}function Hp(t){if(!m(t))return null;const e=r(t.decision_id),n=r(t.trace_id),s=r(t.requested_action),a=r(t.scope_type),o=r(t.scope_id);return!e||!n||!s||!a||!o?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:r(t.operation_id)??null,target_unit_id:r(t.target_unit_id)??null,requested_by:r(t.requested_by),status:r(t.status),reason:r(t.reason)??null,source:r(t.source),detail:t.detail,created_at:r(t.created_at),decided_at:r(t.decided_at)??null,expires_at:r(t.expires_at)??null}}function Dr(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),pending:d(n.pending),approved:d(n.approved),denied:d(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(Hp).filter(s=>s!==null):[]}}function Wp(t){if(!m(t))return null;const e=Ii(t.unit);return e?{unit:e,roster_total:d(t.roster_total),roster_live:d(t.roster_live),headcount_cap:d(t.headcount_cap),active_operations:d(t.active_operations),active_operation_cap:d(t.active_operation_cap),utilization:d(t.utilization)}:null}function Gp(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(Wp).filter(n=>n!==null):[]}}function Jp(t){if(!m(t))return null;const e=r(t.alert_id);return e?{alert_id:e,severity:r(t.severity),kind:r(t.kind),scope_type:r(t.scope_type),scope_id:r(t.scope_id),title:r(t.title),detail:r(t.detail),timestamp:r(t.timestamp)}:null}function Er(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),bad:d(n.bad),warn:d(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(Jp).filter(s=>s!==null):[]}}function jr(t){if(!m(t))return null;const e=r(t.event_id),n=r(t.trace_id),s=r(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:r(t.operation_id)??null,unit_id:r(t.unit_id)??null,actor:r(t.actor)??null,source:r(t.source),timestamp:r(t.timestamp),detail:t.detail}}function Vp(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),events:Array.isArray(e.events)?e.events.map(jr).filter(n=>n!==null):[]}}function Yp(t){if(!m(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function Qp(t){if(!m(t))return null;const e=r(t.lane_id),n=r(t.label),s=r(t.kind),a=r(t.phase),o=r(t.motion_state),l=r(t.source_of_truth),c=r(t.movement_reason),u=r(t.current_step);if(!e||!n||!s||!a||!o||!l||!c||!u)return null;const p=m(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:O(t.present)??!1,phase:a,motion_state:o,source_of_truth:l,last_movement_at:r(t.last_movement_at)??null,movement_reason:c,current_step:u,blockers:q(t.blockers),counts:{operations:d(p.operations),detachments:d(p.detachments),workers:d(p.workers),approvals:d(p.approvals),alerts:d(p.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(Yp).filter(f=>f!==null):[]}}function Xp(t){if(!m(t))return null;const e=r(t.event_id),n=r(t.lane_id),s=r(t.kind),a=r(t.timestamp),o=r(t.title),l=r(t.detail),c=r(t.tone),u=r(t.source);return!e||!n||!s||!a||!o||!l||!c||!u?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:o,detail:l,tone:c,source:u}}function Zp(t){if(!m(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,lane_ids:q(t.lane_ids),count:d(t.count)??0}}function Or(t){if(!m(t))return;const e=m(t.overview)?t.overview:{},n=m(t.gaps)?t.gaps:{},s=m(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:r(t.generated_at),overview:{active_lanes:d(e.active_lanes),moving_lanes:d(e.moving_lanes),stalled_lanes:d(e.stalled_lanes),projected_lanes:d(e.projected_lanes),last_movement_at:r(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(Qp).filter(a=>a!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(Xp).filter(a=>a!==null):[],gaps:{count:d(n.count),items:Array.isArray(n.items)?n.items.map(Zp).filter(a=>a!==null):[]},recommended_next_action:s?{tool:r(s.tool)??"masc_operator_snapshot",label:r(s.label)??"Observe operator state",reason:r(s.reason)??"",lane_id:r(s.lane_id)??null}:void 0}}function tm(t){if(!m(t))return;const e=m(t.workers)?t.workers:{},n=O(t.pass);return{status:r(t.status)??"missing",source:r(t.source)??"none",run_id:r(t.run_id)??null,captured_at:r(t.captured_at)??null,...n!==void 0?{pass:n}:{},...d(t.peak_hot_slots)!=null?{peak_hot_slots:d(t.peak_hot_slots)}:{},...d(t.ctx_per_slot)!=null?{ctx_per_slot:d(t.ctx_per_slot)}:{},workers:{expected:d(e.expected),joined:d(e.joined),current_task_bound:d(e.current_task_bound),fresh_heartbeats:d(e.fresh_heartbeats),done:d(e.done),final:d(e.final)},artifact_ref:r(t.artifact_ref)??null,missing_reason:r(t.missing_reason)??null}}function em(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),topology:Lr(e.topology),operations:Mr(e.operations),detachments:zr(e.detachments),alerts:Er(e.alerts),decisions:Dr(e.decisions),capacity:Gp(e.capacity),traces:Vp(e.traces),swarm_status:Or(e.swarm_status)}}function nm(t){const e=m(t)?t:{},n=Lr(e.topology),s=Mr(e.operations),a=zr(e.detachments),o=Er(e.alerts),l=Dr(e.decisions);return{version:r(e.version),generated_at:r(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:Or(e.swarm_status),swarm_proof:tm(e.swarm_proof)}}function sm(t){return m(t)?{chain_id:r(t.chain_id)??null,started_at:d(t.started_at)??null,progress:d(t.progress)??null,elapsed_sec:d(t.elapsed_sec)??null}:null}function qr(t){if(!m(t))return null;const e=r(t.event);return e?{event:e,chain_id:r(t.chain_id)??null,timestamp:r(t.timestamp)??null,duration_ms:d(t.duration_ms)??null,message:r(t.message)??null,tokens:d(t.tokens)??null}:null}function am(t){if(!m(t))return null;const e=sa(t.operation);return e?{operation:e,runtime:sm(t.runtime),history:qr(t.history),mermaid:r(t.mermaid)??null,preview_run:Fr(t.preview_run)}:null}function im(t){const e=m(t)?t:{};return{status:r(e.status)??"disconnected",base_url:r(e.base_url)??null,message:r(e.message)??null}}function om(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),connection:im(e.connection),summary:n?{linked_operations:d(n.linked_operations),active_chains:d(n.active_chains),running_operations:d(n.running_operations),recent_failures:d(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(am).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(qr).filter(s=>s!==null):[]}}function rm(t){if(!m(t))return null;const e=r(t.id);return e?{id:e,type:r(t.type),status:r(t.status),duration_ms:d(t.duration_ms)??null,error:r(t.error)??null}:null}function Fr(t){if(!m(t))return null;const e=r(t.run_id),n=r(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:d(t.duration_ms),success:O(t.success),mermaid:r(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(rm).filter(s=>s!==null):[]}:null}function lm(t){const e=m(t)?t:{};return{run:Fr(e.run)}}function cm(t){if(!m(t))return null;const e=r(t.title),n=r(t.path);return!e||!n?null:{title:e,path:n}}function dm(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function um(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.tool),a=r(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:q(t.success_signals),pitfalls:q(t.pitfalls)}}function pm(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary),a=r(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(um).filter(o=>o!==null):[]}}function mm(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:q(t.tools)}}function vm(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.symptom),a=r(t.why),o=r(t.fix_tool),l=r(t.fix_summary);return!e||!n||!s||!a||!o||!l?null:{id:e,title:n,symptom:s,why:a,fix_tool:o,fix_summary:l}}function _m(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.path_id),a=r(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:q(t.notes)}}function fm(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(cm).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(dm).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(pm).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(mm).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(vm).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(_m).filter(n=>n!==null):[]}}function gm(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.status),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{id:e,title:n,status:s,detail:a,next_tool:o}}function $m(t){if(!m(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.title),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{code:e,severity:n,title:s,detail:a,next_tool:o}}function hm(t){if(!m(t))return null;const e=r(t.from),n=r(t.content),s=r(t.timestamp),a=d(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function ym(t){if(!m(t))return null;const e=r(t.name),n=r(t.role),s=r(t.lane),a=r(t.status),o=r(t.claim_marker),l=r(t.done_marker),c=r(t.final_marker);if(!e||!n||!s||!a||!o||!l||!c)return null;const u=(()=>{if(!m(t.last_message))return null;const p=d(t.last_message.seq),f=r(t.last_message.content),_=r(t.last_message.timestamp);return p==null||!f||!_?null:{seq:p,content:f,timestamp:_}})();return{name:e,role:n,lane:s,joined:O(t.joined)??!1,live_presence:O(t.live_presence)??!1,completed:O(t.completed)??!1,status:a,current_task:r(t.current_task)??null,bound_task_id:r(t.bound_task_id)??null,bound_task_title:r(t.bound_task_title)??null,bound_task_status:r(t.bound_task_status)??null,current_task_matches_run:O(t.current_task_matches_run)??!1,squad_member:O(t.squad_member)??!1,detachment_member:O(t.detachment_member)??!1,last_seen:r(t.last_seen)??null,heartbeat_age_sec:d(t.heartbeat_age_sec)??null,heartbeat_fresh:O(t.heartbeat_fresh)??!1,claim_marker_seen:O(t.claim_marker_seen)??!1,done_marker_seen:O(t.done_marker_seen)??!1,final_marker_seen:O(t.final_marker_seen)??!1,claim_marker:o,done_marker:l,final_marker:c,last_message:u}}function bm(t){if(!m(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!m(n))return null;const s=r(n.timestamp),a=d(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:r(t.slot_url)??null,provider_base_url:r(t.provider_base_url)??null,provider_reachable:O(t.provider_reachable)??null,provider_status_code:d(t.provider_status_code)??null,provider_model_id:r(t.provider_model_id)??null,actual_model_id:r(t.actual_model_id)??null,expected_slots:d(t.expected_slots),actual_slots:d(t.actual_slots),expected_ctx:d(t.expected_ctx),actual_ctx:d(t.actual_ctx),slot_reachable:O(t.slot_reachable)??null,slot_status_code:d(t.slot_status_code)??null,runtime_blocker:r(t.runtime_blocker)??null,detail:r(t.detail)??null,checked_at:r(t.checked_at)??null,total_slots:d(t.total_slots),ctx_per_slot:d(t.ctx_per_slot),active_slots_now:d(t.active_slots_now),peak_active_slots:d(t.peak_active_slots),sample_count:d(t.sample_count),last_sample_at:r(t.last_sample_at)??null,timeline:e}}function km(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),run_id:r(e.run_id),room_id:r(e.room_id),operation_id:r(e.operation_id)??null,recommended_next_tool:r(e.recommended_next_tool),summary:n?{expected_workers:d(n.expected_workers),joined_workers:d(n.joined_workers),live_workers:d(n.live_workers),squad_roster_size:d(n.squad_roster_size),detachment_roster_size:d(n.detachment_roster_size),current_task_bound:d(n.current_task_bound),fresh_heartbeats:d(n.fresh_heartbeats),claim_markers_seen:d(n.claim_markers_seen),done_markers_seen:d(n.done_markers_seen),final_markers_seen:d(n.final_markers_seen),completed_workers:d(n.completed_workers),peak_hot_slots:d(n.peak_hot_slots),hot_window_ok:O(n.hot_window_ok),pass_hot_concurrency:O(n.pass_hot_concurrency),pass_end_to_end:O(n.pass_end_to_end),pending_decisions:d(n.pending_decisions),pass:O(n.pass)}:void 0,provider:bm(e.provider),operation:sa(e.operation),squad:Ii(e.squad),detachment:Nr(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(ym).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(gm).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map($m).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(hm).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(jr).filter(s=>s!==null):[],truth_notes:q(e.truth_notes)}}function ve(t){V.value=t,Ai(t)&&xm()}async function Kr(){ws.value=!0,Rs.value=null;try{const t=await sc();Ci.value=nm(t)}catch(t){Rs.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{ws.value=!1}}function Ti(t){Oe.value=t}async function wi(){Ps.value=!0,Ls.value=null;try{const t=await nc();Lt.value=em(t)}catch(t){Ls.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{Ps.value=!1}}async function xm(){Lt.value||Ps.value||await wi()}async function Pe(){await Kr(),Ai(V.value)&&await wi()}async function qe(){var t;ti.value=!0,Es.value=null;try{const e=await ac(),n=om(e);Bn.value=n;const s=Oe.value;n.operations.length===0?Oe.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Oe.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Es.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{ti.value=!1}}function Sm(){on=null,wn.value=null,js.value=!1,Pn.value=null}async function Cm(t){on=t,js.value=!0,Pn.value=null;try{const e=await ic(t);if(on!==t)return;wn.value=lm(e)}catch(e){if(on!==t)return;wn.value=null,Pn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{on===t&&(js.value=!1)}}async function Am(){Za.value=!0,Ns.value=null;try{const t=await oc();Kn.value=fm(t)}catch(t){Ns.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Za.value=!1}}async function Ht(t=Dp(),e=Ep()){zs.value=!0,Ds.value=null;try{const n=await rc(t,e);$e.value=km(n)}catch(n){Ds.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{zs.value=!1}}async function ee(t,e,n){Xa.value=t,Ms.value=null;try{await lc(e,n),await Kr(),(Lt.value||Ai(V.value))&&await wi(),await Ht(),await qe()}catch(s){throw Ms.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{Xa.value=null}}function Im(t){return ee(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Tm(t){return ee(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function wm(t){return ee(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Pm(t={}){return ee("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function Rm(t){return ee(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Lm(t){return ee(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Mm(t,e){return ee(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Nm(t,e){return ee(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}Od(()=>{Pe(),qe(),(V.value==="swarm"||V.value==="warroom"||$e.value!==null)&&Ht(),V.value==="warroom"&&pt()});function Os(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function B(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function zm(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Br(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function L(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let ao=!1,Dm=0;function Em(){return++Dm}let pa=null;async function jm(){pa||(pa=zp(()=>import("./mermaid.core-B-ZW_tgy.js").then(e=>e.bE),[]).then(e=>e.default));const t=await pa;return ao||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),ao=!0),t}function Vt(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Un(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function rn(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function Hn(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function re(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:Hn(t/e*100)}function Om(t,e){const n=Hn(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function Ur(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const qm=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],Hr=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],Fm=Hr.map(t=>t.id),Km=["chain_start","node_start","node_complete","chain_complete","chain_error"],Bm={warroom:{title:"라이브 워룸",description:"실제 run, worker, message, trace를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function io(t){return!!t&&Fm.includes(t)}function Um(){const t=N.value.params;return t.source!=="mission"&&t.source!=="execution"?{}:{source:t.source,...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function Wr(t){const e=Um();if(t==="operations")return e;if(t==="chains"){const n=Oe.value;return n?{...e,surface:t,operation:n}:{...e,surface:t}}return{...e,surface:t}}function Hm(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function Wm(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function nt(t){return Xa.value===t}function Wn(){return Ci.value}function Gm(t){var a,o,l,c,u,p,f;const e=Ci.value,n=$e.value,s=Bn.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"live run, worker, message, trace를 한 화면에서 보고 필요한 detail 표면으로 바로 점프합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(o=e==null?void 0:e.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((u=(c=e==null?void 0:e.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:u.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(f=(p=s==null?void 0:s.operations[0])==null?void 0:p.preview_run)!=null&&f.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function Jm(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function Vm(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function Ym(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Gr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function Qm(){const e=Gr().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Jr(){const e=Gr().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Xm(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function Zm(t){return t.status==="claimed"||t.status==="in_progress"}function tv(t){const e=Kn.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function ma(t){var e;return((e=Kn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function ev(t){const e=Kn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function Yt(t){try{await t()}catch{}}function Pi(t){return(t==null?void 0:t.trim().toLowerCase())??""}function Re(t){const e=Pi(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function va(t){const e=Pi(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function nv(){var e,n,s;const t=$e.value;return t?!!(t.run_id||(e=t.operation)!=null&&e.operation_id||(n=t.detachment)!=null&&n.detachment_id||(((s=t.summary)==null?void 0:s.expected_workers)??0)>0||t.workers.length>0||t.recent_messages.length>0||t.recent_trace_events.length>0):!1}function sv(t){const e=Pi(t.status);return e==="active"||e==="running"}function av(){var o,l,c,u;const t=((o=vt.value)==null?void 0:o.sessions)??[],e=$e.value,n=((l=e==null?void 0:e.detachment)==null?void 0:l.session_id)??null;if(n){const p=t.find(f=>f.session_id===n);if(p)return p}const s=((c=e==null?void 0:e.operation)==null?void 0:c.operation_id)??Jr();if(s){const p=t.find(f=>f.command_plane_operation_id===s);if(p)return p}const a=((u=e==null?void 0:e.detachment)==null?void 0:u.detachment_id)??null;if(a){const p=t.find(f=>f.command_plane_detachment_id===a);if(p)return p}return t.find(sv)??t[0]??null}function iv(t){return t==="proven"?"ok":t==="partial"?"warn":"bad"}function vn(t){return Array.isArray(t)?t:[]}function ov({item:t}){return i`
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
        <span class="command-chip">${B(t.timestamp)}</span>
      </div>
    </article>
  `}function rv({item:t}){return i`
    <article class="mission-activity-row">
      <div class="mission-activity-head">
        <div>
          <strong>${t.actor}</strong>
          <div class="mission-activity-meta">
            <span>${t.role??"participant"}</span>
            <span>${t.last_active_at?B(t.last_active_at):"n/a"}</span>
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
      ${vn(t.recent_tool_names).length>0?i`<div class="semantic-tag-row">
            ${vn(t.recent_tool_names).map(e=>i`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
      ${t.recent_event_summary?i`<div class="mission-activity-copy"><span>${t.recent_event_summary}</span></div>`:null}
    </article>
  `}function lv({item:t}){return i`
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
  `}function cv(){var _,g,h;const t=N.value.params,e=t.session_id??null,n=t.operation_id??null;Z(()=>{wr(e,n)},[e,n]);const s=Tr.value;if(Qa.value&&!s)return i`<section class="dashboard-panel"><div class="loading-indicator">Loading proof…</div></section>`;if(we.value&&!s)return i`<section class="dashboard-panel"><div class="error-card">${we.value}</div></section>`;const a=s==null?void 0:s.summary,o=vn(s==null?void 0:s.timeline),l=vn(s==null?void 0:s.actor_contributions),c=vn(s==null?void 0:s.artifacts),u=(s==null?void 0:s.proof_verdict)??"insufficient",p=(s==null?void 0:s.cp_backing_evidence)??null,f=Array.isArray((_=p==null?void 0:p.traces)==null?void 0:_.events)?((h=(g=p.traces)==null?void 0:g.events)==null?void 0:h.length)??0:0;return i`
    <section class="dashboard-panel mission-view">
      <${mt} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>Proof</h2>
          <p>협업, 대화, 도구 사용, backing evidence를 한 화면에서 증명하는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${iv(u)}">${u}</span>
          ${s!=null&&s.session_id?i`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?i`<span class="command-chip">${B(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${we.value?i`<div class="error-card">${we.value}</div>`:null}

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
          <strong>${(a==null?void 0:a.cp_trace_count)??f}</strong>
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
          <pre class="command-json-block">${Os((s==null?void 0:s.goal_binding)??{})}</pre>
        <//>
      </div>

      <div class="mission-human-grid">
        <${T} title="Collaboration Timeline" class="mission-list-card" semanticId="proof.timeline">
          <div class="mission-section-head">
            <h3>협업 타임라인</h3>
            <p>session events와 command-plane traces를 한 흐름으로 읽습니다.</p>
          </div>
          <div class="mission-list-stack">
            ${o.length>0?o.slice(0,24).map(k=>i`<${ov} key=${k.id} item=${k} />`):i`<div class="empty-state">표시할 timeline evidence가 없습니다.</div>`}
          </div>
        <//>

        <${T} title="Actor Contributions" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>actor 기여</h3>
            <p>누가 무엇을 했고 어떤 input/output을 남겼는지 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${l.length>0?l.map(k=>i`<${rv} key=${k.actor} item=${k} />`):i`<div class="empty-state">표시할 actor contribution이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${T} title="Backing Evidence" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>CPv2 backing evidence</h3>
          </div>
          <pre class="command-json-block">${Os(p??{})}</pre>
        <//>

        <${T} title="Artifacts" class="mission-list-card" semanticId="proof.artifacts">
          <div class="mission-section-head">
            <h3>생성 산출물</h3>
          </div>
          <div class="mission-list-stack">
            ${c.length>0?c.map(k=>i`<${lv} key=${k.path} item=${k} />`):i`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function dv(){const t=Fn(N.value);return t?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${ea(t.action_type)}</span>
        <span class="command-chip">${yi(t)}</span>
        <span class="command-chip">${bu(N.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?i`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function uv(){const t=V.value,e=Bm[t],n=Gm(t);return i`
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
  `}function Zn({label:t,value:e,subtext:n,percent:s,color:a}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${Om(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(Hn(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function ts({label:t,value:e,detail:n,percent:s,tone:a}){return i`
    <article class="command-signal-rail ${L(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${L(a)}" style=${`width: ${Math.max(8,Math.round(Hn(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function pv(){var tt,et,F,Y;const t=Wn(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,o=t==null?void 0:t.alerts.summary,l=(tt=t==null?void 0:t.swarm_status)==null?void 0:tt.overview,c=t==null?void 0:t.swarm_proof,u=t==null?void 0:t.operations.microarch,p=(e==null?void 0:e.managed_unit_count)??0,f=(e==null?void 0:e.total_units)??0,_=(n==null?void 0:n.active)??0,g=(s==null?void 0:s.active)??0,h=(l==null?void 0:l.moving_lanes)??0,k=(l==null?void 0:l.active_lanes)??0,$=(c==null?void 0:c.workers.done)??0,A=(c==null?void 0:c.workers.expected)??0,I=(o==null?void 0:o.bad)??0,C=(o==null?void 0:o.warn)??0,S=(a==null?void 0:a.pending)??0,w=(a==null?void 0:a.total)??0,R=_+g,W=((et=u==null?void 0:u.cache)==null?void 0:et.l1_hit_rate)??((Y=(F=u==null?void 0:u.signals)==null?void 0:F.cache_contention)==null?void 0:Y.l1_hit_rate)??0,U=_>0||g>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",_t=_>0||h>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${U}</h3>
        <p>${_t}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${L(_>0?"ok":"warn")}">활성 작전 ${_}</span>
          <span class="command-chip ${L(h>0?"ok":(k>0,"warn"))}">이동 레인 ${h}/${Math.max(k,h)}</span>
          <span class="command-chip ${L(I>0?"bad":C>0?"warn":"ok")}">치명 알림 ${I}</span>
          <span class="command-chip ${L(S>0?"warn":"ok")}">승인 대기 ${S}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${Zn}
          label="관리 단위 범위"
          value=${`${p}/${Math.max(f,p)}`}
          subtext=${f>0?`${f-p}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${re(p,Math.max(f,p))}
          color="#67e8f9"
        />
        <${Zn}
          label="실행 열도"
          value=${String(R)}
          subtext=${`${_}개 작전 + ${g}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${re(R,Math.max(p,R||1))}
          color="#4ade80"
        />
        <${Zn}
          label="스웜 이동감"
          value=${`${h}/${Math.max(k,h)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${B(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${re(h,Math.max(k,h||1))}
          color="#fbbf24"
        />
        <${Zn}
          label="증거 수집률"
          value=${`${$}/${Math.max(A,$)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${re($,Math.max(A,$||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${ts}
        label="승인 대기열"
        value=${`${S}건 대기`}
        detail=${`현재 정책 창에서 ${w}개 결정을 추적 중입니다`}
        percent=${re(S,Math.max(w,S||1))}
        tone=${S>0?"warn":"ok"}
      />
      <${ts}
        label="알림 압력"
        value=${`${I} bad / ${C} warn`}
        detail=${I>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${re(I*2+C,Math.max((I+C)*2,1))}
        tone=${I>0?"bad":C>0?"warn":"ok"}
      />
      <${ts}
        label="디스패치 점유"
          value=${`${g}개 가동`}
        detail=${p>0?`${p}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${re(g,Math.max(p,g||1))}
        tone=${g>0?"ok":"warn"}
      />
      <${ts}
        label="캐시 신뢰도"
        value=${W?Un(W):"n/a"}
        detail=${W?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Hn((W??0)*100)}
        tone=${W>=.75?"ok":W>=.4?"warn":"bad"}
      />
    </div>
  `}function mv(){var g,h,k,$,A;const t=Wn(),e=Bn.value,n=Fn(N.value),s=Jm(n),a=t==null?void 0:t.topology.summary,o=t==null?void 0:t.operations.summary,l=(g=t==null?void 0:t.swarm_status)==null?void 0:g.overview,c=t==null?void 0:t.operations.microarch,u=t==null?void 0:t.decisions.summary,p=t==null?void 0:t.alerts.summary,f=(h=c==null?void 0:c.signals)==null?void 0:h.issue_pressure,_=c==null?void 0:c.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((k=t==null?void 0:t.detachments.summary)==null?void 0:k.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(u==null?void 0:u.pending)??0}</strong><small>${(u==null?void 0:u.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(p==null?void 0:p.bad)??0}</strong><small>${(p==null?void 0:p.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${(($=e==null?void 0:e.summary)==null?void 0:$.active_chains)??0}</strong><small>${((A=e==null?void 0:e.summary)==null?void 0:A.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${B(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(f==null?void 0:f.pending_ops)??0}</strong><small>${(_==null?void 0:_.l1_hit_rate)!=null?`${Un(_.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(f==null?void 0:f.tone)??"n/a"}</small></div>
    </div>
  `}function vv(){var tt,et,F,Y,x,bt,qt,ne,se;const t=Wn(),e=Lt.value,n=$t.value,s=Ym(),a=s?Rt.value.find(D=>D.name===s)??null:null,o=s?Tt.value.filter(D=>D.assignee===s&&Zm(D)):[],l=((tt=t==null?void 0:t.operations.summary)==null?void 0:tt.active)??0,c=((et=t==null?void 0:t.detachments.summary)==null?void 0:et.total)??0,u=((F=t==null?void 0:t.decisions.summary)==null?void 0:F.pending)??0,p=e==null?void 0:e.detachments.detachments.find(D=>{const kt=D.detachment.heartbeat_deadline,ae=kt?Date.parse(kt):Number.NaN;return D.detachment.status==="stalled"||!Number.isNaN(ae)&&ae<=Date.now()}),f=e==null?void 0:e.alerts.alerts.find(D=>D.severity==="bad"),_=!!(n!=null&&n.room||n!=null&&n.project),g=(a==null?void 0:a.current_task)??null,h=Xm(a==null?void 0:a.last_seen),k=h!=null?h<=120:null,$=[_?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:Tt.value.length>0?"masc_claim":"masc_add_task"}:g?k===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${g} 이지만 heartbeat가 stale 합니다 (${h}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${g}${h!=null?` · 마지막 활동 ${h}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((Y=t.topology.summary)==null?void 0:Y.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((x=t.topology.summary)==null?void 0:x.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((bt=t.topology.summary)==null?void 0:bt.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},u>0?{title:"디스패치 준비도",tone:"warn",detail:`${u}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:p||f?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${p?` · detachment ${p.detachment.detachment_id} 가 stalled 상태입니다`:""}${f?` · alert ${f.title??f.alert_id}`:""}${!e&&!p&&!f?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:u>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],A=_?!s||!a?"masc_join":o.length===0?Tt.value.length>0?"masc_claim":"masc_add_task":g?k===!1?"masc_heartbeat":!t||(((qt=t.topology.summary)==null?void 0:qt.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":u>0?"masc_policy_approve":l>0&&c===0||p||f?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",I=tv(A),S=ev(A==="masc_set_room"?["repo-root-room"]:A==="masc_plan_set_task"?["claimed-not-current"]:A==="masc_heartbeat"?["heartbeat-stale"]:A==="masc_dispatch_tick"?["no-detachments"]:A==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),w=ma("room_task_hygiene"),R=ma("cpv2_benchmark"),W=ma("supervisor_session"),U=((ne=Kn.value)==null?void 0:ne.docs)??[],_t=[w,R,W].filter(D=>D!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${M} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(I==null?void 0:I.title)??A}</strong>
            <span class="command-chip ok">${A}</span>
          </div>
          <p>${(I==null?void 0:I.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(se=I==null?void 0:I.success_signals)!=null&&se.length?i`<div class="command-tag-row">
                ${I.success_signals.map(D=>i`<span class="command-tag ok">${D}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${$.map(D=>i`
            <article class="command-readiness-row ${L(D.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${D.title}</strong>
                  <span class="command-chip ${L(D.tone)}">${D.tone}</span>
                </div>
                <p>${D.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${D.tool}</div>
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
                  ${S.map(D=>i`
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
        <div class="card-title-row">
          <div class="card-title">운영 경로</div>
          <${M} panelId="command.summary" compact=${!0} />
        </div>
        ${Za.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:Ns.value?i`<div class="empty-state error">${Ns.value}</div>`:i`
                <div class="command-path-grid">
                  ${_t.map(D=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${D.title}</strong>
                        <span class="command-chip">${D.id}</span>
                      </div>
                      <p>${D.summary}</p>
                      <div class="command-card-sub">${D.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${D.steps.slice(0,4).map(kt=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${kt.tool}</span>
                            <span>${kt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${U.length>0?i`<div class="command-doc-links">
                      ${U.map(D=>i`<span class="command-tag">${D.title}: ${D.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function _v(){return i`
    <${pv} />
    <${mv} />
    <${vv} />
  `}function fv(){return Ps.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:Ls.value?i`<div class="empty-state error">${Ls.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function Vr({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,o=t.unit.policy;return i`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${Wm(t.unit.kind)}</span>
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
            ${t.children.map(l=>i`<${Vr} node=${l} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function gv({alert:t}){return i`
    <article class="command-alert ${L(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${L(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${B(t.timestamp)}</span>
      </div>
      ${t.detail?i`<p>${t.detail}</p>`:null}
    </article>
  `}function Ri({event:t}){return i`
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
      <pre class="command-trace-detail">${Os(t.detail)}</pre>
    </article>
  `}function $v(){const t=Lt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${M} panelId="command.topology" compact=${!0} />
      </div>
      ${t&&t.topology.units.length>0?i`${t.topology.units.map(e=>i`<${Vr} node=${e} />`)}`:i`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function hv(){const t=Lt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${M} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>i`<${gv} alert=${e} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function yv(){const t=Lt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${M} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?i`<div class="command-trace-stack">
            ${t.traces.events.map(e=>i`<${Ri} event=${e} />`)}
          </div>`:i`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function Yr(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function Qr({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const o=a.motion_state;o in e?e[o]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return i`
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
  `}function bv({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${a.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?i`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function kv({lane:t}){const e=t.counts??{},n=Yr(t),s=e.workers??0,a=e.operations??0,o=e.detachments??0,l=a+o,c=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return i`
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
          <span class="command-chip">${B(t.last_movement_at)}</span>
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
                <${bv} total=${s} />
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
              ${t.hard_flags.map(u=>i`<span class="command-chip ${L(u.severity)}">${u.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Xr({lanes:t}){const e=t.slice(0,4);return e.length===0?null:i`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=Yr(n),a=n.counts.workers??0,o=n.counts.operations??0,l=n.counts.detachments??0;return i`
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
  `}function xv({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${L(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?i`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function Sv({gap:t}){return i`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${L(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function Cv({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${L(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${L(e)}">${(t==null?void 0:t.status)??"missing"}</span>
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
  `}function Av(){const t=Wn(),e=Fn(N.value),n=Vm(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,o=(s==null?void 0:s.lanes.filter(_=>_.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],u=s==null?void 0:s.overview,p=s==null?void 0:s.recommended_next_action,f=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${M} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${Xr} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(u==null?void 0:u.active_lanes)??0}</strong><small>${(u==null?void 0:u.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(u==null?void 0:u.stalled_lanes)??0}</strong><small>${(u==null?void 0:u.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${B(u==null?void 0:u.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${B(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(p==null?void 0:p.label)??"운영자 상태 확인"}</strong><small>${(p==null?void 0:p.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${Qr} lanes=${o} />`:null}

            <div class="command-swarm-layout ${f?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(_=>i`<${kv} lane=${_} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight ${n==="recommendation"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>${(p==null?void 0:p.label)??"운영자 상태 확인"}</strong>
                    <span class="command-chip">${(p==null?void 0:p.lane_id)??"전체"}</span>
                  </div>
                  <p>${(p==null?void 0:p.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="command-card-foot">${(p==null?void 0:p.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${Cv} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${L(l.some(_=>_.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?i`<div class="swarm-event-rail">${l.slice(0,4).map(_=>i`<${Sv} gap=${_} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?i`<div class="swarm-event-rail">${c.map(_=>i`<${xv} event=${_} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function Iv({item:t}){return i`
    <article class="command-guide-card ${L(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${L(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Zr({blocker:t}){return i`
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
  `}function Tv({worker:t}){return i`
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
      ${t.last_message?i`<div class="command-card-foot">${B(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function wv(){var u,p,f,_,g,h,k,$,A,I,C,S,w,R,W,U,_t,tt,et,F,Y;const t=$e.value,e=Qm(),n=Jr(),s=(u=t==null?void 0:t.provider)!=null&&u.runtime_blocker?"blocked":(p=t==null?void 0:t.provider)!=null&&p.provider_reachable?"ready":"check",a=((f=t==null?void 0:t.provider)==null?void 0:f.actual_slots)??((_=t==null?void 0:t.provider)==null?void 0:_.total_slots)??0,o=((g=t==null?void 0:t.provider)==null?void 0:g.expected_slots)??"n/a",l=((h=t==null?void 0:t.provider)==null?void 0:h.actual_ctx)??((k=t==null?void 0:t.provider)==null?void 0:k.ctx_per_slot)??0,c=(($=t==null?void 0:t.provider)==null?void 0:$.expected_ctx)??"n/a";return i`
    <div class="command-section-stack">
      <${Av} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${M} panelId="command.swarm" compact=${!0} />
          </div>
          ${zs.value?i`<div class="empty-state">Loading swarm live state…</div>`:Ds.value?i`<div class="empty-state error">${Ds.value}</div>`:t?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((A=t.summary)==null?void 0:A.joined_workers)??0}/${((I=t.summary)==null?void 0:I.expected_workers)??0}</strong><small>${((C=t.summary)==null?void 0:C.live_workers)??0}개 가동 · ${((S=t.summary)==null?void 0:S.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${o} · ctx ${l}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(w=t.summary)!=null&&w.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((R=t.provider)==null?void 0:R.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(W=t.summary)!=null&&W.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((U=t.operation)==null?void 0:U.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((_t=t.squad)==null?void 0:_t.label)??"없음"}</span>
                      <span>실행체</span><span>${((tt=t.detachment)==null?void 0:tt.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((et=t.summary)==null?void 0:et.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((F=t.summary)==null?void 0:F.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((Y=t.provider)==null?void 0:Y.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?i`<div class="command-tag-row">
                          ${t.truth_notes.map(x=>i`<span class="command-tag">${x}</span>`)}
                        </div>`:null}
                  `:i`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${M} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?i`<div class="command-card-stack">
                ${t.checklist.map(x=>i`<${Iv} item=${x} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${M} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?i`<div class="command-card-stack">
                ${t.workers.map(x=>i`<${Tv} worker=${x} />`)}
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
                  <span>Last Sample</span><span>${t.provider.last_sample_at?B(t.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${t.provider.checked_at?B(t.provider.checked_at):"n/a"}</span>
                </div>
                ${t.provider.detail?i`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?i`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(x=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${x.active_slots} active</strong>
                              <span class="command-chip">${B(x.timestamp)}</span>
                            </div>
                            <div class="command-card-sub">slots ${x.active_slot_ids.join(", ")||"none"}</div>
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
                ${t.blockers.map(x=>i`<${Zr} blocker=${x} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${M} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?i`<div class="command-trace-stack">
                ${t.recent_messages.map(x=>i`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${x.from}</strong>
                        <span class="command-chip">${B(x.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${x.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${x.content}</pre>
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
                ${t.recent_trace_events.map(x=>i`<${Ri} event=${x} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function Pv(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"none",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}s`:t.heartbeat_fresh?"clean":"n/a",detail:[t.bound_task_status??null,t.detachment_member?"detachment":null,t.squad_member?"squad":null].filter(Boolean).join(" · ")||"live swarm worker",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function Rv(t,e){const n=t.actor??t.spawn_role??`worker-${e+1}`,s=t.spawn_role??t.worker_class??t.spawn_agent??"worker",a=t.lane_id??t.capsule_mode??t.control_domain??"session",o=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:s,lane:a,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"session lane",heartbeat:t.last_turn_ts_iso?B(t.last_turn_ts_iso):"n/a",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?Un(t.routing_confidence):null].filter(Boolean).join(" · ")||"session worker",markers:o,note:t.routing_reason??null}}function oo(t){return L(t.severity)}function Lv({worker:t}){return i`
    <article class="command-card compact warroom-worker-card ${L(Re(t.status))}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${L(Re(t.status))}">${t.status}</span>
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
  `}function Kt({label:t,surface:e,params:n={}}){return i`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(e){ve(e),rt("command",{...Wr(e),...n});return}rt("intervene")}}
    >
      ${t}
    </button>
  `}function Mv(){var U,_t,tt,et,F,Y,x,bt,qt,ne,se,D,kt,ae,tn,en,Gn,Jn,Vn,Yn;const t=Wn(),e=$e.value,n=vt.value,s=wt.value,a=av(),o=e!=null&&e.operation?((U=Bn.value)==null?void 0:U.operations.find(j=>{var ye;return j.operation.operation_id===((ye=e.operation)==null?void 0:ye.operation_id)}))??null:null,l=(e==null?void 0:e.workers)??[],c=(s==null?void 0:s.worker_cards)??[],u=l.length>0?l.map(Pv):c.map(Rv),p=nv(),f=((_t=t==null?void 0:t.decisions.summary)==null?void 0:_t.pending)??0,_=(n==null?void 0:n.pending_confirms)??[],g=(e==null?void 0:e.blockers)??[],h=(s==null?void 0:s.recommended_actions)??[],k=(s==null?void 0:s.attention_items)??[],$=((tt=e==null?void 0:e.recent_messages[0])==null?void 0:tt.timestamp)??null,A=((et=e==null?void 0:e.recent_trace_events[0])==null?void 0:et.timestamp)??null,I=$??A??null,C=a==null?void 0:a.summary,S=((F=e==null?void 0:e.summary)==null?void 0:F.expected_workers)??(typeof(C==null?void 0:C.planned_worker_count)=="number"?C.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,w=((Y=e==null?void 0:e.summary)==null?void 0:Y.joined_workers)??(typeof(C==null?void 0:C.active_agent_count)=="number"?C.active_agent_count:void 0)??u.length,R=g.length>0||f>0||_.length>0?"warn":p||a?"ok":"warn",W=((x=t==null?void 0:t.swarm_status)==null?void 0:x.lanes.filter(j=>j.present))??[];return Z(()=>{pt()},[]),Z(()=>{a!=null&&a.session_id&&Ge(a.session_id)},[a==null?void 0:a.session_id,n,(bt=e==null?void 0:e.detachment)==null?void 0:bt.session_id]),!p&&!a?zs.value||In.value?i`<div class="empty-state">live war room 불러오는 중…</div>`:i`
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
          <${Kt} label="작전 보기" surface="operations" />
          <${Kt} label="스웜 보기" surface="swarm" />
          <${Kt} label="개입 열기" />
          <${Kt} label="제어 보기" surface="control" />
        </div>
      </section>
    `:i`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${L(R)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">Live War Room</span>
            <strong>${((qt=e==null?void 0:e.operation)==null?void 0:qt.objective)??(a==null?void 0:a.session_id)??"active run"}</strong>
            <div class="command-card-sub">
              ${((ne=e==null?void 0:e.operation)==null?void 0:ne.operation_id)??"operation 없음"}
              ${a!=null&&a.session_id?` · session ${a.session_id}`:""}
              ${(se=e==null?void 0:e.detachment)!=null&&se.detachment_id?` · detachment ${e.detachment.detachment_id}`:""}
            </div>
          </div>
          <div class="command-action-row">
            <${Kt}
              label="스웜 상세"
              surface="swarm"
              params=${{...(D=e==null?void 0:e.operation)!=null&&D.operation_id?{operation_id:e.operation.operation_id}:{},...e!=null&&e.run_id?{run_id:e.run_id}:{}}}
            />
            <${Kt} label="트레이스" surface="trace" />
            ${o?i`<${Kt}
                  label="체인"
                  surface="chains"
                  params=${{operation:o.operation.operation_id}}
                />`:null}
            <${Kt} label="Intervene" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>Workers</span>
            <strong>${w??0}/${S??0}</strong>
            <small>${((kt=e==null?void 0:e.summary)==null?void 0:kt.completed_workers)??0} 완료 · ${u.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>Runtime</span>
            <strong>${(ae=e==null?void 0:e.provider)!=null&&ae.runtime_blocker?"blocked":(tn=e==null?void 0:e.provider)!=null&&tn.provider_reachable?"ready":a?va(a.status):"check"}</strong>
            <small>slots ${((en=e==null?void 0:e.provider)==null?void 0:en.active_slots_now)??0}/${((Gn=e==null?void 0:e.provider)==null?void 0:Gn.actual_slots)??((Jn=e==null?void 0:e.provider)==null?void 0:Jn.total_slots)??0} · ctx ${((Vn=e==null?void 0:e.provider)==null?void 0:Vn.actual_ctx)??((Yn=e==null?void 0:e.provider)==null?void 0:Yn.ctx_per_slot)??0}</small>
          </div>
          <div class="monitor-stat-card ${L(g.length>0||f>0?"warn":"ok")}">
            <span>Pressure</span>
            <strong>${g.length+f+_.length}</strong>
            <small>blockers ${g.length} · approvals ${f} · confirms ${_.length}</small>
          </div>
          <div class="monitor-stat-card">
            <span>Last signal</span>
            <strong>${B(I)}</strong>
            <small>${$?"message":A?"trace":"waiting"}</small>
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
            ${W.length>0?i`
                  <${Xr} lanes=${W} />
                  <${Qr} lanes=${W} />
                `:a?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${L(Re(a.status))}">${va(a.status)}</span>
                      </div>
                      <p>command-plane live run은 아직 옅지만, session 쪽 worker와 digest를 기준으로 워룸을 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${rn(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${rn(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:i`<div class="empty-state">보이는 lane이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Worker Roster</div>
              <${M} panelId="command.warroom" compact=${!0} />
            </div>
            ${u.length>0?i`<div class="command-card-stack">
                  ${u.map(j=>i`<${Lv} worker=${j} />`)}
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
                      <article class="command-guide-card ${oo(j)}">
                        <div class="command-guide-head">
                          <strong>${j.action_type}</strong>
                          <span class="command-chip ${oo(j)}">${j.target_type}</span>
                        </div>
                        <p>${j.reason}</p>
                      </article>
                    `)}
                    ${k.slice(0,3).map(j=>i`
                      <article class="command-alert ${L(j.severity)}">
                        <div class="command-card-head">
                          <strong>${j.kind}</strong>
                          <span class="command-chip ${L(j.severity)}">${j.severity}</span>
                        </div>
                        <p>${j.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?i`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((j,ye)=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>session-event-${ye+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${Os(j)}</pre>
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
                  ${e.recent_trace_events.map(j=>i`<${Ri} event=${j} />`)}
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
              ${g.length>0?g.map(j=>i`<${Zr} blocker=${j} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${f>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending approvals</strong>
                        <span class="command-chip warn">${f}</span>
                      </div>
                      <p>strict action이 묶여 있습니다. 실제 승인 처리는 control 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${_.length>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending confirms</strong>
                        <span class="command-chip warn">${_.length}</span>
                      </div>
                      <p>operator preview가 사람 확인을 기다리고 있습니다.</p>
                      <div class="command-tag-row">
                        ${_.slice(0,3).map(j=>i`<span class="command-tag">${j.confirm_token}</span>`)}
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
                        <span class="command-chip ${L(Re(e.operation.status))}">${e.operation.status}</span>
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
                        <span class="command-chip ${L(Re(e.detachment.status))}">${e.detachment.status??"active"}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Leader</span><span>${e.detachment.leader_id??"unassigned"}</span>
                        <span>Roster</span><span>${e.detachment.roster.length}</span>
                        <span>Session</span><span>${e.detachment.session_id??"none"}</span>
                        <span>Heartbeat</span><span>${Br(e.detachment.heartbeat_deadline)}</span>
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
                        <span class="command-chip ${L(Re(a.status))}">${va(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${rn(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${rn(a.remaining_sec)}</span>
                        <span>Done delta</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function Nv({source:t}){const e=kl(null),[n,s]=ko(null);return Z(()=>{let a=!1;const o=e.current;return o?(o.innerHTML="",s(null),(async()=>{try{const c=await jm(),{svg:u}=await c.render(`command-chain-${Em()}`,t);if(a||!e.current)return;e.current.innerHTML=u}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid render failed")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function zv({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return i`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${Vt(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?i`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?i`<span class="command-tag ${Vt(s==null?void 0:s.status)}">${Un(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${Ur(t.history)}</div>
    </button>
  `}function Dv({item:t}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${Vt(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${B(t.timestamp)}</div>
      <div class="command-card-sub">${Ur(t)}</div>
    </article>
  `}function Ev({node:t}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${Vt(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?i`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function jv({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,o=e.chain,l=(o==null?void 0:o.run_id)??null;return i`
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
        <span>Updated</span><span>${B(e.updated_at)}</span>
      </div>
      ${o?i`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${Vt(o.status)}">${o.status}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">run ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?i`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{ve("swarm"),rt("command",{surface:"swarm",operation_id:e.operation_id,...l?{run_id:l}:{}})}}
        >
          Swarm Live
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{Ti(e.operation_id),ve("chains"),rt("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?i`
              <button class="control-btn ghost" disabled=${nt(n)} onClick=${()=>Yt(()=>Im(e.operation_id))}>
                ${nt(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${nt(a)} onClick=${()=>Yt(()=>wm(e.operation_id))}>
                ${nt(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?i`
              <button class="control-btn ghost" disabled=${nt(s)} onClick=${()=>Yt(()=>Tm(e.operation_id))}>
                ${nt(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Ov({card:t}){var n;const e=t.detachment;return i`
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
        <span>Progress</span><span>${B(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Br(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${B(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?i`<span class="command-tag ${zm(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function qv(){const t=Lt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${M} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?i`<div class="command-card-stack">
              ${t.operations.operations.map(e=>i`<${jv} card=${e} />`)}
            </div>`:i`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${M} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>i`<${Ov} card=${e} />`)}
            </div>`:i`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function Fv(){var c,u,p,f,_,g,h,k,$,A,I,C,S,w,R,W;const t=Bn.value,e=(t==null?void 0:t.operations)??[],n=Oe.value,s=e.find(U=>U.operation.operation_id===n)??e[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,o=((u=wn.value)==null?void 0:u.run)??(s==null?void 0:s.preview_run)??null,l=!((p=wn.value)!=null&&p.run)&&!!(s!=null&&s.preview_run);return Z(()=>{a?Cm(a):Sm()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${M} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${Vt(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${Vt(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(t==null?void 0:t.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((f=t==null?void 0:t.summary)==null?void 0:f.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((_=t==null?void 0:t.summary)==null?void 0:_.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((g=t==null?void 0:t.summary)==null?void 0:g.recent_failures)??0}</span>
            <span>Last Event</span><span>${B((h=t==null?void 0:t.summary)==null?void 0:h.last_history_event_at)}</span>
          </div>
        </article>

        ${Es.value?i`<div class="empty-state error">${Es.value}</div>`:null}

        ${ti.value&&!t?i`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?i`
                <div class="command-chain-list">
                  ${e.map(U=>i`
                    <${zv}
                      overlay=${U}
                      selected=${(s==null?void 0:s.operation.operation_id)===U.operation.operation_id}
                      onSelect=${()=>Ti(U.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(U=>i`<${Dv} item=${U} />`)}
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
                  <span class="command-chip ${Vt((k=s.operation.chain)==null?void 0:k.status)}">
                    ${(($=s.operation.chain)==null?void 0:$.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((A=s.operation.chain)==null?void 0:A.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((I=s.operation.chain)==null?void 0:I.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${Un((C=s.runtime)==null?void 0:C.progress)}</span>
                  <span>Elapsed</span><span>${rn((S=s.runtime)==null?void 0:S.elapsed_sec)}</span>
                  <span>Updated</span><span>${B(((w=s.operation.chain)==null?void 0:w.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(R=s.operation.chain)!=null&&R.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((W=s.operation.chain)==null?void 0:W.chain_id)??"graph"}</span>
                      </div>
                      <${Nv} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"failed":l?"preview":"captured":"pending"}
                  </span>
                </div>
                ${js.value?i`<div class="empty-state">Loading run detail…</div>`:Pn.value?i`<div class="empty-state error">${Pn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${o.chain_id}</span>
                            <span>Run</span><span>${o.run_id??"preview only"}</span>
                            <span>Duration</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${o.nodes.length}</span>
                          </div>
                          ${l?i`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(U=>i`<${Ev} node=${U} />`)}
                          </div>
                        `:i`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:i`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function Kv({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return i`
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
        <span>Created</span><span>${B(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!s?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${nt(e)} onClick=${()=>Yt(()=>Rm(t.decision_id))}>
                ${nt(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${nt(n)} onClick=${()=>Yt(()=>Lm(t.decision_id))}>
                ${nt(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function Bv({row:t}){var c,u,p;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((c=e.policy)!=null&&c.frozen),o=!!((u=e.policy)!=null&&u.kill_switch),l=Math.round((t.utilization??0)*100);return i`
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
        <span>Autonomy</span><span>${((p=e.policy)==null?void 0:p.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${a?"yes":"no"}</span>
        <span>Kill Switch</span><span>${o?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${nt(n)} onClick=${()=>Yt(()=>Mm(e.unit_id,!a))}>
          ${nt(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${nt(s)} onClick=${()=>Yt(()=>Nm(e.unit_id,!o))}>
          ${nt(s)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function Uv(){const t=Lt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${M} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>i`<${Kv} decision=${e} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${M} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>i`<${Bv} row=${e} />`)}
            </div>`:i`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function Hv(){return i`
    <div class="command-surface-tabs grouped">
      ${qm.map(t=>i`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${Hr.filter(e=>e.group===t.id).map(e=>i`
                <button
                  class="command-surface-tab ${V.value===e.id?"active":""}"
                  onClick=${()=>{ve(e.id),rt("command",Wr(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function Wv(){if(V.value==="warroom")return i`<${Mv} />`;if(V.value==="summary")return i`<${_v} />`;if(V.value==="swarm")return i`<${wv} />`;if(!Lt.value)return i`<${fv} />`;switch(V.value){case"chains":return i`<${Fv} />`;case"topology":return i`<${$v} />`;case"alerts":return i`<${hv} />`;case"trace":return i`<${yv} />`;case"control":return i`<${Uv} />`;case"operations":default:return i`<${qv} />`}}function Gv(){return Z(()=>{Pe(),qe(),Am(),Ht()},[]),Z(()=>{if(N.value.tab!=="command")return;const t=N.value.params.surface,e=N.value.params.operation,n=Fn(N.value);if(io(t))ve(t);else if(n){const s=lr(n);io(s)&&ve(s)}else t||ve("warroom");e&&Ti(e),(t==="swarm"||t==="warroom"||V.value==="warroom")&&Ht(),(t==="warroom"||V.value==="warroom")&&pt()},[N.value.tab,N.value.params.surface,N.value.params.operation,N.value.params.operation_id,N.value.params.run_id,N.value.params.source,N.value.params.action_type,N.value.params.target_type,N.value.params.target_id,N.value.params.focus_kind]),Z(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,Pe(),qe(),(V.value==="swarm"||V.value==="warroom")&&Ht(),V.value==="warroom"&&pt()},250))},n=new EventSource(Hm()),s=Km.map(a=>{const o=()=>e();return n.addEventListener(a,o),{type:a,handler:o}});return n.onerror=()=>{e()},()=>{s.forEach(({type:a,handler:o})=>{n.removeEventListener(a,o)}),n.close(),t&&window.clearTimeout(t)}},[]),Z(()=>{const t=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const e=V.value;e!=="swarm"&&e!=="warroom"||(Pe(),Ht(),e==="warroom"&&pt())},5e3);return()=>{window.clearInterval(t)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Yt(()=>Pm())}}
            disabled=${nt("dispatch:tick")}
          >
            ${nt("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Pe(),qe(),Ht(),V.value==="warroom"&&pt()}}
            disabled=${ws.value}
          >
            ${ws.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Rs.value?i`<div class="empty-state error">${Rs.value}</div>`:null}
      ${Ms.value?i`<div class="empty-state error">${Ms.value}</div>`:null}
      <${mt} surfaceId="command" />
      <${dv} />
      ${V.value==="warroom"?null:i`<${uv} />`}
      <${Hv} />
      <${Wv} />
    </section>
  `}const tl="masc_dashboard_agent_name";function Jv(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(tl))==null?void 0:s.trim())||"dashboard"}const aa=v(Jv()),Fe=v(""),ei=v("운영 점검"),Ke=v(""),Rn=v(""),Ln=v("2"),Je=v(""),It=v("note"),Mn=v(""),Nn=v(""),zn=v(""),Dn=v("2"),qs=v("운영자 중지 요청"),Fs=v(""),Be=v(""),es=v(null);function Vv(t){const e=t.trim()||"dashboard";aa.value=e,localStorage.setItem(tl,e)}function el(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Yv(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function Ve(t){return typeof t=="string"?t.trim().toLowerCase():""}function Qv(t){var s;const e=Ve(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=Ve((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function _a(t){const e=Ve(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function ro(t){return t.some(e=>Ve(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function Xv(t){return t.target_type==="team_session"}function Zv(t){return t.target_type==="keeper"}function Ks(t){switch(t){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";case"keeper_msg":return"keeper 메시지";default:return(t==null?void 0:t.trim())||"액션"}}function Bs(t){switch(t){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";default:return(t==null?void 0:t.trim())||"target"}}function ln(t){switch(Ve(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function nl(t){return t?"확인 후 실행":"즉시 실행"}function t_(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";default:return t}}function lt(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function e_(t){if(t.action_type==="team_task_inject")return"task";if(t.action_type==="team_broadcast")return"broadcast";if(t.action_type==="team_note")return"note";if(t.action_type==="team_turn"){const e=lt(t.suggested_payload,"turn_kind");if(e==="broadcast"||e==="task")return e}return"note"}function n_(t){const e=t.suggested_payload;if(t.target_type==="room"){if(t.action_type==="broadcast"){Fe.value=lt(e,"message")??t.summary;return}t.action_type==="task_inject"&&(Ke.value=lt(e,"title")??"운영자 주입 작업",Rn.value=lt(e,"description")??t.summary,Ln.value=lt(e,"priority")??Ln.value);return}if(t.target_type==="team_session"){if(t.target_id&&(Je.value=t.target_id),t.action_type==="team_stop"){qs.value=lt(e,"reason")??t.summary;return}It.value=e_(t);const n=lt(e,"message");n&&(Mn.value=n),It.value==="task"&&(Nn.value=lt(e,"task_title")??lt(e,"title")??"운영자 주입 작업",zn.value=lt(e,"task_description")??lt(e,"description")??t.summary,Dn.value=lt(e,"task_priority")??lt(e,"priority")??Dn.value);return}t.target_type==="keeper"&&(t.target_id&&(Fs.value=t.target_id),Be.value=lt(e,"message")??t.summary)}function s_(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function he(t){const e=aa.value.trim()||"dashboard";try{const n=await ep({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?P("확인 대기열에 올렸습니다","warning"):P(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return P(s,"error"),null}}async function lo(){const t=Fe.value.trim();if(!t)return;await he({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(Fe.value="")}async function a_(){await he({action_type:"room_pause",target_type:"room",payload:{reason:ei.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function sl(){await he({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function i_(){const t=Ke.value.trim();if(!t)return;await he({action_type:"task_inject",target_type:"room",payload:{title:t,description:Rn.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(Ln.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(Ke.value="",Rn.value="")}async function o_(){var l;const t=vt.value,e=Je.value||((l=t==null?void 0:t.sessions[0])==null?void 0:l.session_id)||"";if(!e){P("먼저 세션을 고르세요","warning");return}const n={},s=Mn.value.trim();s&&(n.message=s);let a="team_note";It.value==="broadcast"?a="team_broadcast":It.value==="task"&&(a="team_task_inject"),It.value==="task"&&(n.task_title=Nn.value.trim()||"운영자 주입 작업",n.task_description=zn.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(Dn.value,10)||2),await he({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Mn.value="",It.value==="task"&&(Nn.value="",zn.value=""))}async function r_(){var n;const t=vt.value,e=Je.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){P("먼저 세션을 고르세요","warning");return}await he({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:qs.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function l_(){var a;const t=vt.value,e=Fs.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=Be.value.trim();if(!e){P("먼저 keeper를 고르세요","warning");return}if(!n)return;await he({action_type:"keeper_message",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`${e}에게 메시지를 보냈습니다`})&&(Be.value="")}async function c_(t){const e=aa.value.trim()||"dashboard";try{await np(e,t),P("확인 실행을 완료했습니다","success")}catch(n){const s=n instanceof Error?n.message:"확인 실행에 실패했습니다";P(s,"error")}}function d_(){const t=vt.value,e=xi.value,n=(t==null?void 0:t.room)??{},s=(t==null?void 0:t.pending_confirms)??[],a=(t==null?void 0:t.recent_messages)??[],o=(e==null?void 0:e.recommended_actions)??[],l=a.slice(0,5);return i`
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
            value=${Fe.value}
            onInput=${c=>{Fe.value=c.target.value}}
            onKeyDown=${c=>{c.key==="Enter"&&lo()}}
            disabled=${H.value}
          />
          <button class="control-btn" onClick=${()=>{lo()}} disabled=${H.value||Fe.value.trim()===""}>
            보내기
          </button>
        </div>

        <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
        <div class="control-row ops-split-row">
          <input
            id="ops-pause-reason"
            class="control-input"
            type="text"
            value=${ei.value}
            onInput=${c=>{ei.value=c.target.value}}
            disabled=${H.value}
          />
          <button class="control-btn ghost" onClick=${()=>{a_()}} disabled=${H.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{sl()}} disabled=${H.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${Ke.value}
          onInput=${c=>{Ke.value=c.target.value}}
          disabled=${H.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${Rn.value}
          onInput=${c=>{Rn.value=c.target.value}}
          disabled=${H.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${Ln.value}
            onChange=${c=>{Ln.value=c.target.value}}
            disabled=${H.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{i_()}} disabled=${H.value||Ke.value.trim()===""}>
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
        ${Tn.value&&!e?i`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:o.length>0?i`
          <div class="ops-log-list">
            ${o.map(c=>i`
              <article key=${`${c.action_type}:${c.target_type}:${c.target_id??"room"}`} class="ops-log-entry ${c.severity}">
                <div class="ops-log-head">
                  <strong>${Ks(c.action_type)}</strong>
                  <span>${Bs(c.target_type)}${c.target_id?` · ${c.target_id}`:""}</span>
                  <span>${nl(c.confirm_required)}</span>
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
          <${M} panelId="intervene.pending_confirmations" compact=${!0} />
        </div>
        <p class="ops-context-note">미리보기만 끝났고 아직 사람이 눌러줘야 하는 액션만 남깁니다.</p>
        ${s.length>0?i`
          <div class="ops-confirmation-list">
            ${s.map(c=>i`
              <article key=${c.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${Ks(c.action_type)}</strong>
                  <span>${Bs(c.target_type)}${c.target_id?` · ${c.target_id}`:""}</span>
                  <span>${c.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${c.preview?i`<pre class="ops-code-block compact">${el(c.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{c_(c.confirm_token)}} disabled=${H.value}>
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
          <${M} panelId="intervene.recommended_actions" compact=${!0} />
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
  `}function u_(){const t=vt.value,e=wt.value,n=(t==null?void 0:t.sessions)??[],s=n.find(a=>a.session_id===Je.value)??n[0]??null;return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${M} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map(a=>{var o;return i`
            <button
              key=${a.session_id}
              class="ops-entity-card ${(s==null?void 0:s.session_id)===a.session_id?"active":""}"
              onClick=${()=>{Je.value=a.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${a.session_id}</strong>
                <span class="status-badge ${a.status??"idle"}">${ln(a.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(a.progress_pct??0)}%</span>
                <span>${a.done_delta_total??0}건 완료</span>
                <span>${(o=a.team_health)!=null&&o.status?ln(String(a.team_health.status)):"상태 확인 필요"}</span>
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
        ${s&&e?i`
          <div class="ops-log-list">
            ${e.attention_items.length>0?e.attention_items.map(a=>i`
              <article key=${`${a.kind}:${a.target_id??"session"}`} class="ops-log-entry ${a.severity}">
                <div class="ops-log-head">
                  <strong>${a.kind}</strong>
                  <span>${Bs(a.target_type)}${a.target_id?` · ${a.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${a.summary}</div>
              </article>
            `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${e.worker_cards.length>0?e.worker_cards.map(a=>i`
              <article key=${`${a.actor??a.spawn_role??"worker"}:${a.spawn_agent??a.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${a.actor??a.spawn_role??"worker"}</strong>
                  <span>${ln(a.status)}</span>
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
          <${M} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>

        ${s?i`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${s.session_id}</div>
            <div class="ops-detail-meta">
              <span>상태: ${ln(s.status)}</span>
              <span>경과: ${s.elapsed_sec??0}초</span>
              <span>남은 시간: ${s.remaining_sec??0}초</span>
            </div>
            ${s.recent_events&&s.recent_events.length>0?i`
              <pre class="ops-code-block compact">${el(s.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:i`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row ops-split-row">
          <select
            id="ops-turn-kind"
            class="control-input ops-select"
            value=${It.value}
            onChange=${a=>{It.value=a.target.value}}
            disabled=${H.value||!s}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
          </select>
          <button class="control-btn" onClick=${()=>{o_()}} disabled=${H.value||!s}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${t_(It.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${Mn.value}
          onInput=${a=>{Mn.value=a.target.value}}
          disabled=${H.value||!s}
        ></textarea>

        ${It.value==="task"?i`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${Nn.value}
            onInput=${a=>{Nn.value=a.target.value}}
            disabled=${H.value||!s}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${zn.value}
            onInput=${a=>{zn.value=a.target.value}}
            disabled=${H.value||!s}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${Dn.value}
            onChange=${a=>{Dn.value=a.target.value}}
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
            value=${qs.value}
            onInput=${a=>{qs.value=a.target.value}}
            disabled=${H.value||!s}
          />
          <button class="control-btn ghost" onClick=${()=>{r_()}} disabled=${H.value||!s}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function p_(){var a;const t=vt.value,e=(t==null?void 0:t.keepers)??[],n=(t==null?void 0:t.available_actions)??[],s=e.find(o=>o.name===Fs.value)??e[0]??null;return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${M} panelId="intervene.keeper_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${e.length===0?i`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:e.map(o=>i`
            <button
              key=${o.name}
              class="ops-entity-card ${(s==null?void 0:s.name)===o.name?"active":""}"
              onClick=${()=>{Fs.value=o.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${o.name}</strong>
                <span class="status-badge ${o.status??"idle"}">${ln(o.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${o.model??"model 확인 필요"}</span>
                <span>${typeof o.context_ratio=="number"?`${Math.round(o.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${Yv(o.last_turn_ago_s)}</span>
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
          value=${Be.value}
          onInput=${o=>{Be.value=o.target.value}}
          disabled=${H.value||!s}
        ></textarea>
        <div class="control-row">
          <button class="control-btn" onClick=${()=>{l_()}} disabled=${H.value||!s||Be.value.trim()===""}>
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
          ${n.length?n.map(o=>i`
                <article key=${`${o.action_type}:${o.target_type}`} class="ops-log-entry">
                  <div class="ops-log-head">
                    <strong>${Ks(o.action_type)}</strong>
                    <span>${Bs(o.target_type)}</span>
                    <span>${nl(o.confirm_required)}</span>
                  </div>
                  <div class="ops-log-body">${o.description??"설명이 아직 없습니다."}</div>
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
          ${Is.value.length===0?i`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:Is.value.map(o=>i`
            <article key=${o.id} class="ops-log-entry ${o.outcome}">
              <div class="ops-log-head">
                <strong>${Ks(o.action_type)}</strong>
                <span>${o.target_label}</span>
                <span>${o.at}</span>
              </div>
              <div class="ops-log-body">${o.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function m_(){var $,A;const t=vt.value,e=N.value.tab==="intervene"?Fn(N.value):null,n=xi.value,s=(t==null?void 0:t.room)??{},a=(t==null?void 0:t.sessions)??[],o=(t==null?void 0:t.keepers)??[],l=(t==null?void 0:t.pending_confirms)??[],c=a.find(I=>I.session_id===Je.value)??a[0]??null,u=(n==null?void 0:n.attention_items)??[],p=u.filter(Xv),f=u.filter(Zv),_=a.filter(I=>Qv(I)!=="ok"),g=o.filter(I=>_a(I)!=="ok"),h=s_(e,a,o);Z(()=>{fe()},[]),Z(()=>{if(N.value.tab!=="intervene"){es.value=null;return}if(!e){es.value=null;return}es.value!==e.id&&(es.value=e.id,n_(e))},[N.value.tab,N.value.params.source,N.value.params.action_type,N.value.params.target_type,N.value.params.target_id,N.value.params.focus_kind,e==null?void 0:e.id]),Z(()=>{const I=(c==null?void 0:c.session_id)??null;Ge(I)},[c==null?void 0:c.session_id]);const k=[{key:"room",label:"Room 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:l.length,detail:l.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:l.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:p.length>0?p.length:a.length,detail:p.length>0?(($=p[0])==null?void 0:$.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:p.length>0?ro(p):a.length===0?"warn":_.some(I=>Ve(I.status)==="paused")?"bad":_.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:f.length>0?f.length:g.length,detail:f.length>0?((A=f[0])==null?void 0:A.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":g.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:f.length>0?ro(f):g.some(I=>_a(I)==="bad")?"bad":g.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${mt} surfaceId="intervene" />
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
            value=${aa.value}
            onInput=${I=>Vv(I.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{pt(),fe(),Ge((c==null?void 0:c.session_id)??null)}}
            disabled=${In.value||H.value}
          >
            ${In.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Xt.value?i`<section class="ops-banner error">${Xt.value}</section>`:null}
      ${We.value?i`<section class="ops-banner error">${We.value}</section>`:null}
      ${e?i`
        <section class="ops-banner ${h?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${ea(e.action_type)}</span>
            <span>${yi(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?i`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${h?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const I=[];if(l.length>0&&I.push({label:`확인 대기 ${l.length}건 처리`,desc:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:"bad",onClick:()=>{const C=document.querySelector(".ops-pending-section");C==null||C.scrollIntoView({behavior:"smooth"})}}),s.paused&&I.push({label:"Room 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void sl()}),g.length>0){const C=g.filter(S=>_a(S)==="bad");I.push({label:C.length>0?`Keeper ${C.length}개 오프라인`:`Keeper ${g.length}개 점검 필요`,desc:C.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:C.length>0?"bad":"warn",onClick:()=>{const S=document.querySelector(".ops-keeper-section");S==null||S.scrollIntoView({behavior:"smooth"})}})}return I.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${I.slice(0,3).map(C=>i`
                <button class="ops-action-guide-item ${C.tone}" onClick=${C.onClick}>
                  <strong>${C.label}</strong>
                  <span>${C.desc}</span>
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
          ${k.map(I=>i`
            <div key=${I.key} class="ops-priority-card ${I.tone}">
              <span class="ops-priority-label">${I.label}</span>
              <strong>${I.value}</strong>
              <div class="ops-priority-detail">${I.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${d_} />
        <${u_} />
        <${p_} />
      </div>
    </section>
  `}function v_({text:t}){if(!t)return null;const e=__(t);return i`<div class="markdown-content">${e}</div>`}function __(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),u=[];for(s++;s<e.length&&!e[s].startsWith(l);)u.push(e[s]),s++;s++,n.push(i`<pre><code class=${c?`language-${c}`:""}>${u.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<e.length&&!e[s].includes("</think>");)l.push(e[s]),s++;if(s<e.length){const p=e[s].replace("</think>","").trim();p&&l.push(p),s++}const u=l.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${fa(u)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<e.length&&e[s].startsWith("> ");)l.push(e[s].slice(2)),s++;n.push(i`<blockquote>${fa(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<e.length;){const l=e[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;o.push(l),s++}o.length>0&&n.push(i`<p>${fa(o.join(`
`))}</p>`)}return n}function fa(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&e.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const al=[{id:"recent",label:"Latest"},{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],ms=v(null),vs=v([]),Ye=v(!1),me=v(null),_n=v(""),fn=v(!1),Le=v(!0),Li=20,Ce=v(Li);function f_(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const g_=v(f_());function $_(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function co(t){return t.updated_at!==t.created_at}function h_(t){const e=`${t.title} ${t.author} ${t.tags.join(" ")} ${t.flair??""}`.toLowerCase();return/\b(test|smoke|harness|sandbox|dummy|sample|tmp|qa|e2e)\b/.test(e)||e.includes("테스트")||e.includes("실험")}function y_(t){if(t.post_kind)return t.post_kind==="automation";const e=(t.hearth??"").toLowerCase();return t.visibility!=="internal"||!t.expires_at||!e?!1:!!(e.startsWith("mdal")||e.includes("harness"))}function il(t){return Le.value?t.filter(e=>y_(e)?!1:e.post_kind||e.hearth||e.visibility||e.expires_at?!0:!h_(e)):t}async function Mi(t){me.value=t,ms.value=null,vs.value=[],Ye.value=!0;try{const e=await vc(t);if(me.value!==t)return;ms.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,post_kind:e.post_kind,flair:e.flair,hearth:e.hearth,visibility:e.visibility,expires_at:e.expires_at,hearth_count:e.hearth_count},vs.value=e.comments??[]}catch{me.value===t&&(ms.value=null,vs.value=[])}finally{me.value===t&&(Ye.value=!1)}}async function uo(t){const e=_n.value.trim();if(e){fn.value=!0;try{await _c(t,g_.value,e),_n.value="",P("Comment posted","success"),await Mi(t),Gt()}catch{P("Failed to post comment","error")}finally{fn.value=!1}}}function b_(){const t=kn.value,e=Le.value?"Hiding automation posts":"Show automation posts";return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${al.map(n=>i`
          <button
            class="board-sort-btn ${t===n.id?"active":""}"
            onClick=${()=>{kn.value=n.id,Ce.value=Li,Gt()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Le.value?"is-active":""}"
          onClick=${()=>{Le.value=!Le.value}}
        >
          ${e}
        </button>
        <button
          class="control-btn ghost ${Ie.value?"is-active":""}"
          onClick=${()=>{Ie.value=!Ie.value,Gt()}}
        >
          ${Ie.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${Gt} disabled=${xn.value}>
          ${xn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function ga(){var s;const t=((s=al.find(a=>a.id===kn.value))==null?void 0:s.label)??kn.value,e=il(bn.value),n=bn.value.length-e.length;return i`
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
        <strong>${Le.value?`automation ${n} hidden`:"full feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${Ie.value?"Auto reports hidden":"Full memory feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Ja.value?i`<${Q} timestamp=${Ja.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function k_({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await No(t.id,n),Gt()}catch{P("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>Il(t.id)}>
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
                ${co(t)?i`<span class="board-meta-chip">Updated</span>`:null}
                ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${Q} timestamp=${t.created_at} /></span>
            ${co(t)?i`<span>Updated <${Q} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${$_(t.content)}</div>
      </div>
    </div>
  `}function x_({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${Q} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function S_({postId:t}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${_n.value}
        onInput=${e=>{_n.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&uo(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${fn.value}
      />
      <button
        onClick=${()=>uo(t)}
        disabled=${fn.value||_n.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${fn.value?"...":"Post"}
      </button>
    </div>
  `}function C_({post:t}){me.value!==t.id&&!Ye.value&&Mi(t.id);const e=async n=>{try{await No(t.id,n),Gt()}catch{P("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>rt("memory")}>← Back to Memory</button>
      <${T} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${v_} text=${t.content} />
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
        ${Ye.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${x_} comments=${vs.value} />`}
        <${S_} postId=${t.id} />
      <//>
    </div>
  `}function A_(){const t=il(bn.value),e=N.value.params.post??null,n=e?t.find(s=>s.id===e)??(me.value===e?ms.value:null):null;return e&&!n&&me.value!==e&&!Ye.value&&Mi(e),e?n?i`
          <${mt} surfaceId="memory" />
          <${ga} />
          <${C_} post=${n} />
        `:i`
          <div>
            <${mt} surfaceId="memory" />
            <${ga} />
            <button class="back-btn" onClick=${()=>rt("memory")}>← Back to Memory</button>
            ${Ye.value?i`<div class="loading-indicator">Loading post...</div>`:i`<div class="empty-state">Post not found</div>`}
          </div>
        `:i`
    <div>
      <${mt} surfaceId="memory" />
      <${ga} />
      <${b_} />
      ${xn.value?i`<div class="loading-indicator">Loading memory feed...</div>`:t.length===0?i`<div class="empty-state">No posts in durable memory right now</div>`:i`
              <${T} title="Posts / Comments" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.slice(0,Ce.value).map(s=>i`<${k_} key=${s.id} post=${s} />`)}
                </div>
                ${t.length>Ce.value?i`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{Ce.value=Ce.value+Li}}
                    >
                      Show more (${t.length-Ce.value} remaining)
                    </button>
                  </div>
                `:null}
              <//>
            `}
    </div>
  `}function I_({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,o=2*Math.PI*s,l=o*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),i`
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
  `}const le=v(null),Mt=v(null),Nt=v(null);function ia(t){return t==="bad"||t==="critical"||t==="offline"?"bad":t==="warn"||t==="paused"||t==="blocked"||t==="interrupted"?"warn":"ok"}function T_(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function w_(t){return t?Ot.value.find(e=>e.name===t||e.agent_name===t)??null:null}function P_(t){switch(t){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function R_(t){switch(t){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function po(t){if(!t)return;const e=gu({targetType:t.target_type,targetId:t.target_id,focusKind:t.focus_kind,operationId:t.operation_id??null,commandSurface:t.command_surface??null,sourceLabel:"Execution 진단",summary:t.label});or(e),rt(t.surface,t.surface==="intervene"?rr(e):cr(e))}function xe({label:t,value:e,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function Ni({intervene:t,command:e}){return i`
    <div class="control-row">
      ${t?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),po(t)}}
            >
              ${t.label}
            </button>
          `:null}
      ${e?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),po(e)}}
            >
              ${e.label}
            </button>
          `:null}
    </div>
  `}function L_({item:t,selected:e}){return i`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{le.value=e?null:t.id,Mt.value=null,Nt.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.kind==="session"?t.target_id:t.linked_session_id??t.target_id}</div>
          <div class="mission-card-title">${t.summary}</div>
        </div>
        <span class="command-chip ${ia(t.severity)}">${t.status??t.severity}</span>
      </div>
      <div class="mission-card-meta">
        <span>${t.kind}</span>
        ${t.linked_operation_id?i`<span>linked op · ${t.linked_operation_id}</span>`:null}
        ${t.last_seen_at?i`<span><${Q} timestamp=${t.last_seen_at} /></span>`:null}
      </div>
      <${Ni} intervene=${t.intervene_handoff} command=${t.command_handoff} />
    </button>
  `}function M_({brief:t,selected:e}){return i`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.session-card"
      onClick=${()=>{Mt.value=e?null:t.session_id,Nt.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.session_id}${t.room?` · ${t.room}`:""}</div>
          <div class="mission-card-title">${t.goal}</div>
        </div>
        <span class="command-chip ${ia(t.health??t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="mission-card-meta">
        <span>health · ${t.health??"ok"}</span>
        ${t.linked_operation_id?i`<span>op · ${t.linked_operation_id}</span>`:null}
        ${t.last_activity_at?i`<span><${Q} timestamp=${t.last_activity_at} /></span>`:null}
      </div>
      ${t.runtime_blocker?i`<div class="mission-card-detail">${t.runtime_blocker}</div>`:t.last_activity_summary?i`<div class="mission-card-detail">${t.last_activity_summary}</div>`:null}
      ${t.worker_gap_summary?i`<div class="monitor-footnote">${t.worker_gap_summary}</div>`:null}
      <${Ni} intervene=${t.intervene_handoff} command=${t.command_handoff} />
    </button>
  `}function N_({brief:t,selected:e}){return i`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.operation-card"
      onClick=${()=>{Nt.value=e?null:t.operation_id,Mt.value=t.linked_session_id??null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.operation_id}${t.assigned_unit_label?` · ${t.assigned_unit_label}`:""}</div>
          <div class="mission-card-title">${t.objective}</div>
        </div>
        <span class="command-chip ${ia(t.blocker_summary?"warn":t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="mission-card-meta">
        ${t.stage?i`<span>stage · ${t.stage}</span>`:null}
        ${t.linked_session_id?i`<span>session · ${t.linked_session_id}</span>`:null}
        ${t.updated_at?i`<span><${Q} timestamp=${t.updated_at} /></span>`:null}
      </div>
      ${t.blocker_summary?i`<div class="mission-card-detail">${t.blocker_summary}</div>`:null}
      ${t.next_tool?i`<div class="monitor-footnote">next tool · ${t.next_tool}</div>`:null}
      <${Ni} command=${t.command_handoff} />
    </button>
  `}function mo({row:t,testId:e}){return i`
    <button class="monitor-row ${t.tone} state-${t.state}" data-testid=${e} onClick=${()=>An(t.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.name}</span>
            ${t.korean_name?i`<span class="monitor-sub">${t.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${te} status=${t.status??"unknown"} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${P_(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.last_signal_at?i`<span>신호 <${Q} timestamp=${t.last_signal_at} /></span>`:i`<span>최근 신호 없음</span>`}
        <span>${(t.active_task_count??0)>0?`활성 작업 ${t.active_task_count}개`:"활성 작업 없음"}</span>
        ${t.related_session_id?i`<span>session · ${t.related_session_id}</span>`:null}
        ${t.related_operation_id?i`<span>op · ${t.related_operation_id}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${t.recent_output_preview&&t.recent_output_preview!==t.focus?i`<div class="monitor-footnote">최근 상세: ${t.recent_output_preview}</div>`:null}
    </button>
  `}function z_({row:t}){const e=()=>{const n=w_(t.name);n&&Ar(n)};return i`
    <button class="monitor-row ${t.tone} state-${t.state}" data-testid="execution.continuity-card" onClick=${e}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.name}</span>
            ${t.korean_name?i`<span class="monitor-sub">${t.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${I_} ratio=${t.context_ratio??0} size=${34} stroke=${4} />
        <${te} status=${t.status??"unknown"} />
        <span class="monitor-pill ${t.tone}">${R_(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.last_signal_at?i`<span>최근 활동 <${Q} timestamp=${t.last_signal_at} /></span>`:i`<span>최근 활동 없음</span>`}
        ${t.related_session_id?i`<span>session · ${t.related_session_id}</span>`:null}
        ${t.continuity?i`<span>${t.continuity}</span>`:null}
        ${t.lifecycle?i`<span>라이프사이클 ${t.lifecycle}</span>`:null}
        <span>컨텍스트 ${T_(t.context_ratio)}</span>
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${t.skill_reason?i`<div class="monitor-footnote">연속성 이유: ${t.skill_reason}</div>`:null}
    </button>
  `}function D_(){const t=Oo.value,e=qo.value,n=Fo.value,s=Ko.value,a=Bo.value,o=Uo.value,l=Ho.value;le.value&&!e.some($=>$.id===le.value)&&(le.value=null),Mt.value&&!n.some($=>$.session_id===Mt.value)&&(Mt.value=null),Nt.value&&!s.some($=>$.operation_id===Nt.value)&&(Nt.value=null);const c=le.value?e.find($=>$.id===le.value)??null:null,u=Mt.value?Mt.value:c?c.kind==="session"?c.target_id:c.linked_session_id??null:null,p=Nt.value?Nt.value:c?c.kind==="operation"?c.target_id:c.linked_operation_id??null:null,f=u?n.filter($=>$.session_id===u):p?n.filter($=>$.linked_operation_id===p):n,_=p?s.filter($=>$.operation_id===p):u?s.filter($=>{var A;return $.linked_session_id===u||$.operation_id===((A=f[0])==null?void 0:A.linked_operation_id)}):s,g=u||p?a.filter($=>(u?$.related_session_id===u:!1)||(p?$.related_operation_id===p:!1)):a,h=u?o.filter($=>$.related_session_id===u||$.tone!=="ok"):o,k=u||p?l.filter($=>(u?$.related_session_id===u:!1)||(p?$.related_operation_id===p:!1)||$.tone!=="ok"):l;return i`
    <div class="agents-monitor">
      <${mt} surfaceId="execution" />
      <div class="stats-grid">
        <${xe} label="활성 세션" value=${(t==null?void 0:t.active_sessions)??n.length} color="#4ade80" caption="실행 관점의 session" />
        <${xe} label="막힌 세션" value=${(t==null?void 0:t.blocked_sessions)??n.filter($=>ia($.health??$.status)!=="ok").length} color="#fbbf24" caption="개입 후보 session" />
        <${xe} label="활성 작전" value=${(t==null?void 0:t.active_operations)??s.length} color="#22d3ee" caption="command-plane operation" />
        <${xe} label="막힌 작전" value=${(t==null?void 0:t.blocked_operations)??s.filter($=>$.blocker_summary).length} color="#fb7185" caption="원인 분석이 필요한 작전" />
        <${xe} label="worker 경고" value=${(t==null?void 0:t.worker_alerts)??a.filter($=>$.tone!=="ok").length} color="#fb7185" caption="supporting worker pressure" />
        <${xe} label="연속성 경고" value=${(t==null?void 0:t.continuity_alerts)??o.filter($=>$.tone!=="ok").length} color="#fb7185" caption="keeper continuity pressure" />
      </div>

      <${T}
        title="Execution Queue"
        class="section"
        semanticId="execution.queue"
        testId="execution.queue"
      >
        <div class="monitor-section-head">
          <h2 class="monitor-headline">지금 막힌 실행과 다음 handoff</h2>
          <p class="monitor-subheadline">session과 operation을 한 queue로 보고, 어디를 먼저 Intervene/Command로 넘길지 판단합니다.</p>
        </div>
        <div class="monitor-alert-list">
          ${e.length===0?i`<div class="empty-state">지금은 막힌 실행이 없습니다</div>`:e.map($=>i`<${L_} key=${$.id} item=${$} selected=${le.value===$.id} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${T}
          title="Affected Sessions"
          class="section"
          semanticId="execution.sessions"
          testId="execution.session-briefs"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">영향받는 session</h2>
            <p class="monitor-subheadline">queue에서 고른 실행이 어떤 session 목표와 runtime blocker를 갖는지 요약합니다.</p>
          </div>
          <div class="monitor-list">
            ${f.length===0?i`<div class="empty-state">선택된 실행과 연결된 session이 없습니다</div>`:f.map($=>i`<${M_} key=${$.session_id} brief=${$} selected=${Mt.value===$.session_id} />`)}
          </div>
        <//>

        <${T}
          title="Affected Operations"
          class="section"
          semanticId="execution.operations"
          testId="execution.operation-briefs"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">영향받는 작전</h2>
            <p class="monitor-subheadline">command-plane operation의 blocker와 next tool을 얇게 보여주고, deep truth는 Command로 넘깁니다.</p>
          </div>
          <div class="monitor-list">
            ${_.length===0?i`<div class="empty-state">선택된 실행과 연결된 operation이 없습니다</div>`:_.map($=>i`<${N_} key=${$.operation_id} brief=${$} selected=${Nt.value===$.operation_id} />`)}
          </div>
        <//>

        <${T}
          title="Worker Support"
          class="section"
          semanticId="execution.worker_support"
          testId="execution.worker-support"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">지원 worker</h2>
            <p class="monitor-subheadline">선택된 session/operation에 연결된 worker만 보이고, 전체 worker wall은 더 이상 첫 화면을 차지하지 않습니다.</p>
          </div>
          <div class="monitor-list">
            ${g.length===0?i`<div class="empty-state">연결된 worker가 없습니다</div>`:g.map($=>i`<${mo} key=${$.name} row=${$} testId="execution.worker-card" />`)}
          </div>
        <//>

        <${T}
          title="Continuity"
          class="section"
          semanticId="execution.continuity"
          testId="execution.continuity"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">연속성 보조 lane</h2>
            <p class="monitor-subheadline">keeper continuity는 supporting lane으로만 남기고, unhealthy keeper 위주로 노출합니다.</p>
          </div>
          <div class="monitor-list">
            ${h.length===0?i`<div class="empty-state">지금은 연속성 경고가 없습니다</div>`:h.map($=>i`<${z_} key=${$.name} row=${$} />`)}
          </div>
        <//>

        <${T}
          title="Offline Workers"
          class="section"
          semanticId="execution.offline"
          testId="execution.offline-workers"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">오프라인 worker</h2>
            <p class="monitor-subheadline">빠진 worker는 하단 lane으로 분리해 활성 실행 판단을 방해하지 않게 유지합니다.</p>
          </div>
          <div class="monitor-list">
            ${k.length===0?i`<div class="empty-state">지금은 오프라인 worker가 없습니다</div>`:k.map($=>i`<${mo} key=${$.name} row=${$} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Us=v("all"),Hs=v("all"),ni=v(new Set);function E_(t){const e=new Set(ni.value);e.has(t)?e.delete(t):e.add(t),ni.value=e}const ol=yt(()=>{let t=Ne.value;return Us.value!=="all"&&(t=t.filter(e=>e.horizon===Us.value)),Hs.value!=="all"&&(t=t.filter(e=>e.status===Hs.value)),t}),j_=yt(()=>{const t={short:[],mid:[],long:[]};for(const e of ol.value){const n=t[e.horizon];n&&n.push(e)}return t}),O_=yt(()=>{const t=Array.from(Go.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function q_(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function zi(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function _s(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function F_(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function vo(t){return t.toFixed(4)}function _o(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function K_(t){switch(t){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function fo(t,e){return(t.priority??4)-(e.priority??4)}function B_(t,e){const n=t.updated_at??t.created_at??"";return(e.updated_at??e.created_at??"").localeCompare(n)}function U_(t,e){return t.length<=e?t:t.slice(0,e)+"..."}function H_({goal:t}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${_s(t.horizon)}">
            ${zi(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${q_(t.priority)}</span>
          ${t.metric?i`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?i`<span class="goal-due">Due: <${Q} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?i`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${te} status=${t.status} />
        <div class="goal-updated">
          <${Q} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function $a({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return i`
    <${T} title="${zi(t)} Goals (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${H_} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function W_(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>i`
          <button
            class="goal-filter-btn ${Us.value===t?"active":""}"
            onClick=${()=>{Us.value=t}}
          >
            ${t==="all"?"All":zi(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>i`
          <button
            class="goal-filter-btn ${Hs.value===t?"active":""}"
            onClick=${()=>{Hs.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function G_(){const t=Ne.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return i`
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
        <div class="goal-summary-value" style="color:${_s("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${_s("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${_s("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function J_({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return i`
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
          <span>Baseline ${vo(t.baseline_metric)}</span>
          <span>Current ${vo(t.current_metric)}</span>
          <span class=${_o(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${_o(t)}
          </span>
          <span>Elapsed ${F_(t.elapsed_seconds)}</span>
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
  `}function ha({task:t}){const e=t.priority??4,n=e<=1?"p1":e===2?"p2":e===3?"p3":"p4",s=ni.value.has(t.id),a=!!t.description;return i`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${K_(e)}</span>
        <div class="kanban-card-title">${t.title}</div>
      </div>
      ${a?i`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>E_(t.id)}
        >
          ${s?t.description:U_(t.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${t.created_at?i`<${Q} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function V_(){const{todo:t,inProgress:e,done:n}=Vo.value,s=[...t].sort(fo),a=[...e].sort(fo),o=[...n].sort(B_);return i`
    <${T} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${s.length===0?i`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:s.map(l=>i`<${ha} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${a.length===0?i`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:a.map(l=>i`<${ha} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${o.length===0?i`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:o.slice(0,20).map(l=>i`<${ha} key=${l.id} task=${l} />`)}
          ${o.length>20?i`<div class="empty-state" style="opacity: 0.5;">...and ${o.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function Y_(){const{todo:t,inProgress:e,done:n}=Vo.value,s=t.length+e.length+n.length,a=[...t,...e].filter(f=>(f.priority??4)<=2).length,o=j_.value,l=O_.value,c=Ne.value.length>0,u=l.length>0,p=pi.value;return i`
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
          onClick=${()=>{_i(),er()}}
          disabled=${dn.value||un.value}
        >
          ${dn.value||un.value?"Refreshing...":"Refresh planning data"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${V_} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          Goal Pipeline
          <span class="monitor-pill">${Ne.value.length}</span>
        </summary>
        <div>
          ${c?i`
            <${G_} />
            <${W_} />
            ${dn.value&&Ne.value.length===0?i`<div class="loading-indicator">Loading goals...</div>`:ol.value.length===0?i`<div class="empty-state">No goals match the current filters</div>`:i`
                    <${$a} horizon="short" items=${o.short??[]} />
                    <${$a} horizon="mid" items=${o.mid??[]} />
                    <${$a} horizon="long" items=${o.long??[]} />
                  `}
          `:i`
            <div class="empty-state">
              No goals defined. Use <code>masc_goal_upsert</code> to create goals.
            </div>
          `}
        </div>
      </details>

      <!-- MDAL Loops in collapsible details -->
      <details class="overview-section-collapsible" open=${u}>
        <summary>
          MDAL Loops
          <span class="monitor-pill">${l.length}</span>
        </summary>
        <div>
          ${un.value&&l.length===0?i`<div class="loading-indicator">Loading MDAL loops...</div>`:l.length===0&&(p==="error"||ze.value)?i`<div class="empty-state">MDAL snapshot could not be loaded${ze.value?`: ${ze.value}`:""}. Check backend health.</div>`:l.length===0?i`<div class="empty-state">No active loops. Use <code>masc_mdal_start</code> to start a loop.</div>`:i`
                  <div class="planning-loop-list">
                    ${l.map(f=>i`<${J_} key=${f.loop_id} loop=${f} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const gn=v("debates"),Ws=v([]),Gs=v([]),Js=v(!1),$n=v(!1),En=v(""),hn=v(""),Vs=v(null),xt=v(null),si=v(!1);async function oa(){Js.value=!0,En.value="";try{const t=await Vl();Ws.value=Array.isArray(t.debates)?t.debates:[],Gs.value=Array.isArray(t.sessions)?t.sessions:[]}catch(t){En.value=t instanceof Error?t.message:"Failed to load governance state"}finally{Js.value=!1}}jd(oa);async function go(){const t=hn.value.trim();if(t){$n.value=!0;try{const e=await Kc(t);hn.value="",P(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await oa()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";P(n,"error")}finally{$n.value=!1}}}async function Q_(t){Vs.value=t,xt.value=null,si.value=!0;try{xt.value=await Bc(t)}catch(e){En.value=e instanceof Error?e.message:"Failed to load debate detail"}finally{si.value=!1}}function X_(){return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${Ws.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Voting sessions</span>
        <strong>${Gs.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Active view</span>
        <strong>${gn.value==="debates"?"Debates":"Voting"}</strong>
      </div>
    </div>
  `}function Z_({debate:t}){const e=Vs.value===t.id;return i`
    <button class="council-row ${e?"selected":""}" onClick=${()=>Q_(t.id)}>
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
  `}function tf({session:t}){return i`
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
  `}function ef(){const t=gn.value;return i`
    <div class="overview-sub-tabs" style="margin-bottom:12px;">
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{gn.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{gn.value="voting"}}>Voting</button>
    </div>
  `}function nf(){return i`
    <div>
      <${T} title="Start Debate" class="section" semanticId="governance.debates">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${hn.value}
            onInput=${t=>{hn.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&go()}}
            disabled=${$n.value}
          />
          <button
            class="control-btn secondary"
            onClick=${go}
            disabled=${$n.value||hn.value.trim()===""}
          >
            ${$n.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${oa} disabled=${Js.value}>
            ${Js.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${En.value?i`<div class="council-error">${En.value}</div>`:null}
      <//>

      <${T} title="Debates" class="section" semanticId="governance.debates">
        <div class="council-list">
          ${Ws.value.length===0?i`<div class="empty-state">No debates yet</div>`:Ws.value.map(t=>i`<${Z_} key=${t.id} debate=${t} />`)}
        </div>
      <//>

      <${T} title=${Vs.value?`Debate Detail (${Vs.value})`:"Debate Detail"} class="section" semanticId="governance.debates">
        ${si.value?i`<div class="loading-indicator">Loading debate detail...</div>`:xt.value?i`
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
  `}function sf(){return i`
    <${T} title="Voting Sessions" class="section" semanticId="governance.voting">
      <div class="council-list">
        ${Gs.value.length===0?i`<div class="empty-state">No active sessions</div>`:Gs.value.map(t=>i`<${tf} key=${t.id} session=${t} />`)}
      </div>
    <//>
  `}function af(){return Z(()=>{oa()},[]),i`
    <div>
      <${mt} surfaceId="governance" />
      <${X_} />
      <${ef} />
      ${gn.value==="debates"?i`<${nf} />`:i`<${sf} />`}
    </div>
  `}const Ae=v(""),ya=v("ability_check"),ba=v("10"),ka=v("12"),ns=v(""),ss=v("idle"),Bt=v(""),as=v("keeper-late"),xa=v("player"),Sa=v(""),gt=v("idle"),Ca=v(null),is=v(""),Aa=v(""),Ia=v("player"),Ta=v(""),wa=v(""),Pa=v(""),yn=v("20"),Ra=v("20"),La=v(""),os=v("idle"),ai=v(null),rl=v("overview"),Ma=v("all"),Na=v("all"),za=v("all"),of=12e4,ra=v(null),$o=v(Date.now());function rf(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function lf(t,e){return e>0?Math.round(t/e*100):0}const cf={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},df={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function rs(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function uf(t){const e=t.trim().toLowerCase();return cf[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function pf(t){const e=t.trim().toLowerCase();return df[e]??"상황에 따라 선택되는 전술 액션입니다."}function ut(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function St(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function jn(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const mf=new Set(["str","dex","con","int","wis","cha"]);function vf(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!m(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const l=a.trim();if(l){if(typeof o=="number"&&Number.isFinite(o)){s[l]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const c=Number.parseFloat(o.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function _f(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(yn.value.trim(),10);Number.isFinite(s)&&s>n&&(yn.value=String(n))}function ii(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function ff(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function gf(t){rl.value=t}function ll(t){const e=ra.value;return e==null||e<=t}function $f(t){const e=ra.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Ys(){ra.value=null}function cl(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function hf(t,e){cl(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(ra.value=Date.now()+of,P("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function fs(t){return ll(t)?(P("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function oi(t,e,n){return cl([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function yf({hp:t,max:e}){const n=lf(t,e),s=rf(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function bf({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function kf({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function dl({actor:t}){var u,p,f,_;const e=(u=t.archetype)==null?void 0:u.trim(),n=(p=t.persona)==null?void 0:p.trim(),s=(f=t.portrait)==null?void 0:f.trim(),a=(_=t.background)==null?void 0:_.trim(),o=t.traits??[],l=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([g,h])=>Number.isFinite(h)).filter(([g])=>!mf.has(g.toLowerCase()));return i`
    <div class="trpg-actor">
      ${s?i`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${g=>{const h=g.target;h&&(h.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${te} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${kf} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${yf} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${bf} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${rs(e)}</div>`:null}
      ${a?i`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([g,h])=>i`
                <span class="trpg-custom-stat-chip">${rs(g)} ${h}</span>
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
                  <span class="trpg-annot-name">${rs(g)}</span>
                  <span class="trpg-annot-desc">${uf(g)}</span>
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
                  <span class="trpg-annot-name">${rs(g)}</span>
                  <span class="trpg-annot-desc">${pf(g)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function xf({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function ul({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?i`<div class="empty-state" style="font-size:13px">${e}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${ff(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${ii(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${Q} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Sf({events:t}){const e="__none__",n=Ma.value,s=Na.value,a=za.value,o=Array.from(new Set(t.map(ii).map(_=>_.trim()).filter(_=>_!==""))).sort((_,g)=>_.localeCompare(g)),l=Array.from(new Set(t.map(_=>(_.type??"").trim()).filter(_=>_!==""))).sort((_,g)=>_.localeCompare(g)),c=t.some(_=>(_.type??"").trim()===""),u=Array.from(new Set(t.map(_=>(_.phase??"").trim()).filter(_=>_!==""))).sort((_,g)=>_.localeCompare(g)),p=t.some(_=>(_.phase??"").trim()===""),f=t.filter(_=>{if(n!=="all"&&ii(_)!==n)return!1;const g=(_.type??"").trim(),h=(_.phase??"").trim();if(s===e){if(g!=="")return!1}else if(s!=="all"&&g!==s)return!1;if(a===e){if(h!=="")return!1}else if(a!=="all"&&h!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${_=>{Ma.value=_.target.value}}>
          <option value="all">all</option>
          ${o.map(_=>i`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${_=>{Na.value=_.target.value}}>
          <option value="all">all</option>
          ${c?i`<option value=${e}>(none)</option>`:null}
          ${l.map(_=>i`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${_=>{za.value=_.target.value}}>
          <option value="all">all</option>
          ${p?i`<option value=${e}>(none)</option>`:null}
          ${u.map(_=>i`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Ma.value="all",Na.value="all",za.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${f.length} / 전체 ${t.length}
      </span>
    </div>
    <${ul} events=${f.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Cf({outcome:t}){if(!t)return null;const e=o=>{const l=o.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function pl({state:t}){const e=t.history??[];return e.length===0?null:i`
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
  `}function Af({state:t,nowMs:e}){var p;const n=Dt.value||((p=t.session)==null?void 0:p.room)||"",s=ss.value,a=t.party??[];if(!a.find(f=>f.id===Ae.value)&&a.length>0){const f=a[0];f&&(Ae.value=f.id)}const l=async()=>{var _,g;if(!n){P("Room ID가 비어 있습니다.","error");return}if(!fs(e))return;const f=((_=t.current_round)==null?void 0:_.phase)??((g=t.session)==null?void 0:g.status)??"unknown";if(oi("라운드 실행",n,f)){ss.value="running";try{const h=await Rc(n);ai.value=h,ss.value="ok";const k=m(h.summary)?h.summary:null,$=k?jn(k,"advanced",!1):!1,A=k?ut(k,"progress_reason",""):"";P($?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${A?`: ${A}`:""}`,$?"success":"warning"),Jt()}catch(h){ai.value=null,ss.value="error";const k=h instanceof Error?h.message:"라운드 실행에 실패했습니다.";P(k,"error")}finally{Ys()}}},c=async()=>{var _,g;if(!n||!fs(e))return;const f=((_=t.current_round)==null?void 0:_.phase)??((g=t.session)==null?void 0:g.status)??"unknown";if(oi("턴 강제 진행",n,f))try{await Nc(n),P("턴을 다음 단계로 이동했습니다.","success"),Jt()}catch{P("턴 이동에 실패했습니다.","error")}finally{Ys()}},u=async()=>{if(!n||!fs(e))return;const f=Ae.value.trim();if(!f){P("먼저 Actor를 선택하세요.","warning");return}const _=Number.parseInt(ba.value,10),g=Number.parseInt(ka.value,10);if(Number.isNaN(_)||Number.isNaN(g)){P("stat/dc는 숫자여야 합니다.","warning");return}const h=Number.parseInt(ns.value,10),k=ns.value.trim()===""||Number.isNaN(h)?void 0:h;try{await Mc({roomId:n,actorId:f,action:ya.value.trim()||"ability_check",statValue:_,dc:g,rawD20:k}),P("주사위 판정을 기록했습니다.","success"),Jt()}catch{P("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${f=>{Dt.value=f.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Ae.value}
            onChange=${f=>{Ae.value=f.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(f=>i`<option value=${f.id}>${f.name} (${f.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${ya.value}
              onInput=${f=>{ya.value=f.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${ba.value}
              onInput=${f=>{ba.value=f.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${ka.value}
              onInput=${f=>{ka.value=f.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${ns.value}
              onInput=${f=>{ns.value=f.target.value}}
              onKeyDown=${f=>{f.key==="Enter"&&u()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${u}>Roll</button>
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
  `}function If({state:t}){var a;const e=Dt.value||((a=t.session)==null?void 0:a.room)||"",n=os.value,s=async()=>{if(!e){P("Room ID가 비어 있습니다.","warning");return}const o=is.value.trim(),l=Aa.value.trim();if(!l&&!o){P("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(yn.value.trim(),10),u=Number.parseInt(Ra.value.trim(),10),p=Number.isFinite(u)?Math.max(1,u):20,f=Number.isFinite(c)?Math.max(0,Math.min(p,c)):p;let _={};try{_=vf(La.value)}catch(g){P(g instanceof Error?g.message:"능력치 JSON 오류","error");return}os.value="spawning";try{const g=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,h=await zc(e,{actor_id:o||void 0,name:l||void 0,role:Ia.value,idempotencyKey:g,portrait:wa.value.trim()||void 0,background:Pa.value.trim()||void 0,hp:f,max_hp:p,alive:f>0,stats:Object.keys(_).length>0?_:void 0}),k=typeof h.actor_id=="string"?h.actor_id.trim():"";if(!k)throw new Error("생성 응답에 actor_id가 없습니다.");const $=Ta.value.trim();$&&await Dc(e,k,$),Ae.value=k,Bt.value=k,o||(is.value=""),os.value="ok",P(`Actor 생성 완료: ${k}`,"success"),await Jt()}catch(g){os.value="error",P(g instanceof Error?g.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Aa.value}
            onInput=${o=>{Aa.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ia.value}
            onChange=${o=>{Ia.value=o.target.value}}
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
            value=${Ta.value}
            onInput=${o=>{Ta.value=o.target.value}}
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
              value=${yn.value}
              onInput=${o=>{yn.value=o.target.value}}
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
              value=${Ra.value}
              onInput=${o=>{const l=o.target.value;Ra.value=l,_f(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Pa.value}
              onInput=${o=>{Pa.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${La.value}
              onInput=${o=>{La.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Tf({state:t,nowMs:e}){var g;const n=Dt.value||((g=t.session)==null?void 0:g.room)||"",s=t.join_gate,a=Ca.value,o=m(a)?a:null,l=(t.party??[]).filter(h=>h.role!=="dm"),c=Bt.value.trim(),u=l.some(h=>h.id===c),p=u?c:c?"__manual__":"",f=async()=>{const h=Bt.value.trim(),k=as.value.trim();if(!n||!h){P("Room/Actor가 필요합니다.","warning");return}gt.value="checking";try{const $=await Ec(n,h,k||void 0);Ca.value=$,gt.value="ok",P("참가 가능 여부를 갱신했습니다.","success")}catch($){gt.value="error";const A=$ instanceof Error?$.message:"참가 가능 여부 확인에 실패했습니다.";P(A,"error")}},_=async()=>{var I,C;const h=Bt.value.trim(),k=as.value.trim(),$=Sa.value.trim();if(!n||!h||!k){P("Room/Actor/Keeper가 필요합니다.","warning");return}if(!fs(e))return;const A=((I=t.current_round)==null?void 0:I.phase)??((C=t.session)==null?void 0:C.status)??"unknown";if(oi("Mid-Join 승인 요청",n,A)){gt.value="requesting";try{const S=await jc({room_id:n,actor_id:h,keeper_name:k,role:xa.value,...$?{name:$}:{}});Ca.value=S;const w=m(S)?jn(S,"granted",!1):!1,R=m(S)?ut(S,"reason_code",""):"";w?P("Mid-Join이 승인되었습니다.","success"):P(`Mid-Join이 거절되었습니다${R?`: ${R}`:""}`,"warning"),gt.value=w?"ok":"error",Jt()}catch(S){gt.value="error";const w=S instanceof Error?S.message:"Mid-Join 요청에 실패했습니다.";P(w,"error")}finally{Ys()}}};return i`
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
            value=${p}
            onChange=${h=>{const k=h.target.value;if(k==="__manual__"){(u||!c)&&(Bt.value="");return}Bt.value=k}}
          >
            <option value="">Actor 선택</option>
            ${l.map(h=>i`
              <option value=${h.id}>${h.name} (${h.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${p==="__manual__"?i`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${Bt.value}
                onInput=${h=>{Bt.value=h.target.value}}
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
            value=${xa.value}
            onChange=${h=>{xa.value=h.target.value}}
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
            value=${Sa.value}
            onInput=${h=>{Sa.value=h.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${f} disabled=${gt.value==="checking"||gt.value==="requesting"}>
              ${gt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${_} disabled=${gt.value==="checking"||gt.value==="requesting"}>
              ${gt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${jn(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${St(o,"effective_score",0)}/${St(o,"required_points",0)}</span>
            ${ut(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${ut(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function ml({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function vl({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function _l(){const t=ai.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=m(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(m).slice(-8),o=t.canon_check,l=m(o)?o:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(R=>typeof R=="string").slice(0,3):[],u=l&&Array.isArray(l.violations)?l.violations.filter(R=>typeof R=="string").slice(0,3):[],p=n?jn(n,"advanced",!1):!1,f=n?ut(n,"progress_reason",""):"",_=n?ut(n,"progress_detail",""):"",g=n?St(n,"player_successes",0):0,h=n?St(n,"player_required_successes",0):0,k=n?jn(n,"dm_success",!1):!1,$=n?St(n,"timeouts",0):0,A=n?St(n,"unavailable",0):0,I=n?St(n,"reprompts",0):0,C=n?St(n,"npc_attacks",0):0,S=n?St(n,"keeper_timeout_sec",0):0,w=n?St(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${p?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${p?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${k?"DM ok":"DM stalled"} / players ${g}/${h}
          </span>
        </div>
        ${f?i`<div style="margin-top:4px; font-size:12px;">${f}</div>`:null}
        ${_?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${_}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${$}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${I}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${S||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${w}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(R=>{const W=ut(R,"status","unknown"),U=ut(R,"actor_id","-"),_t=ut(R,"role","-"),tt=ut(R,"reason",""),et=ut(R,"action_type",""),F=ut(R,"reply","");return i`
                <div class="trpg-round-item ${W.includes("fallback")||W.includes("timeout")?"failed":"active"}">
                  <span>${U} (${_t})</span>
                  <span style="margin-left:auto; font-size:11px;">${W}</span>
                  ${et?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${et}</div>`:null}
                  ${tt?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${tt}</div>`:null}
                  ${F?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${F.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${ut(l,"status","unknown")}</strong>
            </div>
            ${u.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${u.map(R=>i`<div>violation: ${R}</div>`)}
                </div>`:null}
            ${c.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(R=>i`<div>warning: ${R}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function wf({state:t,nowMs:e}){var l,c,u;const n=Dt.value||((l=t.session)==null?void 0:l.room)||"",s=((c=t.current_round)==null?void 0:c.phase)??((u=t.session)==null?void 0:u.status)??"unknown",a=ll(e),o=$f(e);return i`
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
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>hf(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{Ys(),P("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Pf({active:t}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>gf(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Rf({state:t}){const e=t.party??[],n=t.story_log??[];return i`
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
          <${ul} events=${n.slice(-20)} />
        <//>

        ${t.map?i`
            <${T} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${xf} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${T} title="현재 라운드" semanticId="lab.trpg">
          <${vl} state=${t} />
        <//>

        <${T} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${ml} state=${t} />
        <//>

        <${T} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>i`<${dl} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?i`
            <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${pl} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Lf({state:t}){const e=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${T} title=${`이벤트 타임라인 (${e.length})`}>
          <${Sf} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${T} title="최근 라운드 결과" semanticId="lab.trpg">
          <${_l} />
        <//>

        <${T} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${vl} state=${t} />
        <//>
      </div>
    </div>
  `}function Mf({state:t,nowMs:e}){const n=t.party??[];return i`
    <div>
      <${wf} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${T} title="조작 패널" semanticId="lab.trpg">
            <${Af} state=${t} nowMs=${e} />
          <//>

          <${T} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${If} state=${t} />
          <//>

          <${T} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${Tf} state=${t} nowMs=${e} />
          <//>

          <${T} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${_l} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${T} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${ml} state=${t} />
          <//>

          <${T} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${dl} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?i`
              <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${pl} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Nf(){var c,u,p,f,_;const t=Wo.value,e=Ga.value;if(Z(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const g=window.setInterval(()=>{$o.value=Date.now()},1e3);return()=>{window.clearInterval(g)}},[]),e&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Jt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,o=rl.value,l=$o.value;return i`
    <div>
      <${mt} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Dt.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((u=t.current_round)==null?void 0:u.phase)??((p=t.session)==null?void 0:p.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Jt()}>새로고침</button>
      </div>

      <${Cf} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((f=t.session)==null?void 0:f.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((_=t.current_round)==null?void 0:_.round_number)??0}</div>
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

      <${Pf} active=${o} />

      ${o==="overview"?i`<${Rf} state=${t} />`:o==="timeline"?i`<${Lf} state=${t} />`:i`<${Mf} state=${t} nowMs=${l} />`}
    </div>
  `}function zf(){return i`
    <div>
      <${mt} surfaceId="lab" />
      <${T} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${T} title="TRPG" class="section" semanticId="lab.trpg">
        <${Nf} />
      <//>
    </div>
  `}const Qs=v(new Set(["broadcast","tasks","keepers","system"]));function Df(t){const e=new Set(Qs.value);e.has(t)?e.delete(t):e.add(t),Qs.value=e}const Di=v(null);function fl(t){Di.value=t}function Ef(t){return t.kind==="board"?"broadcast":t.kind==="tasks"?"tasks":t.kind==="keepers"?"keepers":"system"}const jf=yt(()=>{const t=Qs.value;return $s.value.filter(e=>t.has(Ef(e)))}),Of=12e4,qf=yt(()=>{const t=Yo.value,e=Date.now();return Rt.value.map(n=>{const s=n.name.trim().toLowerCase(),a=t.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?o=e-new Date(l).getTime()>Of?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),Ff=yt(()=>{const t=Yo.value;return Rt.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle").map(e=>{const n=e.name.trim().toLowerCase(),s=t.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:e.name,emoji:e.emoji??"",koreanName:e.koreanName??null,currentTask:e.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((e,n)=>{const s={hot:0,normal:1,calm:2};return s[e.pressure]-s[n.pressure]})});function ho(t){return t.kind==="board"?"live-event-broadcast":t.kind==="tasks"?"live-event-task":t.kind==="keepers"?"live-event-keeper":"live-event-system"}function Kf(t){const e=t.eventType;return e==="broadcast"?"broadcast":e==="agent_joined"?"joined":e==="agent_left"?"left":e==="task_update"?"task":e==="board_post"?"post":e==="board_comment"?"comment":e==="keeper_heartbeat"?"heartbeat":e==="keeper_handoff"?"handoff":e==="keeper_compaction"?"compact":e==="keeper_guardrail"?"guardrail":t.kind==="board"?"board":t.kind==="tasks"?"task":t.kind==="keepers"?"keeper":"system"}function Bf(t){switch(t){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function Uf(){const t=qf.value,e=Di.value;return t.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${t.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${Bf(n.state)} ${e===n.name?"pulse-selected":""}"
          onClick=${()=>fl(e===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const Hf=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function Wf(){const t=Qs.value;return i`
    <div class="activity-filter-bar">
      ${Hf.map(e=>i`
        <button
          key=${e.kind}
          class="activity-filter-btn ${e.cssClass} ${t.has(e.kind)?"active":""}"
          onClick=${()=>Df(e.kind)}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Gf(){const t=jf.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${t.length} events</span>
      </div>
      <${Wf} />
      <div class="activity-stream-list">
        ${t.length===0?i`<div class="activity-empty">No events matching filters</div>`:t.map((e,n)=>i`
            <div
              key=${`${e.timestamp}-${n}`}
              class="activity-item ${ho(e)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${ho(e)}">${Kf(e)}</span>
                <span class="activity-agent">${e.agent}</span>
                <span class="activity-time">${gr(e.timestamp)}</span>
              </div>
              <div class="activity-item-text">${e.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function Jf(t){switch(t){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function Vf(t){switch(t){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function Yf(){const t=Ff.value,e=Di.value;return i`
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
              onClick=${()=>fl(e===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?i`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${Jf(n.pressure)}">
                  ${Vf(n.pressure)}
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
  `}function Qf(){const t=Qt.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>Live Monitor</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${t?"connected":"disconnected"}"></span>
            ${t?"Connected":"Offline"}
          </span>
          <span class="live-stat">${Rt.value.length} agents</span>
          <span class="live-stat">${Xs.value} events</span>
        </div>
      </div>

      <${Uf} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${Gf} />
        </div>
        <div class="live-panel-side">
          <${Yf} />
        </div>
      </div>
    </div>
  `}const yo=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],ri=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"proof",label:"Proof",icon:"🔍",group:"observe",description:"협업, 대화, 도구, backing evidence를 증명 중심으로 읽는 표면"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"live",label:"Live",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}];function Xf(){const t=Qt.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"재연결 중..."}</span>
      <span class="event-count">${Xs.value} events</span>
    </div>
  `}function li(t){t==="command"&&(Pe(),qe(),(V.value==="swarm"||V.value==="warroom")&&Ht(),V.value==="warroom"&&pt()),t==="mission"&&(sr(),xs()),t==="proof"&&wr(N.value.params.session_id,N.value.params.operation_id),t==="execution"&&de(),t==="intervene"&&(pt(),fe()),t==="memory"&&Gt(),t==="planning"&&_i(),t==="lab"&&Jt()}function Zf({currentTab:t}){const e=Qt.value;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${M} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${e?"ok":"bad"}">${e?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agent</span>
          <strong>${Rt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keeper</span>
          <strong>${Ot.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Task</span>
          <strong>${Tt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Event</span>
          <strong>${Xs.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{qn(),Zo(),li(t)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>rt("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function tg(){const t=vt.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${M} panelId="side_rail.quick_actions" compact=${!0} />
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
          onClick=${()=>{pt(),fe()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>rt("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function eg(){const t=N.value.tab,e=ri.find(s=>s.id===t),n=yo.find(s=>s.id===(e==null?void 0:e.group));return i`
    <aside class="dashboard-rail">
      <${mt} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${M} panelId="side_rail.navigate" compact=${!0} />
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${yo.map(s=>i`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${ri.filter(a=>a.group===s.id).map(a=>i`
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
          <div class="rail-view-note-label">현재 화면</div>
          <strong>${(e==null?void 0:e.label)??t}</strong>
          <p>${(e==null?void 0:e.description)??"운영 화면"}</p>
        </div>
      </section>

      <${Zf} currentTab=${t} />
      <${tg} />
    </aside>
  `}function ng(){switch(N.value.tab){case"mission":return i`<${no} />`;case"proof":return i`<${cv} />`;case"execution":return i`<${D_} />`;case"live":return i`<${Qf} />`;case"memory":return i`<${A_} />`;case"governance":return i`<${af} />`;case"planning":return i`<${Y_} />`;case"intervene":return i`<${m_} />`;case"command":return i`<${Gv} />`;case"lab":return i`<${zf} />`;default:return i`<${no} />`}}function sg(){Z(()=>{Tl(),To(),tr(),de(),Zo(),sr();const n=Fd();return Kd(),()=>{Dl(),n(),Bd()}},[]),Z(()=>{const n=setInterval(()=>{li(N.value.tab)},15e3);return()=>{clearInterval(n)}},[]),Z(()=>{li(N.value.tab)},[N.value.tab]);const t=N.value.tab,e=ri.find(n=>n.id===t);return i`
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
          <${Xf} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${eg} />
        <main class="dashboard-main">
          ${Wa.value&&!Qt.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${ng} />`}
        </main>
      </div>

      <${Cp} />
      <${Hu} />
      <${ju} />
    </div>
  `}const bo=document.getElementById("app");bo&&xl(i`<${sg} />`,bo);export{zp as _};
