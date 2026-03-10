var sl=Object.defineProperty;var al=(t,e,n)=>e in t?sl(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Ie=(t,e,n)=>al(t,typeof e!="symbol"?e+"":e,n);import{e as il,_ as ol,c as f,b as It,y as rt,d as wo,A as rl,G as ll}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const r of o.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=il.bind(ol);const cl=["mission","execution","live","memory","governance","planning","intervene","command","lab"],To={tab:"mission",params:{},postId:null};function Fi(t){return!!t&&cl.includes(t)}function Ka(t){try{return decodeURIComponent(t)}catch{return t}}function Ua(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function dl(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Io(t,e){if(t[0]==="chains"){const o={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(o.operation=Ka(t[2])),{tab:"command",params:o,postId:null}}if(t[0]==="lab"){const o={...e};return t[1]&&(o.surface=Ka(t[1])),{tab:"lab",params:o,postId:null}}const n=t[0],s=e.tab;return{tab:Fi(n)?n:Fi(s)?s:"mission",params:e,postId:null}}function $s(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return To;const n=Ka(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=Ua(a),r=dl(s);return Io(r,o)}function ul(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...To,params:Ua(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Ua(e.replace(/^\?/,""));return Io(s,a)}function No(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const O=f($s(window.location.hash));window.addEventListener("hashchange",()=>{O.value=$s(window.location.hash)});function gt(t,e){const n={tab:t,params:e??{}};window.location.hash=No(n)}function pl(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function ml(){if(window.location.hash&&window.location.hash!=="#"){O.value=$s(window.location.hash);return}const t=ul(window.location.pathname,window.location.search);if(t){O.value=t;const e=No(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",O.value=$s(window.location.hash)}const qi="masc_dashboard_sse_session_id",vl=1e3,_l=15e3,re=f(!1),Xs=f(0),Ro=f(null),hs=f([]);function fl(){let t=sessionStorage.getItem(qi);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(qi,t)),t}const gl=200;function $l(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};hs.value=[a,...hs.value].slice(0,gl)}function Ha(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Ki(t,e){const n=Ha(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function Ct(t,e,n,s,a={}){$l(t,e,n,{eventType:s,...a})}let Mt=null,Oe=null,Wa=0;function Po(){Oe&&(clearTimeout(Oe),Oe=null)}function hl(){if(Oe)return;Wa++;const t=Math.min(Wa,5),e=Math.min(_l,vl*Math.pow(2,t));Oe=setTimeout(()=>{Oe=null,Lo()},e)}function Lo(){Po(),Mt&&(Mt.close(),Mt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",fl());const a=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(a);Mt=o,o.onopen=()=>{Mt===o&&(Wa=0,re.value=!0)},o.onerror=()=>{Mt===o&&(re.value=!1,o.close(),Mt=null,hl())},o.onmessage=r=>{try{const c=JSON.parse(r.data);Xs.value++,Ro.value=c,yl(c)}catch{}}}function yl(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":Ct(n,"Joined","system","agent_joined");break;case"agent_left":Ct(n,"Left","system","agent_left");break;case"broadcast":Ct(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Ct(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Ct(n,Ki("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Ha(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":Ct(n,Ki("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Ha(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":Ct(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Ct(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Ct(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Ct(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Ct(n,e,"system","unknown")}}function bl(){Po(),Mt&&(Mt.close(),Mt=null),re.value=!1}function Mo(){return new URLSearchParams(window.location.search)}function Do(){const t=Mo(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function Eo(){return{...Do(),"Content-Type":"application/json"}}const kl=15e3,gi=3e4,xl=6e4,Ui=new Set([408,425,429,500,502,503,504]);class zn extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);Ie(this,"method");Ie(this,"path");Ie(this,"status");Ie(this,"statusText");Ie(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function $i(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new zn({method:r,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function Sl(){var e,n;const t=Mo();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function ot(t){const e=await $i(t,{headers:Do()},kl);if(!e.ok)throw new zn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Al(t){return new Promise(e=>setTimeout(e,t))}function Cl(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function wl(t){if(t instanceof zn)return t.timeout||typeof t.status=="number"&&Ui.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=Cl(t.message);return e!==null&&Ui.has(e)}async function zo(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!wl(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${o}ms`,a),await Al(o),s+=1}}async function Kt(t,e,n,s=gi){const a=await $i(t,{method:"POST",headers:{...Eo(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new zn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function Tl(t,e,n,s=gi){const a=await $i(t,{method:"POST",headers:{...Eo(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new zn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function Il(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Nl(t){var e,n,s,a,o,r,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((c=(r=(o=t.result)==null?void 0:o.content)==null?void 0:r[0])==null?void 0:c.text)??""}async function ce(t,e){const n=await Tl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},xl),s=Il(n);return Nl(s)}function Rl(){return ot("/api/v1/dashboard/shell")}function Pl(){return ot("/api/v1/dashboard/execution")}function Ll(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),ot(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function Ml(){return ot("/api/v1/dashboard/governance")}function Dl(){return ot("/api/v1/dashboard/semantics")}function El(){return ot("/api/v1/dashboard/mission")}function zl(){return ot("/api/v1/dashboard/planning")}function jl(){return ot("/api/v1/operator")}function jo(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return ot(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Ol(){return ot("/api/v1/command-plane")}function Fl(){return ot("/api/v1/command-plane/summary")}function ql(){return ot("/api/v1/chains/summary")}function Kl(t){return ot(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Ul(){return ot("/api/v1/command-plane/help")}function Hl(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return ot(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function Wl(t,e){return Kt(t,e)}function Bl(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return gi}}function Qs(t){return Kt("/api/v1/operator/action",t,void 0,Bl(t))}function Gl(t,e){return Kt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function ys(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function Jl(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Vl(t){if(!K(t))return null;const e=h(t.id,"").trim(),n=h(t.author,"").trim(),s=h(t.content,"").trim();if(!e||!n)return null;const a=J(t.score,0),o=J(t.votes_up,0),r=J(t.votes_down,0),c=J(t.votes,a||o-r),d=J(t.comment_count,J(t.reply_count,0)),m=(()=>{const k=t.flair;if(typeof k=="string"&&k.trim())return k.trim();if(K(k)){const w=h(k.name,"").trim();if(w)return w}return h(t.flair_name,"").trim()||void 0})(),u=h(t.created_at_iso,"").trim()||ys(t.created_at),p=h(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?ys(t.updated_at):u),$=h(t.title,"").trim()||Jl(s);return{id:e,author:n,title:$,content:s,tags:[],votes:c,vote_balance:a,comment_count:d,created_at:u,updated_at:p,flair:m,hearth_count:J(t.hearth_count,0)}}function Yl(t){if(!K(t))return null;const e=h(t.id,"").trim(),n=h(t.post_id,"").trim(),s=h(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:h(t.content,""),created_at:ys(t.created_at)}}async function Xl(t){return zo("fetchBoardPost",async()=>{const e=await ot(`/api/v1/board/${t}?format=flat`),n=K(e.post)?e.post:e,s=Vl(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},o=(Array.isArray(e.comments)?e.comments:[]).map(Yl).filter(r=>r!==null);return{...s,comments:o}})}function Oo(t,e){return Kt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Sl()})}function Ql(t,e,n){return Kt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Zl(t){const e=h(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function pt(...t){for(const e of t){const n=h(e,"");if(n.trim())return n.trim()}return""}function Hi(t){const e=Zl(pt(t.outcome,t.result,t.result_code));if(!e)return;const n=pt(t.reason,t.reason_code,t.description,t.detail),s=pt(t.summary,t.summary_ko,t.summary_en,t.note),a=pt(t.details,t.details_text,t.text,t.note),o=pt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=pt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=pt(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const p=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof p=="string"?[p]:Array.isArray(p)?p.map(_=>{if(typeof _=="string")return _.trim();if(K(_)){const $=h(_.summary,"").trim();if($)return $;const k=h(_.text,"").trim();if(k)return k;const A=h(_.type,"").trim();return A||h(_.event_id,"").trim()}return""}).filter(_=>_.length>0):[]})(),m=(()=>{const p=J(t.turn,Number.NaN);if(Number.isFinite(p))return p;const _=J(t.turn_number,Number.NaN);if(Number.isFinite(_))return _;const $=J(t.current_turn,Number.NaN);if(Number.isFinite($))return $;const k=J(t.round,Number.NaN);return Number.isFinite(k)?k:void 0})(),u=pt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:c||void 0,turn:m,phase:u||void 0}}function tc(t,e){const n=K(t.state)?t.state:{};if(h(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>K(r)?h(r.type,"")==="session.outcome":!1),o=K(n.session_outcome)?n.session_outcome:{};if(K(o)&&Object.keys(o).length>0){const r=Hi(o);if(r)return r}if(K(a))return Hi(K(a.payload)?a.payload:{})}function K(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function J(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function ec(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Ba(t,e=!1){return typeof t=="boolean"?t:e}function nn(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(K(e)){const n=h(e.name,"").trim(),s=h(e.id,"").trim(),a=h(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function nc(t){const e={};if(!K(t)&&!Array.isArray(t))return e;if(K(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),o=h(s,"").trim();!a||!o||(e[a]=o)}),e;for(const n of t){if(!K(n))continue;const s=pt(n.to,n.target,n.actor_id,n.name,n.id),a=pt(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function sc(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function bt(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const ac=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function ic(t){const e=K(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const o=s.trim();o&&(ac.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function oc(t,e){if(t!=="dice.rolled")return;const n=J(e.raw_d20,0),s=J(e.total,0),a=J(e.bonus,0),o=h(e.action,"roll"),r=J(e.dc,0);return{notation:r>0?`${o} (DC ${r})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function rc(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function lc(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function cc(t,e,n,s){const a=n||e||h(s.actor_id,"")||h(s.actor_name,"");switch(t){case"turn.action.proposed":{const o=h(s.proposed_action,h(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=h(s.reply,h(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return h(s.reply,h(s.content,h(s.text,"Narration")));case"dice.rolled":{const o=h(s.action,"roll"),r=J(s.total,0),c=J(s.dc,0),d=h(s.label,""),m=a||"actor",u=c>0?` vs DC ${c}`:"",p=d?` (${d})`:"";return`${m} ${o}: ${r}${u}${p}`}case"turn.started":return`Turn ${J(s.turn,1)} started`;case"phase.changed":return`Phase: ${h(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(s.name,K(s.actor)?h(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${h(s.keeper_name,h(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${h(s.keeper_name,h(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${J(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${J(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||h(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||h(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${h(s.reason_code,"unknown")}`;case"memory.signal":{const o=K(s.entity_refs)?s.entity_refs:{},r=h(o.requested_tier,""),c=h(o.effective_tier,""),d=Ba(o.guardrail_applied,!1),m=h(s.summary_en,h(s.summary_ko,"Memory signal"));if(!r&&!c)return m;const u=r&&c?`${r}->${c}`:c||r;return`${m} [${u}${d?" (guardrail)":""}]`}case"world.event":{if(h(s.event_type,"")==="canon.check"){const r=h(s.status,"unknown"),c=h(s.contract_id,"n/a");return`Canon ${r}: ${c}`}return h(s.description,h(s.summary,"World event"))}case"combat.attack":return h(s.summary,h(s.result,"Attack resolved"));case"combat.defense":return h(s.summary,h(s.result,"Defense resolved"));case"session.outcome":return h(s.summary,h(s.outcome,"Session ended"));default:{const o=rc(s);return o?`${t}: ${o}`:t}}}function dc(t,e){const n=K(t)?t:{},s=h(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=h(n.actor_name,"").trim()||e[a]||h(K(n.payload)?n.payload.actor_name:"",""),r=K(n.payload)?n.payload:{},c=h(n.ts,h(n.timestamp,new Date().toISOString())),d=h(n.phase,h(r.phase,"")),m=h(n.category,"");return{type:s,actor:o||a||h(r.actor_name,""),actor_id:a||h(r.actor_id,""),actor_name:o,seq:n.seq,room_id:h(n.room_id,""),phase:d||void 0,category:m||lc(s),visibility:h(n.visibility,h(r.visibility,"public")),event_id:h(n.event_id,""),content:cc(s,a,o,r),dice_roll:oc(s,r),timestamp:c}}function uc(t,e,n){var F,tt;const s=h(t.room_id,"")||n||"default",a=K(t.state)?t.state:{},o=K(a.party)?a.party:{},r=K(a.actor_control)?a.actor_control:{},c=K(a.join_gate)?a.join_gate:{},d=K(a.contribution_ledger)?a.contribution_ledger:{},m=Object.entries(o).map(([W,et])=>{const b=K(et)?et:{},Nt=bt(b,"max_hp",void 0,10),Qt=bt(b,"hp",void 0,Nt),ve=bt(b,"max_mp",void 0,0),_e=bt(b,"mp",void 0,0),j=bt(b,"level",void 0,1),Rt=bt(b,"xp",void 0,0),fe=Ba(b.alive,Qt>0),tn=r[W],en=typeof tn=="string"?tn:void 0,Wn=sc(b.role,W,en),Bn=ec(b.generation),Gn=pt(b.joined_at,b.joinedAt,b.started_at,b.startedAt),Jn=pt(b.claimed_at,b.claimedAt,b.assigned_at,b.assignedAt,b.assigned_time),q=pt(b.last_seen,b.lastSeen,b.last_seen_at,b.lastSeenAt,b.last_active,b.lastActive),Te=pt(b.scene,b.current_scene,b.currentScene,b.world_scene,b.scene_name,b.sceneName),nl=pt(b.location,b.current_location,b.currentLocation,b.position,b.zone,b.area);return{id:W,name:h(b.name,W),role:Wn,keeper:en,archetype:h(b.archetype,""),persona:h(b.persona,""),portrait:h(b.portrait,"")||void 0,background:h(b.background,"")||void 0,traits:nn(b.traits),skills:nn(b.skills),stats_raw:ic(b),status:fe?"active":"dead",generation:Bn,joined_at:Gn||void 0,claimed_at:Jn||void 0,last_seen:q||void 0,scene:Te||void 0,location:nl||void 0,inventory:nn(b.inventory),notes:nn(b.notes),relationships:nc(b.relationships),stats:{hp:Qt,max_hp:Nt,mp:_e,max_mp:ve,level:j,xp:Rt,strength:bt(b,"strength","str",10),dexterity:bt(b,"dexterity","dex",10),constitution:bt(b,"constitution","con",10),intelligence:bt(b,"intelligence","int",10),wisdom:bt(b,"wisdom","wis",10),charisma:bt(b,"charisma","cha",10)}}}),u=m.filter(W=>W.status!=="dead"),p=tc(t,e),_={phase_open:Ba(c.phase_open,!0),min_points:J(c.min_points,3),window:h(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},$=Object.entries(d).map(([W,et])=>{const b=K(et)?et:{};return{actor_id:W,score:J(b.score,0),last_reason:h(b.last_reason,"")||null,reasons:nn(b.reasons)}}),k=m.reduce((W,et)=>(W[et.id]=et.name,W),{}),A=e.map(W=>dc(W,k)),w=J(a.turn,1),L=h(a.phase,"round"),z=h(a.map,""),E=K(a.world)?a.world:{},I=z||h(E.ascii_map,h(E.map,"")),N=A.filter((W,et)=>{const b=e[et];if(!K(b))return!1;const Nt=K(b.payload)?b.payload:{};return J(Nt.turn,-1)===w}),Y=(N.length>0?N:A).slice(-12),G=h(a.status,"active");return{session:{id:s,room:s,status:G==="ended"?"ended":G==="paused"?"paused":"active",round:w,actors:u,created_at:((F=A[0])==null?void 0:F.timestamp)??new Date().toISOString()},current_round:{round_number:w,phase:L,events:Y,timestamp:((tt=A[A.length-1])==null?void 0:tt.timestamp)??new Date().toISOString()},map:I||void 0,join_gate:_,contribution_ledger:$,outcome:p,party:u,story_log:A,history:[]}}async function pc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await ot(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function mc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([ot(`/api/v1/trpg/state${e}`),pc(t)]);return uc(n,s,t)}function vc(t){return Kt("/api/v1/trpg/rounds/run",{room_id:t})}function _c(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function fc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Kt("/api/v1/trpg/dice/roll",e)}function gc(t,e){const n=_c();return Kt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function $c(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Kt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function hc(t,e,n){return Kt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function yc(t,e,n){const s=await ce("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function bc(t){const e=await ce("trpg.mid_join.request",t);return JSON.parse(e)}async function kc(t,e){await ce("masc_broadcast",{agent_name:t,message:e})}async function xc(t=40){return(await ce("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Sc(t,e=20){return ce("masc_task_history",{task_id:t,limit:e})}async function Ac(t){const e=await ce("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Cc(t){return zo("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await ot(`/api/v1/council/debates/${e}/summary`);if(!K(n))return null;const s=h(n.id,"").trim();return s?{id:s,topic:h(n.topic,""),status:h(n.status,"open"),support_count:J(n.support_count,0),oppose_count:J(n.oppose_count,0),neutral_count:J(n.neutral_count,0),total_arguments:J(n.total_arguments,0),created_at:ys(n.created_at_iso??n.created_at),summary_text:h(n.summary_text,"")}:null})}function wc(t,e,n){return ce("masc_keeper_msg",{name:t,message:e})}const Tc=f(""),Jt=f({}),vt=f({}),Ga=f({}),Ja=f({}),Va=f({}),Ya=f({}),Vt=f({});function dt(t,e,n){t.value={...t.value,[e]:n}}function Xt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function X(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function Tt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Me(t){return typeof t=="boolean"?t:void 0}function Xa(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function Qa(t){return Array.isArray(t)?t.map(e=>X(e)).filter(e=>!!e):[]}function Ic(t){var n;const e=(n=X(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Nc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function pa(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!Xt(s))continue;const a=X(s.name);if(!a)continue;const o=X(s[e]);e==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function Rc(t){if(!Xt(t))return null;const e=X(t.name);return e?{name:e,trigger:X(t.trigger),outcome:X(t.outcome),summary:X(t.summary),reason:X(t.reason)}:null}function Pc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Lc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Fo(t,e,n){return X(t)??Lc(e,n)}function qo(t,e){return typeof t=="boolean"?t:e==="recover"}function bs(t){if(!Xt(t))return null;const e=X(t.health_state),n=X(t.next_action_path),s=X(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:X(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:Xa(t.last_reply_at),last_reply_preview:X(t.last_reply_preview)??null,last_error:X(t.last_error)??null,next_eligible_at_s:Tt(t.next_eligible_at_s)??null,recoverable:qo(t.recoverable,n),summary:Fo(t.summary,e,X(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Ko(t){return Xt(t)?{hour:Tt(t.hour),checked:Tt(t.checked)??0,acted:Tt(t.acted)??0,acted_names:Qa(t.acted_names),activity_report:X(t.activity_report),quiet_hours_overridden:Me(t.quiet_hours_overridden),skipped_reason:X(t.skipped_reason),acted_rows:pa(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:pa(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:pa(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Rc).filter(e=>e!==null):[]}:null}function Mc(t){return Xt(t)?{enabled:Me(t.enabled)??!1,interval_s:Tt(t.interval_s)??0,quiet_start:Tt(t.quiet_start),quiet_end:Tt(t.quiet_end),quiet_active:Me(t.quiet_active),use_planner:Me(t.use_planner),delegate_llm:Me(t.delegate_llm),agent_count:Tt(t.agent_count),agents:Qa(t.agents),last_tick_ago_s:Tt(t.last_tick_ago_s)??null,last_tick_ago:X(t.last_tick_ago),total_ticks:Tt(t.total_ticks),total_checkins:Tt(t.total_checkins),last_skip_reason:X(t.last_skip_reason)??null,last_tick_result:Ko(t.last_tick_result),active_self_heartbeats:Qa(t.active_self_heartbeats)}:null}function Dc(t){return Xt(t)?{status:t.status,diagnostic:bs(t.diagnostic)}:null}function Ec(t){return Xt(t)?{recovered:Me(t.recovered)??!1,skipped_reason:X(t.skipped_reason)??null,before:bs(t.before),after:bs(t.after),down:t.down,up:t.up}:null}function zc(t,e){var z,E;if(!(t!=null&&t.name))return null;const n=X((z=t.agent)==null?void 0:z.status)??X(t.status)??"unknown",s=X((E=t.agent)==null?void 0:E.error)??null,a=t.presence_keepalive??!0,o=t.keepalive_running??!1,r=t.turn_count??0,c=t.last_turn_ago_s??null,d=t.proactive_enabled??!1,m=t.proactive_cooldown_sec??0,u=t.last_proactive_ago_s??null,p=d&&u!=null?Math.max(0,m-u):null,_=r<=0||c==null?"never":c>900?"stale":"fresh",$=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,k=s??(a&&!o?"keeper keepalive is not running":null),A=n==="offline"||n==="inactive"?"offline":k?"degraded":_==="stale"?"stale":_==="never"?"idle":"healthy",w=k?Pc(k):e!=null&&e.quiet_active&&_!=="fresh"?"quiet_hours":a&&!o?"disabled":r<=0?"never_started":p!=null&&p>0?"min_gap":_==="fresh"||_==="stale"?"no_recent_activity":"unknown",L=A==="offline"||A==="degraded"||A==="stale"?"recover":w==="quiet_hours"?"manual_lodge_poke":w==="unknown"?"probe":"direct_message";return{health_state:A,quiet_reason:w,next_action_path:L,last_reply_status:_,last_reply_at:$,last_reply_preview:null,last_error:k,next_eligible_at_s:p!=null&&p>0?p:null,recoverable:qo(void 0,L),summary:Fo(void 0,A,w),keepalive_running:o}}function jc(t,e){if(!Xt(t))return null;const n=Ic(t.role),s=X(t.content)??X(t.preview);if(!s)return null;const a=Xa(t.ts_unix)??Xa(t.timestamp);return{id:`${n}-${a??"entry"}-${e}`,role:n,label:Nc(n),text:s,timestamp:a,delivery:"history"}}function Oc(t,e,n){const s=Xt(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,r)=>jc(o,r)).filter(o=>o!==null):[];return{name:t,diagnostic:bs(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function Wi(t,e){const n=vt.value[t]??[];vt.value={...vt.value,[t]:[...n,e].slice(-50)}}function Fc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function qc(t,e){const s=(vt.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(o=>Fc(a,o)));vt.value={...vt.value,[t]:[...e,...s].slice(-50)}}function Zs(t,e){Jt.value={...Jt.value,[t]:e},qc(t,e.history)}function Bi(t,e){const n=Jt.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Zs(t,{...n,diagnostic:{...s,...e}})}async function hi(){try{await jn()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Kc(t){Tc.value=t.trim()}async function Uo(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Jt.value[n])return Jt.value[n];dt(Ga,n,!0),dt(Vt,n,null);try{const s=await ce("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=Oc(n,s,a);return Zs(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return dt(Vt,n,a),null}finally{dt(Ga,n,!1)}}async function Uc(t,e){const n=t.trim(),s=e.trim();if(!n||!s)return;const a=`local-${Date.now()}`;Wi(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),dt(Ja,n,!0),dt(Vt,n,null);try{const o=await wc(n,s);vt.value={...vt.value,[n]:(vt.value[n]??[]).map(r=>r.id===a?{...r,delivery:"delivered"}:r)},Wi(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Bi(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await hi()}catch(o){const r=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw vt.value={...vt.value,[n]:(vt.value[n]??[]).map(c=>c.id===a?{...c,delivery:"error",error:r}:c)},Bi(n,{last_reply_status:"error",last_error:r}),dt(Vt,n,r),o}finally{dt(Ja,n,!1)}}async function Hc(t,e){const n=t.trim();if(!n)return null;dt(Va,n,!0),dt(Vt,n,null);try{const s=await Qs({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=Dc(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const r=Jt.value[n];Zs(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??vt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await hi(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw dt(Vt,n,a),s}finally{dt(Va,n,!1)}}async function Wc(t,e){const n=t.trim();if(!n)return null;dt(Ya,n,!0),dt(Vt,n,null);try{const s=await Qs({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Ec(s.result),o=(a==null?void 0:a.after)??null;if(o){const r=Jt.value[n];Zs(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??vt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await hi(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw dt(Vt,n,a),s}finally{dt(Ya,n,!1)}}function ge(t){return(t??"").trim().toLowerCase()}function $t(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ls(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Vn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function sn(t){return t.last_heartbeat??Vn(t.last_turn_ago_s)??Vn(t.last_proactive_ago_s)??Vn(t.last_handoff_ago_s)??Vn(t.last_compaction_ago_s)}function Bc(t){const e=t.title.trim();return e||ls(t.content)}function Gc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Jc(t,e,n,s,a={}){var E;const o=ge(t),r=e.filter(I=>ge(I.assignee)===o&&(I.status==="claimed"||I.status==="in_progress")).length,c=n.filter(I=>ge(I.from)===o).sort((I,N)=>$t(N.timestamp)-$t(I.timestamp))[0],d=s.filter(I=>ge(I.agent)===o||ge(I.author)===o).sort((I,N)=>$t(N.timestamp)-$t(I.timestamp))[0],m=(a.boardPosts??[]).filter(I=>ge(I.author)===o).sort((I,N)=>$t(N.updated_at||N.created_at)-$t(I.updated_at||I.created_at))[0],u=(a.keepers??[]).filter(I=>ge(I.name)===o&&sn(I)!==null).sort((I,N)=>$t(sn(N)??0)-$t(sn(I)??0))[0],p=c?$t(c.timestamp):0,_=d?$t(d.timestamp):0,$=m?$t(m.updated_at||m.created_at):0,k=u?$t(sn(u)??0):0,A=a.lastSeen?$t(a.lastSeen):0,w=((E=a.currentTask)==null?void 0:E.trim())||(r>0?`${r} claimed tasks`:null);if(p===0&&_===0&&$===0&&k===0&&A===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:w};const z=[c?{timestamp:c.timestamp,ts:p,text:ls(c.content)}:null,m?{timestamp:m.updated_at||m.created_at,ts:$,text:`Post: ${ls(Bc(m))}`}:null,u?{timestamp:sn(u),ts:k,text:Gc(u)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:_,text:ls(d.text)}:null].filter(I=>I!==null).sort((I,N)=>N.ts-I.ts)[0];return z&&z.ts>=A?{activeAssignedCount:r,lastActivityAt:z.timestamp,lastActivityText:z.text}:{activeAssignedCount:r,lastActivityAt:a.lastSeen??null,lastActivityText:w??"Presence heartbeat"}}const At=f([]),jt=f([]),Be=f([]),de=f([]),Fe=f(null),Vc=f(null),Za=f(new Map),ta=f([]),$n=f("hot"),De=f(!0),Ho=f(null),Gt=f(""),hn=f([]),Ee=f(!1),Wo=f(new Map),yi=f("unknown"),ks=f(null),ti=f(!1),yn=f(!1),ei=f(!1),ze=f(!1),bi=f(null),xs=f(!1),Ss=f(null),Bo=f(null),ni=f(null),Go=f(null),Jo=f(null),Yc=f(null);It(()=>At.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const Xc=It(()=>{const t=jt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),ea=It(()=>{const t=new Map,e=jt.value,n=Be.value,s=hs.value,a=ta.value,o=de.value;for(const r of At.value)t.set(r.name.trim().toLowerCase(),Jc(r.name,e,n,s,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:a,keepers:o}));return t});function Qc(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const Zc=It(()=>{const t=new Map;for(const e of de.value)t.set(e.name,Qc(e));return t}),td=12e4;function ed(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}const nd=It(()=>{const t=Date.now(),e=new Set,n=Za.value;for(const s of de.value){const a=ed(s,n);a!=null&&t-a>td&&e.add(s.name)}return e});let ma=null;function sd(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function ct(t){return typeof t=="object"&&t!==null}function y(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function C(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Dt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function si(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Vo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function ad(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function id(t){if(!ct(t))return null;const e=y(t.name);return e?{name:e,agent_type:y(t.agent_type),status:Vo(t.status),current_task:y(t.current_task)??null,joined_at:y(t.joined_at),last_seen:y(t.last_seen),capabilities:Dt(t.capabilities),emoji:y(t.emoji),koreanName:y(t.koreanName)??y(t.korean_name),model:y(t.model),traits:Dt(t.traits),interests:Dt(t.interests),activityLevel:C(t.activityLevel)??C(t.activity_level),primaryValue:y(t.primaryValue)??y(t.primary_value)}:null}function od(t){if(!ct(t))return null;const e=y(t.id),n=y(t.title);return!e||!n?null:{id:e,title:n,status:ad(t.status),priority:C(t.priority),assignee:y(t.assignee),description:y(t.description),created_at:y(t.created_at),updated_at:y(t.updated_at)}}function rd(t){if(!ct(t))return null;const e=y(t.from)??y(t.from_agent)??"system",n=y(t.content)??"",s=y(t.timestamp)??new Date().toISOString();return{id:y(t.id),seq:C(t.seq),from:e,content:n,timestamp:s,type:y(t.type)}}function Gi(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function ld(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>Gi(s)-Gi(a)).slice(-500)}function cd(t){return Array.isArray(t)?t.map(e=>{if(!ct(e))return null;const n=C(e.ts_unix);if(n==null)return null;const s=ct(e.handoff)?e.handoff:null;return{ts:n,context_ratio:C(e.context_ratio)??0,context_tokens:C(e.context_tokens)??0,context_max:C(e.context_max)??0,latency_ms:C(e.latency_ms)??0,generation:C(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:C(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:C(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?C(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Ji(t){if(!ct(t))return null;const e=y(t.health_state),n=y(t.next_action_path),s=y(t.last_reply_status);if(!e||!n||!s)return null;const a=y(t.quiet_reason)??null,o=y(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:si(t.last_reply_at)??y(t.last_reply_at)??null,last_reply_preview:y(t.last_reply_preview)??null,last_error:y(t.last_error)??null,next_eligible_at_s:C(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function dd(t,e){return(Array.isArray(t)?t:ct(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!ct(s))return null;const a=ct(s.agent)?s.agent:null,o=ct(s.context)?s.context:null,r=ct(s.metrics_window)?s.metrics_window:void 0,c=y(s.name);if(!c)return null;const d=C(s.context_ratio)??C(o==null?void 0:o.context_ratio),m=y(s.status)??y(a==null?void 0:a.status)??"offline",u=Vo(m),p=y(s.model)??y(s.active_model)??y(s.primary_model),_=Dt(s.skill_secondary),$=o?{source:y(o.source),context_ratio:C(o.context_ratio),context_tokens:C(o.context_tokens),context_max:C(o.context_max),message_count:C(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,k=a?{name:y(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:y(a.error),agent_type:y(a.agent_type),status:y(a.status),current_task:y(a.current_task)??null,joined_at:y(a.joined_at),last_seen:y(a.last_seen),last_seen_ago_s:C(a.last_seen_ago_s),capabilities:Dt(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,A=cd(s.metrics_series),w={name:c,emoji:y(s.emoji),koreanName:y(s.koreanName)??y(s.korean_name),agent_name:y(s.agent_name),trace_id:y(s.trace_id),model:p,primary_model:y(s.primary_model),active_model:y(s.active_model),next_model_hint:y(s.next_model_hint)??null,status:u,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:C(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:C(s.proactive_idle_sec),proactive_cooldown_sec:C(s.proactive_cooldown_sec),last_heartbeat:y(s.last_heartbeat)??y(a==null?void 0:a.last_seen),generation:C(s.generation),turn_count:C(s.turn_count)??C(s.total_turns),keeper_age_s:C(s.keeper_age_s),last_turn_ago_s:C(s.last_turn_ago_s),last_handoff_ago_s:C(s.last_handoff_ago_s),last_compaction_ago_s:C(s.last_compaction_ago_s),last_proactive_ago_s:C(s.last_proactive_ago_s),last_proactive_preview:y(s.last_proactive_preview)??null,context_ratio:d,context_tokens:C(s.context_tokens)??C(o==null?void 0:o.context_tokens),context_max:C(s.context_max)??C(o==null?void 0:o.context_max),context_source:y(s.context_source)??y(o==null?void 0:o.source),context:$,traits:Dt(s.traits),interests:Dt(s.interests),primaryValue:y(s.primaryValue)??y(s.primary_value),activityLevel:C(s.activityLevel)??C(s.activity_level),memory_recent_note:y(s.memory_recent_note)??null,recent_input_preview:y(s.recent_input_preview)??null,recent_output_preview:y(s.recent_output_preview)??null,recent_tool_names:Dt(s.recent_tool_names)??[],conversation_tail_count:C(s.conversation_tail_count),k2k_count:C(s.k2k_count),handoff_count_total:C(s.handoff_count_total)??C(s.trace_history_count),compaction_count:C(s.compaction_count),last_compaction_saved_tokens:C(s.last_compaction_saved_tokens),diagnostic:Ji(s.diagnostic),skill_primary:y(s.skill_primary)??null,skill_secondary:_,skill_reason:y(s.skill_reason)??null,metrics_series:A.length>0?A:void 0,metrics_window:r,agent:k};return w.diagnostic=Ji(s.diagnostic)??zc(w,(e==null?void 0:e.lodge)??null),w}).filter(s=>s!==null)}function Yo(t){return ct(t)?{...t,lodge:Mc(t.lodge)??void 0}:null}function ud(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function pd(t){if(!ct(t))return null;const e=C(t.iteration);if(e==null)return null;const n=C(t.metric_before)??0,s=C(t.metric_after)??n,a=ct(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:C(t.delta)??s-n,changes:y(t.changes)??"",failed_attempts:y(t.failed_attempts)??"",next_suggestion:y(t.next_suggestion)??"",elapsed_ms:C(t.elapsed_ms)??0,cost_usd:C(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:y(a.worker_model)??"",tool_call_count:C(a.tool_call_count)??0,tool_names:Dt(a.tool_names)??[],session_id:y(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function md(t){var o,r;if(!ct(t))return null;const e=y(t.loop_id);if(!e)return null;const n=C(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(pd).filter(c=>c!==null):[],a=C(t.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:y(t.profile)??"unknown",status:ud(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:y(t.error_message)??y(t.error_reason)??null,stop_reason:y(t.stop_reason)??y(t.reason)??null,current_iteration:C(t.current_iteration)??((r=s[0])==null?void 0:r.iteration)??0,max_iterations:C(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:y(t.target)??"",stagnation_streak:C(t.stagnation_streak)??0,stagnation_limit:C(t.stagnation_limit)??0,elapsed_seconds:C(t.elapsed_seconds)??0,updated_at:si(t.updated_at)??null,stopped_at:si(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:y(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:C(t.latest_tool_call_count)??0,latest_tool_names:Dt(t.latest_tool_names)??[],session_id:y(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function jn(){ti.value=!0;try{await Promise.all([Qo(),Ht()]),Bo.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{ti.value=!1}}async function Xo(){xs.value=!0,Ss.value=null;try{const t=await Dl();bi.value=t,Yc.value=new Date().toISOString()}catch(t){Ss.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{xs.value=!1}}function vd(t){var e;return((e=bi.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function _d(t){var n;const e=((n=bi.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(o=>o.id===t);if(a)return a}return null}function fd(t){var s,a;hn.value=(Array.isArray(t.goals)?t.goals:[]).map(o=>{if(!ct(o))return null;const r=y(o.id),c=y(o.title),d=y(o.horizon),m=y(o.status),u=y(o.created_at),p=y(o.updated_at);return!r||!c||!d||!m||!u||!p?null:{id:r,horizon:d,title:c,metric:y(o.metric)??null,target_value:y(o.target_value)??null,due_date:y(o.due_date)??null,priority:C(o.priority)??3,status:m,parent_goal_id:y(o.parent_goal_id)??null,last_review_note:y(o.last_review_note)??null,last_review_at:y(o.last_review_at)??null,created_at:u,updated_at:p}}).filter(o=>o!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const o of n){const r=md(o);r&&e.set(r.loop_id,r)}Wo.value=e,ks.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,yi.value=ks.value?"error":e.size===0?"idle":"ready"}async function Qo(){try{const t=await Rl(),e=Yo(t.status);e&&(Fe.value=e)}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Ht(){var t;try{const e=await Pl(),n=Yo(e.status),s=(t=Fe.value)==null?void 0:t.room;n&&(Fe.value=n);const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;At.value=(Array.isArray(e.agents)?e.agents:[]).map(id).filter(r=>r!==null),jt.value=(Array.isArray(e.tasks)?e.tasks:[]).map(od).filter(r=>r!==null);const o=(Array.isArray(e.messages)?e.messages:[]).map(rd).filter(r=>r!==null);Be.value=a?o:ld(Be.value,o),de.value=dd(e.keepers,n??Fe.value),Vc.value=null,Bo.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function Ot(){yn.value=!0;try{const t=await Ll($n.value,{excludeSystem:De.value});ta.value=t.posts??[],ni.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{yn.value=!1}}async function Ft(){var t;ei.value=!0;try{const e=Gt.value||((t=Fe.value)==null?void 0:t.room)||"default";Gt.value||(Gt.value=e);const n=await mc(e);Ho.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{ei.value=!1}}async function Ge(){Ee.value=!0,ze.value=!0;try{const t=await zl();fd(t),Go.value=new Date().toISOString(),Jo.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),yi.value="error",ks.value=t instanceof Error?t.message:String(t)}finally{Ee.value=!1,ze.value=!1}}async function ai(){return Ge()}let cs=null;function gd(t){cs=t}let ds=null;function $d(t){ds=t}let us=null;function hd(t){us=t}const ye={};function $e(t,e,n=500){ye[t]&&clearTimeout(ye[t]),ye[t]=setTimeout(()=>{e(),delete ye[t]},n)}function yd(){const t=Ro.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Za.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Za.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&$e("execution",Ht),sd(e.type)&&(ma||(ma=setTimeout(()=>{jn(),ds==null||ds(),us==null||us(),ma=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&$e("execution",Ht),e.type==="broadcast"&&$e("execution",Ht),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&$e("execution",Ht),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&$e("board",Ot),e.type.startsWith("decision_")&&$e("council",()=>cs==null?void 0:cs()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&$e("mdal",ai,350)}});return()=>{t();for(const e of Object.keys(ye))clearTimeout(ye[e]),delete ye[e]}}let dn=null;function bd(){dn||(dn=setInterval(()=>{re.value,jn()},1e4))}function kd(){dn&&(clearInterval(dn),dn=null)}function xd({metric:t}){return i`
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
  `}function Sd({panel:t}){return i`
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
            ${t.metrics.map(e=>i`<${xd} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function D({panelId:t,compact:e=!1,label:n="Why"}){const s=_d(t);return s?i`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${Sd} panel=${s} />
    </details>
  `:xs.value?i`<span class="semantic-inline-state">Loading semantics…</span>`:null}function xt({surfaceId:t,compact:e=!1}){const n=vd(t);return n?i`
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
  `:xs.value?i`<div class="semantic-surface-card ${e?"compact":""}">Loading semantics…</div>`:Ss.value?i`<div class="semantic-surface-card ${e?"compact":""}">${Ss.value}</div>`:null}function T({title:t,class:e,semanticId:n,children:s}){return i`
    <div class="card ${e??""}">
      ${t?i`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?i`<${D} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${s}
    </div>
  `}const na=f(null),ii=f(!1),As=f(null);function U(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function R(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function B(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function ki(t){return typeof t=="boolean"?t:void 0}function Wt(t,e=[]){if(Array.isArray(t))return t;if(!U(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function sa(t){if(!U(t))return null;const e=R(t.kind),n=R(t.summary),s=R(t.target_type);return!e||!n||!s?null:{kind:e,severity:R(t.severity)??"warn",summary:n,target_type:s,target_id:R(t.target_id)??null,actor:R(t.actor)??null,evidence:t.evidence}}function aa(t){if(!U(t))return null;const e=R(t.action_type),n=R(t.target_type),s=R(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:R(t.target_id)??null,severity:R(t.severity)??"warn",reason:s,confirm_required:ki(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Ad(t){if(!U(t))return null;const e=R(t.session_id);return e?{session_id:e,goal:R(t.goal),status:R(t.status),health:R(t.health),scale_profile:R(t.scale_profile),control_profile:R(t.control_profile),planned_worker_count:B(t.planned_worker_count),active_agent_count:B(t.active_agent_count),last_turn_age_sec:B(t.last_turn_age_sec)??null,attention_count:B(t.attention_count),recommended_action_count:B(t.recommended_action_count),top_attention:sa(t.top_attention),top_recommendation:aa(t.top_recommendation)}:null}function Cd(t){if(!U(t))return null;const e=R(t.session_id);if(!e)return null;const n=U(t.status)?t.status:t,s=U(n.summary)?n.summary:void 0;return{session_id:e,status:R(t.status)??R(s==null?void 0:s.status)??(U(n.session)?R(n.session.status):void 0),progress_pct:B(t.progress_pct)??B(s==null?void 0:s.progress_pct),elapsed_sec:B(t.elapsed_sec)??B(s==null?void 0:s.elapsed_sec),remaining_sec:B(t.remaining_sec)??B(s==null?void 0:s.remaining_sec),done_delta_total:B(t.done_delta_total)??B(s==null?void 0:s.done_delta_total),summary:U(t.summary)?t.summary:s,team_health:U(t.team_health)?t.team_health:U(n.team_health)?n.team_health:void 0,communication_metrics:U(t.communication_metrics)?t.communication_metrics:U(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:U(t.orchestration_state)?t.orchestration_state:U(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:U(t.cascade_metrics)?t.cascade_metrics:U(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:U(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,o])=>{const r=R(o);return r?[a,r]:null}).filter(a=>a!==null)):U(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const r=R(o);return r?[a,r]:null}).filter(a=>a!==null)):void 0,session:U(t.session)?t.session:U(n.session)?n.session:void 0,recent_events:Wt(t.recent_events,["events"]).filter(U)}}function wd(t){if(!U(t))return null;const e=R(t.name);return e?{name:e,agent_name:R(t.agent_name),status:R(t.status),autonomy_level:R(t.autonomy_level),context_ratio:B(t.context_ratio),generation:B(t.generation),active_goal_ids:Wt(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:R(t.last_autonomous_action_at)??null,last_turn_ago_s:B(t.last_turn_ago_s),model:R(t.model)}:null}function Td(t){if(!U(t))return null;const e=R(t.confirm_token)??R(t.token);return e?{confirm_token:e,actor:R(t.actor),action_type:R(t.action_type),target_type:R(t.target_type),target_id:R(t.target_id)??null,delegated_tool:R(t.delegated_tool),created_at:R(t.created_at),preview:t.preview}:null}function Id(t){if(!U(t))return null;const e=R(t.action_type),n=R(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:R(t.description),confirm_required:ki(t.confirm_required)}}function Nd(t){const e=U(t)?t:{};return{room_health:R(e.room_health),cluster:R(e.cluster),project:R(e.project),current_room:R(e.current_room)??null,paused:ki(e.paused),tempo_interval_s:B(e.tempo_interval_s),active_agents:B(e.active_agents),keeper_pressure:B(e.keeper_pressure),active_operations:B(e.active_operations),pending_approvals:B(e.pending_approvals),incident_count:B(e.incident_count),recommended_action_count:B(e.recommended_action_count),top_attention:sa(e.top_attention),top_action:aa(e.top_action)}}function Rd(t){const e=U(t)?t:{},n=U(e.swarm_overview)?e.swarm_overview:{};return{health:R(e.health),active_operations:B(e.active_operations),pending_approvals:B(e.pending_approvals),swarm_overview:{active_lanes:B(n.active_lanes),moving_lanes:B(n.moving_lanes),stalled_lanes:B(n.stalled_lanes),projected_lanes:B(n.projected_lanes),last_movement_at:R(n.last_movement_at)??null},top_attention:sa(e.top_attention),top_action:aa(e.top_action),session_cards:Wt(e.session_cards).map(Ad).filter(s=>s!==null)}}function Pd(t){const e=U(t)?t:{};return{sessions:Wt(e.sessions,["items"]).map(Cd).filter(n=>n!==null),keepers:Wt(e.keepers,["items"]).map(wd).filter(n=>n!==null),pending_confirms:Wt(e.pending_confirms).map(Td).filter(n=>n!==null),available_actions:Wt(e.available_actions).map(Id).filter(n=>n!==null)}}function Ld(t){const e=U(t)?t:{};return{generated_at:R(e.generated_at),summary:Nd(e.summary),incidents:Wt(e.incidents).map(sa).filter(n=>n!==null),recommended_actions:Wt(e.recommended_actions).map(aa).filter(n=>n!==null),command_focus:Rd(e.command_focus),operator_targets:Pd(e.operator_targets)}}async function ps(){ii.value=!0,As.value=null;try{const t=await El();na.value=Ld(t)}catch(t){As.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{ii.value=!1}}function ue({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Zo(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const o=Math.floor(a/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function it({timestamp:t}){const e=Zo(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return i`<span class="time-ago" title=${n}>${e}</span>`}let Md=0;const be=f([]);function P(t,e="success",n=4e3){const s=++Md;be.value=[...be.value,{id:s,message:t,type:e}],setTimeout(()=>{be.value=be.value.filter(a=>a.id!==s)},n)}function Dd(t){be.value=be.value.filter(e=>e.id!==t)}function Ed(){const t=be.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Dd(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const zd="masc_dashboard_agent_name",Qe=f(null),Cs=f(!1),bn=f(""),ws=f([]),kn=f([]),qe=f(""),un=f(!1);function ia(t){Qe.value=t,xi()}function Vi(){Qe.value=null,bn.value="",ws.value=[],kn.value=[],qe.value=""}function jd(){const t=Qe.value;return t?At.value.find(e=>e.name===t)??null:null}function tr(t){return t?jt.value.filter(e=>e.assignee===t):[]}async function xi(){const t=Qe.value;if(t){Cs.value=!0,bn.value="",ws.value=[],kn.value=[];try{const e=await xc(80);ws.value=e.filter(a=>a.includes(t)).slice(0,20);const n=tr(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await Sc(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const r=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));kn.value=s}catch(e){bn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Cs.value=!1}}}async function Yi(){var s;const t=Qe.value,e=qe.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(zd))==null?void 0:s.trim())||"dashboard";un.value=!0;try{await kc(n,`@${t} ${e}`),qe.value="",P(`Mention sent to ${t}`,"success"),xi()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";P(o,"error")}finally{un.value=!1}}function Od({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${ue} status=${t.status} />
    </div>
  `}function Fd({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function qd(){var a,o,r,c;const t=Qe.value;if(!t)return null;const e=jd(),n=tr(t),s=ws.value;return i`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&Vi()}}
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
                        <${ue} status=${e.status} />
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
            ${(((a=e==null?void 0:e.traits)==null?void 0:a.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(o=e==null?void 0:e.traits)==null?void 0:o.map(d=>i`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(c=e==null?void 0:e.interests)==null?void 0:c.map(d=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?i`
                    ${e.current_task?i`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?i`<span>Last seen: <${it} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{xi()}} disabled=${Cs.value}>
              ${Cs.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Vi}>Close</button>
          </div>
        </div>

        ${bn.value?i`<div class="council-error">${bn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${T} title="Assigned Tasks">
            ${n.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${n.map(d=>i`<${Od} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${T} title="Recent Activity">
            ${s.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${s.map((d,m)=>i`<div key=${m} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${T} title="Task History">
          ${kn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${kn.value.map(d=>i`<${Fd} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${T} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${qe.value}
              onInput=${d=>{qe.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&Yi()}}
              disabled=${un.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Yi()}}
              disabled=${un.value||qe.value.trim()===""}
            >
              ${un.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function Kd(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Ud(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Hd(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Xi(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function er(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Wd(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function nr(t){if(!t)return null;const e=Jt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function Bd({keeper:t,showRawStatus:e=!1}){if(rt(()=>{t!=null&&t.name&&Uo(t.name)},[t==null?void 0:t.name]),!t)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Jt.value[t.name],s=nr(t),a=Ga.value[t.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${Kd(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Ud((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?i` · ${er(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?i` · next eligible ${Wd(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Gd({keeperName:t,placeholder:e}){const[n,s]=wo("");rt(()=>{t&&Uo(t)},[t]);const a=vt.value[t]??[],o=Ja.value[t]??!1,r=Vt.value[t],c=async()=>{const d=n.trim();if(!(!t||!d)){s("");try{await Uc(t,d)}catch(m){const u=m instanceof Error?m.message:`Failed to message ${t}`;P(u,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(d=>i`
              <div class="keeper-conversation-item" key=${d.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Xi(d)}`}>${d.label}</span>
                  <span class=${`keeper-role-chip ${Xi(d)}`}>${Hd(d)}</span>
                  ${d.timestamp?i`<span class="keeper-conversation-time">${er(d.timestamp)}</span>`:null}
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
  `}function Jd({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=nr(e),a=Va.value[e.name]??!1,o=Ya.value[e.name]??!1,r=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??r==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{Hc(e.name,t).catch(d=>{const m=d instanceof Error?d.message:`Failed to probe ${e.name}`;P(m,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{Wc(e.name,t).catch(d=>{const m=d instanceof Error?d.message:`Failed to recover ${e.name}`;P(m,"error")})}}
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
  `}const Si=f(null);function Ai(t){Si.value=t,Kc(t.name)}function Qi(){Si.value=null}const Pe=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Vd(t){if(!t)return 0;const e=Pe.findIndex(n=>n.level===t);return e>=0?e:0}function Yd({keeper:t}){const e=Vd(t.autonomy_level),n=Pe[e]??Pe[0];if(!n)return null;const s=(e+1)/Pe.length*100;return i`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${Pe.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Pe.map((a,o)=>i`
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
  `}function ms(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Xd({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${ms(t.context_tokens)}</div>
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
  `}function Qd({keeper:t}){var u,p;const e=t.metrics_series??[];if(e.length<2){const _=(((u=t.context)==null?void 0:u.context_ratio)??0)*100,$=_>85?"#ef4444":_>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${_.toFixed(1)}%;background:${$}"></div>
        </div>
        <span class="chart-pct">${_.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=e.length,r=e.map((_,$)=>{const k=a+$/(o-1)*(n-2*a),A=s-a-(_.context_ratio??0)*(s-2*a);return{x:k,y:A,p:_}}),c=r.map(({x:_,y:$})=>`${_.toFixed(1)},${$.toFixed(1)}`).join(" "),d=(((p=e[e.length-1])==null?void 0:p.context_ratio)??0)*100,m=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:_})=>_.is_handoff).map(({x:_})=>i`
          <line x1="${_.toFixed(1)}" y1="${a}" x2="${_.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${m}" stroke-width="1.5"/>
        ${r.filter(({p:_})=>_.is_compaction).map(({x:_,y:$})=>i`
          <circle cx="${_.toFixed(1)}" cy="${$.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const va=f("");function Zd({keeper:t}){var a,o,r,c;const e=va.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${va.value}
        onInput=${d=>{va.value=d.target.value}}
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
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${ms(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${ms(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${ms(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function tu({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
  `}function eu({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function nu({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Zi({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function _a(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function su({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:_a(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:_a(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:_a(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(s=>i`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function sr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function au(){try{const t=await Qs({actor:sr(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Ko(t.result);await jn(),e!=null&&e.skipped_reason?P(e.skipped_reason,"warning"):P(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";P(e,"error")}}function iu({keeper:t}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Bd} keeper=${t} />
          <${Jd}
            actor=${sr()}
            keeper=${t}
            onPokeLodge=${()=>{au()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Gd}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function ou(){var e,n,s;const t=Si.value;return t?i`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Qi()}}
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
            <${ue} status=${t.status} />
            ${t.model?i`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Qi()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Xd} keeper=${t} />

        ${""}
        <${Qd} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${T} title="Field Dictionary">
            <${Zd} keeper=${t} />
          <//>

          ${""}
          <${T} title="Profile">
            <${Zi} traits=${t.traits??[]} label="Traits" />
            <${Zi} traits=${t.interests??[]} label="Interests" />
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
              <${T} title="Autonomy">
                <${Yd} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?i`
              <${T} title="TRPG Stats">
                <${tu} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${T} title="Equipment (${t.inventory.length})">
                <${eu} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${T} title="Relationships (${Object.keys(t.relationships).length})">
                <${nu} rels=${t.relationships} />
              <//>
            `:null}

          <${T} title="Runtime Signals">
            <${su} keeper=${t} />
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
        <${iu} keeper=${t} />
      </div>
    </div>
  `:null}const Ts="masc_dashboard_workflow_context",ru=900*1e3;function Ci(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function wt(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function Zt(t){const e=wt(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function ar(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function oi(t){return Ci(t)?t:null}function lu(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function cu(t){if(!t)return null;try{const e=JSON.parse(t);if(!Ci(e))return null;const n=wt(e.id),s=wt(e.source_surface),a=wt(e.source_label),o=wt(e.summary),r=wt(e.created_at);return!n||s!=="mission"||!a||!o||!r?null:{id:n,source_surface:"mission",source_label:a,action_type:wt(e.action_type),target_type:wt(e.target_type),target_id:wt(e.target_id),focus_kind:wt(e.focus_kind),summary:o,payload_preview:wt(e.payload_preview),suggested_payload:oi(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:r}}catch{return null}}function wi(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=ru}function du(){const t=ar(),e=cu((t==null?void 0:t.getItem(Ts))??null);return e?wi(e)?e:(t==null||t.removeItem(Ts),null):null}const ir=f(du());function uu(t){const e=t&&wi(t)?t:null;ir.value=e;const n=ar();if(!n)return;if(!e){n.removeItem(Ts);return}const s=lu(e);s&&n.setItem(Ts,s)}function or(t){if(!t)return null;const e=oi(t.suggested_payload);if(e)return e;if(Ci(t.preview)){const n=oi(t.preview.payload);if(n)return n}return null}function rr(t){if(!t)return null;const e=Zt(t.message);if(e)return e;const n=Zt(t.task_title)??Zt(t.title),s=Zt(t.task_description)??Zt(t.description),a=Zt(t.reason),o=Zt(t.priority)??Zt(t.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function lr(t,e,n,s,a,o){return["mission",t,e??"action",n??"target",s??"room",a??"focus",o].join(":")}function Ze(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=or(t),o=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,r=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,c=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,d=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:lr(n,(t==null?void 0:t.action_type)??null,o,r,c,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:o,target_id:r,focus_kind:c,summary:d,payload_preview:rr(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function pu(t,e){return e.source==="mission"&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)}function On(t){const{params:e}=t;if(e.source!=="mission")return null;const n=ir.value;if(n&&wi(n)&&pu(n,e))return n;const s=new Date().toISOString();return{id:lr("상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,s),source_surface:"mission",source_label:"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,summary:e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function mu(t){return{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function cr(t){const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.target_type==="room"?"summary":"swarm"}function vu(t){return{source:"mission",surface:cr(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function Ti(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function Ii(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";default:return(t==null?void 0:t.trim())||"추천 액션"}}function _u(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}function yt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function mt(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function xn(t){return typeof t=="number"&&Number.isFinite(t)?t:null}function fa(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function nt(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function St(t){return t==="bad"||t==="offline"||t==="critical"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"?"warn":"ok"}function Ae(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:n<86400?`${Math.round(n/3600)}h 전`:`${Math.round(n/86400)}d 전`}function fu(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:t<86400?`${Math.round(t/3600)}h`:`${Math.round(t/86400)}d`}function to(t){const e=xn(t.ts);if(e!=null)return e;const n=mt(t.ts_iso);if(!n)return 0;const s=Date.parse(n);return Number.isNaN(s)?0:s}function gu(t){return[...new Set(t.filter(Boolean))]}function $u(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function hu(t){return rr(or(t))}function yu(t){return Ti(t?Ze(t,null,"상황판 추천 액션"):null)}function oa(t,e=Ze()){uu(e),gt(t,t==="intervene"?mu(e):vu(e))}function bu(t){oa("intervene",Ze(null,t,"상황판 incident"))}function ku(t){oa("command",Ze(null,t,"상황판 incident"))}function xu(t,e,n="상황판 추천 액션"){oa("intervene",Ze(t,e,n))}function Su(t,e,n="상황판 추천 액션"){oa("command",Ze(t,e,n))}function eo(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),gt(t,n)}function dr(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>(s.from??"").trim().toLowerCase()===n).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function Au(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>{if((s.from??"").trim().toLowerCase()===n)return!1;const o=(s.content??"").trim().toLowerCase();return o.includes(`@${n}`)||o.includes(n)}).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function Cu(t){const e=yt(t.session)?t.session:{},n=yt(t.summary)?t.summary:{};return gu([...fa(e.agent_names),...fa(n.active_agents),...fa(n.planned_participants)])}function wu(t){const e=yt(t.session)?t.session:{};return mt(e.goal)??mt(e.session_id)??t.session_id}function Tu(t){const e=yt(t.session)?t.session:{};return mt(e.room_id)}function Iu(t){const e=yt(t.session)?t.session:{};return mt(e.created_at_iso)}function Nu(t){const e=yt(t.session)?t.session:{};return mt(e.updated_at_iso)}function Ru(t){const e=yt(t.communication_metrics)?t.communication_metrics:{};return mt(e.mode)}function Pu(t){const e=yt(t.communication_metrics)?t.communication_metrics:{};return xn(e.broadcast_count)??0}function Lu(t){const e=yt(t.communication_metrics)?t.communication_metrics:{};return xn(e.portal_count)??0}function Mu(t){const e=yt(t.team_health)?t.team_health:{};return{active:xn(e.active_agents_count)??0,required:xn(e.required_agents)??0}}function Du(t){const n=[...t.recent_events??[]].sort((u,p)=>to(p)-to(u))[0];if(!n)return{at:null,summary:"최근 session event가 없습니다."};const s=yt(n.detail)?n.detail:{},a=mt(n.event_type)??"event",o=mt(s.actor),r=mt(s.task_title)??mt(s.title),c=nt(mt(s.result),120),d=nt(mt(s.reason),120),m=r?`${o?`${o} · `:""}${r}`:c??d??a.replace(/_/g," ");return{at:mt(n.ts_iso),summary:m}}function Eu(){const t=na.value;return t?t.operator_targets.sessions.map(e=>{var o,r;const n=Mu(e),s=Du(e),a=t.command_focus.session_cards.find(c=>c.session_id===e.session_id);return{session:e,goal:wu(e),room:Tu(e),status:e.status??"unknown",memberNames:Cu(e),startedAt:Iu(e),stoppedAt:Nu(e),elapsedSec:e.elapsed_sec??null,lastEventAt:s.at,lastEventSummary:s.summary,communicationMode:Ru(e),broadcastCount:Pu(e),portalCount:Lu(e),activeCount:n.active,requiredCount:n.required,attentionSummary:((o=a==null?void 0:a.top_attention)==null?void 0:o.summary)??((r=a==null?void 0:a.top_recommendation)==null?void 0:r.reason)??null}}).sort((e,n)=>{const s=Date.parse(e.lastEventAt??e.startedAt??"")||0;return(Date.parse(n.lastEventAt??n.startedAt??"")||0)-s}):[]}function ur(t){if(t.recent_tool_names&&t.recent_tool_names.length>0)return t.recent_tool_names;const e=yt(t.metrics_window)?t.metrics_window:{};return(Array.isArray(e.top_tools)?e.top_tools:[]).map(s=>yt(s)?mt(s.tool):null).filter(s=>s!==null)}function zu(t){return de.value.find(e=>e.agent_name===t||e.name===t)??null}function pr(t,e){const n=nt(t.current_task,100);if(!n)return"명시된 current task 없음";const s=e.find(o=>o.id===n);if(s)return`${s.id} · ${nt(s.title,92)}`;const a=e.find(o=>o.title===n);return a?`${a.id} · ${nt(a.title,92)}`:n}function ju(t){const e=new Map;for(const n of t)for(const s of n.memberNames)e.has(s)||e.set(s,n);return[...At.value].map(n=>{var _,$;const s=e.get(n.name),a=zu(n.name),o=dr(n.name,Be.value),r=Au(n.name,Be.value),c=ea.value.get(n.name.trim().toLowerCase()),d=s?s.memberNames.filter(k=>k!==n.name):[],m=s?`${s.goal}${s.room?` · ${s.room}`:""}`:((_=na.value)==null?void 0:_.summary.current_room)??"room",u=(a==null?void 0:a.skill_primary)??(n.capabilities&&n.capabilities.length>0?n.capabilities.slice(0,3).join(", "):null)??n.agent_type??null,p=pr(n,jt.value);return{agent:n,where:m,withWhom:d,activeSince:(s==null?void 0:s.startedAt)??n.joined_at??n.last_seen??null,currentWork:p,how:u,recentInput:nt(r==null?void 0:r.content,120)??nt(a==null?void 0:a.recent_input_preview,120)??null,recentOutput:nt(o==null?void 0:o.content,120)??nt(a==null?void 0:a.recent_output_preview,120)??nt(($=a==null?void 0:a.diagnostic)==null?void 0:$.last_reply_preview,120)??null,recentEvent:nt(c==null?void 0:c.lastActivityText,120)??(s==null?void 0:s.lastEventSummary)??null,recentTools:a?ur(a):[]}}).sort((n,s)=>{const a=d=>d==="busy"?4:d==="active"?3:d==="listening"?2:d==="idle"?1:0,o=a(s.agent.status)-a(n.agent.status);if(o!==0)return o;const r=Date.parse(n.agent.last_seen??n.activeSince??"")||0;return(Date.parse(s.agent.last_seen??s.activeSince??"")||0)-r})}function Ou(){return[...de.value].map(t=>{var e,n,s,a;return{keeper:t,activeSince:((e=t.agent)==null?void 0:e.joined_at)??t.created_at??t.last_heartbeat??null,currentWork:nt((n=t.agent)==null?void 0:n.current_task,110)??nt(t.skill_primary,110)??nt(t.last_proactive_reason,110)??"명시된 keeper focus 없음",recentInput:nt(t.recent_input_preview,120)??null,recentOutput:nt(t.recent_output_preview,120)??nt((s=t.diagnostic)==null?void 0:s.last_reply_preview,120)??nt(t.last_proactive_preview,120)??null,recentEvent:nt(t.last_proactive_reason,120)??nt((a=t.diagnostic)==null?void 0:a.summary,120)??null,recentTools:ur(t)}}).sort((t,e)=>{const n=Date.parse(t.keeper.last_heartbeat??t.activeSince??"")||0;return(Date.parse(e.keeper.last_heartbeat??e.activeSince??"")||0)-n})}function Fu({cluster:t,project:e,room:n,generatedAt:s}){return i`
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
        <strong>${s?Ae(s):"fresh"}</strong>
      </div>
    </div>
  `}function Ne({label:t,value:e,detail:n,tone:s}){return i`
    <article class="mission-stat-card ${St(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function qu({row:t}){const e=t.memberNames.slice(0,4).map(n=>{const s=At.value.find(o=>o.name===n),a=dr(n,Be.value);return{name:n,currentTask:s?pr(s,jt.value):"agent snapshot 없음",output:nt(a==null?void 0:a.content,96)}});return i`
    <article class="mission-crew-card ${St(t.status)}">
      <div class="mission-card-head">
        <div>
          <strong>${t.goal}</strong>
          <div class="mission-card-target">${t.session.session_id}${t.room?` · ${t.room}`:""}</div>
        </div>
        <span class="command-chip ${St(t.status)}">${t.status}</span>
      </div>

      <div class="mission-fact-grid">
        <div class="mission-fact-tile">
          <span>멤버</span>
          <strong>${t.memberNames.length}</strong>
          <small>${t.memberNames.slice(0,3).join(", ")||"n/a"}</small>
        </div>
        <div class="mission-fact-tile">
          <span>가동 시간</span>
          <strong>${fu(t.elapsedSec)}</strong>
          <small>${t.startedAt?`${Ae(t.startedAt)} 시작`:"시작 시각 없음"}</small>
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
        <small>${t.lastEventAt?Ae(t.lastEventAt):"시각 없음"}</small>
      </div>

      ${e.length>0?i`
            <div class="mission-member-stack">
              ${e.map(n=>i`
                <button class="mission-member-row" onClick=${()=>ia(n.name)}>
                  <strong>${n.name}</strong>
                  <span>${n.currentTask}</span>
                  <small>${n.output??"최근 출력 없음"}</small>
                </button>
              `)}
            </div>
          `:null}

      ${t.attentionSummary?i`<div class="mission-inline-note">attention: ${t.attentionSummary}</div>`:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>eo("intervene",t.session.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>eo("command",t.session.session_id)}>세션 원인 보기</button>
      </div>
    </article>
  `}function Ku({row:t}){const e=t.recentTools.length>0?t.recentTools.join(", "):"도구 텔레메트리 없음",n=t.withWhom.length>0?t.withWhom.slice(0,3).join(", "):"단독 또는 room-level";return i`
    <button class="mission-activity-card ${St(t.agent.status)}" onClick=${()=>ia(t.agent.name)}>
      <div class="mission-activity-head">
        <div class="mission-activity-title">
          <span class="agent-emoji">${t.agent.emoji??""}</span>
          <div>
            <strong>${t.agent.name}</strong>
            ${t.agent.koreanName?i`<span>${t.agent.koreanName}</span>`:null}
          </div>
        </div>
        <span class="command-chip ${St(t.agent.status)}">${t.agent.status}</span>
      </div>

      <div class="mission-activity-meta">
        <span>어디서 · ${t.where}</span>
        <span>누구와 · ${n}</span>
        <span>언제부터 · ${t.activeSince?Ae(t.activeSince):"n/a"}</span>
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
  `}function Uu({row:t}){const e=[`gen ${t.keeper.generation??0}`,`handoff ${t.keeper.handoff_count_total??0}`,`compact ${t.keeper.compaction_count??0}`,t.keeper.context_ratio!=null?`ctx ${Math.round(t.keeper.context_ratio*100)}%`:null].filter(n=>n!==null).join(" · ");return i`
    <button class="mission-activity-card ${St(t.keeper.status)}" onClick=${()=>Ai(t.keeper)}>
      <div class="mission-activity-head">
        <div class="mission-activity-title">
          <span class="agent-emoji">${t.keeper.emoji??""}</span>
          <div>
            <strong>${t.keeper.name}</strong>
            ${t.keeper.koreanName?i`<span>${t.keeper.koreanName}</span>`:null}
          </div>
        </div>
        <span class="command-chip ${St(t.keeper.status)}">${t.keeper.status}</span>
      </div>

      <div class="mission-activity-meta">
        <span>언제부터 · ${t.activeSince?Ae(t.activeSince):"n/a"}</span>
        <span>최근 heartbeat · ${t.keeper.last_heartbeat?Ae(t.keeper.last_heartbeat):"n/a"}</span>
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
  `}function Hu({item:t}){return i`
    <article class="mission-action-card ${St(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${St(t.severity)}">${t.kind}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>bu(t)}>이 이슈로 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>ku(t)}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `}function Wu({action:t,incident:e}){const n=hu(t);return i`
    <article class="mission-action-card ${St(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${St(t.severity)}">${Ii(t.action_type)}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.reason}</p>
      <div class="mission-action-detail">
        <span>${$u(t)}</span>
        <span>${yu(t)}</span>
      </div>
      ${n?i`<div class="mission-action-preview">${n}</div>`:null}
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>xu(t,e,"상황판 추천 액션")}>이 액션으로 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Su(t,e,"상황판 추천 액션")}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `}function no(){const t=na.value;if(ii.value&&!t)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(As.value&&!t)return i`<div class="empty-state error">${As.value}</div>`;if(!t)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;const e=Eu(),n=ju(e),s=Ou(),a=n.filter(d=>["active","busy","listening","idle"].includes(d.agent.status)).length,o=n.filter(d=>d.recentOutput).length+s.filter(d=>d.recentOutput).length,r=t.incidents[0]??null,c=t.recommended_actions[0]??null;return i`
    <section class="dashboard-panel mission-view">
      <${xt} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>사람 운영자가 누가 어디서 누구와 무엇을 하고 있는지 바로 보는 관찰면입니다. 내부 메트릭은 아래가 아니라 Command로 내렸습니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${St(t.summary.room_health)}">${t.summary.room_health??"ok"}</span>
          <span class="command-chip">${t.summary.project??"room"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?Ae(t.generated_at):"fresh"}</span>
        </div>
      </div>

      <${Fu}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <div class="mission-stat-grid">
        <${Ne} label="활성 흐름" value=${e.length} detail="지금 보이는 crew / session" tone=${e.length>0?"ok":"warn"} />
        <${Ne} label="응답 가능 에이전트" value=${a} detail="지금 응답 가능한 actor 수" tone=${a>0?"ok":"warn"} />
        <${Ne} label="Keeper 수" value=${s.length} detail="연속성 runtime / generation 관찰 대상" tone=${s.length>0?"ok":"warn"} />
        <${Ne} label="최근 output" value=${o} detail="main 화면에서 바로 볼 수 있는 최근 출력 수" tone=${o>0?"ok":"warn"} />
        <${Ne} label="내부 incident" value=${t.incidents.length} detail="시스템 진단 신호는 아래 보조 카드로만 유지" tone=${(r==null?void 0:r.severity)??"ok"} />
        <${Ne} label="추천 액션" value=${t.recommended_actions.length} detail="개입이 필요하면 Intervene로 바로 이동" tone=${(c==null?void 0:c.severity)??"ok"} />
      </div>

      <div class="mission-human-grid">
        <${T} title="같이 움직이는 흐름" class="mission-list-card" semanticId="mission.crews">
          <div class="mission-section-head">
            <h3>누가 누구와 같은 목표를 향하는지</h3>
            <p>team session 단위로 목표, 멤버, 최근 사건, 커뮤니케이션 흔적을 바로 보여줍니다.</p>
          </div>
          <div class="mission-list-stack">
            ${e.length>0?e.map(d=>i`<${qu} key=${d.session.session_id} row=${d} />`):i`<div class="empty-state">지금 열려 있는 crew / session 이 없습니다.</div>`}
          </div>
        <//>

        <${T} title="에이전트 활동" class="mission-list-card" semanticId="mission.agent_activity">
          <div class="mission-section-head">
            <h3>각 에이전트가 지금 뭘 하는가</h3>
            <p>where / with whom / current task / recent input-output / recent tools 를 preview-first로 보여줍니다.</p>
          </div>
          <div class="mission-activity-list">
            ${n.length>0?n.slice(0,10).map(d=>i`<${Ku} key=${d.agent.name} row=${d} />`):i`<div class="empty-state">지금 보이는 에이전트 활동이 없습니다.</div>`}
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
            ${s.length>0?s.slice(0,8).map(d=>i`<${Uu} key=${d.keeper.name} row=${d} />`):i`<div class="empty-state">지금 보이는 keeper 가 없습니다.</div>`}
          </div>
        <//>

        <${T} title="내부 진단은 여기서만" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>internal signal / recommendation</h3>
            <p>artifact_scope_drift 같은 시스템 진단은 메인 판단 근거가 아니라 보조 신호로만 유지합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${t.incidents.slice(0,2).map(d=>i`<${Hu} key=${`${d.kind}:${d.target_id??"room"}`} item=${d} />`)}
            ${t.recommended_actions.slice(0,2).map(d=>i`<${Wu} key=${`${d.action_type}:${d.target_id??"room"}`} action=${d} />`)}
            ${t.incidents.length===0&&t.recommended_actions.length===0?i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`:null}
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>gt("execution")}>실행 관찰면 보기</button>
            <button class="control-btn ghost" onClick=${()=>gt("command")}>지휘 진단면 보기</button>
          </div>
        <//>
      </div>
    </section>
  `}const Bu="modulepreload",Gu=function(t){return"/dashboard/"+t},so={},Ju=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let r=function(m){return Promise.all(m.map(u=>Promise.resolve(u).then(p=>({status:"fulfilled",value:p}),p=>({status:"rejected",reason:p}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),d=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=r(n.map(m=>{if(m=Gu(m),m in so)return;so[m]=!0;const u=m.endsWith(".css"),p=u?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${m}"]${p}`))return;const _=document.createElement("link");if(_.rel=u?"stylesheet":Bu,u||(_.as="script"),_.crossOrigin="",_.href=m,d&&_.setAttribute("nonce",d),document.head.appendChild(_),u)return new Promise(($,k)=>{_.addEventListener("load",$),_.addEventListener("error",()=>k(new Error(`Unable to preload CSS for ${m}`)))})}))}function o(r){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=r,window.dispatchEvent(c),!c.defaultPrevented)throw r}return a.then(r=>{for(const c of r||[])c.status==="rejected"&&o(c.reason);return e().catch(o)})},pe=f(null),mr=f(null),qt=f(null),Sn=f(!1),le=f(null),An=f(!1),Je=f(null),Q=f(!1),Is=f([]);let Vu=1;function H(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function x(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function at(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function ra(t){return typeof t=="boolean"?t:void 0}function Yu(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Et(t,e=[]){if(Array.isArray(t))return t;if(!H(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Xu(t){return H(t)?{id:x(t.id),seq:at(t.seq),from:x(t.from)??x(t.from_agent)??"system",content:x(t.content)??"",timestamp:x(t.timestamp)??new Date().toISOString(),type:x(t.type)}:null}function Qu(t){return H(t)?{room_id:x(t.room_id),current_room:x(t.current_room)??x(t.room),project:x(t.project),cluster:x(t.cluster),paused:ra(t.paused),pause_reason:x(t.pause_reason)??null,paused_by:x(t.paused_by)??null,paused_at:x(t.paused_at)??null}:{}}function ao(t){if(!H(t))return;const e=Object.entries(t).map(([n,s])=>{const a=x(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function vr(t){if(!H(t))return null;const e=x(t.kind),n=x(t.summary),s=x(t.target_type);return!e||!n||!s?null:{kind:e,severity:x(t.severity)??"warn",summary:n,target_type:s,target_id:x(t.target_id)??null,actor:x(t.actor)??null,evidence:t.evidence}}function _r(t){if(!H(t))return null;const e=x(t.action_type),n=x(t.target_type),s=x(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:x(t.target_id)??null,severity:x(t.severity)??"warn",reason:s,confirm_required:ra(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Zu(t){return H(t)?{actor:x(t.actor)??null,spawn_agent:x(t.spawn_agent)??null,spawn_role:x(t.spawn_role)??null,spawn_model:x(t.spawn_model)??null,worker_class:x(t.worker_class)??null,parent_actor:x(t.parent_actor)??null,capsule_mode:x(t.capsule_mode)??null,runtime_pool:x(t.runtime_pool)??null,lane_id:x(t.lane_id)??null,controller_level:x(t.controller_level)??null,control_domain:x(t.control_domain)??null,supervisor_actor:x(t.supervisor_actor)??null,model_tier:x(t.model_tier)??null,task_profile:x(t.task_profile)??null,risk_level:x(t.risk_level)??null,routing_confidence:at(t.routing_confidence)??null,routing_reason:x(t.routing_reason)??null,status:x(t.status)??"unknown",turn_count:at(t.turn_count)??0,empty_note_turn_count:at(t.empty_note_turn_count)??0,has_turn:ra(t.has_turn)??!1,last_turn_ts_iso:x(t.last_turn_ts_iso)??null}:null}function tp(t){if(!H(t))return null;const e=x(t.session_id);return e?{session_id:e,goal:x(t.goal),status:x(t.status),health:x(t.health),scale_profile:x(t.scale_profile),control_profile:x(t.control_profile),planned_worker_count:at(t.planned_worker_count),active_agent_count:at(t.active_agent_count),last_turn_age_sec:at(t.last_turn_age_sec)??null,attention_count:at(t.attention_count),recommended_action_count:at(t.recommended_action_count),top_attention:vr(t.top_attention),top_recommendation:_r(t.top_recommendation)}:null}function fr(t){const e=H(t)?t:{};return{trace_id:x(e.trace_id),target_type:x(e.target_type)??"room",target_id:x(e.target_id)??null,health:x(e.health),swarm_status:H(e.swarm_status)?e.swarm_status:void 0,attention_items:Et(e.attention_items).map(vr).filter(n=>n!==null),recommended_actions:Et(e.recommended_actions).map(_r).filter(n=>n!==null),session_cards:Et(e.session_cards).map(tp).filter(n=>n!==null),worker_cards:Et(e.worker_cards).map(Zu).filter(n=>n!==null)}}function ep(t){if(!H(t))return null;const e=H(t.status)?t.status:void 0,n=H(t.summary)?t.summary:H(e==null?void 0:e.summary)?e.summary:void 0,s=H(t.session)?t.session:H(e==null?void 0:e.session)?e.session:void 0,a=x(t.session_id)??x(n==null?void 0:n.session_id)??x(s==null?void 0:s.session_id);if(!a)return null;const o=ao(t.report_paths)??ao(e==null?void 0:e.report_paths),r=Et(t.recent_events,["events"]).filter(H);return{session_id:a,status:x(t.status)??x(n==null?void 0:n.status)??x(s==null?void 0:s.status),progress_pct:at(t.progress_pct)??at(n==null?void 0:n.progress_pct),elapsed_sec:at(t.elapsed_sec)??at(n==null?void 0:n.elapsed_sec),remaining_sec:at(t.remaining_sec)??at(n==null?void 0:n.remaining_sec),done_delta_total:at(t.done_delta_total)??at(n==null?void 0:n.done_delta_total),summary:n,team_health:H(t.team_health)?t.team_health:H(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:H(t.communication_metrics)?t.communication_metrics:H(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:H(t.orchestration_state)?t.orchestration_state:H(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:H(t.cascade_metrics)?t.cascade_metrics:H(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:s,recent_events:r}}function np(t){if(!H(t))return null;const e=x(t.name);if(!e)return null;const n=H(t.context)?t.context:void 0;return{name:e,agent_name:x(t.agent_name),status:x(t.status),autonomy_level:x(t.autonomy_level),context_ratio:at(t.context_ratio)??at(n==null?void 0:n.context_ratio),generation:at(t.generation),active_goal_ids:Yu(t.active_goal_ids),last_autonomous_action_at:x(t.last_autonomous_action_at)??null,last_turn_ago_s:at(t.last_turn_ago_s),model:x(t.model)??x(t.active_model)??x(t.primary_model)}}function sp(t){if(!H(t))return null;const e=x(t.confirm_token)??x(t.token);return e?{confirm_token:e,actor:x(t.actor),action_type:x(t.action_type),target_type:x(t.target_type),target_id:x(t.target_id)??null,delegated_tool:x(t.delegated_tool),created_at:x(t.created_at),preview:t.preview}:null}function ap(t){const e=H(t)?t:{};return{room:Qu(e.room),sessions:Et(e.sessions,["items","sessions"]).map(ep).filter(n=>n!==null),keepers:Et(e.keepers,["items","keepers"]).map(np).filter(n=>n!==null),recent_messages:Et(e.recent_messages,["messages"]).map(Xu).filter(n=>n!==null),pending_confirms:Et(e.pending_confirms,["items","confirms"]).map(sp).filter(n=>n!==null),available_actions:Et(e.available_actions,["actions"]).filter(H).map(n=>({action_type:x(n.action_type)??"unknown",target_type:x(n.target_type)??"unknown",description:x(n.description),confirm_required:ra(n.confirm_required)}))}}function Yn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function io(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Ns(t){Is.value=[{...t,id:Vu++,at:new Date().toISOString()},...Is.value].slice(0,20)}function gr(t){return t.confirm_required?Yn(t.preview)||"Confirmation required":Yn(t.result)||Yn(t.executed_action)||Yn(t.delegated_tool_result)||t.status}async function ut(){Sn.value=!0,le.value=null;try{const t=await jl();pe.value=ap(t)}catch(t){le.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Sn.value=!1}}async function Yt(){An.value=!0,Je.value=null;try{const t=await jo({targetType:"room"});mr.value=fr(t)}catch(t){Je.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{An.value=!1}}async function Ve(t){if(!t){qt.value=null;return}An.value=!0,Je.value=null;try{const e=await jo({targetType:"team_session",targetId:t,includeWorkers:!0});qt.value=fr(e)}catch(e){Je.value=e instanceof Error?e.message:"Failed to load session digest"}finally{An.value=!1}}async function ip(t){var e;Q.value=!0,le.value=null;try{const n=await Qs(t);return Ns({actor:t.actor,action_type:t.action_type,target_label:io(t),outcome:n.confirm_required?"preview":"executed",message:gr(n),delegated_tool:n.delegated_tool}),await ut(),await Yt(),(e=qt.value)!=null&&e.target_id&&await Ve(qt.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw le.value=s,Ns({actor:t.actor,action_type:t.action_type,target_label:io(t),outcome:"error",message:s}),n}finally{Q.value=!1}}async function op(t,e){var n;Q.value=!0,le.value=null;try{const s=await Gl(t,e);return Ns({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:gr(s),delegated_tool:s.delegated_tool}),await ut(),await Yt(),(n=qt.value)!=null&&n.target_id&&await Ve(qt.value.target_id),s}catch(s){const a=s instanceof Error?s.message:"Operator confirmation failed";throw le.value=a,Ns({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),s}finally{Q.value=!1}}hd(()=>{var t;ut(),Yt(),(t=qt.value)!=null&&t.target_id&&Ve(qt.value.target_id)});const Ni=f(null),Ut=f(null),Rs=f(!1),Ps=f(!1),Ls=f(null),Ms=f(null),ri=f(null),Ds=f(null),V=f("warroom"),Fn=f(null),li=f(!1),Es=f(null),Ce=f(null),zs=f(!1),js=f(null),qn=f(null),ci=f(!1),Os=f(null),Cn=f(null),Fs=f(!1),wn=f(null),Ke=f(null);let ln=null;function Ri(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"}function S(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function l(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function g(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function st(t){return typeof t=="boolean"?t:void 0}function _t(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function $r(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function rp(){const e=$r().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function lp(){const e=$r().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function cp(t){if(S(t))return{policy_class:l(t.policy_class),approval_class:l(t.approval_class),tool_allowlist:_t(t.tool_allowlist),model_allowlist:_t(t.model_allowlist),requires_human_for:_t(t.requires_human_for),autonomy_level:l(t.autonomy_level),escalation_timeout_sec:g(t.escalation_timeout_sec),kill_switch:st(t.kill_switch),frozen:st(t.frozen)}}function dp(t){if(S(t))return{headcount_cap:g(t.headcount_cap),active_operation_cap:g(t.active_operation_cap),max_cost_usd:g(t.max_cost_usd),max_tokens:g(t.max_tokens)}}function Pi(t){if(!S(t))return null;const e=l(t.unit_id),n=l(t.label),s=l(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:l(t.parent_unit_id)??null,leader_id:l(t.leader_id)??null,roster:_t(t.roster),capability_profile:_t(t.capability_profile),source:l(t.source),created_at:l(t.created_at),updated_at:l(t.updated_at),policy:cp(t.policy),budget:dp(t.budget)}}function hr(t){if(!S(t))return null;const e=Pi(t.unit);return e?{unit:e,leader_status:l(t.leader_status),roster_total:g(t.roster_total),roster_live:g(t.roster_live),active_operation_count:g(t.active_operation_count),health:l(t.health),reasons:_t(t.reasons),children:Array.isArray(t.children)?t.children.map(hr).filter(n=>n!==null):[]}:null}function up(t){if(S(t))return{total_units:g(t.total_units),company_count:g(t.company_count),platoon_count:g(t.platoon_count),squad_count:g(t.squad_count),leaf_agent_unit_count:g(t.leaf_agent_unit_count),live_agent_count:g(t.live_agent_count),managed_unit_count:g(t.managed_unit_count),active_operation_count:g(t.active_operation_count)}}function yr(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),source:l(e.source),summary:up(e.summary),units:Array.isArray(e.units)?e.units.map(hr).filter(n=>n!==null):[]}}function pp(t){if(!S(t))return null;const e=l(t.kind),n=l(t.status);return!e||!n?null:{kind:e,chain_id:l(t.chain_id)??null,goal:l(t.goal)??null,run_id:l(t.run_id)??null,status:n,viewer_path:l(t.viewer_path)??null,last_sync_at:l(t.last_sync_at)??null}}function la(t){if(!S(t))return null;const e=l(t.operation_id),n=l(t.objective),s=l(t.assigned_unit_id),a=l(t.trace_id),o=l(t.status);return!e||!n||!s||!a||!o?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:l(t.autonomy_level),policy_class:l(t.policy_class),budget_class:l(t.budget_class),detachment_session_id:l(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:l(t.checkpoint_ref)??null,active_goal_ids:_t(t.active_goal_ids),note:l(t.note)??null,created_by:l(t.created_by),source:l(t.source),status:o,chain:pp(t.chain),created_at:l(t.created_at),updated_at:l(t.updated_at)}}function mp(t){if(!S(t))return null;const e=la(t.operation);return e?{operation:e,assigned_unit_label:l(t.assigned_unit_label)}:null}function an(t){if(S(t))return{tone:l(t.tone),pending_ops:g(t.pending_ops),blocked_ops:g(t.blocked_ops),in_flight_ops:g(t.in_flight_ops),pipeline_stalls:g(t.pipeline_stalls),bus_traffic:g(t.bus_traffic),l1_hit_rate:g(t.l1_hit_rate),invalidation_count:g(t.invalidation_count),current_pending:g(t.current_pending),current_in_flight:g(t.current_in_flight),cdb_wakeups:g(t.cdb_wakeups),total_stolen:g(t.total_stolen),avg_best_score:g(t.avg_best_score),avg_candidate_count:g(t.avg_candidate_count),best_first_operations:g(t.best_first_operations),active_sessions:g(t.active_sessions),commit_rate:g(t.commit_rate),total_speculations:g(t.total_speculations)}}function vp(t){if(!S(t))return;const e=S(t.pipeline)?t.pipeline:void 0,n=S(t.cache)?t.cache:void 0,s=S(t.ooo)?t.ooo:void 0,a=S(t.speculative)?t.speculative:void 0,o=S(t.search_fabric)?t.search_fabric:void 0,r=S(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:g(e.total_ops),completed_ops:g(e.completed_ops),stalled_cycles:g(e.stalled_cycles),hazards_detected:g(e.hazards_detected),forwarding_used:g(e.forwarding_used),pipeline_flushes:g(e.pipeline_flushes),ipc:g(e.ipc)}:void 0,cache:n?{total_reads:g(n.total_reads),total_writes:g(n.total_writes),l1_hit_rate:g(n.l1_hit_rate),invalidation_count:g(n.invalidation_count),writeback_count:g(n.writeback_count),bus_traffic:g(n.bus_traffic)}:void 0,ooo:s?{agent_count:g(s.agent_count),total_added:g(s.total_added),total_issued:g(s.total_issued),total_completed:g(s.total_completed),total_stolen:g(s.total_stolen),cdb_wakeups:g(s.cdb_wakeups),stall_cycles:g(s.stall_cycles),global_cdb_events:g(s.global_cdb_events),current_pending:g(s.current_pending),current_in_flight:g(s.current_in_flight)}:void 0,speculative:a?{total_speculations:g(a.total_speculations),total_commits:g(a.total_commits),total_aborts:g(a.total_aborts),commit_rate:g(a.commit_rate),total_fast_calls:g(a.total_fast_calls),total_cost_usd:g(a.total_cost_usd),active_sessions:g(a.active_sessions)}:void 0,search_fabric:o?{total_operations:g(o.total_operations),best_first_operations:g(o.best_first_operations),legacy_operations:g(o.legacy_operations),blocked_operations:g(o.blocked_operations),ready_operations:g(o.ready_operations),research_pipeline_operations:g(o.research_pipeline_operations),avg_candidate_count:g(o.avg_candidate_count),avg_best_score:g(o.avg_best_score),top_stage:l(o.top_stage)??null}:void 0,signals:r?{issue_pressure:an(r.issue_pressure),cache_contention:an(r.cache_contention),scheduler_efficiency:an(r.scheduler_efficiency),routing_confidence:an(r.routing_confidence),speculative_posture:an(r.speculative_posture)}:void 0}}function br(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:g(n.total),active:g(n.active),paused:g(n.paused),managed:g(n.managed),projected:g(n.projected)}:void 0,microarch:vp(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(mp).filter(s=>s!==null):[]}}function kr(t){if(!S(t))return null;const e=l(t.detachment_id),n=l(t.operation_id),s=l(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:l(t.leader_id)??null,roster:_t(t.roster),session_id:l(t.session_id)??null,checkpoint_ref:l(t.checkpoint_ref)??null,runtime_kind:l(t.runtime_kind)??null,runtime_ref:l(t.runtime_ref)??null,source:l(t.source),status:l(t.status),last_event_at:l(t.last_event_at)??null,last_progress_at:l(t.last_progress_at)??null,heartbeat_deadline:l(t.heartbeat_deadline)??null,created_at:l(t.created_at),updated_at:l(t.updated_at)}}function _p(t){if(!S(t))return null;const e=kr(t.detachment);return e?{detachment:e,assigned_unit_label:l(t.assigned_unit_label),operation:la(t.operation)}:null}function xr(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:g(n.total),active:g(n.active),projected:g(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(_p).filter(s=>s!==null):[]}}function fp(t){if(!S(t))return null;const e=l(t.decision_id),n=l(t.trace_id),s=l(t.requested_action),a=l(t.scope_type),o=l(t.scope_id);return!e||!n||!s||!a||!o?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:l(t.operation_id)??null,target_unit_id:l(t.target_unit_id)??null,requested_by:l(t.requested_by),status:l(t.status),reason:l(t.reason)??null,source:l(t.source),detail:t.detail,created_at:l(t.created_at),decided_at:l(t.decided_at)??null,expires_at:l(t.expires_at)??null}}function Sr(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:g(n.total),pending:g(n.pending),approved:g(n.approved),denied:g(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(fp).filter(s=>s!==null):[]}}function gp(t){if(!S(t))return null;const e=Pi(t.unit);return e?{unit:e,roster_total:g(t.roster_total),roster_live:g(t.roster_live),headcount_cap:g(t.headcount_cap),active_operations:g(t.active_operations),active_operation_cap:g(t.active_operation_cap),utilization:g(t.utilization)}:null}function $p(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(gp).filter(n=>n!==null):[]}}function hp(t){if(!S(t))return null;const e=l(t.alert_id);return e?{alert_id:e,severity:l(t.severity),kind:l(t.kind),scope_type:l(t.scope_type),scope_id:l(t.scope_id),title:l(t.title),detail:l(t.detail),timestamp:l(t.timestamp)}:null}function Ar(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:g(n.total),bad:g(n.bad),warn:g(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(hp).filter(s=>s!==null):[]}}function Cr(t){if(!S(t))return null;const e=l(t.event_id),n=l(t.trace_id),s=l(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:l(t.operation_id)??null,unit_id:l(t.unit_id)??null,actor:l(t.actor)??null,source:l(t.source),timestamp:l(t.timestamp),detail:t.detail}}function yp(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),events:Array.isArray(e.events)?e.events.map(Cr).filter(n=>n!==null):[]}}function bp(t){if(!S(t))return null;const e=l(t.code),n=l(t.severity),s=l(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function kp(t){if(!S(t))return null;const e=l(t.lane_id),n=l(t.label),s=l(t.kind),a=l(t.phase),o=l(t.motion_state),r=l(t.source_of_truth),c=l(t.movement_reason),d=l(t.current_step);if(!e||!n||!s||!a||!o||!r||!c||!d)return null;const m=S(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:st(t.present)??!1,phase:a,motion_state:o,source_of_truth:r,last_movement_at:l(t.last_movement_at)??null,movement_reason:c,current_step:d,blockers:_t(t.blockers),counts:{operations:g(m.operations),detachments:g(m.detachments),workers:g(m.workers),approvals:g(m.approvals),alerts:g(m.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(bp).filter(u=>u!==null):[]}}function xp(t){if(!S(t))return null;const e=l(t.event_id),n=l(t.lane_id),s=l(t.kind),a=l(t.timestamp),o=l(t.title),r=l(t.detail),c=l(t.tone),d=l(t.source);return!e||!n||!s||!a||!o||!r||!c||!d?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:o,detail:r,tone:c,source:d}}function Sp(t){if(!S(t))return null;const e=l(t.code),n=l(t.severity),s=l(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,lane_ids:_t(t.lane_ids),count:g(t.count)??0}}function wr(t){if(!S(t))return;const e=S(t.overview)?t.overview:{},n=S(t.gaps)?t.gaps:{},s=S(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:l(t.generated_at),overview:{active_lanes:g(e.active_lanes),moving_lanes:g(e.moving_lanes),stalled_lanes:g(e.stalled_lanes),projected_lanes:g(e.projected_lanes),last_movement_at:l(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(kp).filter(a=>a!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(xp).filter(a=>a!==null):[],gaps:{count:g(n.count),items:Array.isArray(n.items)?n.items.map(Sp).filter(a=>a!==null):[]},recommended_next_action:s?{tool:l(s.tool)??"masc_operator_snapshot",label:l(s.label)??"Observe operator state",reason:l(s.reason)??"",lane_id:l(s.lane_id)??null}:void 0}}function Ap(t){if(!S(t))return;const e=S(t.workers)?t.workers:{},n=st(t.pass);return{status:l(t.status)??"missing",source:l(t.source)??"none",run_id:l(t.run_id)??null,captured_at:l(t.captured_at)??null,...n!==void 0?{pass:n}:{},...g(t.peak_hot_slots)!=null?{peak_hot_slots:g(t.peak_hot_slots)}:{},...g(t.ctx_per_slot)!=null?{ctx_per_slot:g(t.ctx_per_slot)}:{},workers:{expected:g(e.expected),joined:g(e.joined),current_task_bound:g(e.current_task_bound),fresh_heartbeats:g(e.fresh_heartbeats),done:g(e.done),final:g(e.final)},artifact_ref:l(t.artifact_ref)??null,missing_reason:l(t.missing_reason)??null}}function Cp(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),topology:yr(e.topology),operations:br(e.operations),detachments:xr(e.detachments),alerts:Ar(e.alerts),decisions:Sr(e.decisions),capacity:$p(e.capacity),traces:yp(e.traces),swarm_status:wr(e.swarm_status)}}function wp(t){const e=S(t)?t:{},n=yr(e.topology),s=br(e.operations),a=xr(e.detachments),o=Ar(e.alerts),r=Sr(e.decisions);return{version:l(e.version),generated_at:l(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:wr(e.swarm_status),swarm_proof:Ap(e.swarm_proof)}}function Tp(t){return S(t)?{chain_id:l(t.chain_id)??null,started_at:g(t.started_at)??null,progress:g(t.progress)??null,elapsed_sec:g(t.elapsed_sec)??null}:null}function Tr(t){if(!S(t))return null;const e=l(t.event);return e?{event:e,chain_id:l(t.chain_id)??null,timestamp:l(t.timestamp)??null,duration_ms:g(t.duration_ms)??null,message:l(t.message)??null,tokens:g(t.tokens)??null}:null}function Ip(t){if(!S(t))return null;const e=la(t.operation);return e?{operation:e,runtime:Tp(t.runtime),history:Tr(t.history),mermaid:l(t.mermaid)??null,preview_run:Ir(t.preview_run)}:null}function Np(t){const e=S(t)?t:{};return{status:l(e.status)??"disconnected",base_url:l(e.base_url)??null,message:l(e.message)??null}}function Rp(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),connection:Np(e.connection),summary:n?{linked_operations:g(n.linked_operations),active_chains:g(n.active_chains),running_operations:g(n.running_operations),recent_failures:g(n.recent_failures),last_history_event_at:l(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(Ip).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(Tr).filter(s=>s!==null):[]}}function Pp(t){if(!S(t))return null;const e=l(t.id);return e?{id:e,type:l(t.type),status:l(t.status),duration_ms:g(t.duration_ms)??null,error:l(t.error)??null}:null}function Ir(t){if(!S(t))return null;const e=l(t.run_id),n=l(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:g(t.duration_ms),success:st(t.success),mermaid:l(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(Pp).filter(s=>s!==null):[]}:null}function Lp(t){const e=S(t)?t:{};return{run:Ir(e.run)}}function Mp(t){if(!S(t))return null;const e=l(t.title),n=l(t.path);return!e||!n?null:{title:e,path:n}}function Dp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function Ep(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.tool),a=l(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:_t(t.success_signals),pitfalls:_t(t.pitfalls)}}function zp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.summary),a=l(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(Ep).filter(o=>o!==null):[]}}function jp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:_t(t.tools)}}function Op(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.symptom),a=l(t.why),o=l(t.fix_tool),r=l(t.fix_summary);return!e||!n||!s||!a||!o||!r?null:{id:e,title:n,symptom:s,why:a,fix_tool:o,fix_summary:r}}function Fp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.path_id),a=l(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:_t(t.notes)}}function qp(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(Mp).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(Dp).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(zp).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(jp).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Op).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Fp).filter(n=>n!==null):[]}}function Kp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),s=l(t.status),a=l(t.detail),o=l(t.next_tool);return!e||!n||!s||!a||!o?null:{id:e,title:n,status:s,detail:a,next_tool:o}}function Up(t){if(!S(t))return null;const e=l(t.code),n=l(t.severity),s=l(t.title),a=l(t.detail),o=l(t.next_tool);return!e||!n||!s||!a||!o?null:{code:e,severity:n,title:s,detail:a,next_tool:o}}function Hp(t){if(!S(t))return null;const e=l(t.from),n=l(t.content),s=l(t.timestamp),a=g(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function Wp(t){if(!S(t))return null;const e=l(t.name),n=l(t.role),s=l(t.lane),a=l(t.status),o=l(t.claim_marker),r=l(t.done_marker),c=l(t.final_marker);if(!e||!n||!s||!a||!o||!r||!c)return null;const d=(()=>{if(!S(t.last_message))return null;const m=g(t.last_message.seq),u=l(t.last_message.content),p=l(t.last_message.timestamp);return m==null||!u||!p?null:{seq:m,content:u,timestamp:p}})();return{name:e,role:n,lane:s,joined:st(t.joined)??!1,live_presence:st(t.live_presence)??!1,completed:st(t.completed)??!1,status:a,current_task:l(t.current_task)??null,bound_task_id:l(t.bound_task_id)??null,bound_task_title:l(t.bound_task_title)??null,bound_task_status:l(t.bound_task_status)??null,current_task_matches_run:st(t.current_task_matches_run)??!1,squad_member:st(t.squad_member)??!1,detachment_member:st(t.detachment_member)??!1,last_seen:l(t.last_seen)??null,heartbeat_age_sec:g(t.heartbeat_age_sec)??null,heartbeat_fresh:st(t.heartbeat_fresh)??!1,claim_marker_seen:st(t.claim_marker_seen)??!1,done_marker_seen:st(t.done_marker_seen)??!1,final_marker_seen:st(t.final_marker_seen)??!1,claim_marker:o,done_marker:r,final_marker:c,last_message:d}}function Bp(t){if(!S(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!S(n))return null;const s=l(n.timestamp),a=g(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:l(t.slot_url)??null,provider_base_url:l(t.provider_base_url)??null,provider_reachable:st(t.provider_reachable)??null,provider_status_code:g(t.provider_status_code)??null,provider_model_id:l(t.provider_model_id)??null,actual_model_id:l(t.actual_model_id)??null,expected_slots:g(t.expected_slots),actual_slots:g(t.actual_slots),expected_ctx:g(t.expected_ctx),actual_ctx:g(t.actual_ctx),slot_reachable:st(t.slot_reachable)??null,slot_status_code:g(t.slot_status_code)??null,runtime_blocker:l(t.runtime_blocker)??null,detail:l(t.detail)??null,checked_at:l(t.checked_at)??null,total_slots:g(t.total_slots),ctx_per_slot:g(t.ctx_per_slot),active_slots_now:g(t.active_slots_now),peak_active_slots:g(t.peak_active_slots),sample_count:g(t.sample_count),last_sample_at:l(t.last_sample_at)??null,timeline:e}}function Gp(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),run_id:l(e.run_id),room_id:l(e.room_id),operation_id:l(e.operation_id)??null,recommended_next_tool:l(e.recommended_next_tool),summary:n?{expected_workers:g(n.expected_workers),joined_workers:g(n.joined_workers),live_workers:g(n.live_workers),squad_roster_size:g(n.squad_roster_size),detachment_roster_size:g(n.detachment_roster_size),current_task_bound:g(n.current_task_bound),fresh_heartbeats:g(n.fresh_heartbeats),claim_markers_seen:g(n.claim_markers_seen),done_markers_seen:g(n.done_markers_seen),final_markers_seen:g(n.final_markers_seen),completed_workers:g(n.completed_workers),peak_hot_slots:g(n.peak_hot_slots),hot_window_ok:st(n.hot_window_ok),pass_hot_concurrency:st(n.pass_hot_concurrency),pass_end_to_end:st(n.pass_end_to_end),pending_decisions:g(n.pending_decisions),pass:st(n.pass)}:void 0,provider:Bp(e.provider),operation:la(e.operation),squad:Pi(e.squad),detachment:kr(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Wp).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Kp).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Up).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Hp).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(Cr).filter(s=>s!==null):[],truth_notes:_t(e.truth_notes)}}function xe(t){V.value=t,Ri(t)&&Jp()}async function Nr(){Rs.value=!0,Ls.value=null;try{const t=await Fl();Ni.value=wp(t)}catch(t){Ls.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{Rs.value=!1}}function Li(t){Ke.value=t}async function Mi(){Ps.value=!0,Ms.value=null;try{const t=await Ol();Ut.value=Cp(t)}catch(t){Ms.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{Ps.value=!1}}async function Jp(){Ut.value||Ps.value||await Mi()}async function Se(){await Nr(),Ri(V.value)&&await Mi()}async function se(){var t;ci.value=!0,Os.value=null;try{const e=await ql(),n=Rp(e);qn.value=n;const s=Ke.value;n.operations.length===0?Ke.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Ke.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Os.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{ci.value=!1}}function Vp(){ln=null,Cn.value=null,Fs.value=!1,wn.value=null}async function Yp(t){ln=t,Fs.value=!0,wn.value=null;try{const e=await Kl(t);if(ln!==t)return;Cn.value=Lp(e)}catch(e){if(ln!==t)return;Cn.value=null,wn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{ln===t&&(Fs.value=!1)}}async function Xp(){li.value=!0,Es.value=null;try{const t=await Ul();Fn.value=qp(t)}catch(t){Es.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{li.value=!1}}async function Bt(t=rp(),e=lp()){zs.value=!0,js.value=null;try{const n=await Hl(t,e);Ce.value=Gp(n)}catch(n){js.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{zs.value=!1}}async function me(t,e,n){ri.value=t,Ds.value=null;try{await Wl(e,n),await Nr(),(Ut.value||Ri(V.value))&&await Mi(),await Bt(),await se()}catch(s){throw Ds.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{ri.value=null}}function Qp(t){return me(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Zp(t){return me(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function tm(t){return me(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function em(t={}){return me("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function nm(t){return me(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function sm(t){return me(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function am(t,e){return me(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function im(t,e){return me(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}$d(()=>{Se(),se(),(V.value==="swarm"||V.value==="warroom"||Ce.value!==null)&&Bt(),V.value==="warroom"&&ut()});function Rr(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Z(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function om(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Pr(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function M(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let oo=!1,rm=0,ga=null;async function lm(){ga||(ga=Ju(()=>import("./mermaid.core-BLQ6t3sT.js").then(e=>e.bE),[]).then(e=>e.default));const t=await ga;return oo||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),oo=!0),t}function ae(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Kn(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function cn(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function Un(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function he(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:Un(t/e*100)}function cm(t,e){const n=Un(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function Lr(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const dm=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],Mr=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],um=Mr.map(t=>t.id),pm=["chain_start","node_start","node_complete","chain_complete","chain_error"],mm={warroom:{title:"라이브 워룸",description:"실제 run, worker, message, trace를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function ro(t){return!!t&&um.includes(t)}function vm(){const t=O.value.params;return t.source!=="mission"?{}:{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function Dr(t){const e=vm();if(t==="operations")return e;if(t==="chains"){const n=Ke.value;return n?{...e,surface:t,operation:n}:{...e,surface:t}}return{...e,surface:t}}function _m(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function fm(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function lt(t){return ri.value===t}function Hn(){return Ni.value}function gm(t){var a,o,r,c,d,m,u;const e=Ni.value,n=Ce.value,s=qn.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"live run, worker, message, trace를 한 화면에서 보고 필요한 detail 표면으로 바로 점프합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((r=(o=e==null?void 0:e.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:r.tool)??"masc_observe_traces",reason:((d=(c=e==null?void 0:e.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:d.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(u=(m=s==null?void 0:s.operations[0])==null?void 0:m.preview_run)!=null&&u.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function $m(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function hm(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function ym(){const t=On(O.value);return t?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${Ii(t.action_type)}</span>
        <span class="command-chip">${Ti(t)}</span>
        <span class="command-chip">${_u(O.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?i`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function bm(){const t=V.value,e=mm[t],n=gm(t);return i`
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
  `}function Xn({label:t,value:e,subtext:n,percent:s,color:a}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${cm(s,a)}>
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
  `}function Qn({label:t,value:e,detail:n,percent:s,tone:a}){return i`
    <article class="command-signal-rail ${M(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${M(a)}" style=${`width: ${Math.max(8,Math.round(Un(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function km(){var F,tt,W,et;const t=Hn(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,o=t==null?void 0:t.alerts.summary,r=(F=t==null?void 0:t.swarm_status)==null?void 0:F.overview,c=t==null?void 0:t.swarm_proof,d=t==null?void 0:t.operations.microarch,m=(e==null?void 0:e.managed_unit_count)??0,u=(e==null?void 0:e.total_units)??0,p=(n==null?void 0:n.active)??0,_=(s==null?void 0:s.active)??0,$=(r==null?void 0:r.moving_lanes)??0,k=(r==null?void 0:r.active_lanes)??0,A=(c==null?void 0:c.workers.done)??0,w=(c==null?void 0:c.workers.expected)??0,L=(o==null?void 0:o.bad)??0,z=(o==null?void 0:o.warn)??0,E=(a==null?void 0:a.pending)??0,I=(a==null?void 0:a.total)??0,N=p+_,Y=((tt=d==null?void 0:d.cache)==null?void 0:tt.l1_hit_rate)??((et=(W=d==null?void 0:d.signals)==null?void 0:W.cache_contention)==null?void 0:et.l1_hit_rate)??0,G=p>0||_>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",v=p>0||$>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${G}</h3>
        <p>${v}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${M(p>0?"ok":"warn")}">활성 작전 ${p}</span>
          <span class="command-chip ${M($>0?"ok":(k>0,"warn"))}">이동 레인 ${$}/${Math.max(k,$)}</span>
          <span class="command-chip ${M(L>0?"bad":z>0?"warn":"ok")}">치명 알림 ${L}</span>
          <span class="command-chip ${M(E>0?"warn":"ok")}">승인 대기 ${E}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${Xn}
          label="관리 단위 범위"
          value=${`${m}/${Math.max(u,m)}`}
          subtext=${u>0?`${u-m}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${he(m,Math.max(u,m))}
          color="#67e8f9"
        />
        <${Xn}
          label="실행 열도"
          value=${String(N)}
          subtext=${`${p}개 작전 + ${_}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${he(N,Math.max(m,N||1))}
          color="#4ade80"
        />
        <${Xn}
          label="스웜 이동감"
          value=${`${$}/${Math.max(k,$)}`}
          subtext=${r!=null&&r.last_movement_at?`마지막 이동 ${Z(r.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${he($,Math.max(k,$||1))}
          color="#fbbf24"
        />
        <${Xn}
          label="증거 수집률"
          value=${`${A}/${Math.max(w,A)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${he(A,Math.max(w,A||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${Qn}
        label="승인 대기열"
        value=${`${E}건 대기`}
        detail=${`현재 정책 창에서 ${I}개 결정을 추적 중입니다`}
        percent=${he(E,Math.max(I,E||1))}
        tone=${E>0?"warn":"ok"}
      />
      <${Qn}
        label="알림 압력"
        value=${`${L} bad / ${z} warn`}
        detail=${L>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${he(L*2+z,Math.max((L+z)*2,1))}
        tone=${L>0?"bad":z>0?"warn":"ok"}
      />
      <${Qn}
        label="디스패치 점유"
          value=${`${_}개 가동`}
        detail=${m>0?`${m}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${he(_,Math.max(m,_||1))}
        tone=${_>0?"ok":"warn"}
      />
      <${Qn}
        label="캐시 신뢰도"
        value=${Y?Kn(Y):"n/a"}
        detail=${Y?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Un((Y??0)*100)}
        tone=${Y>=.75?"ok":Y>=.4?"warn":"bad"}
      />
    </div>
  `}function xm(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Er(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function Sm(){const e=Er().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function zr(){const e=Er().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Am(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function Cm(t){return t.status==="claimed"||t.status==="in_progress"}function wm(t){const e=Fn.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function $a(t){var e;return((e=Fn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function Tm(t){const e=Fn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function ie(t){try{await t()}catch{}}function Di(t){return(t==null?void 0:t.trim().toLowerCase())??""}function je(t){const e=Di(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function ha(t){const e=Di(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function Im(){var e,n,s;const t=Ce.value;return t?!!(t.run_id||(e=t.operation)!=null&&e.operation_id||(n=t.detachment)!=null&&n.detachment_id||(((s=t.summary)==null?void 0:s.expected_workers)??0)>0||t.workers.length>0||t.recent_messages.length>0||t.recent_trace_events.length>0):!1}function Nm(t){const e=Di(t.status);return e==="active"||e==="running"}function Rm(){var o,r,c,d;const t=((o=pe.value)==null?void 0:o.sessions)??[],e=Ce.value,n=((r=e==null?void 0:e.detachment)==null?void 0:r.session_id)??null;if(n){const m=t.find(u=>u.session_id===n);if(m)return m}const s=((c=e==null?void 0:e.operation)==null?void 0:c.operation_id)??zr();if(s){const m=t.find(u=>u.command_plane_operation_id===s);if(m)return m}const a=((d=e==null?void 0:e.detachment)==null?void 0:d.detachment_id)??null;if(a){const m=t.find(u=>u.command_plane_detachment_id===a);if(m)return m}return t.find(Nm)??t[0]??null}function Pm(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"none",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}s`:t.heartbeat_fresh?"clean":"n/a",detail:[t.bound_task_status??null,t.detachment_member?"detachment":null,t.squad_member?"squad":null].filter(Boolean).join(" · ")||"live swarm worker",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function Lm(t,e){const n=t.actor??t.spawn_role??`worker-${e+1}`,s=t.spawn_role??t.worker_class??t.spawn_agent??"worker",a=t.lane_id??t.capsule_mode??t.control_domain??"session",o=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:s,lane:a,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"session lane",heartbeat:t.last_turn_ts_iso?Z(t.last_turn_ts_iso):"n/a",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?Kn(t.routing_confidence):null].filter(Boolean).join(" · ")||"session worker",markers:o,note:t.routing_reason??null}}function lo(t){return M(t.severity)}function Mm({worker:t}){return i`
    <article class="command-card compact warroom-worker-card ${M(je(t.status))}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${M(je(t.status))}">${t.status}</span>
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
  `}function te({label:t,surface:e,params:n={}}){return i`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(e){xe(e),gt("command",{...Dr(e),...n});return}gt("intervene")}}
    >
      ${t}
    </button>
  `}function Dm(){var _,$,k,A,w;const t=Hn(),e=qn.value,n=On(O.value),s=$m(n),a=t==null?void 0:t.topology.summary,o=t==null?void 0:t.operations.summary,r=(_=t==null?void 0:t.swarm_status)==null?void 0:_.overview,c=t==null?void 0:t.operations.microarch,d=t==null?void 0:t.decisions.summary,m=t==null?void 0:t.alerts.summary,u=($=c==null?void 0:c.signals)==null?void 0:$.issue_pressure,p=c==null?void 0:c.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((k=t==null?void 0:t.detachments.summary)==null?void 0:k.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(d==null?void 0:d.pending)??0}</strong><small>${(d==null?void 0:d.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(m==null?void 0:m.bad)??0}</strong><small>${(m==null?void 0:m.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((A=e==null?void 0:e.summary)==null?void 0:A.active_chains)??0}</strong><small>${((w=e==null?void 0:e.summary)==null?void 0:w.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(r==null?void 0:r.active_lanes)??0}</strong><small>${r?`${r.stalled_lanes??0}개 정체 · ${Z(r.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(u==null?void 0:u.pending_ops)??0}</strong><small>${(p==null?void 0:p.l1_hit_rate)!=null?`${Kn(p.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(u==null?void 0:u.tone)??"n/a"}</small></div>
    </div>
  `}function jr(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function Or({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const o=a.motion_state;o in e?e[o]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return i`
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
  `}function Em({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${a.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?i`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function zm({lane:t}){const e=t.counts??{},n=jr(t),s=e.workers??0,a=e.operations??0,o=e.detachments??0,r=a+o,c=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return i`
    <article class="swarm-lane-strip ${M(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${M(n)}">${t.phase}</span>
          <span class="command-chip ${M(n)}">${t.motion_state}</span>
          <span class="command-chip">${Z(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${M(n)}" style=${`width:${c}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${s>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${Em} total=${s} />
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
              ${t.hard_flags.map(d=>i`<span class="command-chip ${M(d.severity)}">${d.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Fr({lanes:t}){const e=t.slice(0,4);return e.length===0?null:i`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=jr(n),a=n.counts.workers??0,o=n.counts.operations??0,r=n.counts.detachments??0;return i`
          <article class="swarm-story-card ${M(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${M(s)}">${n.motion_state}</span>
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
  `}function jm({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${M(t.tone)}"></span>
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
      <span class="command-chip ${M(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function Fm({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${M(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${M(e)}">${(t==null?void 0:t.status)??"missing"}</span>
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
  `}function qm(){const t=Hn(),e=On(O.value),n=hm(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,o=(s==null?void 0:s.lanes.filter(p=>p.present))??[],r=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],d=s==null?void 0:s.overview,m=s==null?void 0:s.recommended_next_action,u=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${D} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${Fr} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(d==null?void 0:d.active_lanes)??0}</strong><small>${(d==null?void 0:d.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(d==null?void 0:d.stalled_lanes)??0}</strong><small>${(d==null?void 0:d.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${Z(d==null?void 0:d.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${Z(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong><small>${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${Or} lanes=${o} />`:null}

            <div class="command-swarm-layout ${u?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(p=>i`<${zm} lane=${p} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${Fm} proof=${a} />

                <div class="command-guide-card ${r.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${M(r.some(p=>p.severity==="bad")?"bad":r.length>0?"warn":"ok")}">${r.length}</span>
                  </div>
                  ${r.length>0?i`<div class="swarm-event-rail">${r.slice(0,4).map(p=>i`<${Om} gap=${p} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?i`<div class="swarm-event-rail">${c.map(p=>i`<${jm} event=${p} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function Km(){return i`
    <div class="command-surface-tabs grouped">
      ${dm.map(t=>i`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${Mr.filter(e=>e.group===t.id).map(e=>i`
                <button
                  class="command-surface-tab ${V.value===e.id?"active":""}"
                  onClick=${()=>{xe(e.id),gt("command",Dr(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function Um(){var F,tt,W,et,b,Nt,Qt,ve,_e;const t=Hn(),e=Ut.value,n=Fe.value,s=xm(),a=s?At.value.find(j=>j.name===s)??null:null,o=s?jt.value.filter(j=>j.assignee===s&&Cm(j)):[],r=((F=t==null?void 0:t.operations.summary)==null?void 0:F.active)??0,c=((tt=t==null?void 0:t.detachments.summary)==null?void 0:tt.total)??0,d=((W=t==null?void 0:t.decisions.summary)==null?void 0:W.pending)??0,m=e==null?void 0:e.detachments.detachments.find(j=>{const Rt=j.detachment.heartbeat_deadline,fe=Rt?Date.parse(Rt):Number.NaN;return j.detachment.status==="stalled"||!Number.isNaN(fe)&&fe<=Date.now()}),u=e==null?void 0:e.alerts.alerts.find(j=>j.severity==="bad"),p=!!(n!=null&&n.room||n!=null&&n.project),_=(a==null?void 0:a.current_task)??null,$=Am(a==null?void 0:a.last_seen),k=$!=null?$<=120:null,A=[p?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:jt.value.length>0?"masc_claim":"masc_add_task"}:_?k===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${_} 이지만 heartbeat가 stale 합니다 (${$}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${_}${$!=null?` · 마지막 활동 ${$}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((et=t.topology.summary)==null?void 0:et.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:r===0?{title:"작전 준비도",tone:"warn",detail:`${((b=t.topology.summary)==null?void 0:b.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((Nt=t.topology.summary)==null?void 0:Nt.managed_unit_count)??0}개 관리 단위 위에서 ${r}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},d>0?{title:"디스패치 준비도",tone:"warn",detail:`${d}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:r>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:m||u?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${m?` · detachment ${m.detachment.detachment_id} 가 stalled 상태입니다`:""}${u?` · alert ${u.title??u.alert_id}`:""}${!e&&!m&&!u?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:d>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],w=p?!s||!a?"masc_join":o.length===0?jt.value.length>0?"masc_claim":"masc_add_task":_?k===!1?"masc_heartbeat":!t||(((Qt=t.topology.summary)==null?void 0:Qt.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":d>0?"masc_policy_approve":r>0&&c===0||m||u?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",L=wm(w),E=Tm(w==="masc_set_room"?["repo-root-room"]:w==="masc_plan_set_task"?["claimed-not-current"]:w==="masc_heartbeat"?["heartbeat-stale"]:w==="masc_dispatch_tick"?["no-detachments"]:w==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),I=$a("room_task_hygiene"),N=$a("cpv2_benchmark"),Y=$a("supervisor_session"),G=((ve=Fn.value)==null?void 0:ve.docs)??[],v=[I,N,Y].filter(j=>j!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${D} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(L==null?void 0:L.title)??w}</strong>
            <span class="command-chip ok">${w}</span>
          </div>
          <p>${(L==null?void 0:L.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(_e=L==null?void 0:L.success_signals)!=null&&_e.length?i`<div class="command-tag-row">
                ${L.success_signals.map(j=>i`<span class="command-tag ok">${j}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${A.map(j=>i`
            <article class="command-readiness-row ${M(j.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${j.title}</strong>
                  <span class="command-chip ${M(j.tone)}">${j.tone}</span>
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
          <${D} panelId="command.summary" compact=${!0} />
        </div>
        ${li.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:Es.value?i`<div class="empty-state error">${Es.value}</div>`:i`
                <div class="command-path-grid">
                  ${v.map(j=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${j.title}</strong>
                        <span class="command-chip">${j.id}</span>
                      </div>
                      <p>${j.summary}</p>
                      <div class="command-card-sub">${j.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${j.steps.slice(0,4).map(Rt=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Rt.tool}</span>
                            <span>${Rt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${G.length>0?i`<div class="command-doc-links">
                      ${G.map(j=>i`<span class="command-tag">${j.title}: ${j.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Hm(){return i`
    <${km} />
    <${Dm} />
    <${Um} />
  `}function Wm(){return Ps.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:Ms.value?i`<div class="empty-state error">${Ms.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function qr({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,o=t.unit.policy;return i`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${fm(t.unit.kind)}</span>
            <span class="command-chip ${M(t.health)}">${t.health??"ok"}</span>
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
            ${t.children.map(r=>i`<${qr} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function Bm({source:t}){const e=rl(null),[n,s]=wo(null);return rt(()=>{let a=!1;const o=e.current;return o?(o.innerHTML="",s(null),(async()=>{try{const c=await lm(),{svg:d}=await c.render(`command-chain-${++rm}`,t);if(a||!e.current)return;e.current.innerHTML=d}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid render failed")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function Gm({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return i`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${ae(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?i`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?i`<span class="command-tag ${ae(s==null?void 0:s.status)}">${Kn(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${Lr(t.history)}</div>
    </button>
  `}function Jm({item:t}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${ae(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${Z(t.timestamp)}</div>
      <div class="command-card-sub">${Lr(t)}</div>
    </article>
  `}function Vm({node:t}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${ae(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?i`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function Ym({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,o=e.chain,r=(o==null?void 0:o.run_id)??null;return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${M(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
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
              <span class="command-tag ${ae(o.status)}">${o.status}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">run ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?i`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{xe("swarm"),gt("command",{surface:"swarm",operation_id:e.operation_id,...r?{run_id:r}:{}})}}
        >
          Swarm Live
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{Li(e.operation_id),xe("chains"),gt("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?i`
              <button class="control-btn ghost" disabled=${lt(n)} onClick=${()=>ie(()=>Qp(e.operation_id))}>
                ${lt(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${lt(a)} onClick=${()=>ie(()=>tm(e.operation_id))}>
                ${lt(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?i`
              <button class="control-btn ghost" disabled=${lt(s)} onClick=${()=>ie(()=>Zp(e.operation_id))}>
                ${lt(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Xm({card:t}){var n;const e=t.detachment;return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${M(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${Z(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Pr(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${Z(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?i`<span class="command-tag ${om(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Qm({alert:t}){return i`
    <article class="command-alert ${M(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${M(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${Z(t.timestamp)}</span>
      </div>
      ${t.detail?i`<p>${t.detail}</p>`:null}
    </article>
  `}function Ei({event:t}){return i`
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
      <pre class="command-trace-detail">${Rr(t.detail)}</pre>
    </article>
  `}function Zm({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return i`
    <article class="command-card ${M(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${M(t.status)}">${t.status??"pending"}</span>
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
              <button class="control-btn ghost" disabled=${lt(e)} onClick=${()=>ie(()=>nm(t.decision_id))}>
                ${lt(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${lt(n)} onClick=${()=>ie(()=>sm(t.decision_id))}>
                ${lt(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function tv({row:t}){var c,d,m;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((c=e.policy)!=null&&c.frozen),o=!!((d=e.policy)!=null&&d.kill_switch),r=Math.round((t.utilization??0)*100);return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${M(r>100?"bad":r>70?"warn":"ok")}">${r}%</span>
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
        <button class="control-btn ghost" disabled=${lt(n)} onClick=${()=>ie(()=>am(e.unit_id,!a))}>
          ${lt(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${lt(s)} onClick=${()=>ie(()=>im(e.unit_id,!o))}>
          ${lt(s)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function ev({item:t}){return i`
    <article class="command-guide-card ${M(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${M(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Kr({blocker:t}){return i`
    <article class="command-alert ${M(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${M(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function nv({worker:t}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${M(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
  `}function sv(){var G,v,F,tt,W,et,b,Nt,Qt,ve,_e,j,Rt,fe,tn,en,Wn,Bn,Gn,Jn;const t=Hn(),e=Ce.value,n=pe.value,s=qt.value,a=Rm(),o=e!=null&&e.operation?((G=qn.value)==null?void 0:G.operations.find(q=>{var Te;return q.operation.operation_id===((Te=e.operation)==null?void 0:Te.operation_id)}))??null:null,r=(e==null?void 0:e.workers)??[],c=(s==null?void 0:s.worker_cards)??[],d=r.length>0?r.map(Pm):c.map(Lm),m=Im(),u=((v=t==null?void 0:t.decisions.summary)==null?void 0:v.pending)??0,p=(n==null?void 0:n.pending_confirms)??[],_=(e==null?void 0:e.blockers)??[],$=(s==null?void 0:s.recommended_actions)??[],k=(s==null?void 0:s.attention_items)??[],A=((F=e==null?void 0:e.recent_messages[0])==null?void 0:F.timestamp)??null,w=((tt=e==null?void 0:e.recent_trace_events[0])==null?void 0:tt.timestamp)??null,L=A??w??null,z=a==null?void 0:a.summary,E=((W=e==null?void 0:e.summary)==null?void 0:W.expected_workers)??(typeof(z==null?void 0:z.planned_worker_count)=="number"?z.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,I=((et=e==null?void 0:e.summary)==null?void 0:et.joined_workers)??(typeof(z==null?void 0:z.active_agent_count)=="number"?z.active_agent_count:void 0)??d.length,N=_.length>0||u>0||p.length>0?"warn":m||a?"ok":"warn",Y=((b=t==null?void 0:t.swarm_status)==null?void 0:b.lanes.filter(q=>q.present))??[];return rt(()=>{ut()},[]),rt(()=>{a!=null&&a.session_id&&Ve(a.session_id)},[a==null?void 0:a.session_id,n,(Nt=e==null?void 0:e.detachment)==null?void 0:Nt.session_id]),!m&&!a?zs.value||Sn.value?i`<div class="empty-state">live war room 불러오는 중…</div>`:i`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">라이브 워룸</div>
          <${D} panelId="command.warroom" compact=${!0} />
        </div>
        <div class="command-warroom-empty-copy">
          <strong>현재 live run 없음</strong>
          <p>활성 operation 또는 team session이 시작되면 이 화면이 자동으로 붙잡습니다.</p>
        </div>
        <div class="command-action-row">
          <${te} label="작전 보기" surface="operations" />
          <${te} label="스웜 보기" surface="swarm" />
          <${te} label="개입 열기" />
          <${te} label="제어 보기" surface="control" />
        </div>
      </section>
    `:i`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${M(N)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">Live War Room</span>
            <strong>${((Qt=e==null?void 0:e.operation)==null?void 0:Qt.objective)??(a==null?void 0:a.session_id)??"active run"}</strong>
            <div class="command-card-sub">
              ${((ve=e==null?void 0:e.operation)==null?void 0:ve.operation_id)??"operation 없음"}
              ${a!=null&&a.session_id?` · session ${a.session_id}`:""}
              ${(_e=e==null?void 0:e.detachment)!=null&&_e.detachment_id?` · detachment ${e.detachment.detachment_id}`:""}
            </div>
          </div>
          <div class="command-action-row">
            <${te}
              label="스웜 상세"
              surface="swarm"
              params=${{...(j=e==null?void 0:e.operation)!=null&&j.operation_id?{operation_id:e.operation.operation_id}:{},...e!=null&&e.run_id?{run_id:e.run_id}:{}}}
            />
            <${te} label="트레이스" surface="trace" />
            ${o?i`<${te}
                  label="체인"
                  surface="chains"
                  params=${{operation:o.operation.operation_id}}
                />`:null}
            <${te} label="Intervene" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>Workers</span>
            <strong>${I??0}/${E??0}</strong>
            <small>${((Rt=e==null?void 0:e.summary)==null?void 0:Rt.completed_workers)??0} 완료 · ${d.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>Runtime</span>
            <strong>${(fe=e==null?void 0:e.provider)!=null&&fe.runtime_blocker?"blocked":(tn=e==null?void 0:e.provider)!=null&&tn.provider_reachable?"ready":a?ha(a.status):"check"}</strong>
            <small>slots ${((en=e==null?void 0:e.provider)==null?void 0:en.active_slots_now)??0}/${((Wn=e==null?void 0:e.provider)==null?void 0:Wn.actual_slots)??((Bn=e==null?void 0:e.provider)==null?void 0:Bn.total_slots)??0} · ctx ${((Gn=e==null?void 0:e.provider)==null?void 0:Gn.actual_ctx)??((Jn=e==null?void 0:e.provider)==null?void 0:Jn.ctx_per_slot)??0}</small>
          </div>
          <div class="monitor-stat-card ${M(_.length>0||u>0?"warn":"ok")}">
            <span>Pressure</span>
            <strong>${_.length+u+p.length}</strong>
            <small>blockers ${_.length} · approvals ${u} · confirms ${p.length}</small>
          </div>
          <div class="monitor-stat-card">
            <span>Last signal</span>
            <strong>${Z(L)}</strong>
            <small>${A?"message":w?"trace":"waiting"}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            ${Y.length>0?i`
                  <${Fr} lanes=${Y} />
                  <${Or} lanes=${Y} />
                `:a?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${M(je(a.status))}">${ha(a.status)}</span>
                      </div>
                      <p>command-plane live run은 아직 옅지만, session 쪽 worker와 digest를 기준으로 워룸을 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${cn(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${cn(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:i`<div class="empty-state">보이는 lane이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Worker Roster</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            ${d.length>0?i`<div class="command-card-stack">
                  ${d.map(q=>i`<${Mm} worker=${q} />`)}
                </div>`:i`<div class="empty-state">활성 worker 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Live Feed</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            ${e&&e.recent_messages.length>0?i`<div class="command-trace-stack">
                  ${e.recent_messages.map(q=>i`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${q.from}</strong>
                          <span class="command-chip">${Z(q.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${q.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${q.content}</pre>
                    </article>
                  `)}
                </div>`:$.length>0||k.length>0?i`<div class="command-card-stack">
                    ${$.slice(0,4).map(q=>i`
                      <article class="command-guide-card ${lo(q)}">
                        <div class="command-guide-head">
                          <strong>${q.action_type}</strong>
                          <span class="command-chip ${lo(q)}">${q.target_type}</span>
                        </div>
                        <p>${q.reason}</p>
                      </article>
                    `)}
                    ${k.slice(0,3).map(q=>i`
                      <article class="command-alert ${M(q.severity)}">
                        <div class="command-card-head">
                          <strong>${q.kind}</strong>
                          <span class="command-chip ${M(q.severity)}">${q.severity}</span>
                        </div>
                        <p>${q.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?i`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((q,Te)=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>session-event-${Te+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${Rr(q)}</pre>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">메시지나 attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Trace Feed</div>
              <${D} panelId="command.trace" compact=${!0} />
            </div>
            ${e&&e.recent_trace_events.length>0?i`<div class="command-trace-stack">
                  ${e.recent_trace_events.map(q=>i`<${Ei} event=${q} />`)}
                </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Pressure</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${_.length>0?_.map(q=>i`<${Kr} blocker=${q} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
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
                        ${p.slice(0,3).map(q=>i`<span class="command-tag">${q.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
            </div>
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Focus Detail</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${e!=null&&e.operation?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${e.operation.objective}</strong>
                          <div class="command-card-sub">${e.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${M(je(e.operation.status))}">${e.operation.status}</span>
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
                        <span class="command-chip ${M(je(e.detachment.status))}">${e.detachment.status??"active"}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Leader</span><span>${e.detachment.leader_id??"unassigned"}</span>
                        <span>Roster</span><span>${e.detachment.roster.length}</span>
                        <span>Session</span><span>${e.detachment.session_id??"none"}</span>
                        <span>Heartbeat</span><span>${Pr(e.detachment.heartbeat_deadline)}</span>
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
                        <span class="command-chip ${M(je(a.status))}">${ha(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${cn(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${cn(a.remaining_sec)}</span>
                        <span>Done delta</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function av(){var d,m,u,p,_,$,k,A,w,L,z,E,I,N,Y,G,v,F,tt,W,et;const t=Ce.value,e=Sm(),n=zr(),s=(d=t==null?void 0:t.provider)!=null&&d.runtime_blocker?"blocked":(m=t==null?void 0:t.provider)!=null&&m.provider_reachable?"ready":"check",a=((u=t==null?void 0:t.provider)==null?void 0:u.actual_slots)??((p=t==null?void 0:t.provider)==null?void 0:p.total_slots)??0,o=((_=t==null?void 0:t.provider)==null?void 0:_.expected_slots)??"n/a",r=(($=t==null?void 0:t.provider)==null?void 0:$.actual_ctx)??((k=t==null?void 0:t.provider)==null?void 0:k.ctx_per_slot)??0,c=((A=t==null?void 0:t.provider)==null?void 0:A.expected_ctx)??"n/a";return i`
    <div class="command-section-stack">
      <${qm} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${zs.value?i`<div class="empty-state">Loading swarm live state…</div>`:js.value?i`<div class="empty-state error">${js.value}</div>`:t?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((w=t.summary)==null?void 0:w.joined_workers)??0}/${((L=t.summary)==null?void 0:L.expected_workers)??0}</strong><small>${((z=t.summary)==null?void 0:z.live_workers)??0}개 가동 · ${((E=t.summary)==null?void 0:E.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${o} · ctx ${r}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(I=t.summary)!=null&&I.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((N=t.provider)==null?void 0:N.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(Y=t.summary)!=null&&Y.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((G=t.operation)==null?void 0:G.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((v=t.squad)==null?void 0:v.label)??"없음"}</span>
                      <span>실행체</span><span>${((F=t.detachment)==null?void 0:F.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((tt=t.summary)==null?void 0:tt.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((W=t.summary)==null?void 0:W.final_markers_seen)??0}</span>
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
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?i`<div class="command-card-stack">
                ${t.checklist.map(b=>i`<${ev} item=${b} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?i`<div class="command-card-stack">
                ${t.workers.map(b=>i`<${nv} worker=${b} />`)}
              </div>`:i`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${D} panelId="command.swarm" compact=${!0} />
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
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?i`<div class="command-card-stack">
                ${t.blockers.map(b=>i`<${Kr} blocker=${b} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${D} panelId="command.swarm" compact=${!0} />
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
            <${D} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${t.recent_trace_events.map(b=>i`<${Ei} event=${b} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function iv(){const t=Ut.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${D} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?i`<div class="command-card-stack">
              ${t.operations.operations.map(e=>i`<${Ym} card=${e} />`)}
            </div>`:i`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${D} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>i`<${Xm} card=${e} />`)}
            </div>`:i`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function ov(){var c,d,m,u,p,_,$,k,A,w,L,z,E,I,N,Y;const t=qn.value,e=(t==null?void 0:t.operations)??[],n=Ke.value,s=e.find(G=>G.operation.operation_id===n)??e[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,o=((d=Cn.value)==null?void 0:d.run)??(s==null?void 0:s.preview_run)??null,r=!((m=Cn.value)!=null&&m.run)&&!!(s!=null&&s.preview_run);return rt(()=>{a?Yp(a):Vp()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${D} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${ae(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${ae(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(t==null?void 0:t.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((u=t==null?void 0:t.summary)==null?void 0:u.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((p=t==null?void 0:t.summary)==null?void 0:p.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((_=t==null?void 0:t.summary)==null?void 0:_.recent_failures)??0}</span>
            <span>Last Event</span><span>${Z(($=t==null?void 0:t.summary)==null?void 0:$.last_history_event_at)}</span>
          </div>
        </article>

        ${Os.value?i`<div class="empty-state error">${Os.value}</div>`:null}

        ${ci.value&&!t?i`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?i`
                <div class="command-chain-list">
                  ${e.map(G=>i`
                    <${Gm}
                      overlay=${G}
                      selected=${(s==null?void 0:s.operation.operation_id)===G.operation.operation_id}
                      onSelect=${()=>Li(G.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(G=>i`<${Jm} item=${G} />`)}
                </div>
              `:i`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chain Detail</div>
          <${D} panelId="command.chains" compact=${!0} />
        </div>
        ${s?i`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${ae((k=s.operation.chain)==null?void 0:k.status)}">
                    ${((A=s.operation.chain)==null?void 0:A.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((w=s.operation.chain)==null?void 0:w.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((L=s.operation.chain)==null?void 0:L.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${Kn((z=s.runtime)==null?void 0:z.progress)}</span>
                  <span>Elapsed</span><span>${cn((E=s.runtime)==null?void 0:E.elapsed_sec)}</span>
                  <span>Updated</span><span>${Z(((I=s.operation.chain)==null?void 0:I.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(N=s.operation.chain)!=null&&N.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((Y=s.operation.chain)==null?void 0:Y.chain_id)??"graph"}</span>
                      </div>
                      <${Bm} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"failed":r?"preview":"captured":"pending"}
                  </span>
                </div>
                ${Fs.value?i`<div class="empty-state">Loading run detail…</div>`:wn.value?i`<div class="empty-state error">${wn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${o.chain_id}</span>
                            <span>Run</span><span>${o.run_id??"preview only"}</span>
                            <span>Duration</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${o.nodes.length}</span>
                          </div>
                          ${r?i`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(G=>i`<${Vm} node=${G} />`)}
                          </div>
                        `:i`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:i`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function rv(){const t=Ut.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${D} panelId="command.topology" compact=${!0} />
      </div>
      ${t&&t.topology.units.length>0?i`${t.topology.units.map(e=>i`<${qr} node=${e} />`)}`:i`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function lv(){const t=Ut.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${D} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>i`<${Qm} alert=${e} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function cv(){const t=Ut.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${D} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?i`<div class="command-trace-stack">
            ${t.traces.events.map(e=>i`<${Ei} event=${e} />`)}
          </div>`:i`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function dv(){const t=Ut.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${D} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>i`<${Zm} decision=${e} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${D} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>i`<${tv} row=${e} />`)}
            </div>`:i`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function uv(){if(V.value==="warroom")return i`<${sv} />`;if(V.value==="summary")return i`<${Hm} />`;if(V.value==="swarm")return i`<${av} />`;if(!Ut.value)return i`<${Wm} />`;switch(V.value){case"chains":return i`<${ov} />`;case"topology":return i`<${rv} />`;case"alerts":return i`<${lv} />`;case"trace":return i`<${cv} />`;case"control":return i`<${dv} />`;case"operations":default:return i`<${iv} />`}}function pv(){return rt(()=>{Se(),se(),Xp(),Bt()},[]),rt(()=>{if(O.value.tab!=="command")return;const t=O.value.params.surface,e=O.value.params.operation,n=On(O.value);if(ro(t))xe(t);else if(n){const s=cr(n);ro(s)&&xe(s)}else t||xe("warroom");e&&Li(e),(t==="swarm"||t==="warroom"||V.value==="warroom")&&Bt(),(t==="warroom"||V.value==="warroom")&&ut()},[O.value.tab,O.value.params.surface,O.value.params.operation,O.value.params.operation_id,O.value.params.run_id,O.value.params.source,O.value.params.action_type,O.value.params.target_type,O.value.params.target_id,O.value.params.focus_kind]),rt(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,Se(),se(),(V.value==="swarm"||V.value==="warroom")&&Bt(),V.value==="warroom"&&ut()},250))},n=new EventSource(_m()),s=pm.map(a=>{const o=()=>e();return n.addEventListener(a,o),{type:a,handler:o}});return n.onerror=()=>{e()},()=>{s.forEach(({type:a,handler:o})=>{n.removeEventListener(a,o)}),n.close(),t&&window.clearTimeout(t)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{ie(()=>em())}}
            disabled=${lt("dispatch:tick")}
          >
            ${lt("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Se(),se(),Bt(),V.value==="warroom"&&ut()}}
            disabled=${Rs.value}
          >
            ${Rs.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Ls.value?i`<div class="empty-state error">${Ls.value}</div>`:null}
      ${Ds.value?i`<div class="empty-state error">${Ds.value}</div>`:null}
      <${xt} surfaceId="command" />
      <${ym} />
      ${V.value==="warroom"?null:i`<${bm} />`}
      <${Km} />
      <${uv} />
    </section>
  `}const Ur="masc_dashboard_agent_name";function mv(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Ur))==null?void 0:s.trim())||"dashboard"}const ca=f(mv()),Ue=f(""),di=f("운영 점검"),He=f(""),Tn=f(""),In=f("2"),Nn=f(""),zt=f("note"),Rn=f(""),Pn=f(""),Ln=f(""),Mn=f("2"),qs=f("운영자 중지 요청"),Ks=f(""),We=f(""),Zn=f(null);function vv(t){const e=t.trim()||"dashboard";ca.value=e,localStorage.setItem(Ur,e)}function co(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function _v(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function Ye(t){return typeof t=="string"?t.trim().toLowerCase():""}function fv(t){var s;const e=Ye(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=Ye((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function ya(t){const e=Ye(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function uo(t){return t.some(e=>Ye(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function gv(t){return t.target_type==="team_session"}function $v(t){return t.target_type==="keeper"}function ts(t){switch(t){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";case"keeper_msg":return"keeper 메시지";default:return(t==null?void 0:t.trim())||"액션"}}function es(t){switch(t){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";default:return(t==null?void 0:t.trim())||"target"}}function on(t){switch(Ye(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function po(t){return t?"확인 후 실행":"즉시 실행"}function hv(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";default:return t}}function ft(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function yv(t){if(t.action_type==="team_task_inject")return"task";if(t.action_type==="team_broadcast")return"broadcast";if(t.action_type==="team_note")return"note";if(t.action_type==="team_turn"){const e=ft(t.suggested_payload,"turn_kind");if(e==="broadcast"||e==="task")return e}return"note"}function bv(t){const e=t.suggested_payload;if(t.target_type==="room"){if(t.action_type==="broadcast"){Ue.value=ft(e,"message")??t.summary;return}t.action_type==="task_inject"&&(He.value=ft(e,"title")??"운영자 주입 작업",Tn.value=ft(e,"description")??t.summary,In.value=ft(e,"priority")??In.value);return}if(t.target_type==="team_session"){if(t.target_id&&(Nn.value=t.target_id),t.action_type==="team_stop"){qs.value=ft(e,"reason")??t.summary;return}zt.value=yv(t);const n=ft(e,"message");n&&(Rn.value=n),zt.value==="task"&&(Pn.value=ft(e,"task_title")??ft(e,"title")??"운영자 주입 작업",Ln.value=ft(e,"task_description")??ft(e,"description")??t.summary,Mn.value=ft(e,"task_priority")??ft(e,"priority")??Mn.value);return}t.target_type==="keeper"&&(t.target_id&&(Ks.value=t.target_id),We.value=ft(e,"message")??t.summary)}function kv(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function we(t){const e=ca.value.trim()||"dashboard";try{const n=await ip({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?P("확인 대기열에 올렸습니다","warning"):P(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return P(s,"error"),null}}async function mo(){const t=Ue.value.trim();if(!t)return;await we({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(Ue.value="")}async function xv(){await we({action_type:"room_pause",target_type:"room",payload:{reason:di.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function vo(){await we({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function Sv(){const t=He.value.trim();if(!t)return;await we({action_type:"task_inject",target_type:"room",payload:{title:t,description:Tn.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(In.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(He.value="",Tn.value="")}async function Av(){var r;const t=pe.value,e=Nn.value||((r=t==null?void 0:t.sessions[0])==null?void 0:r.session_id)||"";if(!e){P("먼저 세션을 고르세요","warning");return}const n={},s=Rn.value.trim();s&&(n.message=s);let a="team_note";zt.value==="broadcast"?a="team_broadcast":zt.value==="task"&&(a="team_task_inject"),zt.value==="task"&&(n.task_title=Pn.value.trim()||"운영자 주입 작업",n.task_description=Ln.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(Mn.value,10)||2),await we({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Rn.value="",zt.value==="task"&&(Pn.value="",Ln.value=""))}async function Cv(){var n;const t=pe.value,e=Nn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){P("먼저 세션을 고르세요","warning");return}await we({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:qs.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function wv(){var a;const t=pe.value,e=Ks.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=We.value.trim();if(!e){P("먼저 keeper를 고르세요","warning");return}if(!n)return;await we({action_type:"keeper_message",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`${e}에게 메시지를 보냈습니다`})&&(We.value="")}async function Tv(t){const e=ca.value.trim()||"dashboard";try{await op(e,t),P("확인 실행을 완료했습니다","success")}catch(n){const s=n instanceof Error?n.message:"확인 실행에 실패했습니다";P(s,"error")}}function Iv(){var N,Y,G;const t=pe.value,e=O.value.tab==="intervene"?On(O.value):null,n=mr.value,s=qt.value,a=(t==null?void 0:t.room)??{},o=(t==null?void 0:t.sessions)??[],r=(t==null?void 0:t.keepers)??[],c=(t==null?void 0:t.pending_confirms)??[],d=(t==null?void 0:t.recent_messages)??[],m=(n==null?void 0:n.recommended_actions)??[],u=(t==null?void 0:t.available_actions)??[],p=o.find(v=>v.session_id===Nn.value)??o[0]??null,_=r.find(v=>v.name===Ks.value)??r[0]??null,$=(n==null?void 0:n.attention_items)??[],k=$.filter(gv),A=$.filter($v),w=o.filter(v=>fv(v)!=="ok"),L=r.filter(v=>ya(v)!=="ok"),z=d.slice(0,5),E=kv(e,o,r);rt(()=>{Yt()},[]),rt(()=>{if(O.value.tab!=="intervene"){Zn.value=null;return}if(!e){Zn.value=null;return}Zn.value!==e.id&&(Zn.value=e.id,bv(e))},[O.value.tab,O.value.params.source,O.value.params.action_type,O.value.params.target_type,O.value.params.target_id,O.value.params.focus_kind,e==null?void 0:e.id]),rt(()=>{const v=(p==null?void 0:p.session_id)??null;Ve(v)},[p==null?void 0:p.session_id]);const I=[{key:"room",label:"Room 게이트",value:a.paused?"일시정지":"열림",detail:a.paused?`재개 전환 대기 중${a.pause_reason?` · ${a.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:a.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:c.length,detail:c.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:c.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:k.length>0?k.length:o.length,detail:k.length>0?((N=k[0])==null?void 0:N.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":o.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:k.length>0?uo(k):o.length===0?"warn":w.some(v=>Ye(v.status)==="paused")?"bad":w.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:A.length>0?A.length:L.length,detail:A.length>0?((Y=A[0])==null?void 0:Y.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":L.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:A.length>0?uo(A):L.some(v=>ya(v)==="bad")?"bad":L.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${xt} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">Intervene</div>
            <${D} panelId="intervene.action_studio" compact=${!0} />
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
            value=${ca.value}
            onInput=${v=>vv(v.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{ut(),Yt(),Ve((p==null?void 0:p.session_id)??null)}}
            disabled=${Sn.value||Q.value}
          >
            ${Sn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${le.value?i`<section class="ops-banner error">${le.value}</section>`:null}
      ${Je.value?i`<section class="ops-banner error">${Je.value}</section>`:null}
      ${e?i`
        <section class="ops-banner ${E?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${Ii(e.action_type)}</span>
            <span>${Ti(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?i`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${E?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const v=[];if(c.length>0&&v.push({label:`확인 대기 ${c.length}건 처리`,desc:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:"bad",onClick:()=>{const F=document.querySelector(".ops-pending-section");F==null||F.scrollIntoView({behavior:"smooth"})}}),a.paused&&v.push({label:"Room 재개",desc:`현재 일시정지 상태${a.pause_reason?` (${a.pause_reason})`:""}`,tone:"warn",onClick:()=>void vo()}),L.length>0){const F=L.filter(tt=>ya(tt)==="bad");v.push({label:F.length>0?`Keeper ${F.length}개 오프라인`:`Keeper ${L.length}개 점검 필요`,desc:F.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:F.length>0?"bad":"warn",onClick:()=>{const tt=document.querySelector(".ops-keeper-section");tt==null||tt.scrollIntoView({behavior:"smooth"})}})}return v.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${v.slice(0,3).map(F=>i`
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
          <${D} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 room인지, session인지, keeper인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${I.map(v=>i`
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
              <${D} panelId="intervene.action_studio" compact=${!0} />
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
                value=${Ue.value}
                onInput=${v=>{Ue.value=v.target.value}}
                onKeyDown=${v=>{v.key==="Enter"&&mo()}}
                disabled=${Q.value}
              />
              <button class="control-btn" onClick=${()=>{mo()}} disabled=${Q.value||Ue.value.trim()===""}>
                보내기
              </button>
            </div>

            <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
            <div class="control-row ops-split-row">
              <input
                id="ops-pause-reason"
                class="control-input"
                type="text"
                value=${di.value}
                onInput=${v=>{di.value=v.target.value}}
                disabled=${Q.value}
              />
              <button class="control-btn ghost" onClick=${()=>{xv()}} disabled=${Q.value}>
                일시정지
              </button>
              <button class="control-btn ghost" onClick=${()=>{vo()}} disabled=${Q.value}>
                재개
              </button>
            </div>

            <div class="ops-section-head">작업 주입</div>
            <input
              class="control-input"
              type="text"
              placeholder="작업 제목"
              value=${He.value}
              onInput=${v=>{He.value=v.target.value}}
              disabled=${Q.value}
            />
            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="작업 설명"
              value=${Tn.value}
              onInput=${v=>{Tn.value=v.target.value}}
              disabled=${Q.value}
            ></textarea>
            <div class="control-row ops-split-row">
              <select
                class="control-input ops-select"
                value=${In.value}
                onChange=${v=>{In.value=v.target.value}}
                disabled=${Q.value}
              >
                <option value="1">P1</option>
                <option value="2">P2</option>
                <option value="3">P3</option>
                <option value="4">P4</option>
                <option value="5">P5</option>
              </select>
              <button class="control-btn" onClick=${()=>{Sv()}} disabled=${Q.value||He.value.trim()===""}>
                주입
              </button>
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">추천 개입</div>
              <${D} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
            ${An.value&&!n?i`
              <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
            `:m.length>0?i`
              <div class="ops-log-list">
                ${m.map(v=>i`
                  <article key=${`${v.action_type}:${v.target_type}:${v.target_id??"room"}`} class="ops-log-entry ${v.severity}">
                    <div class="ops-log-head">
                      <strong>${ts(v.action_type)}</strong>
                      <span>${es(v.target_type)}${v.target_id?` · ${v.target_id}`:""}</span>
                      <span>${po(v.confirm_required)}</span>
                    </div>
                    <div class="ops-log-body">${v.reason}</div>
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
              <${D} panelId="intervene.pending_confirmations" compact=${!0} />
            </div>
            <p class="ops-context-note">미리보기만 끝났고 아직 사람이 눌러줘야 하는 액션만 남깁니다.</p>
            ${c.length>0?i`
              <div class="ops-confirmation-list">
                ${c.map(v=>i`
                  <article key=${v.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${ts(v.action_type)}</strong>
                      <span>${es(v.target_type)}${v.target_id?` · ${v.target_id}`:""}</span>
                      <span>${v.delegated_tool??"위임 도구 확인 필요"}</span>
                    </div>
                    ${v.preview?i`<pre class="ops-code-block compact">${co(v.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{Tv(v.confirm_token)}} disabled=${Q.value}>
                        실행
                      </button>
                      <span class="ops-token">${v.confirm_token}</span>
                    </div>
                  </article>
                `)}
              </div>
            `:i`<div class="ops-empty">지금 승인 대기는 없습니다.</div>`}
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 Room 메시지</div>
              <${D} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
            ${z.length>0?i`
              <div class="ops-feed-list">
                ${z.map(v=>i`
                  <article key=${v.seq??v.id??v.timestamp} class="ops-feed-item">
                    <div class="ops-feed-meta">
                      <strong>${v.from}</strong>
                      <span>${v.timestamp}</span>
                    </div>
                    <div class="ops-feed-content">${v.content}</div>
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
              <${D} panelId="intervene.session_queue" compact=${!0} />
            </div>
            <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

            <div class="ops-entity-list">
              ${o.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:o.map(v=>{var F;return i`
                <button
                  key=${v.session_id}
                  class="ops-entity-card ${(p==null?void 0:p.session_id)===v.session_id?"active":""}"
                  onClick=${()=>{Nn.value=v.session_id}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${v.session_id}</strong>
                    <span class="status-badge ${v.status??"idle"}">${on(v.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round(v.progress_pct??0)}%</span>
                    <span>${v.done_delta_total??0}건 완료</span>
                    <span>${(F=v.team_health)!=null&&F.status?on(String(v.team_health.status)):"상태 확인 필요"}</span>
                  </div>
                </button>
              `})}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">선택한 Session 요약</div>
              <${D} panelId="intervene.session_digest" compact=${!0} />
            </div>
            <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
            ${p&&s?i`
              <div class="ops-log-list">
                ${s.attention_items.length>0?s.attention_items.map(v=>i`
                  <article key=${`${v.kind}:${v.target_id??"session"}`} class="ops-log-entry ${v.severity}">
                    <div class="ops-log-head">
                      <strong>${v.kind}</strong>
                      <span>${es(v.target_type)}${v.target_id?` · ${v.target_id}`:""}</span>
                    </div>
                    <div class="ops-log-body">${v.summary}</div>
                  </article>
                `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
                ${s.worker_cards.length>0?s.worker_cards.map(v=>i`
                  <article key=${`${v.actor??v.spawn_role??"worker"}:${v.spawn_agent??v.runtime_pool??"runtime"}`} class="ops-log-entry">
                    <div class="ops-log-head">
                      <strong>${v.actor??v.spawn_role??"worker"}</strong>
                      <span>${on(v.status)}</span>
                      <span>${v.spawn_agent??v.runtime_pool??"runtime 확인 필요"}</span>
                    </div>
                    <div class="ops-log-body">
                      ${v.worker_class??"worker"}${v.lane_id?` · ${v.lane_id}`:""}${v.routing_reason?` · ${v.routing_reason}`:""}
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
              <${D} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>

            ${p?i`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${p.session_id}</div>
                <div class="ops-detail-meta">
                  <span>상태: ${on(p.status)}</span>
                  <span>경과: ${p.elapsed_sec??0}초</span>
                  <span>남은 시간: ${p.remaining_sec??0}초</span>
                </div>
                ${p.recent_events&&p.recent_events.length>0?i`
                  <pre class="ops-code-block compact">${co(p.recent_events.slice(-3))}</pre>
                `:null}
              </div>
            `:i`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

            <label class="control-label" for="ops-turn-kind">세션 액션</label>
            <div class="control-row ops-split-row">
              <select
                id="ops-turn-kind"
                class="control-input ops-select"
                value=${zt.value}
                onChange=${v=>{zt.value=v.target.value}}
                disabled=${Q.value||!p}
              >
                <option value="note">노트</option>
                <option value="broadcast">방송</option>
                <option value="task">작업</option>
              </select>
              <button class="control-btn" onClick=${()=>{Av()}} disabled=${Q.value||!p}>
                적용
              </button>
            </div>
            <div class="ops-context-note">현재 선택: ${hv(zt.value)}</div>

            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="세션에 남길 메시지"
              value=${Rn.value}
              onInput=${v=>{Rn.value=v.target.value}}
              disabled=${Q.value||!p}
            ></textarea>

            ${zt.value==="task"?i`
              <input
                class="control-input"
                type="text"
                placeholder="주입할 작업 제목"
                value=${Pn.value}
                onInput=${v=>{Pn.value=v.target.value}}
                disabled=${Q.value||!p}
              />
              <textarea
                class="control-textarea"
                rows=${2}
                placeholder="주입할 작업 설명"
                value=${Ln.value}
                onInput=${v=>{Ln.value=v.target.value}}
                disabled=${Q.value||!p}
              ></textarea>
              <select
                class="control-input ops-select"
                value=${Mn.value}
                onChange=${v=>{Mn.value=v.target.value}}
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
                value=${qs.value}
                onInput=${v=>{qs.value=v.target.value}}
                disabled=${Q.value||!p}
              />
              <button class="control-btn ghost" onClick=${()=>{Cv()}} disabled=${Q.value||!p}>
                세션 중지
              </button>
            </div>
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel ops-keeper-section">
            <div class="card-title-row">
              <div class="card-title">Keeper 개입</div>
              <${D} panelId="intervene.keeper_queue" compact=${!0} />
            </div>
            <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

            <div class="ops-entity-list">
              ${r.length===0?i`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:r.map(v=>i`
                <button
                  key=${v.name}
                  class="ops-entity-card ${(_==null?void 0:_.name)===v.name?"active":""}"
                  onClick=${()=>{Ks.value=v.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${v.name}</strong>
                    <span class="status-badge ${v.status??"idle"}">${on(v.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${v.model??"model 확인 필요"}</span>
                    <span>${typeof v.context_ratio=="number"?`${Math.round(v.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                    <span>${_v(v.last_turn_ago_s)}</span>
                  </div>
                </button>
              `)}
            </div>
          </section>

          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">선택한 Keeper 액션</div>
              <${D} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">선택한 keeper에만 직접 메시지를 보내서 probe, 수정, 재지시를 합니다.</p>

            ${_?i`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${_.name}</div>
                <div class="ops-detail-meta">
                  <span>자율성: ${_.autonomy_level??"확인 없음"}</span>
                  <span>세대: ${_.generation??0}</span>
                  <span>활성 목표: ${((G=_.active_goal_ids)==null?void 0:G.length)??0}</span>
                </div>
              </div>
            `:i`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

            <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
            <textarea
              id="ops-keeper-message"
              class="control-textarea"
              rows=${6}
              placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
              value=${We.value}
              onInput=${v=>{We.value=v.target.value}}
              disabled=${Q.value||!_}
            ></textarea>
            <div class="control-row">
              <button class="control-btn" onClick=${()=>{wv()}} disabled=${Q.value||!_||We.value.trim()===""}>
                keeper에 보내기
              </button>
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">가능한 액션 목록</div>
              <${D} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
            <div class="ops-log-list">
              ${u.length?u.map(v=>i`
                    <article key=${`${v.action_type}:${v.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${ts(v.action_type)}</strong>
                        <span>${es(v.target_type)}</span>
                        <span>${po(v.confirm_required)}</span>
                      </div>
                      <div class="ops-log-body">${v.description??"설명이 아직 없습니다."}</div>
                    </article>
                  `):i`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 개입 로그</div>
              <${D} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <div class="ops-log-list">
              ${Is.value.length===0?i`
                <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
              `:Is.value.map(v=>i`
                <article key=${v.id} class="ops-log-entry ${v.outcome}">
                  <div class="ops-log-head">
                    <strong>${ts(v.action_type)}</strong>
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
  `}function Nv({text:t}){if(!t)return null;const e=Rv(t);return i`<div class="markdown-content">${e}</div>`}function Rv(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(i`<pre><code class=${c?`language-${c}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&r.push(c),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const m=e[s].replace("</think>","").trim();m&&r.push(m),s++}const d=r.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${ba(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(i`<blockquote>${ba(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;o.push(r),s++}o.length>0&&n.push(i`<p>${ba(o.join(`
`))}</p>`)}return n}function ba(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&e.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Hr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],vs=f(null),_s=f([]),Xe=f(!1),ke=f(null),pn=f(""),mn=f(!1);function Pv(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Lv=f(Pv());function Mv(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function _o(t){return t.updated_at!==t.created_at}async function zi(t){ke.value=t,vs.value=null,_s.value=[],Xe.value=!0;try{const e=await Xl(t);if(ke.value!==t)return;vs.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},_s.value=e.comments??[]}catch{ke.value===t&&(vs.value=null,_s.value=[])}finally{ke.value===t&&(Xe.value=!1)}}async function fo(t){const e=pn.value.trim();if(e){mn.value=!0;try{await Ql(t,Lv.value,e),pn.value="",P("Comment posted","success"),await zi(t),Ot()}catch{P("Failed to post comment","error")}finally{mn.value=!1}}}function Dv(){const t=$n.value;return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Hr.map(e=>i`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{$n.value=e.id,Ot()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${De.value?"is-active":""}"
          onClick=${()=>{De.value=!De.value,Ot()}}
        >
          ${De.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${Ot} disabled=${yn.value}>
          ${yn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function ka(){var e;const t=((e=Hr.find(n=>n.id===$n.value))==null?void 0:e.label)??$n.value;return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Visible posts</span>
        <strong>${ta.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Sort</span>
        <strong>${t}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${De.value?"Auto reports hidden":"Full memory feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${ni.value?i`<${it} timestamp=${ni.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Ev({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Oo(t.id,n),Ot()}catch{P("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>pl(t.id)}>
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
              ${_o(t)?i`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${it} timestamp=${t.created_at} /></span>
            ${_o(t)?i`<span>Updated <${it} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${Mv(t.content)}</div>
      </div>
    </div>
  `}function zv({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${it} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function jv({postId:t}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${pn.value}
        onInput=${e=>{pn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&fo(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${mn.value}
      />
      <button
        onClick=${()=>fo(t)}
        disabled=${mn.value||pn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${mn.value?"...":"Post"}
      </button>
    </div>
  `}function Ov({post:t}){ke.value!==t.id&&!Xe.value&&zi(t.id);const e=async n=>{try{await Oo(t.id,n),Ot()}catch{P("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>gt("memory")}>← Back to Memory</button>
      <${T} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${Nv} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${t.author}</span>
            <${it} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
          </div>
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${T} title="Comments" semanticId="memory.feed">
        ${Xe.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${zv} comments=${_s.value} />`}
        <${jv} postId=${t.id} />
      <//>
    </div>
  `}function Fv(){const t=ta.value,e=O.value.params.post??null,n=e?t.find(s=>s.id===e)??(ke.value===e?vs.value:null):null;return e&&!n&&ke.value!==e&&!Xe.value&&zi(e),e?n?i`
          <${xt} surfaceId="memory" />
          <${ka} />
          <${Ov} post=${n} />
        `:i`
          <div>
            <${xt} surfaceId="memory" />
            <${ka} />
            <button class="back-btn" onClick=${()=>gt("memory")}>← Back to Memory</button>
            ${Xe.value?i`<div class="loading-indicator">Loading post...</div>`:i`<div class="empty-state">Post not found</div>`}
          </div>
        `:i`
    <div>
      <${xt} surfaceId="memory" />
      <${ka} />
      <${Dv} />
      ${yn.value?i`<div class="loading-indicator">Loading memory feed...</div>`:t.length===0?i`<div class="empty-state">No posts in durable memory right now</div>`:i`
              <${T} title="Posts / Comments" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.map(s=>i`<${Ev} key=${s.id} post=${s} />`)}
                </div>
              <//>
            `}
    </div>
  `}function Wr({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,o=2*Math.PI*s,r=o*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),i`
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
  `}const xa=600*1e3,qv=1200*1e3,go=.8;function ee(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Re(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Kv(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function Uv(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Hv(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Wv(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function Bv(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function Gv(t){var d,m;const e=ea.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,s=n?Math.max(0,Date.now()-ee(n)):Number.POSITIVE_INFINITY,a=!!((d=t.current_task)!=null&&d.trim())||e.activeAssignedCount>0;let o="watching",r="ok",c="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",r="bad",c=n?"Offline or inactive":"No recent presence"):s>qv?(o="quiet",r="bad",c=a?"Working without a fresh signal":"No fresh agent signal"):a?(o="working",r=s>xa?"warn":"ok",c=s>xa?"Execution looks quiet for too long":"Task and live signal aligned"):s>xa?(o="quiet",r="warn",c="Quiet but still reachable"):t.status==="idle"&&(o="watching",r="ok",c="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:r,focus:((m=t.current_task)==null?void 0:m.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:c}}function Jv(t){const e=Zc.value.get(t.name)??"idle",n=nd.value.has(t.name),s=t.context_ratio??0;let a="healthy",o="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(a="critical",o="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||s>=go)&&(a="warning",o="warn",r=s>=go?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:a,tone:o,focus:Wv(t),note:r}}function rn({label:t,value:e,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function Vv({item:t}){const e=t.kind==="agent"?()=>ia(t.agent.name):()=>Ai(t.keeper);return i`
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
  `}function $o({row:t}){const{agent:e,motion:n}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>ia(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Wr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${ue} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${Kv(t.state)}</span>
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
  `}function Yv({row:t}){const{keeper:e}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Ai(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Wr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${ue} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Uv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?i`<span>Heartbeat <${it} timestamp=${e.last_heartbeat} /></span>`:i`<span>No heartbeat</span>`}
        <span>${Bv(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${Hv(e.context_ratio)}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?i`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function Xv(){const t=[...At.value].map(Gv).sort((u,p)=>{const _=Re(p.tone)-Re(u.tone);if(_!==0)return _;const $=p.activeTaskCount-u.activeTaskCount;return $!==0?$:ee(p.lastSignalAt)-ee(u.lastSignalAt)}),e=[...de.value].map(Jv).sort((u,p)=>{const _=Re(p.tone)-Re(u.tone);if(_!==0)return _;const $=(p.keeper.context_ratio??0)-(u.keeper.context_ratio??0);return $!==0?$:ee(p.keeper.last_heartbeat)-ee(u.keeper.last_heartbeat)}),n=t.filter(u=>u.state!=="offline"),s=t.filter(u=>u.state==="offline"),a=n.length,o=t.filter(u=>u.state==="working").length,r=t.filter(u=>u.lastSignalAt&&Date.now()-ee(u.lastSignalAt)<=12e4).length,c=t.filter(u=>u.tone!=="ok"),d=e.filter(u=>u.tone!=="ok"),m=[...d.map(u=>({kind:"keeper",key:`keeper-${u.keeper.name}`,tone:u.tone,title:u.keeper.name,subtitle:`${u.note} · ${u.focus}`,timestamp:u.keeper.last_heartbeat??null,keeper:u.keeper})),...c.map(u=>({kind:"agent",key:`agent-${u.agent.name}`,tone:u.tone,title:u.agent.name,subtitle:`${u.note} · ${u.focus}`,timestamp:u.lastSignalAt,agent:u.agent}))].sort((u,p)=>{const _=Re(p.tone)-Re(u.tone);return _!==0?_:ee(p.timestamp)-ee(u.timestamp)}).slice(0,8);return i`
    <div class="agents-monitor">
      <${xt} surfaceId="execution" />
      <div class="stats-grid">
        <${rn} label="Workers online" value=${a} color="#4ade80" caption="활성 + 대기 실행 actor" />
        <${rn} label="Working now" value=${o} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${rn} label="Fresh signals" value=${r} color="#22d3ee" caption="최근 2분 이내 신호" />
        <${rn} label="Worker alerts" value=${c.length} color=${c.length>0?"#fb7185":"#4ade80"} caption="실행 actor 경고" />
        <${rn} label="Continuity alerts" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="keeper 연속성 경고" />
      </div>

      <${T} title="Execution Priorities" class="section" semanticId="execution.priority_queue">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs execution attention right now</h2>
          <p class="monitor-subheadline">Worker drift and keeper continuity risk are ranked together here, but diagnosed in separate sections below.</p>
        </div>
        <div class="monitor-alert-list">
          ${m.length===0?i`<div class="empty-state">No execution alerts right now</div>`:m.map(u=>i`<${Vv} key=${u.key} item=${u} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${T} title="Workers" class="section" semanticId="execution.workers">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Live workers stay grouped here so owner drift is visible before you scan offline history.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?i`<div class="empty-state">No active workers visible</div>`:n.map(u=>i`<${$o} key=${u.agent.name} row=${u} />`)}
          </div>
        <//>

        <${T} title="Continuity" class="section" semanticId="execution.continuity">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper continuity</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and handoff state are isolated from worker execution drift.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?i`<div class="empty-state">No keepers active</div>`:e.map(u=>i`<${Yv} key=${u.keeper.name} row=${u} />`)}
          </div>
        <//>

        <${T} title="Offline Workers" class="section" semanticId="execution.offline">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who dropped out of the live loop</h2>
            <p class="monitor-subheadline">Offline rows stay separate so they do not drown the active execution monitor.</p>
          </div>
          <div class="monitor-list">
            ${s.length===0?i`<div class="empty-state">No offline workers right now</div>`:s.map(u=>i`<${$o} key=${u.agent.name} row=${u} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Us=f("all"),Hs=f("all"),ui=It(()=>{let t=hn.value;return Us.value!=="all"&&(t=t.filter(e=>e.horizon===Us.value)),Hs.value!=="all"&&(t=t.filter(e=>e.status===Hs.value)),t}),Qv=It(()=>{const t={short:[],mid:[],long:[]};for(const e of ui.value){const n=t[e.horizon];n&&n.push(e)}return t}),Zv=It(()=>{const t=Array.from(Wo.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function t_(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function ji(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function fs(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function e_(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function ho(t){return t.toFixed(4)}function yo(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function n_({goal:t}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${fs(t.horizon)}">
            ${ji(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${t_(t.priority)}</span>
          ${t.metric?i`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?i`<span class="goal-due">Due: <${it} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?i`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${ue} status=${t.status} />
        <div class="goal-updated">
          <${it} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function bo({label:t,timestamp:e,source:n,note:s}){return i`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${s?i`<div class="planning-freshness-source">${s}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?i`<${it} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function Sa({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return i`
    <${T} title="${ji(t)} Goals (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${n_} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function s_(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>i`
          <button
            class="goal-filter-btn ${Us.value===t?"active":""}"
            onClick=${()=>{Us.value=t}}
          >
            ${t==="all"?"All":ji(t)}
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
  `}function a_(){const t=hn.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return i`
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
        <div class="goal-summary-value" style="color:${fs("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${fs("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${fs("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function i_({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return i`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${ue} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${ho(t.baseline_metric)}</span>
          <span>Current ${ho(t.current_metric)}</span>
          <span class=${yo(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${yo(t)}
          </span>
          <span>Elapsed ${e_(t.elapsed_seconds)}</span>
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
  `}function Aa({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return i`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?i`<${it} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function o_(){const{todo:t,inProgress:e,done:n}=Xc.value;return i`
    <${T} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?i`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>i`<${Aa} key=${s.id} task=${s} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?i`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>i`<${Aa} key=${s.id} task=${s} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?i`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>i`<${Aa} key=${s.id} task=${s} />`)}
          ${n.length>20?i`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function r_(){const t=Qv.value,e=Zv.value,n=e.filter(c=>c.status==="running").length,s=e.filter(c=>c.recoverable).length,a=hn.value.filter(c=>c.status==="active").length,o=yi.value,r=o==="idle"?"No loop running":o==="error"?ks.value??"MDAL snapshot unavailable":"Current loop snapshot";return i`
    <div>
      <${xt} surfaceId="planning" />
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${a}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${ui.value.length}</div>
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
            <button class="control-btn ghost" onClick=${Ge} disabled=${Ee.value}>
              ${Ee.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${ai} disabled=${ze.value}>
              ${ze.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{Ge(),ai()}}
              disabled=${Ee.value||ze.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${bo} label="Goals" timestamp=${Go.value} source="/api/v1/dashboard/planning" />
          <${bo}
            label="MDAL loops"
            timestamp=${Jo.value}
            source="/api/v1/dashboard/planning"
            note=${r}
          />
        </div>
      <//>

      <${T} title="Goal Pipeline" class="section" semanticId="planning.goal_pipeline">
        <${a_} />
        <${s_} />
      <//>

      ${Ee.value&&hn.value.length===0?i`<div class="loading-indicator">Loading goals...</div>`:ui.value.length===0?i`<div class="empty-state">No goals match the current filters</div>`:i`
              <${Sa} horizon="short" items=${t.short??[]} />
              <${Sa} horizon="mid" items=${t.mid??[]} />
              <${Sa} horizon="long" items=${t.long??[]} />
            `}

      <${T} title="MDAL Loops" class="section" semanticId="planning.mdal_loops">
        ${ze.value&&e.length===0?i`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&o==="error"?i`
                <div class="empty-state">
                  MDAL snapshot could not be loaded right now. Check the backend tool contract or runtime health.
                </div>
              `:e.length===0&&o==="idle"?i`
                <div class="empty-state">
                  No loop is running right now. This section wakes up when <code>masc_mdal_start</code> exposes a live loop.
                </div>
              `:e.length===0?i`
                  <div class="empty-state">
                    No loop snapshot is visible yet. Refresh once the backend has reported a planning loop.
                  </div>
                `:i`
                <div class="planning-loop-list">
                  ${e.map(c=>i`<${i_} key=${c.loop_id} loop=${c} />`)}
                </div>
              `}
      <//>

      <${o_} />
    </div>
  `}const vn=f("debates"),Ws=f([]),Bs=f([]),Gs=f(!1),_n=f(!1),Dn=f(""),fn=f(""),Js=f(null),Pt=f(null),pi=f(!1);async function da(){Gs.value=!0,Dn.value="";try{const t=await Ml();Ws.value=Array.isArray(t.debates)?t.debates:[],Bs.value=Array.isArray(t.sessions)?t.sessions:[]}catch(t){Dn.value=t instanceof Error?t.message:"Failed to load governance state"}finally{Gs.value=!1}}gd(da);async function ko(){const t=fn.value.trim();if(t){_n.value=!0;try{const e=await Ac(t);fn.value="",P(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await da()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";P(n,"error")}finally{_n.value=!1}}}async function l_(t){Js.value=t,Pt.value=null,pi.value=!0;try{Pt.value=await Cc(t)}catch(e){Dn.value=e instanceof Error?e.message:"Failed to load debate detail"}finally{pi.value=!1}}function c_(){return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${Ws.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Voting sessions</span>
        <strong>${Bs.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Active view</span>
        <strong>${vn.value==="debates"?"Debates":"Voting"}</strong>
      </div>
    </div>
  `}function d_({debate:t}){const e=Js.value===t.id;return i`
    <button class="council-row ${e?"selected":""}" onClick=${()=>l_(t.id)}>
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
  `}function u_({session:t}){return i`
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
  `}function p_(){const t=vn.value;return i`
    <div class="overview-sub-tabs" style="margin-bottom:12px;">
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{vn.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{vn.value="voting"}}>Voting</button>
    </div>
  `}function m_(){return i`
    <div>
      <${T} title="Start Debate" class="section" semanticId="governance.debates">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${fn.value}
            onInput=${t=>{fn.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&ko()}}
            disabled=${_n.value}
          />
          <button
            class="control-btn secondary"
            onClick=${ko}
            disabled=${_n.value||fn.value.trim()===""}
          >
            ${_n.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${da} disabled=${Gs.value}>
            ${Gs.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Dn.value?i`<div class="council-error">${Dn.value}</div>`:null}
      <//>

      <${T} title="Debates" class="section" semanticId="governance.debates">
        <div class="council-list">
          ${Ws.value.length===0?i`<div class="empty-state">No debates yet</div>`:Ws.value.map(t=>i`<${d_} key=${t.id} debate=${t} />`)}
        </div>
      <//>

      <${T} title=${Js.value?`Debate Detail (${Js.value})`:"Debate Detail"} class="section" semanticId="governance.debates">
        ${pi.value?i`<div class="loading-indicator">Loading debate detail...</div>`:Pt.value?i`
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
  `}function v_(){return i`
    <${T} title="Voting Sessions" class="section" semanticId="governance.voting">
      <div class="council-list">
        ${Bs.value.length===0?i`<div class="empty-state">No active sessions</div>`:Bs.value.map(t=>i`<${u_} key=${t.id} session=${t} />`)}
      </div>
    <//>
  `}function __(){return rt(()=>{da()},[]),i`
    <div>
      <${xt} surfaceId="governance" />
      <${c_} />
      <${p_} />
      ${vn.value==="debates"?i`<${m_} />`:i`<${v_} />`}
    </div>
  `}const Le=f(""),Ca=f("ability_check"),wa=f("10"),Ta=f("12"),ns=f(""),ss=f("idle"),ne=f(""),as=f("keeper-late"),Ia=f("player"),Na=f(""),kt=f("idle"),Ra=f(null),is=f(""),Pa=f(""),La=f("player"),Ma=f(""),Da=f(""),Ea=f(""),gn=f("20"),za=f("20"),ja=f(""),os=f("idle"),mi=f(null),Br=f("overview"),Oa=f("all"),Fa=f("all"),qa=f("all"),f_=12e4,ua=f(null),xo=f(Date.now());function g_(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function $_(t,e){return e>0?Math.round(t/e*100):0}const h_={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},y_={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function rs(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function b_(t){const e=t.trim().toLowerCase();return h_[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function k_(t){const e=t.trim().toLowerCase();return y_[e]??"상황에 따라 선택되는 전술 액션입니다."}function oe(t){return typeof t=="object"&&t!==null}function ht(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function Lt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function En(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const x_=new Set(["str","dex","con","int","wis","cha"]);function S_(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!oe(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const r=a.trim();if(r){if(typeof o=="number"&&Number.isFinite(o)){s[r]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const c=Number.parseFloat(o.trim());if(Number.isFinite(c)){s[r]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),s}function A_(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(gn.value.trim(),10);Number.isFinite(s)&&s>n&&(gn.value=String(n))}function vi(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function C_(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function w_(t){Br.value=t}function Gr(t){const e=ua.value;return e==null||e<=t}function T_(t){const e=ua.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Vs(){ua.value=null}function Jr(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function I_(t,e){Jr(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(ua.value=Date.now()+f_,P("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function gs(t){return Gr(t)?(P("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function _i(t,e,n){return Jr([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function N_({hp:t,max:e}){const n=$_(t,e),s=g_(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function R_({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function P_({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Vr({actor:t}){var d,m,u,p;const e=(d=t.archetype)==null?void 0:d.trim(),n=(m=t.persona)==null?void 0:m.trim(),s=(u=t.portrait)==null?void 0:u.trim(),a=(p=t.background)==null?void 0:p.trim(),o=t.traits??[],r=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([_,$])=>Number.isFinite($)).filter(([_])=>!x_.has(_.toLowerCase()));return i`
    <div class="trpg-actor">
      ${s?i`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${_=>{const $=_.target;$&&($.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${ue} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${P_} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${N_} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${R_} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${rs(e)}</div>`:null}
      ${a?i`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([_,$])=>i`
                <span class="trpg-custom-stat-chip">${rs(_)} ${$}</span>
              `)}
            </div>
          </div>
        `:null}
      ${o.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${o.map(_=>i`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${rs(_)}</span>
                  <span class="trpg-annot-desc">${b_(_)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(_=>i`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${rs(_)}</span>
                  <span class="trpg-annot-desc">${k_(_)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function L_({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function Yr({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?i`<div class="empty-state" style="font-size:13px">${e}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${C_(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${vi(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${it} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function M_({events:t}){const e="__none__",n=Oa.value,s=Fa.value,a=qa.value,o=Array.from(new Set(t.map(vi).map(p=>p.trim()).filter(p=>p!==""))).sort((p,_)=>p.localeCompare(_)),r=Array.from(new Set(t.map(p=>(p.type??"").trim()).filter(p=>p!==""))).sort((p,_)=>p.localeCompare(_)),c=t.some(p=>(p.type??"").trim()===""),d=Array.from(new Set(t.map(p=>(p.phase??"").trim()).filter(p=>p!==""))).sort((p,_)=>p.localeCompare(_)),m=t.some(p=>(p.phase??"").trim()===""),u=t.filter(p=>{if(n!=="all"&&vi(p)!==n)return!1;const _=(p.type??"").trim(),$=(p.phase??"").trim();if(s===e){if(_!=="")return!1}else if(s!=="all"&&_!==s)return!1;if(a===e){if($!=="")return!1}else if(a!=="all"&&$!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${p=>{Oa.value=p.target.value}}>
          <option value="all">all</option>
          ${o.map(p=>i`<option value=${p}>${p}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${p=>{Fa.value=p.target.value}}>
          <option value="all">all</option>
          ${c?i`<option value=${e}>(none)</option>`:null}
          ${r.map(p=>i`<option value=${p}>${p}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${p=>{qa.value=p.target.value}}>
          <option value="all">all</option>
          ${m?i`<option value=${e}>(none)</option>`:null}
          ${d.map(p=>i`<option value=${p}>${p}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Oa.value="all",Fa.value="all",qa.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${u.length} / 전체 ${t.length}
      </span>
    </div>
    <${Yr} events=${u.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function D_({outcome:t}){if(!t)return null;const e=o=>{const r=o.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
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
  `}function E_({state:t,nowMs:e}){var m;const n=Gt.value||((m=t.session)==null?void 0:m.room)||"",s=ss.value,a=t.party??[];if(!a.find(u=>u.id===Le.value)&&a.length>0){const u=a[0];u&&(Le.value=u.id)}const r=async()=>{var p,_;if(!n){P("Room ID가 비어 있습니다.","error");return}if(!gs(e))return;const u=((p=t.current_round)==null?void 0:p.phase)??((_=t.session)==null?void 0:_.status)??"unknown";if(_i("라운드 실행",n,u)){ss.value="running";try{const $=await vc(n);mi.value=$,ss.value="ok";const k=oe($.summary)?$.summary:null,A=k?En(k,"advanced",!1):!1,w=k?ht(k,"progress_reason",""):"";P(A?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${w?`: ${w}`:""}`,A?"success":"warning"),Ft()}catch($){mi.value=null,ss.value="error";const k=$ instanceof Error?$.message:"라운드 실행에 실패했습니다.";P(k,"error")}finally{Vs()}}},c=async()=>{var p,_;if(!n||!gs(e))return;const u=((p=t.current_round)==null?void 0:p.phase)??((_=t.session)==null?void 0:_.status)??"unknown";if(_i("턴 강제 진행",n,u))try{await gc(n),P("턴을 다음 단계로 이동했습니다.","success"),Ft()}catch{P("턴 이동에 실패했습니다.","error")}finally{Vs()}},d=async()=>{if(!n||!gs(e))return;const u=Le.value.trim();if(!u){P("먼저 Actor를 선택하세요.","warning");return}const p=Number.parseInt(wa.value,10),_=Number.parseInt(Ta.value,10);if(Number.isNaN(p)||Number.isNaN(_)){P("stat/dc는 숫자여야 합니다.","warning");return}const $=Number.parseInt(ns.value,10),k=ns.value.trim()===""||Number.isNaN($)?void 0:$;try{await fc({roomId:n,actorId:u,action:Ca.value.trim()||"ability_check",statValue:p,dc:_,rawD20:k}),P("주사위 판정을 기록했습니다.","success"),Ft()}catch{P("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${u=>{Gt.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Le.value}
            onChange=${u=>{Le.value=u.target.value}}
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
              value=${Ca.value}
              onInput=${u=>{Ca.value=u.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${wa.value}
              onInput=${u=>{wa.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Ta.value}
              onInput=${u=>{Ta.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${ns.value}
              onInput=${u=>{ns.value=u.target.value}}
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
  `}function z_({state:t}){var a;const e=Gt.value||((a=t.session)==null?void 0:a.room)||"",n=os.value,s=async()=>{if(!e){P("Room ID가 비어 있습니다.","warning");return}const o=is.value.trim(),r=Pa.value.trim();if(!r&&!o){P("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(gn.value.trim(),10),d=Number.parseInt(za.value.trim(),10),m=Number.isFinite(d)?Math.max(1,d):20,u=Number.isFinite(c)?Math.max(0,Math.min(m,c)):m;let p={};try{p=S_(ja.value)}catch(_){P(_ instanceof Error?_.message:"능력치 JSON 오류","error");return}os.value="spawning";try{const _=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,$=await $c(e,{actor_id:o||void 0,name:r||void 0,role:La.value,idempotencyKey:_,portrait:Da.value.trim()||void 0,background:Ea.value.trim()||void 0,hp:u,max_hp:m,alive:u>0,stats:Object.keys(p).length>0?p:void 0}),k=typeof $.actor_id=="string"?$.actor_id.trim():"";if(!k)throw new Error("생성 응답에 actor_id가 없습니다.");const A=Ma.value.trim();A&&await hc(e,k,A),Le.value=k,ne.value=k,o||(is.value=""),os.value="ok",P(`Actor 생성 완료: ${k}`,"success"),await Ft()}catch(_){os.value="error",P(_ instanceof Error?_.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Pa.value}
            onInput=${o=>{Pa.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${La.value}
            onChange=${o=>{La.value=o.target.value}}
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
            value=${Ma.value}
            onInput=${o=>{Ma.value=o.target.value}}
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
              value=${Da.value}
              onInput=${o=>{Da.value=o.target.value}}
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
              value=${gn.value}
              onInput=${o=>{gn.value=o.target.value}}
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
              value=${za.value}
              onInput=${o=>{const r=o.target.value;za.value=r,A_(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Ea.value}
              onInput=${o=>{Ea.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${ja.value}
              onInput=${o=>{ja.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function j_({state:t,nowMs:e}){var _;const n=Gt.value||((_=t.session)==null?void 0:_.room)||"",s=t.join_gate,a=Ra.value,o=oe(a)?a:null,r=(t.party??[]).filter($=>$.role!=="dm"),c=ne.value.trim(),d=r.some($=>$.id===c),m=d?c:c?"__manual__":"",u=async()=>{const $=ne.value.trim(),k=as.value.trim();if(!n||!$){P("Room/Actor가 필요합니다.","warning");return}kt.value="checking";try{const A=await yc(n,$,k||void 0);Ra.value=A,kt.value="ok",P("참가 가능 여부를 갱신했습니다.","success")}catch(A){kt.value="error";const w=A instanceof Error?A.message:"참가 가능 여부 확인에 실패했습니다.";P(w,"error")}},p=async()=>{var L,z;const $=ne.value.trim(),k=as.value.trim(),A=Na.value.trim();if(!n||!$||!k){P("Room/Actor/Keeper가 필요합니다.","warning");return}if(!gs(e))return;const w=((L=t.current_round)==null?void 0:L.phase)??((z=t.session)==null?void 0:z.status)??"unknown";if(_i("Mid-Join 승인 요청",n,w)){kt.value="requesting";try{const E=await bc({room_id:n,actor_id:$,keeper_name:k,role:Ia.value,...A?{name:A}:{}});Ra.value=E;const I=oe(E)?En(E,"granted",!1):!1,N=oe(E)?ht(E,"reason_code",""):"";I?P("Mid-Join이 승인되었습니다.","success"):P(`Mid-Join이 거절되었습니다${N?`: ${N}`:""}`,"warning"),kt.value=I?"ok":"error",Ft()}catch(E){kt.value="error";const I=E instanceof Error?E.message:"Mid-Join 요청에 실패했습니다.";P(I,"error")}finally{Vs()}}};return i`
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
            onChange=${$=>{const k=$.target.value;if(k==="__manual__"){(d||!c)&&(ne.value="");return}ne.value=k}}
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
                value=${ne.value}
                onInput=${$=>{ne.value=$.target.value}}
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
            onInput=${$=>{as.value=$.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ia.value}
            onChange=${$=>{Ia.value=$.target.value}}
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
            value=${Na.value}
            onInput=${$=>{Na.value=$.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${u} disabled=${kt.value==="checking"||kt.value==="requesting"}>
              ${kt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${p} disabled=${kt.value==="checking"||kt.value==="requesting"}>
              ${kt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${En(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Lt(o,"effective_score",0)}/${Lt(o,"required_points",0)}</span>
            ${ht(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${ht(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Qr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Zr({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function tl(){const t=mi.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=oe(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(oe).slice(-8),o=t.canon_check,r=oe(o)?o:null,c=r&&Array.isArray(r.warnings)?r.warnings.filter(N=>typeof N=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(N=>typeof N=="string").slice(0,3):[],m=n?En(n,"advanced",!1):!1,u=n?ht(n,"progress_reason",""):"",p=n?ht(n,"progress_detail",""):"",_=n?Lt(n,"player_successes",0):0,$=n?Lt(n,"player_required_successes",0):0,k=n?En(n,"dm_success",!1):!1,A=n?Lt(n,"timeouts",0):0,w=n?Lt(n,"unavailable",0):0,L=n?Lt(n,"reprompts",0):0,z=n?Lt(n,"npc_attacks",0):0,E=n?Lt(n,"keeper_timeout_sec",0):0,I=n?Lt(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${m?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${m?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${k?"DM ok":"DM stalled"} / players ${_}/${$}
          </span>
        </div>
        ${u?i`<div style="margin-top:4px; font-size:12px;">${u}</div>`:null}
        ${p?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${p}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${w}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${L}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${z}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${E||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${I}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(N=>{const Y=ht(N,"status","unknown"),G=ht(N,"actor_id","-"),v=ht(N,"role","-"),F=ht(N,"reason",""),tt=ht(N,"action_type",""),W=ht(N,"reply","");return i`
                <div class="trpg-round-item ${Y.includes("fallback")||Y.includes("timeout")?"failed":"active"}">
                  <span>${G} (${v})</span>
                  <span style="margin-left:auto; font-size:11px;">${Y}</span>
                  ${tt?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${tt}</div>`:null}
                  ${F?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${F}</div>`:null}
                  ${W?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${W.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${ht(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(N=>i`<div>violation: ${N}</div>`)}
                </div>`:null}
            ${c.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(N=>i`<div>warning: ${N}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function O_({state:t,nowMs:e}){var r,c,d;const n=Gt.value||((r=t.session)==null?void 0:r.room)||"",s=((c=t.current_round)==null?void 0:c.phase)??((d=t.session)==null?void 0:d.status)??"unknown",a=Gr(e),o=T_(e);return i`
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
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>I_(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{Vs(),P("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function F_({active:t}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>w_(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function q_({state:t}){const e=t.party??[],n=t.story_log??[];return i`
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
          <${Yr} events=${n.slice(-20)} />
        <//>

        ${t.map?i`
            <${T} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${L_} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${T} title="현재 라운드" semanticId="lab.trpg">
          <${Zr} state=${t} />
        <//>

        <${T} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${Qr} state=${t} />
        <//>

        <${T} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>i`<${Vr} key=${s.id??s.name} actor=${s} />`)}
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
  `}function K_({state:t}){const e=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${T} title=${`이벤트 타임라인 (${e.length})`}>
          <${M_} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${T} title="최근 라운드 결과" semanticId="lab.trpg">
          <${tl} />
        <//>

        <${T} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${Zr} state=${t} />
        <//>
      </div>
    </div>
  `}function U_({state:t,nowMs:e}){const n=t.party??[];return i`
    <div>
      <${O_} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${T} title="조작 패널" semanticId="lab.trpg">
            <${E_} state=${t} nowMs=${e} />
          <//>

          <${T} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${z_} state=${t} />
          <//>

          <${T} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${j_} state=${t} nowMs=${e} />
          <//>

          <${T} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${tl} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${T} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${Qr} state=${t} />
          <//>

          <${T} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${Vr} key=${s.id??s.name} actor=${s} />`)}
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
  `}function H_(){var c,d,m,u,p;const t=Ho.value,e=ei.value;if(rt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const _=window.setInterval(()=>{xo.value=Date.now()},1e3);return()=>{window.clearInterval(_)}},[]),e&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Ft()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,o=Br.value,r=xo.value;return i`
    <div>
      <${xt} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Gt.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((m=t.session)==null?void 0:m.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Ft()}>새로고침</button>
      </div>

      <${D_} outcome=${a} />

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

      <${F_} active=${o} />

      ${o==="overview"?i`<${q_} state=${t} />`:o==="timeline"?i`<${K_} state=${t} />`:i`<${U_} state=${t} nowMs=${r} />`}
    </div>
  `}function W_(){return i`
    <div>
      <${xt} surfaceId="lab" />
      <${T} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${T} title="TRPG" class="section" semanticId="lab.trpg">
        <${H_} />
      <//>
    </div>
  `}const Ys=f(new Set(["broadcast","tasks","keepers","system"]));function B_(t){const e=new Set(Ys.value);e.has(t)?e.delete(t):e.add(t),Ys.value=e}const Oi=f(null);function el(t){Oi.value=t}function G_(t){return t.kind==="board"?"broadcast":t.kind==="tasks"?"tasks":t.kind==="keepers"?"keepers":"system"}const J_=It(()=>{const t=Ys.value;return hs.value.filter(e=>t.has(G_(e)))}),V_=12e4,Y_=It(()=>{const t=ea.value,e=Date.now();return At.value.map(n=>{const s=n.name.trim().toLowerCase(),a=t.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const r=a==null?void 0:a.lastActivityAt;r?o=e-new Date(r).getTime()>V_?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),X_=It(()=>{const t=ea.value;return At.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle").map(e=>{const n=e.name.trim().toLowerCase(),s=t.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:e.name,emoji:e.emoji??"",koreanName:e.koreanName??null,currentTask:e.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((e,n)=>{const s={hot:0,normal:1,calm:2};return s[e.pressure]-s[n.pressure]})});function So(t){return t.kind==="board"?"live-event-broadcast":t.kind==="tasks"?"live-event-task":t.kind==="keepers"?"live-event-keeper":"live-event-system"}function Q_(t){const e=t.eventType;return e==="broadcast"?"broadcast":e==="agent_joined"?"joined":e==="agent_left"?"left":e==="task_update"?"task":e==="board_post"?"post":e==="board_comment"?"comment":e==="keeper_heartbeat"?"heartbeat":e==="keeper_handoff"?"handoff":e==="keeper_compaction"?"compact":e==="keeper_guardrail"?"guardrail":t.kind==="board"?"board":t.kind==="tasks"?"task":t.kind==="keepers"?"keeper":"system"}function Z_(t){switch(t){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function tf(){const t=Y_.value,e=Oi.value;return t.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${t.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${Z_(n.state)} ${e===n.name?"pulse-selected":""}"
          onClick=${()=>el(e===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const ef=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function nf(){const t=Ys.value;return i`
    <div class="activity-filter-bar">
      ${ef.map(e=>i`
        <button
          key=${e.kind}
          class="activity-filter-btn ${e.cssClass} ${t.has(e.kind)?"active":""}"
          onClick=${()=>B_(e.kind)}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function sf(){const t=J_.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${t.length} events</span>
      </div>
      <${nf} />
      <div class="activity-stream-list">
        ${t.length===0?i`<div class="activity-empty">No events matching filters</div>`:t.map((e,n)=>i`
            <div
              key=${`${e.timestamp}-${n}`}
              class="activity-item ${So(e)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${So(e)}">${Q_(e)}</span>
                <span class="activity-agent">${e.agent}</span>
                <span class="activity-time">${Zo(e.timestamp)}</span>
              </div>
              <div class="activity-item-text">${e.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function af(t){switch(t){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function of(t){switch(t){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function rf(){const t=X_.value,e=Oi.value;return i`
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
              onClick=${()=>el(e===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?i`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${af(n.pressure)}">
                  ${of(n.pressure)}
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
  `}function lf(){const t=re.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>Live Monitor</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${t?"connected":"disconnected"}"></span>
            ${t?"Connected":"Offline"}
          </span>
          <span class="live-stat">${At.value.length} agents</span>
          <span class="live-stat">${Xs.value} events</span>
        </div>
      </div>

      <${tf} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${sf} />
        </div>
        <div class="live-panel-side">
          <${rf} />
        </div>
      </div>
    </div>
  `}const Ao=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],fi=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"live",label:"Live",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}];function cf(){const t=re.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Xs.value} events</span>
    </div>
  `}function df({currentTab:t,currentSectionLabel:e}){const n=re.value;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>Snapshot</h3>
        <${D} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${n?"ok":"bad"}">${n?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agents</span>
          <strong>${At.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keepers</span>
          <strong>${de.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Tasks</span>
          <strong>${jt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Events</span>
          <strong>${Xs.value}</strong>
        </div>
      </div>
      <div class="rail-snapshot-copy">
        <span>Connection ${n?"healthy":"recovering"}</span>
        <span>${e} workspace active</span>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{jn(),Xo(),t==="command"&&(Se(),se(),(V.value==="swarm"||V.value==="warroom")&&Bt(),V.value==="warroom"&&ut()),t==="mission"&&ps(),t==="execution"&&Ht(),t==="intervene"&&(ut(),Yt()),t==="memory"&&Ot(),t==="planning"&&Ge(),t==="lab"&&Ft()}}
        >
          Refresh Now
        </button>
        <button class="rail-secondary-btn" onClick=${()=>gt("intervene")}>
          Open Intervene
        </button>
      </div>
    </section>
  `}function uf(){const t=pe.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${D} panelId="side_rail.quick_actions" compact=${!0} />
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
          onClick=${()=>{ut(),Yt()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>gt("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function pf(){const t=O.value.tab,e=fi.find(s=>s.id===t),n=Ao.find(s=>s.id===(e==null?void 0:e.group));return i`
    <aside class="dashboard-rail">
      <${xt} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          <${D} panelId="side_rail.navigate" compact=${!0} />
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${Ao.map(s=>i`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${fi.filter(a=>a.group===s.id).map(a=>i`
                  <button
                    class="rail-tab-btn ${t===a.id?"active":""}"
                    onClick=${()=>gt(a.id)}
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

      <${df} currentTab=${t} currentSectionLabel=${(n==null?void 0:n.label)??"Observe"} />
      <${uf} />
    </aside>
  `}function mf(){switch(O.value.tab){case"mission":return i`<${no} />`;case"execution":return i`<${Xv} />`;case"live":return i`<${lf} />`;case"memory":return i`<${Fv} />`;case"governance":return i`<${__} />`;case"planning":return i`<${r_} />`;case"intervene":return i`<${Iv} />`;case"command":return i`<${pv} />`;case"lab":return i`<${W_} />`;default:return i`<${no} />`}}function vf(){rt(()=>{ml(),Lo(),Qo(),Ht(),Xo(),ps();const n=yd();return bd(),()=>{bl(),n(),kd()}},[]),rt(()=>{const n=setInterval(()=>{const s=O.value.tab;s==="command"?(Se(),se(),(V.value==="swarm"||V.value==="warroom")&&Bt(),V.value==="warroom"&&ut()):s==="mission"?ps():s==="execution"?Ht():s==="intervene"?(ut(),Yt()):s==="memory"?Ot():s==="planning"?Ge():s==="lab"&&Ft()},15e3);return()=>{clearInterval(n)}},[]),rt(()=>{const n=O.value.tab;n==="command"&&(Se(),se(),(V.value==="swarm"||V.value==="warroom")&&Bt(),V.value==="warroom"&&ut()),n==="mission"&&ps(),n==="execution"&&Ht(),n==="intervene"&&(ut(),Yt()),n==="memory"&&Ot(),n==="planning"&&Ge(),n==="lab"&&Ft()},[O.value.tab]);const t=O.value.tab,e=fi.find(n=>n.id===t);return i`
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
          <${cf} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${pf} />
        <main class="dashboard-main">
          ${ti.value&&!re.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${mf} />`}
        </main>
      </div>

      <${ou} />
      <${qd} />
      <${Ed} />
    </div>
  `}const Co=document.getElementById("app");Co&&ll(i`<${vf} />`,Co);export{Ju as _};
