<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
var Wr=Object.defineProperty;var Gr=(t,e,n)=>e in t?Wr(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var ke=(t,e,n)=>Gr(t,typeof e!="symbol"?e+"":e,n);import{e as Jr,_ as Vr,c as _,b as St,y as rt,d as Ua,A as wo,G as Qr}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const i of document.querySelectorAll('link[rel="modulepreload"]'))a(i);new MutationObserver(i=>{for(const o of i)if(o.type==="childList")for(const r of o.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(i){const o={};return i.integrity&&(o.integrity=i.integrity),i.referrerPolicy&&(o.referrerPolicy=i.referrerPolicy),i.crossOrigin==="use-credentials"?o.credentials="include":i.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function a(i){if(i.ep)return;i.ep=!0;const o=n(i);fetch(i.href,o)}})();var s=Jr.bind(Vr);const Yr=["command","overview","board","goals","agents","ops","trpg"],Co={tab:"overview",params:{},postId:null},Xr={journal:"overview",mdal:"goals",tasks:"goals",execution:"overview",council:"board",activity:"overview"};function Mi(t){return!!t&&Yr.includes(t)}function Oi(t){if(t)return Xr[t]??t}function Qn(t){try{return decodeURIComponent(t)}catch{return t}}function Rs(t){const e={};return t&&new URLSearchParams(t).forEach((a,i)=>{e[i]=a}),e}function Zr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function To(t,e){if(t[0]==="chains"){const r={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(r.operation=Qn(t[2])),{tab:"command",params:r,postId:null}}const n=Oi(t[0]),a=Oi(e.tab),i=Mi(n)?n:Mi(a)?a:"overview";let o=null;return i==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?o=Qn(t[2]):t[0]==="post"&&t[1]&&(o=Qn(t[1]))),{tab:i,params:e,postId:o}}function la(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Co;const n=Qn(e);let a=n,i;if(n.startsWith("?"))a="",i=n.slice(1);else{const l=n.indexOf("?");l>=0&&(a=n.slice(0,l),i=n.slice(l+1))}!i&&a.includes("=")&&!a.includes("/")&&(i=a,a="");const o=Rs(i),r=Zr(a);return To(r,o)}function tl(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...Co,params:Rs(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const i=Rs(e.replace(/^\?/,""));return To(a,i)}function No(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([i])=>i!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const tt=_(la(window.location.hash));window.addEventListener("hashchange",()=>{tt.value=la(window.location.hash)});function Rt(t,e){const n={tab:t,params:e??{},postId:null};window.location.hash=No(n)}function el(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function nl(){if(window.location.hash&&window.location.hash!=="#"){tt.value=la(window.location.hash);return}const t=tl(window.location.pathname,window.location.search);if(t){tt.value=t;const e=No(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",tt.value=la(window.location.hash)}const zi="masc_dashboard_sse_session_id",al=1e3,sl=15e3,jt=_(!1),In=_(0),Ro=_(null),ca=_([]);function il(){let t=sessionStorage.getItem(zi);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(zi,t)),t}const ol=200;function rl(t,e,n="system",a={}){const i={agent:t,text:e,timestamp:Date.now(),kind:n,...a};ca.value=[i,...ca.value].slice(0,ol)}function Ls(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function qi(t,e){const n=Ls(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function Ct(t,e,n,a,i={}){rl(t,e,n,{eventType:a,...i})}let Mt=null,De=null,Ps=0;function Lo(){De&&(clearTimeout(De),De=null)}function ll(){if(De)return;Ps++;const t=Math.min(Ps,5),e=Math.min(sl,al*Math.pow(2,t));De=setTimeout(()=>{De=null,Po()},e)}function Po(){Lo(),Mt&&(Mt.close(),Mt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",il());const i=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(i);Mt=o,o.onopen=()=>{Mt===o&&(Ps=0,jt.value=!0)},o.onerror=()=>{Mt===o&&(jt.value=!1,o.close(),Mt=null,ll())},o.onmessage=r=>{try{const l=JSON.parse(r.data);In.value++,Ro.value=l,cl(l)}catch{}}}function cl(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":Ct(n,"Joined","system","agent_joined");break;case"agent_left":Ct(n,"Left","system","agent_left");break;case"broadcast":Ct(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Ct(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Ct(n,qi("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Ls(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":Ct(n,qi("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Ls(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":Ct(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Ct(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Ct(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Ct(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Ct(n,e,"system","unknown")}}function dl(){Lo(),Mt&&(Mt.close(),Mt=null),jt.value=!1}function Do(){return new URLSearchParams(window.location.search)}function Eo(){const t=Do(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Io(){return{...Eo(),"Content-Type":"application/json"}}const ul=15e3,_i=3e4,pl=6e4,ji=new Set([408,425,429,500,502,503,504]);class Mn extends Error{constructor(n){const a=n.method.toUpperCase(),i=n.timeout===!0,o=i?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);ke(this,"method");ke(this,"path");ke(this,"status");ke(this,"statusText");ke(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=i}}async function gi(t,e,n){const a=new AbortController,i=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Mn({method:r,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(i)}}function ml(){var e,n;const t=Do();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function X(t){const e=await gi(t,{headers:Eo()},ul);if(!e.ok)throw new Mn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function vl(t){return new Promise(e=>setTimeout(e,t))}function fl(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function _l(t){if(t instanceof Mn)return t.timeout||typeof t.status=="number"&&ji.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=fl(t.message);return e!==null&&ji.has(e)}async function Ue(t,e,n=2){let a=0;for(;;)try{return await e()}catch(i){if(!_l(i)||a>=n)throw i;const o=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${o}ms`,i),await vl(o),a+=1}}async function Ft(t,e,n,a=_i){const i=await gi(t,{method:"POST",headers:{...Io(),...n??{}},body:JSON.stringify(e)},a);if(!i.ok)throw new Mn({method:"POST",path:t,status:i.status,statusText:i.statusText});return i.json()}async function gl(t,e,n,a=_i){const i=await gi(t,{method:"POST",headers:{...Io(),...n??{}},body:JSON.stringify(e)},a);if(!i.ok)throw new Mn({method:"POST",path:t,status:i.status,statusText:i.statusText});return i.text()}function $l(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function hl(t){var e,n,a,i,o,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const p=((i=(a=t.result.content)==null?void 0:a[0])==null?void 0:i.text)??"MCP tool call failed";throw new Error(p)}return((l=(r=(o=t.result)==null?void 0:o.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function ht(t,e){const n=await gl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},pl),a=$l(n);return hl(a)}function yl(t="compact"){return X(`/api/v1/dashboard?mode=${t}`)}function bl(){return X("/api/v1/agents?limit=100")}function kl(t){const e=new URLSearchParams({limit:"200"});return e.set("include_done","true"),e.set("include_cancelled","true"),X(`/api/v1/tasks?${e}`)}function xl(t){const e=new URLSearchParams({limit:"50"});return t!=null&&t>0&&e.set("since_seq",String(t)),X(`/api/v1/messages?${e}`)}function Sl(t={}){return Ue("fetchMdalLoops",async()=>{const e=new URLSearchParams;t.limit!=null&&e.set("limit",String(t.limit)),t.historyLimit!=null&&e.set("history_limit",String(t.historyLimit)),t.status&&e.set("status",t.status);const n=e.toString();return X(`/api/v1/mdal/loops${n?`?${n}`:""}`)})}function Al(){return X("/api/v1/operator")}function wl(){return X("/api/v1/command-plane")}function Cl(){return X("/api/v1/command-plane/summary")}function Tl(){return X("/api/v1/chains/summary")}function Nl(t){return X(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Rl(){return X("/api/v1/command-plane/help")}function Ll(t){const e=new URLSearchParams;t&&e.set("run_id",t);const n=e.toString();return X(`/api/v1/command-plane/swarm${n?`?${n}`:""}`)}function Pl(t,e){return Ft(t,e)}function Dl(t){switch(t.action_type){case"keeper_msg":case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return _i}}function On(t){return Ft("/api/v1/operator/action",t,void 0,Dl(t))}function El(t,e){return Ft("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const Il=new Set(["lodge-system","team-session"]);function ze(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function Ml(t){return Il.has(t.trim().toLowerCase())}function Ol(t){return t.filter(e=>!Ml(e.author))}function zl(t){var i;const e=t.trim(),a=((i=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:i.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function Mo(t){if(!O(t))return null;const e=h(t.id,"").trim(),n=h(t.author,"").trim(),a=h(t.content,"").trim();if(!e||!n)return null;const i=q(t.score,0),o=q(t.votes_up,0),r=q(t.votes_down,0),l=q(t.votes,i||o-r),p=q(t.comment_count,q(t.reply_count,0)),$=(()=>{const y=t.flair;if(typeof y=="string"&&y.trim())return y.trim();if(O(y)){const T=h(y.name,"").trim();if(T)return T}return h(t.flair_name,"").trim()||void 0})(),m=h(t.created_at_iso,"").trim()||ze(t.created_at),d=h(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?ze(t.updated_at):m),c=h(t.title,"").trim()||zl(a);return{id:e,author:n,title:c,content:a,tags:[],votes:l,vote_balance:i,comment_count:p,created_at:m,updated_at:d,flair:$,hearth_count:q(t.hearth_count,0)}}function ql(t){if(!O(t))return null;const e=h(t.id,"").trim(),n=h(t.post_id,"").trim(),a=h(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:h(t.content,""),created_at:ze(t.created_at)}}async function jl(t,e){return Ue("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const a=n.toString(),i=await X(`/api/v1/board${a?`?${a}`:""}`),o=Array.isArray(i.posts)?i.posts.map(Mo).filter(l=>l!==null):[];return{posts:e!=null&&e.excludeSystem?Ol(o):o}})}async function Fl(t){return Ue("fetchBoardPost",async()=>{const e=await X(`/api/v1/board/${t}?format=flat`),n=O(e.post)?e.post:e,a=Mo(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},o=(Array.isArray(e.comments)?e.comments:[]).map(ql).filter(r=>r!==null);return{...a,comments:o}})}function Oo(t,e){return Ft("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:ml()})}function Kl(t,e,n){return Ft("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Hl(t){const e=h(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function lt(...t){for(const e of t){const n=h(e,"");if(n.trim())return n.trim()}return""}function Fi(t){const e=Hl(lt(t.outcome,t.result,t.result_code));if(!e)return;const n=lt(t.reason,t.reason_code,t.description,t.detail),a=lt(t.summary,t.summary_ko,t.summary_en,t.note),i=lt(t.details,t.details_text,t.text,t.note),o=lt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=lt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=lt(t.raw_reason,t.raw_reason_code,t.error_message),p=(()=>{const d=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof d=="string"?[d]:Array.isArray(d)?d.map(v=>{if(typeof v=="string")return v.trim();if(O(v)){const c=h(v.summary,"").trim();if(c)return c;const y=h(v.text,"").trim();if(y)return y;const S=h(v.type,"").trim();return S||h(v.event_id,"").trim()}return""}).filter(v=>v.length>0):[]})(),$=(()=>{const d=q(t.turn,Number.NaN);if(Number.isFinite(d))return d;const v=q(t.turn_number,Number.NaN);if(Number.isFinite(v))return v;const c=q(t.current_turn,Number.NaN);if(Number.isFinite(c))return c;const y=q(t.round,Number.NaN);return Number.isFinite(y)?y:void 0})(),m=lt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:i||void 0,winner:o||void 0,winner_actor_id:r||void 0,evidence:p.length>0?p:void 0,raw_reason:l||void 0,turn:$,phase:m||void 0}}function Ul(t,e){const n=O(t.state)?t.state:{};if(h(n.status,"active").toLowerCase()!=="ended")return;const i=[...e].reverse().find(r=>O(r)?h(r.type,"")==="session.outcome":!1),o=O(n.session_outcome)?n.session_outcome:{};if(O(o)&&Object.keys(o).length>0){const r=Fi(o);if(r)return r}if(O(i))return Fi(O(i.payload)?i.payload:{})}function O(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function q(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Bl(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Ds(t,e=!1){return typeof t=="boolean"?t:e}function Qe(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(O(e)){const n=h(e.name,"").trim(),a=h(e.id,"").trim(),i=h(e.skill,"").trim();return n||a||i}return""}).filter(e=>e.length>0):[]}function Wl(t){const e={};if(!O(t)&&!Array.isArray(t))return e;if(O(t))return Object.entries(t).forEach(([n,a])=>{const i=n.trim(),o=h(a,"").trim();!i||!o||(e[i]=o)}),e;for(const n of t){if(!O(n))continue;const a=lt(n.to,n.target,n.actor_id,n.name,n.id),i=lt(n.relationship,n.relation,n.type,n.kind);!a||!i||(e[a]=i)}return e}function Gl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function bt(t,e,n,a=0){const i=t[e];if(typeof i=="number"&&Number.isFinite(i))return i;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return a}const Jl=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Vl(t){const e=O(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,i])=>{const o=a.trim();o&&(Jl.has(o.toLowerCase())||typeof i=="number"&&Number.isFinite(i)&&(n[o]=i))}),n}function Ql(t,e){if(t!=="dice.rolled")return;const n=q(e.raw_d20,0),a=q(e.total,0),i=q(e.bonus,0),o=h(e.action,"roll"),r=q(e.dc,0);return{notation:r>0?`${o} (DC ${r})`:o,rolls:n>0?[n]:[],total:a,modifier:i}}function Yl(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Xl(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Zl(t,e,n,a){const i=n||e||h(a.actor_id,"")||h(a.actor_name,"");switch(t){case"turn.action.proposed":{const o=h(a.proposed_action,h(a.reply,""));return o?`${i||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=h(a.reply,h(a.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return h(a.reply,h(a.content,h(a.text,"Narration")));case"dice.rolled":{const o=h(a.action,"roll"),r=q(a.total,0),l=q(a.dc,0),p=h(a.label,""),$=i||"actor",m=l>0?` vs DC ${l}`:"",d=p?` (${p})`:"";return`${$} ${o}: ${r}${m}${d}`}case"turn.started":return`Turn ${q(a.turn,1)} started`;case"phase.changed":return`Phase: ${h(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(a.name,O(a.actor)?h(a.actor.name,i||"unknown"):i||"unknown")}`;case"actor.claimed":return`${h(a.keeper_name,h(a.keeper,"keeper"))} claimed ${i||"actor"}`;case"actor.released":return`${h(a.keeper_name,h(a.keeper,"keeper"))} released ${i||"actor"}`;case"join.window.opened":return`Join window opened (turn ${q(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${q(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${i||h(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${i||h(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${h(a.reason_code,"unknown")}`;case"memory.signal":{const o=O(a.entity_refs)?a.entity_refs:{},r=h(o.requested_tier,""),l=h(o.effective_tier,""),p=Ds(o.guardrail_applied,!1),$=h(a.summary_en,h(a.summary_ko,"Memory signal"));if(!r&&!l)return $;const m=r&&l?`${r}->${l}`:l||r;return`${$} [${m}${p?" (guardrail)":""}]`}case"world.event":{if(h(a.event_type,"")==="canon.check"){const r=h(a.status,"unknown"),l=h(a.contract_id,"n/a");return`Canon ${r}: ${l}`}return h(a.description,h(a.summary,"World event"))}case"combat.attack":return h(a.summary,h(a.result,"Attack resolved"));case"combat.defense":return h(a.summary,h(a.result,"Defense resolved"));case"session.outcome":return h(a.summary,h(a.outcome,"Session ended"));default:{const o=Yl(a);return o?`${t}: ${o}`:t}}}function tc(t,e){const n=O(t)?t:{},a=h(n.type,"event"),i=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=h(n.actor_name,"").trim()||e[i]||h(O(n.payload)?n.payload.actor_name:"",""),r=O(n.payload)?n.payload:{},l=h(n.ts,h(n.timestamp,new Date().toISOString())),p=h(n.phase,h(r.phase,"")),$=h(n.category,"");return{type:a,actor:o||i||h(r.actor_name,""),actor_id:i||h(r.actor_id,""),actor_name:o,seq:n.seq,room_id:h(n.room_id,""),phase:p||void 0,category:$||Xl(a),visibility:h(n.visibility,h(r.visibility,"public")),event_id:h(n.event_id,""),content:Zl(a,i,o,r),dice_roll:Ql(a,r),timestamp:l}}function ec(t,e,n){var At,wt;const a=h(t.room_id,"")||n||"default",i=O(t.state)?t.state:{},o=O(i.party)?i.party:{},r=O(i.actor_control)?i.actor_control:{},l=O(i.join_gate)?i.join_gate:{},p=O(i.contribution_ledger)?i.contribution_ledger:{},$=Object.entries(o).map(([W,nt])=>{const x=O(nt)?nt:{},Pt=bt(x,"max_hp",void 0,10),Jt=bt(x,"hp",void 0,Pt),oe=bt(x,"max_mp",void 0,0),re=bt(x,"mp",void 0,0),I=bt(x,"level",void 0,1),Dt=bt(x,"xp",void 0,0),le=Ds(x.alive,Jt>0),Je=r[W],Ve=typeof Je=="string"?Je:void 0,f=Gl(x.role,W,Ve),R=Bl(x.generation),j=lt(x.joined_at,x.joinedAt,x.started_at,x.startedAt),at=lt(x.claimed_at,x.claimedAt,x.assigned_at,x.assignedAt,x.assigned_time),z=lt(x.last_seen,x.lastSeen,x.last_seen_at,x.lastSeenAt,x.last_active,x.lastActive),mt=lt(x.scene,x.current_scene,x.currentScene,x.world_scene,x.scene_name,x.sceneName),J=lt(x.location,x.current_location,x.currentLocation,x.position,x.zone,x.area);return{id:W,name:h(x.name,W),role:f,keeper:Ve,archetype:h(x.archetype,""),persona:h(x.persona,""),portrait:h(x.portrait,"")||void 0,background:h(x.background,"")||void 0,traits:Qe(x.traits),skills:Qe(x.skills),stats_raw:Vl(x),status:le?"active":"dead",generation:R,joined_at:j||void 0,claimed_at:at||void 0,last_seen:z||void 0,scene:mt||void 0,location:J||void 0,inventory:Qe(x.inventory),notes:Qe(x.notes),relationships:Wl(x.relationships),stats:{hp:Jt,max_hp:Pt,mp:re,max_mp:oe,level:I,xp:Dt,strength:bt(x,"strength","str",10),dexterity:bt(x,"dexterity","dex",10),constitution:bt(x,"constitution","con",10),intelligence:bt(x,"intelligence","int",10),wisdom:bt(x,"wisdom","wis",10),charisma:bt(x,"charisma","cha",10)}}}),m=$.filter(W=>W.status!=="dead"),d=Ul(t,e),v={phase_open:Ds(l.phase_open,!0),min_points:q(l.min_points,3),window:h(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},c=Object.entries(p).map(([W,nt])=>{const x=O(nt)?nt:{};return{actor_id:W,score:q(x.score,0),last_reason:h(x.last_reason,"")||null,reasons:Qe(x.reasons)}}),y=$.reduce((W,nt)=>(W[nt.id]=nt.name,W),{}),S=e.map(W=>tc(W,y)),T=q(i.turn,1),D=h(i.phase,"round"),L=h(i.map,""),M=O(i.world)?i.world:{},N=L||h(M.ascii_map,h(M.map,"")),P=S.filter((W,nt)=>{const x=e[nt];if(!O(x))return!1;const Pt=O(x.payload)?x.payload:{};return q(Pt.turn,-1)===T}),et=(P.length>0?P:S).slice(-12),U=h(i.status,"active");return{session:{id:a,room:a,status:U==="ended"?"ended":U==="paused"?"paused":"active",round:T,actors:m,created_at:((At=S[0])==null?void 0:At.timestamp)??new Date().toISOString()},current_round:{round_number:T,phase:D,events:et,timestamp:((wt=S[S.length-1])==null?void 0:wt.timestamp)??new Date().toISOString()},map:N||void 0,join_gate:v,contribution_ledger:c,outcome:d,party:m,story_log:S,history:[]}}async function nc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await X(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function ac(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([X(`/api/v1/trpg/state${e}`),nc(t)]);return ec(n,a,t)}function sc(t){return Ft("/api/v1/trpg/rounds/run",{room_id:t})}function ic(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function oc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Ft("/api/v1/trpg/dice/roll",e)}function rc(t,e){const n=ic();return Ft("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function lc(t,e){var i;const n=(i=e.idempotencyKey)==null?void 0:i.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),Ft("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function cc(t,e,n){return Ft("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function dc(t,e,n){const a=await ht("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function uc(t){const e=await ht("trpg.mid_join.request",t);return JSON.parse(e)}async function zo(t,e){await ht("masc_broadcast",{agent_name:t,message:e})}async function pc(t,e,n=1){await ht("masc_add_task",{title:t,description:e,priority:n})}async function mc(t){return ht("masc_join",{agent_name:t})}async function qo(t){await ht("masc_leave",{agent_name:t})}async function vc(t){await ht("masc_heartbeat",{agent_name:t})}async function fc(t=40){return(await ht("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function _c(t,e=20){return ht("masc_task_history",{task_id:t,limit:e})}async function gc(){return Ue("fetchDebates",async()=>{const t=await X("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!O(e))return null;const n=h(e.id,"").trim(),a=h(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:h(e.status,"open"),argument_count:q(e.argument_count,0),created_at:ze(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function $c(){return Ue("fetchCouncilSessions",async()=>{const t=await X("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!O(e))return null;const n=h(e.id,"").trim(),a=h(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:h(e.initiator,"system"),votes:q(e.votes,0),quorum:q(e.quorum,0),state:h(e.state,"open"),created_at:ze(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function hc(t){const e=await ht("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function yc(t){return Ue("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await X(`/api/v1/council/debates/${e}/summary`);if(!O(n))return null;const a=h(n.id,"").trim();return a?{id:a,topic:h(n.topic,""),status:h(n.status,"open"),support_count:q(n.support_count,0),oppose_count:q(n.oppose_count,0),neutral_count:q(n.neutral_count,0),total_arguments:q(n.total_arguments,0),created_at:ze(n.created_at_iso??n.created_at),summary_text:h(n.summary_text,"")}:null})}function bc(t,e,n){return ht("masc_keeper_msg",{name:t,message:e})}async function kc(){try{const t=await ht("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const on=_(""),Ut=_({}),dt=_({}),Es=_({}),Is=_({}),Ms=_({}),Os=_({}),Bt=_({});function ot(t,e,n){t.value={...t.value,[e]:n}}function Wt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function K(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function Nt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ne(t){return typeof t=="boolean"?t:void 0}function zs(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function qs(t){return Array.isArray(t)?t.map(e=>K(e)).filter(e=>!!e):[]}function xc(t){var n;const e=(n=K(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Sc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Xa(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!Wt(a))continue;const i=K(a.name);if(!i)continue;const o=K(a[e]);e==="summary"?n.push({name:i,summary:o}):n.push({name:i,reason:o})}return n}function Ac(t){if(!Wt(t))return null;const e=K(t.name);return e?{name:e,trigger:K(t.trigger),outcome:K(t.outcome),summary:K(t.summary),reason:K(t.reason)}:null}function wc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Cc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function jo(t,e,n){return K(t)??Cc(e,n)}function Fo(t,e){return typeof t=="boolean"?t:e==="recover"}function da(t){if(!Wt(t))return null;const e=K(t.health_state),n=K(t.next_action_path),a=K(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:K(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:zs(t.last_reply_at),last_reply_preview:K(t.last_reply_preview)??null,last_error:K(t.last_error)??null,next_eligible_at_s:Nt(t.next_eligible_at_s)??null,recoverable:Fo(t.recoverable,n),summary:jo(t.summary,e,K(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function $i(t){return Wt(t)?{hour:Nt(t.hour),checked:Nt(t.checked)??0,acted:Nt(t.acted)??0,acted_names:qs(t.acted_names),activity_report:K(t.activity_report),quiet_hours_overridden:Ne(t.quiet_hours_overridden),skipped_reason:K(t.skipped_reason),acted_rows:Xa(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:Xa(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:Xa(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Ac).filter(e=>e!==null):[]}:null}function Tc(t){return Wt(t)?{enabled:Ne(t.enabled)??!1,interval_s:Nt(t.interval_s)??0,quiet_start:Nt(t.quiet_start),quiet_end:Nt(t.quiet_end),quiet_active:Ne(t.quiet_active),use_planner:Ne(t.use_planner),delegate_llm:Ne(t.delegate_llm),agent_count:Nt(t.agent_count),agents:qs(t.agents),last_tick_ago_s:Nt(t.last_tick_ago_s)??null,last_tick_ago:K(t.last_tick_ago),total_ticks:Nt(t.total_ticks),total_checkins:Nt(t.total_checkins),last_skip_reason:K(t.last_skip_reason)??null,last_tick_result:$i(t.last_tick_result),active_self_heartbeats:qs(t.active_self_heartbeats)}:null}function Nc(t){return Wt(t)?{status:t.status,diagnostic:da(t.diagnostic)}:null}function Rc(t){return Wt(t)?{recovered:Ne(t.recovered)??!1,skipped_reason:K(t.skipped_reason)??null,before:da(t.before),after:da(t.after),down:t.down,up:t.up}:null}function Lc(t,e){var L,M;if(!(t!=null&&t.name))return null;const n=K((L=t.agent)==null?void 0:L.status)??K(t.status)??"unknown",a=K((M=t.agent)==null?void 0:M.error)??null,i=t.presence_keepalive??!0,o=t.keepalive_running??!1,r=t.turn_count??0,l=t.last_turn_ago_s??null,p=t.proactive_enabled??!1,$=t.proactive_cooldown_sec??0,m=t.last_proactive_ago_s??null,d=p&&m!=null?Math.max(0,$-m):null,v=r<=0||l==null?"never":l>900?"stale":"fresh",c=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,y=a??(i&&!o?"keeper keepalive is not running":null),S=n==="offline"||n==="inactive"?"offline":y?"degraded":v==="stale"?"stale":v==="never"?"idle":"healthy",T=y?wc(y):e!=null&&e.quiet_active&&v!=="fresh"?"quiet_hours":i&&!o?"disabled":r<=0?"never_started":d!=null&&d>0?"min_gap":v==="fresh"||v==="stale"?"no_recent_activity":"unknown",D=S==="offline"||S==="degraded"||S==="stale"?"recover":T==="quiet_hours"?"manual_lodge_poke":T==="unknown"?"probe":"direct_message";return{health_state:S,quiet_reason:T,next_action_path:D,last_reply_status:v,last_reply_at:c,last_reply_preview:null,last_error:y,next_eligible_at_s:d!=null&&d>0?d:null,recoverable:Fo(void 0,D),summary:jo(void 0,S,T),keepalive_running:o}}function Pc(t,e){if(!Wt(t))return null;const n=xc(t.role),a=K(t.content)??K(t.preview);if(!a)return null;const i=zs(t.ts_unix)??zs(t.timestamp);return{id:`${n}-${i??"entry"}-${e}`,role:n,label:Sc(n),text:a,timestamp:i,delivery:"history"}}function Dc(t,e,n){const a=Wt(n)?n:null,i=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((o,r)=>Pc(o,r)).filter(o=>o!==null):[];return{name:t,diagnostic:da(a==null?void 0:a.diagnostic),history:i,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function Ki(t,e){const n=dt.value[t]??[];dt.value={...dt.value,[t]:[...n,e].slice(-50)}}function Ec(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Ic(t,e){const a=(dt.value[t]??[]).filter(i=>i.delivery!=="history"&&!e.some(o=>Ec(i,o)));dt.value={...dt.value,[t]:[...e,...a].slice(-50)}}function Ba(t,e){Ut.value={...Ut.value,[t]:e},Ic(t,e.history)}function Hi(t,e){const n=Ut.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Ba(t,{...n,diagnostic:{...a,...e}})}async function hi(){qe();try{await ee()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Yn(t){on.value=t.trim()}async function Ko(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Ut.value[n])return Ut.value[n];ot(Es,n,!0),ot(Bt,n,null);try{const a=await ht("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let i=null;try{i=JSON.parse(a)}catch{i=null}const o=Dc(n,a,i);return Ba(n,o),o}catch(a){const i=a instanceof Error?a.message:`Failed to inspect ${n}`;return ot(Bt,n,i),null}finally{ot(Es,n,!1)}}async function Mc(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const i=`local-${Date.now()}`;Ki(n,{id:i,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),ot(Is,n,!0),ot(Bt,n,null);try{const o=await bc(n,a);dt.value={...dt.value,[n]:(dt.value[n]??[]).map(r=>r.id===i?{...r,delivery:"delivered"}:r)},Ki(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Hi(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await hi()}catch(o){const r=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw dt.value={...dt.value,[n]:(dt.value[n]??[]).map(l=>l.id===i?{...l,delivery:"error",error:r}:l)},Hi(n,{last_reply_status:"error",last_error:r}),ot(Bt,n,r),o}finally{ot(Is,n,!1)}}async function Oc(t,e){const n=t.trim();if(!n)return null;ot(Ms,n,!0),ot(Bt,n,null);try{const a=await On({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),i=Nc(a.result),o=(i==null?void 0:i.diagnostic)??null;if(o){const r=Ut.value[n];Ba(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??dt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await hi(),o}catch(a){const i=a instanceof Error?a.message:`Failed to probe ${n}`;throw ot(Bt,n,i),a}finally{ot(Ms,n,!1)}}async function zc(t,e){const n=t.trim();if(!n)return null;ot(Os,n,!0),ot(Bt,n,null);try{const a=await On({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),i=Rc(a.result),o=(i==null?void 0:i.after)??null;if(o){const r=Ut.value[n];Ba(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??dt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await hi(),o}catch(a){const i=a instanceof Error?a.message:`Failed to recover ${n}`;throw ot(Bt,n,i),a}finally{ot(Os,n,!1)}}function ce(t){return(t??"").trim().toLowerCase()}function vt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Xn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function jn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ye(t){return t.last_heartbeat??jn(t.last_turn_ago_s)??jn(t.last_proactive_ago_s)??jn(t.last_handoff_ago_s)??jn(t.last_compaction_ago_s)}function qc(t){const e=t.title.trim();return e||Xn(t.content)}function jc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Fc(t,e,n,a,i={}){var M;const o=ce(t),r=e.filter(N=>ce(N.assignee)===o&&(N.status==="claimed"||N.status==="in_progress")).length,l=n.filter(N=>ce(N.from)===o).sort((N,P)=>vt(P.timestamp)-vt(N.timestamp))[0],p=a.filter(N=>ce(N.agent)===o||ce(N.author)===o).sort((N,P)=>vt(P.timestamp)-vt(N.timestamp))[0],$=(i.boardPosts??[]).filter(N=>ce(N.author)===o).sort((N,P)=>vt(P.updated_at||P.created_at)-vt(N.updated_at||N.created_at))[0],m=(i.keepers??[]).filter(N=>ce(N.name)===o&&Ye(N)!==null).sort((N,P)=>vt(Ye(P)??0)-vt(Ye(N)??0))[0],d=l?vt(l.timestamp):0,v=p?vt(p.timestamp):0,c=$?vt($.updated_at||$.created_at):0,y=m?vt(Ye(m)??0):0,S=i.lastSeen?vt(i.lastSeen):0,T=((M=i.currentTask)==null?void 0:M.trim())||(r>0?`${r} claimed tasks`:null);if(d===0&&v===0&&c===0&&y===0&&S===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:T};const L=[l?{timestamp:l.timestamp,ts:d,text:Xn(l.content)}:null,$?{timestamp:$.updated_at||$.created_at,ts:c,text:`Post: ${Xn(qc($))}`}:null,m?{timestamp:Ye(m),ts:y,text:jc(m)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:v,text:Xn(p.text)}:null].filter(N=>N!==null).sort((N,P)=>P.ts-N.ts)[0];return L&&L.ts>=S?{activeAssignedCount:r,lastActivityAt:L.timestamp,lastActivityText:L.text}:{activeAssignedCount:r,lastActivityAt:i.lastSeen??null,lastActivityText:T??"Presence heartbeat"}}const xt=_([]),$t=_([]),Sn=_([]),Gt=_([]),ae=_(null),nn=_(null),js=_(new Map),Be=_([]),An=_("hot"),ue=_(!0),Ho=_(null),Ht=_(""),wn=_([]),Re=_(!1),Uo=_(new Map),Fs=_("unknown"),Ks=_(null),Hs=_(!1),Cn=_(!1),Us=_(!1),Le=_(!1),Kc=_(null),Bs=_(null),Bo=_(null),Wo=_(null),Hc=St(()=>xt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle")),Go=St(()=>{const t=$t.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Wa=St(()=>{const t=new Map,e=$t.value,n=Sn.value,a=ca.value,i=Be.value,o=Gt.value;for(const r of xt.value)t.set(r.name.trim().toLowerCase(),Fc(r.name,e,n,a,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:i,keepers:o}));return t});function Uc(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const i=a.context_ratio;return i>.85?"handoff-imminent":i>.7?"preparing":i>.5?"compacting":"active"}const Jo=St(()=>{const t=new Map;for(const e of Gt.value)t.set(e.name,Uc(e));return t}),Bc=12e4;function Wc(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const i=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof i=="number"?Date.now()-i*1e3:null}const Vo=St(()=>{const t=Date.now(),e=new Set,n=js.value;for(const a of Gt.value){const i=Wc(a,n);i!=null&&t-i>Bc&&e.add(a.name)}return e}),ua={},Gc=5e3;let Za=null;function Jc(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function qe(){delete ua.compact,delete ua.full}function ut(t){return typeof t=="object"&&t!==null}function b(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function A(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function _e(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Ws(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Qo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Vc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Yo(t){if(!ut(t))return null;const e=b(t.name);return e?{name:e,status:Qo(t.status),current_task:b(t.current_task)??null,last_seen:b(t.last_seen),emoji:b(t.emoji),koreanName:b(t.koreanName)??b(t.korean_name),model:b(t.model),traits:_e(t.traits),interests:_e(t.interests),activityLevel:A(t.activityLevel)??A(t.activity_level),primaryValue:b(t.primaryValue)??b(t.primary_value)}:null}function Xo(t){if(!ut(t))return null;const e=b(t.id),n=b(t.title);return!e||!n?null:{id:e,title:n,status:Vc(t.status),priority:A(t.priority),assignee:b(t.assignee),description:b(t.description),created_at:b(t.created_at),updated_at:b(t.updated_at)}}function Zo(t){if(!ut(t))return null;const e=b(t.from)??b(t.from_agent)??"system",n=b(t.content)??"",a=b(t.timestamp)??new Date().toISOString();return{id:b(t.id),seq:A(t.seq),from:e,content:n,timestamp:a,type:b(t.type)}}function Qc(t){return Array.isArray(t)?t.map(e=>{if(!ut(e))return null;const n=A(e.ts_unix);if(n==null)return null;const a=ut(e.handoff)?e.handoff:null;return{ts:n,context_ratio:A(e.context_ratio)??0,context_tokens:A(e.context_tokens)??0,context_max:A(e.context_max)??0,latency_ms:A(e.latency_ms)??0,generation:A(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:A(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:A(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?A(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function Ui(t){if(!ut(t))return null;const e=b(t.health_state),n=b(t.next_action_path),a=b(t.last_reply_status);if(!e||!n||!a)return null;const i=b(t.quiet_reason)??null,o=b(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":i==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":i==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":i==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:i,next_action_path:n,last_reply_status:a,last_reply_at:Ws(t.last_reply_at)??b(t.last_reply_at)??null,last_reply_preview:b(t.last_reply_preview)??null,last_error:b(t.last_error)??null,next_eligible_at_s:A(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Yc(t,e){return(Array.isArray(t)?t:ut(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!ut(a))return null;const i=ut(a.agent)?a.agent:null,o=ut(a.context)?a.context:null,r=ut(a.metrics_window)?a.metrics_window:void 0,l=b(a.name);if(!l)return null;const p=A(a.context_ratio)??A(o==null?void 0:o.context_ratio),$=b(a.status)??b(i==null?void 0:i.status)??"offline",m=Qo($),d=b(a.model)??b(a.active_model)??b(a.primary_model),v=_e(a.skill_secondary),c=o?{source:b(o.source),context_ratio:A(o.context_ratio),context_tokens:A(o.context_tokens),context_max:A(o.context_max),message_count:A(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,y=i?{name:b(i.name),exists:typeof i.exists=="boolean"?i.exists:void 0,error:b(i.error),status:b(i.status),current_task:b(i.current_task)??null,last_seen:b(i.last_seen),last_seen_ago_s:A(i.last_seen_ago_s),is_zombie:typeof i.is_zombie=="boolean"?i.is_zombie:void 0}:void 0,S=Qc(a.metrics_series),T={name:l,emoji:b(a.emoji),koreanName:b(a.koreanName)??b(a.korean_name),agent_name:b(a.agent_name),trace_id:b(a.trace_id),model:d,primary_model:b(a.primary_model),active_model:b(a.active_model),next_model_hint:b(a.next_model_hint)??null,status:m,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:A(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:A(a.proactive_idle_sec),proactive_cooldown_sec:A(a.proactive_cooldown_sec),last_heartbeat:b(a.last_heartbeat)??b(i==null?void 0:i.last_seen),generation:A(a.generation),turn_count:A(a.turn_count)??A(a.total_turns),keeper_age_s:A(a.keeper_age_s),last_turn_ago_s:A(a.last_turn_ago_s),last_handoff_ago_s:A(a.last_handoff_ago_s),last_compaction_ago_s:A(a.last_compaction_ago_s),last_proactive_ago_s:A(a.last_proactive_ago_s),context_ratio:p,context_tokens:A(a.context_tokens)??A(o==null?void 0:o.context_tokens),context_max:A(a.context_max)??A(o==null?void 0:o.context_max),context_source:b(a.context_source)??b(o==null?void 0:o.source),context:c,traits:_e(a.traits),interests:_e(a.interests),primaryValue:b(a.primaryValue)??b(a.primary_value),activityLevel:A(a.activityLevel)??A(a.activity_level),memory_recent_note:b(a.memory_recent_note)??null,conversation_tail_count:A(a.conversation_tail_count),k2k_count:A(a.k2k_count),handoff_count_total:A(a.handoff_count_total)??A(a.trace_history_count),compaction_count:A(a.compaction_count),last_compaction_saved_tokens:A(a.last_compaction_saved_tokens),diagnostic:Ui(a.diagnostic),skill_primary:b(a.skill_primary)??null,skill_secondary:v,skill_reason:b(a.skill_reason)??null,metrics_series:S.length>0?S:void 0,metrics_window:r,agent:y};return T.diagnostic=Ui(a.diagnostic)??Lc(T,(e==null?void 0:e.lodge)??null),T}).filter(a=>a!==null)}function Xc(t){return ut(t)?{...t,lodge:Tc(t.lodge)??void 0}:null}function Zc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function td(t){if(!ut(t))return null;const e=A(t.iteration);if(e==null)return null;const n=A(t.metric_before)??0,a=A(t.metric_after)??n,i=ut(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:a,delta:A(t.delta)??a-n,changes:b(t.changes)??"",failed_attempts:b(t.failed_attempts)??"",next_suggestion:b(t.next_suggestion)??"",elapsed_ms:A(t.elapsed_ms)??0,cost_usd:A(t.cost_usd)??null,evidence:i?{worker_engine:(i.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:b(i.worker_model)??"",tool_call_count:A(i.tool_call_count)??0,tool_names:_e(i.tool_names)??[],session_id:b(i.session_id)??"",evidence_status:i.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function ed(t){var o,r;if(!ut(t))return null;const e=b(t.loop_id);if(!e)return null;const n=A(t.baseline_metric)??0,a=Array.isArray(t.history)?t.history.map(td).filter(l=>l!==null):[],i=A(t.current_metric)??((o=a[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:b(t.profile)??"unknown",status:Zc(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:b(t.error_message)??b(t.error_reason)??null,stop_reason:b(t.stop_reason)??b(t.reason)??null,current_iteration:A(t.current_iteration)??((r=a[0])==null?void 0:r.iteration)??0,max_iterations:A(t.max_iterations)??0,baseline_metric:n,current_metric:i,target:b(t.target)??"",stagnation_streak:A(t.stagnation_streak)??0,stagnation_limit:A(t.stagnation_limit)??0,elapsed_seconds:A(t.elapsed_seconds)??0,updated_at:Ws(t.updated_at)??null,stopped_at:Ws(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:b(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:A(t.latest_tool_call_count)??0,latest_tool_names:_e(t.latest_tool_names)??[],session_id:b(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:a}}async function ee(t="full"){var a,i,o;const e=Date.now(),n=ua[t];if(!(n&&e-n.time<Gc)){Hs.value=!0;try{const r=await yl(t);ua[t]={data:r,time:e},xt.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(Yo).filter(p=>p!==null),$t.value=(Array.isArray((i=r.tasks)==null?void 0:i.tasks)?r.tasks.tasks:[]).map(Xo).filter(p=>p!==null),Sn.value=(Array.isArray((o=r.messages)==null?void 0:o.messages)?r.messages.messages:[]).map(Zo).filter(p=>p!==null);const l=Xc(r.status);ae.value=l,Gt.value=Yc(r.keepers,l),nn.value=r.perpetual??null,Kc.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{Hs.value=!1}}}async function nd(){try{const t=await bl(),e=(Array.isArray(t.agents)?t.agents:[]).map(Yo).filter(i=>i!==null),n=xt.value,a=new Map(n.map(i=>[i.name,i]));xt.value=e.map(i=>{const o=a.get(i.name);return o?{...o,status:i.status,current_task:i.current_task}:i})}catch(t){console.error("Agents selective fetch error:",t)}}async function ad(){try{const t=await kl({includeDone:!0,includeCancelled:!0}),e=(Array.isArray(t.tasks)?t.tasks:[]).map(Xo).filter(i=>i!==null),n=$t.value,a=new Map(n.map(i=>[i.id,i]));$t.value=e.map(i=>{const o=a.get(i.id);return o?{...o,status:i.status,priority:i.priority??o.priority,assignee:i.assignee??o.assignee}:i})}catch(t){console.error("Tasks selective fetch error:",t)}}async function sd(){try{const t=Sn.value,e=t.reduce((l,p)=>Math.max(l,p.seq??0),0),n=await xl(e),a=(Array.isArray(n.messages)?n.messages:[]).map(Zo).filter(l=>l!==null);if(a.length===0)return;const i=new Set(t.map(l=>l.seq).filter(l=>l!=null)),o=new Set(t.filter(l=>l.seq==null).map(l=>`${l.timestamp}|${l.from}`)),r=a.filter(l=>{if(l.seq!=null)return!i.has(l.seq);const p=`${l.timestamp}|${l.from}`;return o.has(p)?!1:(o.add(p),!0)});if(r.length>0){const l=[...t,...r];Sn.value=l.length>500?l.slice(-500):l}}catch(t){console.error("Messages selective fetch error:",t)}}async function zt(){Cn.value=!0;try{const t=await jl(An.value,{excludeSystem:ue.value});Be.value=t.posts??[],Bs.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Cn.value=!1}}async function qt(){var t;Us.value=!0;try{const e=Ht.value||((t=ae.value)==null?void 0:t.room)||"default";Ht.value||(Ht.value=e);const n=await ac(e);Ho.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Us.value=!1}}async function Tn(){Re.value=!0;try{const t=await kc();wn.value=Array.isArray(t)?t:[],Bo.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Re.value=!1}}async function je(){Le.value=!0;try{const t=await Sl(),e=Array.isArray(t.loops)?t.loops:[],n=new Map;for(const a of e){const i=ed(a);i&&n.set(i.loop_id,i)}Uo.value=n,Wo.value=new Date().toISOString(),Ks.value=null,Fs.value=n.size===0?"idle":"ready"}catch(t){console.error("MDAL fetch error:",t),Fs.value="error",Ks.value=t instanceof Error?t.message:String(t)}finally{Le.value=!1}}let Zn=null;function id(t){Zn=t}let ta=null;function od(t){ta=t}const pe={};function de(t,e,n=500){pe[t]&&clearTimeout(pe[t]),pe[t]=setTimeout(()=>{e(),delete pe[t]},n)}function rd(){const t=Ro.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(js.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),js.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&de("agents",nd),Jc(e.type)&&(qe(),Za||(Za=setTimeout(()=>{ee(),ta==null||ta(),Za=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&de("tasks",ad),e.type==="broadcast"&&de("messages",sd),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&de("dashboard",()=>{qe(),ee()}),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&de("board",zt),e.type.startsWith("decision_")&&de("council",()=>Zn==null?void 0:Zn()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&de("mdal",je,350)}});return()=>{t();for(const e of Object.keys(pe))clearTimeout(pe[e]),delete pe[e]}}let rn=null;function ld(){rn||(rn=setInterval(()=>{jt.value||qe(),ee()},1e4))}function cd(){rn&&(clearInterval(rn),rn=null)}function C({title:t,class:e,children:n}){return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
var Ur=Object.defineProperty;var Br=(t,e,n)=>e in t?Ur(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var xe=(t,e,n)=>Br(t,typeof e!="symbol"?e+"":e,n);import{e as Wr,_ as Gr,c as f,b as St,y as rt,d as Ha,A as xo,G as Jr}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const i of document.querySelectorAll('link[rel="modulepreload"]'))a(i);new MutationObserver(i=>{for(const o of i)if(o.type==="childList")for(const r of o.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(i){const o={};return i.integrity&&(o.integrity=i.integrity),i.referrerPolicy&&(o.referrerPolicy=i.referrerPolicy),i.crossOrigin==="use-credentials"?o.credentials="include":i.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function a(i){if(i.ep)return;i.ep=!0;const o=n(i);fetch(i.href,o)}})();var s=Wr.bind(Gr);const Vr=["command","overview","board","goals","agents","ops","trpg"],So={tab:"overview",params:{},postId:null},Qr={journal:"overview",mdal:"goals",tasks:"goals",execution:"overview",council:"board",activity:"overview"};function Di(t){return!!t&&Vr.includes(t)}function Ei(t){if(t)return Qr[t]??t}function Qn(t){try{return decodeURIComponent(t)}catch{return t}}function Ts(t){const e={};return t&&new URLSearchParams(t).forEach((a,i)=>{e[i]=a}),e}function Yr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Ao(t,e){if(t[0]==="chains"){const r={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(r.operation=Qn(t[2])),{tab:"command",params:r,postId:null}}const n=Ei(t[0]),a=Ei(e.tab),i=Di(n)?n:Di(a)?a:"overview";let o=null;return i==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?o=Qn(t[2]):t[0]==="post"&&t[1]&&(o=Qn(t[1]))),{tab:i,params:e,postId:o}}function la(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return So;const n=Qn(e);let a=n,i;if(n.startsWith("?"))a="",i=n.slice(1);else{const l=n.indexOf("?");l>=0&&(a=n.slice(0,l),i=n.slice(l+1))}!i&&a.includes("=")&&!a.includes("/")&&(i=a,a="");const o=Ts(i),r=Yr(a);return Ao(r,o)}function Xr(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...So,params:Ts(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const i=Ts(e.replace(/^\?/,""));return Ao(a,i)}function wo(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([i])=>i!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const tt=f(la(window.location.hash));window.addEventListener("hashchange",()=>{tt.value=la(window.location.hash)});function Rt(t,e){const n={tab:t,params:e??{},postId:null};window.location.hash=wo(n)}function Zr(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function tl(){if(window.location.hash&&window.location.hash!=="#"){tt.value=la(window.location.hash);return}const t=Xr(window.location.pathname,window.location.search);if(t){tt.value=t;const e=wo(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",tt.value=la(window.location.hash)}const Ii="masc_dashboard_sse_session_id",el=1e3,nl=15e3,jt=f(!1),In=f(0),Co=f(null),ca=f([]);function al(){let t=sessionStorage.getItem(Ii);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Ii,t)),t}const sl=200;function il(t,e,n="system",a={}){const i={agent:t,text:e,timestamp:Date.now(),kind:n,...a};ca.value=[i,...ca.value].slice(0,sl)}function Ns(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Mi(t,e){const n=Ns(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function Ct(t,e,n,a,i={}){il(t,e,n,{eventType:a,...i})}let Mt=null,Ee=null,Rs=0;function To(){Ee&&(clearTimeout(Ee),Ee=null)}function ol(){if(Ee)return;Rs++;const t=Math.min(Rs,5),e=Math.min(nl,el*Math.pow(2,t));Ee=setTimeout(()=>{Ee=null,No()},e)}function No(){To(),Mt&&(Mt.close(),Mt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",al());const i=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(i);Mt=o,o.onopen=()=>{Mt===o&&(Rs=0,jt.value=!0)},o.onerror=()=>{Mt===o&&(jt.value=!1,o.close(),Mt=null,ol())},o.onmessage=r=>{try{const l=JSON.parse(r.data);In.value++,Co.value=l,rl(l)}catch{}}}function rl(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":Ct(n,"Joined","system","agent_joined");break;case"agent_left":Ct(n,"Left","system","agent_left");break;case"broadcast":Ct(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Ct(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Ct(n,Mi("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Ns(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":Ct(n,Mi("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Ns(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":Ct(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Ct(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Ct(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Ct(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Ct(n,e,"system","unknown")}}function ll(){To(),Mt&&(Mt.close(),Mt=null),jt.value=!1}function Ro(){return new URLSearchParams(window.location.search)}function Lo(){const t=Ro(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Po(){return{...Lo(),"Content-Type":"application/json"}}const cl=15e3,vi=3e4,dl=6e4,Oi=new Set([408,425,429,500,502,503,504]);class Mn extends Error{constructor(n){const a=n.method.toUpperCase(),i=n.timeout===!0,o=i?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);xe(this,"method");xe(this,"path");xe(this,"status");xe(this,"statusText");xe(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=i}}async function fi(t,e,n){const a=new AbortController,i=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Mn({method:r,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(i)}}function ul(){var e,n;const t=Ro();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function X(t){const e=await fi(t,{headers:Lo()},cl);if(!e.ok)throw new Mn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function pl(t){return new Promise(e=>setTimeout(e,t))}function ml(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function vl(t){if(t instanceof Mn)return t.timeout||typeof t.status=="number"&&Oi.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=ml(t.message);return e!==null&&Oi.has(e)}async function Ue(t,e,n=2){let a=0;for(;;)try{return await e()}catch(i){if(!vl(i)||a>=n)throw i;const o=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${o}ms`,i),await pl(o),a+=1}}async function Ft(t,e,n,a=vi){const i=await fi(t,{method:"POST",headers:{...Po(),...n??{}},body:JSON.stringify(e)},a);if(!i.ok)throw new Mn({method:"POST",path:t,status:i.status,statusText:i.statusText});return i.json()}async function fl(t,e,n,a=vi){const i=await fi(t,{method:"POST",headers:{...Po(),...n??{}},body:JSON.stringify(e)},a);if(!i.ok)throw new Mn({method:"POST",path:t,status:i.status,statusText:i.statusText});return i.text()}function gl(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function _l(t){var e,n,a,i,o,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const p=((i=(a=t.result.content)==null?void 0:a[0])==null?void 0:i.text)??"MCP tool call failed";throw new Error(p)}return((l=(r=(o=t.result)==null?void 0:o.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function ht(t,e){const n=await fl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},dl),a=gl(n);return _l(a)}function $l(t="compact"){return X(`/api/v1/dashboard?mode=${t}`)}function hl(){return X("/api/v1/agents?limit=100")}function yl(t){const e=new URLSearchParams({limit:"200"});return e.set("include_done","true"),e.set("include_cancelled","true"),X(`/api/v1/tasks?${e}`)}function bl(t){const e=new URLSearchParams({limit:"50"});return t!=null&&t>0&&e.set("since_seq",String(t)),X(`/api/v1/messages?${e}`)}function kl(t={}){return Ue("fetchMdalLoops",async()=>{const e=new URLSearchParams;t.limit!=null&&e.set("limit",String(t.limit)),t.historyLimit!=null&&e.set("history_limit",String(t.historyLimit)),t.status&&e.set("status",t.status);const n=e.toString();return X(`/api/v1/mdal/loops${n?`?${n}`:""}`)})}function xl(){return X("/api/v1/operator")}function Sl(){return X("/api/v1/command-plane")}function Al(){return X("/api/v1/command-plane/summary")}function wl(){return X("/api/v1/chains/summary")}function Cl(t){return X(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Tl(){return X("/api/v1/command-plane/help")}function Nl(t){const e=new URLSearchParams;t&&e.set("run_id",t);const n=e.toString();return X(`/api/v1/command-plane/swarm${n?`?${n}`:""}`)}function Rl(t,e){return Ft(t,e)}function Ll(t){switch(t.action_type){case"keeper_msg":case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return vi}}function On(t){return Ft("/api/v1/operator/action",t,void 0,Ll(t))}function Pl(t,e){return Ft("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const Dl=new Set(["lodge-system","team-session"]);function ze(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function El(t){return Dl.has(t.trim().toLowerCase())}function Il(t){return t.filter(e=>!El(e.author))}function Ml(t){var i;const e=t.trim(),a=((i=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:i.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function Do(t){if(!O(t))return null;const e=$(t.id,"").trim(),n=$(t.author,"").trim(),a=$(t.content,"").trim();if(!e||!n)return null;const i=q(t.score,0),o=q(t.votes_up,0),r=q(t.votes_down,0),l=q(t.votes,i||o-r),p=q(t.comment_count,q(t.reply_count,0)),_=(()=>{const y=t.flair;if(typeof y=="string"&&y.trim())return y.trim();if(O(y)){const T=$(y.name,"").trim();if(T)return T}return $(t.flair_name,"").trim()||void 0})(),m=$(t.created_at_iso,"").trim()||ze(t.created_at),d=$(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?ze(t.updated_at):m),g=$(t.title,"").trim()||Ml(a);return{id:e,author:n,title:g,content:a,tags:[],votes:l,vote_balance:i,comment_count:p,created_at:m,updated_at:d,flair:_,hearth_count:q(t.hearth_count,0)}}function Ol(t){if(!O(t))return null;const e=$(t.id,"").trim(),n=$(t.post_id,"").trim(),a=$(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:$(t.content,""),created_at:ze(t.created_at)}}async function zl(t,e){return Ue("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const a=n.toString(),i=await X(`/api/v1/board${a?`?${a}`:""}`),o=Array.isArray(i.posts)?i.posts.map(Do).filter(l=>l!==null):[];return{posts:e!=null&&e.excludeSystem?Il(o):o}})}async function ql(t){return Ue("fetchBoardPost",async()=>{const e=await X(`/api/v1/board/${t}?format=flat`),n=O(e.post)?e.post:e,a=Do(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},o=(Array.isArray(e.comments)?e.comments:[]).map(Ol).filter(r=>r!==null);return{...a,comments:o}})}function Eo(t,e){return Ft("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:ul()})}function jl(t,e,n){return Ft("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Fl(t){const e=$(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function lt(...t){for(const e of t){const n=$(e,"");if(n.trim())return n.trim()}return""}function zi(t){const e=Fl(lt(t.outcome,t.result,t.result_code));if(!e)return;const n=lt(t.reason,t.reason_code,t.description,t.detail),a=lt(t.summary,t.summary_ko,t.summary_en,t.note),i=lt(t.details,t.details_text,t.text,t.note),o=lt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=lt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=lt(t.raw_reason,t.raw_reason_code,t.error_message),p=(()=>{const d=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof d=="string"?[d]:Array.isArray(d)?d.map(c=>{if(typeof c=="string")return c.trim();if(O(c)){const g=$(c.summary,"").trim();if(g)return g;const y=$(c.text,"").trim();if(y)return y;const S=$(c.type,"").trim();return S||$(c.event_id,"").trim()}return""}).filter(c=>c.length>0):[]})(),_=(()=>{const d=q(t.turn,Number.NaN);if(Number.isFinite(d))return d;const c=q(t.turn_number,Number.NaN);if(Number.isFinite(c))return c;const g=q(t.current_turn,Number.NaN);if(Number.isFinite(g))return g;const y=q(t.round,Number.NaN);return Number.isFinite(y)?y:void 0})(),m=lt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:i||void 0,winner:o||void 0,winner_actor_id:r||void 0,evidence:p.length>0?p:void 0,raw_reason:l||void 0,turn:_,phase:m||void 0}}function Kl(t,e){const n=O(t.state)?t.state:{};if($(n.status,"active").toLowerCase()!=="ended")return;const i=[...e].reverse().find(r=>O(r)?$(r.type,"")==="session.outcome":!1),o=O(n.session_outcome)?n.session_outcome:{};if(O(o)&&Object.keys(o).length>0){const r=zi(o);if(r)return r}if(O(i))return zi(O(i.payload)?i.payload:{})}function O(t){return typeof t=="object"&&t!==null}function $(t,e=""){return typeof t=="string"?t:e}function q(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Hl(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Ls(t,e=!1){return typeof t=="boolean"?t:e}function Qe(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(O(e)){const n=$(e.name,"").trim(),a=$(e.id,"").trim(),i=$(e.skill,"").trim();return n||a||i}return""}).filter(e=>e.length>0):[]}function Ul(t){const e={};if(!O(t)&&!Array.isArray(t))return e;if(O(t))return Object.entries(t).forEach(([n,a])=>{const i=n.trim(),o=$(a,"").trim();!i||!o||(e[i]=o)}),e;for(const n of t){if(!O(n))continue;const a=lt(n.to,n.target,n.actor_id,n.name,n.id),i=lt(n.relationship,n.relation,n.type,n.kind);!a||!i||(e[a]=i)}return e}function Bl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function bt(t,e,n,a=0){const i=t[e];if(typeof i=="number"&&Number.isFinite(i))return i;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return a}const Wl=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Gl(t){const e=O(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,i])=>{const o=a.trim();o&&(Wl.has(o.toLowerCase())||typeof i=="number"&&Number.isFinite(i)&&(n[o]=i))}),n}function Jl(t,e){if(t!=="dice.rolled")return;const n=q(e.raw_d20,0),a=q(e.total,0),i=q(e.bonus,0),o=$(e.action,"roll"),r=q(e.dc,0);return{notation:r>0?`${o} (DC ${r})`:o,rolls:n>0?[n]:[],total:a,modifier:i}}function Vl(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Ql(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Yl(t,e,n,a){const i=n||e||$(a.actor_id,"")||$(a.actor_name,"");switch(t){case"turn.action.proposed":{const o=$(a.proposed_action,$(a.reply,""));return o?`${i||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=$(a.reply,$(a.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return $(a.reply,$(a.content,$(a.text,"Narration")));case"dice.rolled":{const o=$(a.action,"roll"),r=q(a.total,0),l=q(a.dc,0),p=$(a.label,""),_=i||"actor",m=l>0?` vs DC ${l}`:"",d=p?` (${p})`:"";return`${_} ${o}: ${r}${m}${d}`}case"turn.started":return`Turn ${q(a.turn,1)} started`;case"phase.changed":return`Phase: ${$(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${$(a.name,O(a.actor)?$(a.actor.name,i||"unknown"):i||"unknown")}`;case"actor.claimed":return`${$(a.keeper_name,$(a.keeper,"keeper"))} claimed ${i||"actor"}`;case"actor.released":return`${$(a.keeper_name,$(a.keeper,"keeper"))} released ${i||"actor"}`;case"join.window.opened":return`Join window opened (turn ${q(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${q(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${i||$(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${i||$(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${$(a.reason_code,"unknown")}`;case"memory.signal":{const o=O(a.entity_refs)?a.entity_refs:{},r=$(o.requested_tier,""),l=$(o.effective_tier,""),p=Ls(o.guardrail_applied,!1),_=$(a.summary_en,$(a.summary_ko,"Memory signal"));if(!r&&!l)return _;const m=r&&l?`${r}->${l}`:l||r;return`${_} [${m}${p?" (guardrail)":""}]`}case"world.event":{if($(a.event_type,"")==="canon.check"){const r=$(a.status,"unknown"),l=$(a.contract_id,"n/a");return`Canon ${r}: ${l}`}return $(a.description,$(a.summary,"World event"))}case"combat.attack":return $(a.summary,$(a.result,"Attack resolved"));case"combat.defense":return $(a.summary,$(a.result,"Defense resolved"));case"session.outcome":return $(a.summary,$(a.outcome,"Session ended"));default:{const o=Vl(a);return o?`${t}: ${o}`:t}}}function Xl(t,e){const n=O(t)?t:{},a=$(n.type,"event"),i=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=$(n.actor_name,"").trim()||e[i]||$(O(n.payload)?n.payload.actor_name:"",""),r=O(n.payload)?n.payload:{},l=$(n.ts,$(n.timestamp,new Date().toISOString())),p=$(n.phase,$(r.phase,"")),_=$(n.category,"");return{type:a,actor:o||i||$(r.actor_name,""),actor_id:i||$(r.actor_id,""),actor_name:o,seq:n.seq,room_id:$(n.room_id,""),phase:p||void 0,category:_||Ql(a),visibility:$(n.visibility,$(r.visibility,"public")),event_id:$(n.event_id,""),content:Yl(a,i,o,r),dice_roll:Jl(a,r),timestamp:l}}function Zl(t,e,n){var At,wt;const a=$(t.room_id,"")||n||"default",i=O(t.state)?t.state:{},o=O(i.party)?i.party:{},r=O(i.actor_control)?i.actor_control:{},l=O(i.join_gate)?i.join_gate:{},p=O(i.contribution_ledger)?i.contribution_ledger:{},_=Object.entries(o).map(([W,nt])=>{const k=O(nt)?nt:{},Pt=bt(k,"max_hp",void 0,10),Jt=bt(k,"hp",void 0,Pt),oe=bt(k,"max_mp",void 0,0),re=bt(k,"mp",void 0,0),I=bt(k,"level",void 0,1),Dt=bt(k,"xp",void 0,0),le=Ls(k.alive,Jt>0),Je=r[W],Ve=typeof Je=="string"?Je:void 0,v=Bl(k.role,W,Ve),R=Hl(k.generation),j=lt(k.joined_at,k.joinedAt,k.started_at,k.startedAt),at=lt(k.claimed_at,k.claimedAt,k.assigned_at,k.assignedAt,k.assigned_time),z=lt(k.last_seen,k.lastSeen,k.last_seen_at,k.lastSeenAt,k.last_active,k.lastActive),mt=lt(k.scene,k.current_scene,k.currentScene,k.world_scene,k.scene_name,k.sceneName),J=lt(k.location,k.current_location,k.currentLocation,k.position,k.zone,k.area);return{id:W,name:$(k.name,W),role:v,keeper:Ve,archetype:$(k.archetype,""),persona:$(k.persona,""),portrait:$(k.portrait,"")||void 0,background:$(k.background,"")||void 0,traits:Qe(k.traits),skills:Qe(k.skills),stats_raw:Gl(k),status:le?"active":"dead",generation:R,joined_at:j||void 0,claimed_at:at||void 0,last_seen:z||void 0,scene:mt||void 0,location:J||void 0,inventory:Qe(k.inventory),notes:Qe(k.notes),relationships:Ul(k.relationships),stats:{hp:Jt,max_hp:Pt,mp:re,max_mp:oe,level:I,xp:Dt,strength:bt(k,"strength","str",10),dexterity:bt(k,"dexterity","dex",10),constitution:bt(k,"constitution","con",10),intelligence:bt(k,"intelligence","int",10),wisdom:bt(k,"wisdom","wis",10),charisma:bt(k,"charisma","cha",10)}}}),m=_.filter(W=>W.status!=="dead"),d=Kl(t,e),c={phase_open:Ls(l.phase_open,!0),min_points:q(l.min_points,3),window:$(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},g=Object.entries(p).map(([W,nt])=>{const k=O(nt)?nt:{};return{actor_id:W,score:q(k.score,0),last_reason:$(k.last_reason,"")||null,reasons:Qe(k.reasons)}}),y=_.reduce((W,nt)=>(W[nt.id]=nt.name,W),{}),S=e.map(W=>Xl(W,y)),T=q(i.turn,1),D=$(i.phase,"round"),L=$(i.map,""),M=O(i.world)?i.world:{},N=L||$(M.ascii_map,$(M.map,"")),P=S.filter((W,nt)=>{const k=e[nt];if(!O(k))return!1;const Pt=O(k.payload)?k.payload:{};return q(Pt.turn,-1)===T}),et=(P.length>0?P:S).slice(-12),U=$(i.status,"active");return{session:{id:a,room:a,status:U==="ended"?"ended":U==="paused"?"paused":"active",round:T,actors:m,created_at:((At=S[0])==null?void 0:At.timestamp)??new Date().toISOString()},current_round:{round_number:T,phase:D,events:et,timestamp:((wt=S[S.length-1])==null?void 0:wt.timestamp)??new Date().toISOString()},map:N||void 0,join_gate:c,contribution_ledger:g,outcome:d,party:m,story_log:S,history:[]}}async function tc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await X(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function ec(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([X(`/api/v1/trpg/state${e}`),tc(t)]);return Zl(n,a,t)}function nc(t){return Ft("/api/v1/trpg/rounds/run",{room_id:t})}function ac(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function sc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Ft("/api/v1/trpg/dice/roll",e)}function ic(t,e){const n=ac();return Ft("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function oc(t,e){var i;const n=(i=e.idempotencyKey)==null?void 0:i.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),Ft("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function rc(t,e,n){return Ft("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function lc(t,e,n){const a=await ht("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function cc(t){const e=await ht("trpg.mid_join.request",t);return JSON.parse(e)}async function Io(t,e){await ht("masc_broadcast",{agent_name:t,message:e})}async function dc(t,e,n=1){await ht("masc_add_task",{title:t,description:e,priority:n})}async function uc(t){return ht("masc_join",{agent_name:t})}async function Mo(t){await ht("masc_leave",{agent_name:t})}async function pc(t){await ht("masc_heartbeat",{agent_name:t})}async function mc(t=40){return(await ht("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function vc(t,e=20){return ht("masc_task_history",{task_id:t,limit:e})}async function fc(){return Ue("fetchDebates",async()=>{const t=await X("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!O(e))return null;const n=$(e.id,"").trim(),a=$(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:$(e.status,"open"),argument_count:q(e.argument_count,0),created_at:ze(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function gc(){return Ue("fetchCouncilSessions",async()=>{const t=await X("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!O(e))return null;const n=$(e.id,"").trim(),a=$(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:$(e.initiator,"system"),votes:q(e.votes,0),quorum:q(e.quorum,0),state:$(e.state,"open"),created_at:ze(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function _c(t){const e=await ht("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function $c(t){return Ue("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await X(`/api/v1/council/debates/${e}/summary`);if(!O(n))return null;const a=$(n.id,"").trim();return a?{id:a,topic:$(n.topic,""),status:$(n.status,"open"),support_count:q(n.support_count,0),oppose_count:q(n.oppose_count,0),neutral_count:q(n.neutral_count,0),total_arguments:q(n.total_arguments,0),created_at:ze(n.created_at_iso??n.created_at),summary_text:$(n.summary_text,"")}:null})}function hc(t,e,n){return ht("masc_keeper_msg",{name:t,message:e})}async function yc(){try{const t=await ht("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const sn=f(""),Ut=f({}),dt=f({}),Ps=f({}),Ds=f({}),Es=f({}),Is=f({}),Bt=f({});function ot(t,e,n){t.value={...t.value,[e]:n}}function Wt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function K(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function Nt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Re(t){return typeof t=="boolean"?t:void 0}function Ms(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function Os(t){return Array.isArray(t)?t.map(e=>K(e)).filter(e=>!!e):[]}function bc(t){var n;const e=(n=K(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function kc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Ya(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!Wt(a))continue;const i=K(a.name);if(!i)continue;const o=K(a[e]);e==="summary"?n.push({name:i,summary:o}):n.push({name:i,reason:o})}return n}function xc(t){if(!Wt(t))return null;const e=K(t.name);return e?{name:e,trigger:K(t.trigger),outcome:K(t.outcome),summary:K(t.summary),reason:K(t.reason)}:null}function Sc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Ac(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Oo(t,e,n){return K(t)??Ac(e,n)}function zo(t,e){return typeof t=="boolean"?t:e==="recover"}function da(t){if(!Wt(t))return null;const e=K(t.health_state),n=K(t.next_action_path),a=K(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:K(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:Ms(t.last_reply_at),last_reply_preview:K(t.last_reply_preview)??null,last_error:K(t.last_error)??null,next_eligible_at_s:Nt(t.next_eligible_at_s)??null,recoverable:zo(t.recoverable,n),summary:Oo(t.summary,e,K(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function gi(t){return Wt(t)?{hour:Nt(t.hour),checked:Nt(t.checked)??0,acted:Nt(t.acted)??0,acted_names:Os(t.acted_names),activity_report:K(t.activity_report),quiet_hours_overridden:Re(t.quiet_hours_overridden),skipped_reason:K(t.skipped_reason),acted_rows:Ya(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:Ya(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:Ya(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(xc).filter(e=>e!==null):[]}:null}function wc(t){return Wt(t)?{enabled:Re(t.enabled)??!1,interval_s:Nt(t.interval_s)??0,quiet_start:Nt(t.quiet_start),quiet_end:Nt(t.quiet_end),quiet_active:Re(t.quiet_active),use_planner:Re(t.use_planner),delegate_llm:Re(t.delegate_llm),agent_count:Nt(t.agent_count),agents:Os(t.agents),last_tick_ago_s:Nt(t.last_tick_ago_s)??null,last_tick_ago:K(t.last_tick_ago),total_ticks:Nt(t.total_ticks),total_checkins:Nt(t.total_checkins),last_skip_reason:K(t.last_skip_reason)??null,last_tick_result:gi(t.last_tick_result),active_self_heartbeats:Os(t.active_self_heartbeats)}:null}function Cc(t){return Wt(t)?{status:t.status,diagnostic:da(t.diagnostic)}:null}function Tc(t){return Wt(t)?{recovered:Re(t.recovered)??!1,skipped_reason:K(t.skipped_reason)??null,before:da(t.before),after:da(t.after),down:t.down,up:t.up}:null}function Nc(t,e){var L,M;if(!(t!=null&&t.name))return null;const n=K((L=t.agent)==null?void 0:L.status)??K(t.status)??"unknown",a=K((M=t.agent)==null?void 0:M.error)??null,i=t.presence_keepalive??!0,o=t.keepalive_running??!1,r=t.turn_count??0,l=t.last_turn_ago_s??null,p=t.proactive_enabled??!1,_=t.proactive_cooldown_sec??0,m=t.last_proactive_ago_s??null,d=p&&m!=null?Math.max(0,_-m):null,c=r<=0||l==null?"never":l>900?"stale":"fresh",g=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,y=a??(i&&!o?"keeper keepalive is not running":null),S=n==="offline"||n==="inactive"?"offline":y?"degraded":c==="stale"?"stale":c==="never"?"idle":"healthy",T=y?Sc(y):e!=null&&e.quiet_active&&c!=="fresh"?"quiet_hours":i&&!o?"disabled":r<=0?"never_started":d!=null&&d>0?"min_gap":c==="fresh"||c==="stale"?"no_recent_activity":"unknown",D=S==="offline"||S==="degraded"||S==="stale"?"recover":T==="quiet_hours"?"manual_lodge_poke":T==="unknown"?"probe":"direct_message";return{health_state:S,quiet_reason:T,next_action_path:D,last_reply_status:c,last_reply_at:g,last_reply_preview:null,last_error:y,next_eligible_at_s:d!=null&&d>0?d:null,recoverable:zo(void 0,D),summary:Oo(void 0,S,T),keepalive_running:o}}function Rc(t,e){if(!Wt(t))return null;const n=bc(t.role),a=K(t.content)??K(t.preview);if(!a)return null;const i=Ms(t.ts_unix)??Ms(t.timestamp);return{id:`${n}-${i??"entry"}-${e}`,role:n,label:kc(n),text:a,timestamp:i,delivery:"history"}}function Lc(t,e,n){const a=Wt(n)?n:null,i=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((o,r)=>Rc(o,r)).filter(o=>o!==null):[];return{name:t,diagnostic:da(a==null?void 0:a.diagnostic),history:i,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function qi(t,e){const n=dt.value[t]??[];dt.value={...dt.value,[t]:[...n,e].slice(-50)}}function Pc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Dc(t,e){const a=(dt.value[t]??[]).filter(i=>i.delivery!=="history"&&!e.some(o=>Pc(i,o)));dt.value={...dt.value,[t]:[...e,...a].slice(-50)}}function Ua(t,e){Ut.value={...Ut.value,[t]:e},Dc(t,e.history)}function ji(t,e){const n=Ut.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Ua(t,{...n,diagnostic:{...a,...e}})}async function _i(){qe();try{await ee()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Yn(t){sn.value=t.trim()}async function qo(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Ut.value[n])return Ut.value[n];ot(Ps,n,!0),ot(Bt,n,null);try{const a=await ht("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let i=null;try{i=JSON.parse(a)}catch{i=null}const o=Lc(n,a,i);return Ua(n,o),o}catch(a){const i=a instanceof Error?a.message:`Failed to inspect ${n}`;return ot(Bt,n,i),null}finally{ot(Ps,n,!1)}}async function Ec(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const i=`local-${Date.now()}`;qi(n,{id:i,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),ot(Ds,n,!0),ot(Bt,n,null);try{const o=await hc(n,a);dt.value={...dt.value,[n]:(dt.value[n]??[]).map(r=>r.id===i?{...r,delivery:"delivered"}:r)},qi(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),ji(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await _i()}catch(o){const r=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw dt.value={...dt.value,[n]:(dt.value[n]??[]).map(l=>l.id===i?{...l,delivery:"error",error:r}:l)},ji(n,{last_reply_status:"error",last_error:r}),ot(Bt,n,r),o}finally{ot(Ds,n,!1)}}async function Ic(t,e){const n=t.trim();if(!n)return null;ot(Es,n,!0),ot(Bt,n,null);try{const a=await On({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),i=Cc(a.result),o=(i==null?void 0:i.diagnostic)??null;if(o){const r=Ut.value[n];Ua(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??dt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await _i(),o}catch(a){const i=a instanceof Error?a.message:`Failed to probe ${n}`;throw ot(Bt,n,i),a}finally{ot(Es,n,!1)}}async function Mc(t,e){const n=t.trim();if(!n)return null;ot(Is,n,!0),ot(Bt,n,null);try{const a=await On({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),i=Tc(a.result),o=(i==null?void 0:i.after)??null;if(o){const r=Ut.value[n];Ua(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??dt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await _i(),o}catch(a){const i=a instanceof Error?a.message:`Failed to recover ${n}`;throw ot(Bt,n,i),a}finally{ot(Is,n,!1)}}function ce(t){return(t??"").trim().toLowerCase()}function vt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Xn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function jn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ye(t){return t.last_heartbeat??jn(t.last_turn_ago_s)??jn(t.last_proactive_ago_s)??jn(t.last_handoff_ago_s)??jn(t.last_compaction_ago_s)}function Oc(t){const e=t.title.trim();return e||Xn(t.content)}function zc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function qc(t,e,n,a,i={}){var M;const o=ce(t),r=e.filter(N=>ce(N.assignee)===o&&(N.status==="claimed"||N.status==="in_progress")).length,l=n.filter(N=>ce(N.from)===o).sort((N,P)=>vt(P.timestamp)-vt(N.timestamp))[0],p=a.filter(N=>ce(N.agent)===o||ce(N.author)===o).sort((N,P)=>vt(P.timestamp)-vt(N.timestamp))[0],_=(i.boardPosts??[]).filter(N=>ce(N.author)===o).sort((N,P)=>vt(P.updated_at||P.created_at)-vt(N.updated_at||N.created_at))[0],m=(i.keepers??[]).filter(N=>ce(N.name)===o&&Ye(N)!==null).sort((N,P)=>vt(Ye(P)??0)-vt(Ye(N)??0))[0],d=l?vt(l.timestamp):0,c=p?vt(p.timestamp):0,g=_?vt(_.updated_at||_.created_at):0,y=m?vt(Ye(m)??0):0,S=i.lastSeen?vt(i.lastSeen):0,T=((M=i.currentTask)==null?void 0:M.trim())||(r>0?`${r} claimed tasks`:null);if(d===0&&c===0&&g===0&&y===0&&S===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:T};const L=[l?{timestamp:l.timestamp,ts:d,text:Xn(l.content)}:null,_?{timestamp:_.updated_at||_.created_at,ts:g,text:`Post: ${Xn(Oc(_))}`}:null,m?{timestamp:Ye(m),ts:y,text:zc(m)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:c,text:Xn(p.text)}:null].filter(N=>N!==null).sort((N,P)=>P.ts-N.ts)[0];return L&&L.ts>=S?{activeAssignedCount:r,lastActivityAt:L.timestamp,lastActivityText:L.text}:{activeAssignedCount:r,lastActivityAt:i.lastSeen??null,lastActivityText:T??"Presence heartbeat"}}const xt=f([]),$t=f([]),Sn=f([]),Gt=f([]),ae=f(null),en=f(null),zs=f(new Map),Be=f([]),An=f("hot"),ue=f(!0),jo=f(null),Ht=f(""),wn=f([]),Le=f(!1),Fo=f(new Map),qs=f("unknown"),js=f(null),Fs=f(!1),Cn=f(!1),Ks=f(!1),Pe=f(!1),jc=f(null),Hs=f(null),Ko=f(null),Ho=f(null),Fc=St(()=>xt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle")),Uo=St(()=>{const t=$t.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Ba=St(()=>{const t=new Map,e=$t.value,n=Sn.value,a=ca.value,i=Be.value,o=Gt.value;for(const r of xt.value)t.set(r.name.trim().toLowerCase(),qc(r.name,e,n,a,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:i,keepers:o}));return t});function Kc(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const i=a.context_ratio;return i>.85?"handoff-imminent":i>.7?"preparing":i>.5?"compacting":"active"}const Bo=St(()=>{const t=new Map;for(const e of Gt.value)t.set(e.name,Kc(e));return t}),Hc=12e4;function Uc(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const i=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof i=="number"?Date.now()-i*1e3:null}const Wo=St(()=>{const t=Date.now(),e=new Set,n=zs.value;for(const a of Gt.value){const i=Uc(a,n);i!=null&&t-i>Hc&&e.add(a.name)}return e}),ua={},Bc=5e3;let Xa=null;function Wc(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function qe(){delete ua.compact,delete ua.full}function ut(t){return typeof t=="object"&&t!==null}function b(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function A(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function _e(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Us(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Go(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Gc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Jo(t){if(!ut(t))return null;const e=b(t.name);return e?{name:e,status:Go(t.status),current_task:b(t.current_task)??null,last_seen:b(t.last_seen),emoji:b(t.emoji),koreanName:b(t.koreanName)??b(t.korean_name),model:b(t.model),traits:_e(t.traits),interests:_e(t.interests),activityLevel:A(t.activityLevel)??A(t.activity_level),primaryValue:b(t.primaryValue)??b(t.primary_value)}:null}function Vo(t){if(!ut(t))return null;const e=b(t.id),n=b(t.title);return!e||!n?null:{id:e,title:n,status:Gc(t.status),priority:A(t.priority),assignee:b(t.assignee),description:b(t.description),created_at:b(t.created_at),updated_at:b(t.updated_at)}}function Qo(t){if(!ut(t))return null;const e=b(t.from)??b(t.from_agent)??"system",n=b(t.content)??"",a=b(t.timestamp)??new Date().toISOString();return{id:b(t.id),seq:A(t.seq),from:e,content:n,timestamp:a,type:b(t.type)}}function Jc(t){return Array.isArray(t)?t.map(e=>{if(!ut(e))return null;const n=A(e.ts_unix);if(n==null)return null;const a=ut(e.handoff)?e.handoff:null;return{ts:n,context_ratio:A(e.context_ratio)??0,context_tokens:A(e.context_tokens)??0,context_max:A(e.context_max)??0,latency_ms:A(e.latency_ms)??0,generation:A(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:A(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:A(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?A(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function Fi(t){if(!ut(t))return null;const e=b(t.health_state),n=b(t.next_action_path),a=b(t.last_reply_status);if(!e||!n||!a)return null;const i=b(t.quiet_reason)??null,o=b(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":i==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":i==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":i==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:i,next_action_path:n,last_reply_status:a,last_reply_at:Us(t.last_reply_at)??b(t.last_reply_at)??null,last_reply_preview:b(t.last_reply_preview)??null,last_error:b(t.last_error)??null,next_eligible_at_s:A(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Vc(t,e){return(Array.isArray(t)?t:ut(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!ut(a))return null;const i=ut(a.agent)?a.agent:null,o=ut(a.context)?a.context:null,r=ut(a.metrics_window)?a.metrics_window:void 0,l=b(a.name);if(!l)return null;const p=A(a.context_ratio)??A(o==null?void 0:o.context_ratio),_=b(a.status)??b(i==null?void 0:i.status)??"offline",m=Go(_),d=b(a.model)??b(a.active_model)??b(a.primary_model),c=_e(a.skill_secondary),g=o?{source:b(o.source),context_ratio:A(o.context_ratio),context_tokens:A(o.context_tokens),context_max:A(o.context_max),message_count:A(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,y=i?{name:b(i.name),exists:typeof i.exists=="boolean"?i.exists:void 0,error:b(i.error),status:b(i.status),current_task:b(i.current_task)??null,last_seen:b(i.last_seen),last_seen_ago_s:A(i.last_seen_ago_s),is_zombie:typeof i.is_zombie=="boolean"?i.is_zombie:void 0}:void 0,S=Jc(a.metrics_series),T={name:l,emoji:b(a.emoji),koreanName:b(a.koreanName)??b(a.korean_name),agent_name:b(a.agent_name),trace_id:b(a.trace_id),model:d,primary_model:b(a.primary_model),active_model:b(a.active_model),next_model_hint:b(a.next_model_hint)??null,status:m,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:A(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:A(a.proactive_idle_sec),proactive_cooldown_sec:A(a.proactive_cooldown_sec),last_heartbeat:b(a.last_heartbeat)??b(i==null?void 0:i.last_seen),generation:A(a.generation),turn_count:A(a.turn_count)??A(a.total_turns),keeper_age_s:A(a.keeper_age_s),last_turn_ago_s:A(a.last_turn_ago_s),last_handoff_ago_s:A(a.last_handoff_ago_s),last_compaction_ago_s:A(a.last_compaction_ago_s),last_proactive_ago_s:A(a.last_proactive_ago_s),context_ratio:p,context_tokens:A(a.context_tokens)??A(o==null?void 0:o.context_tokens),context_max:A(a.context_max)??A(o==null?void 0:o.context_max),context_source:b(a.context_source)??b(o==null?void 0:o.source),context:g,traits:_e(a.traits),interests:_e(a.interests),primaryValue:b(a.primaryValue)??b(a.primary_value),activityLevel:A(a.activityLevel)??A(a.activity_level),memory_recent_note:b(a.memory_recent_note)??null,conversation_tail_count:A(a.conversation_tail_count),k2k_count:A(a.k2k_count),handoff_count_total:A(a.handoff_count_total)??A(a.trace_history_count),compaction_count:A(a.compaction_count),last_compaction_saved_tokens:A(a.last_compaction_saved_tokens),diagnostic:Fi(a.diagnostic),skill_primary:b(a.skill_primary)??null,skill_secondary:c,skill_reason:b(a.skill_reason)??null,metrics_series:S.length>0?S:void 0,metrics_window:r,agent:y};return T.diagnostic=Fi(a.diagnostic)??Nc(T,(e==null?void 0:e.lodge)??null),T}).filter(a=>a!==null)}function Qc(t){return ut(t)?{...t,lodge:wc(t.lodge)??void 0}:null}function Yc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function Xc(t){if(!ut(t))return null;const e=A(t.iteration);if(e==null)return null;const n=A(t.metric_before)??0,a=A(t.metric_after)??n,i=ut(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:a,delta:A(t.delta)??a-n,changes:b(t.changes)??"",failed_attempts:b(t.failed_attempts)??"",next_suggestion:b(t.next_suggestion)??"",elapsed_ms:A(t.elapsed_ms)??0,cost_usd:A(t.cost_usd)??null,evidence:i?{worker_engine:(i.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:b(i.worker_model)??"",tool_call_count:A(i.tool_call_count)??0,tool_names:_e(i.tool_names)??[],session_id:b(i.session_id)??"",evidence_status:i.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function Zc(t){var o,r;if(!ut(t))return null;const e=b(t.loop_id);if(!e)return null;const n=A(t.baseline_metric)??0,a=Array.isArray(t.history)?t.history.map(Xc).filter(l=>l!==null):[],i=A(t.current_metric)??((o=a[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:b(t.profile)??"unknown",status:Yc(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:b(t.error_message)??b(t.error_reason)??null,stop_reason:b(t.stop_reason)??b(t.reason)??null,current_iteration:A(t.current_iteration)??((r=a[0])==null?void 0:r.iteration)??0,max_iterations:A(t.max_iterations)??0,baseline_metric:n,current_metric:i,target:b(t.target)??"",stagnation_streak:A(t.stagnation_streak)??0,stagnation_limit:A(t.stagnation_limit)??0,elapsed_seconds:A(t.elapsed_seconds)??0,updated_at:Us(t.updated_at)??null,stopped_at:Us(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:b(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:A(t.latest_tool_call_count)??0,latest_tool_names:_e(t.latest_tool_names)??[],session_id:b(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:a}}async function ee(t="full"){var a,i,o;const e=Date.now(),n=ua[t];if(!(n&&e-n.time<Bc)){Fs.value=!0;try{const r=await $l(t);ua[t]={data:r,time:e},xt.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(Jo).filter(p=>p!==null),$t.value=(Array.isArray((i=r.tasks)==null?void 0:i.tasks)?r.tasks.tasks:[]).map(Vo).filter(p=>p!==null),Sn.value=(Array.isArray((o=r.messages)==null?void 0:o.messages)?r.messages.messages:[]).map(Qo).filter(p=>p!==null);const l=Qc(r.status);ae.value=l,Gt.value=Vc(r.keepers,l),en.value=r.perpetual??null,jc.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{Fs.value=!1}}}async function td(){try{const t=await hl(),e=(Array.isArray(t.agents)?t.agents:[]).map(Jo).filter(i=>i!==null),n=xt.value,a=new Map(n.map(i=>[i.name,i]));xt.value=e.map(i=>{const o=a.get(i.name);return o?{...o,status:i.status,current_task:i.current_task}:i})}catch(t){console.error("Agents selective fetch error:",t)}}async function ed(){try{const t=await yl({includeDone:!0,includeCancelled:!0}),e=(Array.isArray(t.tasks)?t.tasks:[]).map(Vo).filter(i=>i!==null),n=$t.value,a=new Map(n.map(i=>[i.id,i]));$t.value=e.map(i=>{const o=a.get(i.id);return o?{...o,status:i.status,priority:i.priority??o.priority,assignee:i.assignee??o.assignee}:i})}catch(t){console.error("Tasks selective fetch error:",t)}}async function nd(){try{const t=Sn.value,e=t.reduce((l,p)=>Math.max(l,p.seq??0),0),n=await bl(e),a=(Array.isArray(n.messages)?n.messages:[]).map(Qo).filter(l=>l!==null);if(a.length===0)return;const i=new Set(t.map(l=>l.seq).filter(l=>l!=null)),o=new Set(t.filter(l=>l.seq==null).map(l=>`${l.timestamp}|${l.from}`)),r=a.filter(l=>{if(l.seq!=null)return!i.has(l.seq);const p=`${l.timestamp}|${l.from}`;return o.has(p)?!1:(o.add(p),!0)});if(r.length>0){const l=[...t,...r];Sn.value=l.length>500?l.slice(-500):l}}catch(t){console.error("Messages selective fetch error:",t)}}async function zt(){Cn.value=!0;try{const t=await zl(An.value,{excludeSystem:ue.value});Be.value=t.posts??[],Hs.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Cn.value=!1}}async function qt(){var t;Ks.value=!0;try{const e=Ht.value||((t=ae.value)==null?void 0:t.room)||"default";Ht.value||(Ht.value=e);const n=await ec(e);jo.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Ks.value=!1}}async function Tn(){Le.value=!0;try{const t=await yc();wn.value=Array.isArray(t)?t:[],Ko.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Le.value=!1}}async function je(){Pe.value=!0;try{const t=await kl(),e=Array.isArray(t.loops)?t.loops:[],n=new Map;for(const a of e){const i=Zc(a);i&&n.set(i.loop_id,i)}Fo.value=n,Ho.value=new Date().toISOString(),js.value=null,qs.value=n.size===0?"idle":"ready"}catch(t){console.error("MDAL fetch error:",t),qs.value="error",js.value=t instanceof Error?t.message:String(t)}finally{Pe.value=!1}}let Zn=null;function ad(t){Zn=t}let ta=null;function sd(t){ta=t}const pe={};function de(t,e,n=500){pe[t]&&clearTimeout(pe[t]),pe[t]=setTimeout(()=>{e(),delete pe[t]},n)}function id(){const t=Co.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(zs.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),zs.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&de("agents",td),Wc(e.type)&&(qe(),Xa||(Xa=setTimeout(()=>{ee(),ta==null||ta(),Xa=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&de("tasks",ed),e.type==="broadcast"&&de("messages",nd),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&de("dashboard",()=>{qe(),ee()}),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&de("board",zt),e.type.startsWith("decision_")&&de("council",()=>Zn==null?void 0:Zn()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&de("mdal",je,350)}});return()=>{t();for(const e of Object.keys(pe))clearTimeout(pe[e]),delete pe[e]}}let on=null;function od(){on||(on=setInterval(()=>{jt.value||qe(),ee()},1e4))}function rd(){on&&(clearInterval(on),on=null)}function C({title:t,class:e,children:n}){return s`
========
var Ur=Object.defineProperty;var Br=(t,e,n)=>e in t?Ur(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var xe=(t,e,n)=>Br(t,typeof e!="symbol"?e+"":e,n);import{e as Wr,_ as Gr,c as f,b as Ct,y as rt,d as Ha,A as xo,G as Jr}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const i of document.querySelectorAll('link[rel="modulepreload"]'))a(i);new MutationObserver(i=>{for(const o of i)if(o.type==="childList")for(const r of o.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(i){const o={};return i.integrity&&(o.integrity=i.integrity),i.referrerPolicy&&(o.referrerPolicy=i.referrerPolicy),i.crossOrigin==="use-credentials"?o.credentials="include":i.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function a(i){if(i.ep)return;i.ep=!0;const o=n(i);fetch(i.href,o)}})();var s=Wr.bind(Gr);const Vr=["command","overview","board","goals","agents","ops","trpg"],So={tab:"overview",params:{},postId:null},Qr={journal:"overview",mdal:"goals",tasks:"goals",execution:"overview",council:"board",activity:"overview"};function Di(t){return!!t&&Vr.includes(t)}function Ei(t){if(t)return Qr[t]??t}function Qn(t){try{return decodeURIComponent(t)}catch{return t}}function Ts(t){const e={};return t&&new URLSearchParams(t).forEach((a,i)=>{e[i]=a}),e}function Yr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Ao(t,e){if(t[0]==="chains"){const r={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(r.operation=Qn(t[2])),{tab:"command",params:r,postId:null}}const n=Ei(t[0]),a=Ei(e.tab),i=Di(n)?n:Di(a)?a:"overview";let o=null;return i==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?o=Qn(t[2]):t[0]==="post"&&t[1]&&(o=Qn(t[1]))),{tab:i,params:e,postId:o}}function la(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return So;const n=Qn(e);let a=n,i;if(n.startsWith("?"))a="",i=n.slice(1);else{const l=n.indexOf("?");l>=0&&(a=n.slice(0,l),i=n.slice(l+1))}!i&&a.includes("=")&&!a.includes("/")&&(i=a,a="");const o=Ts(i),r=Yr(a);return Ao(r,o)}function Xr(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...So,params:Ts(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const i=Ts(e.replace(/^\?/,""));return Ao(a,i)}function Co(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([i])=>i!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const nt=f(la(window.location.hash));window.addEventListener("hashchange",()=>{nt.value=la(window.location.hash)});function Rt(t,e){const n={tab:t,params:e??{},postId:null};window.location.hash=Co(n)}function Zr(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function tl(){if(window.location.hash&&window.location.hash!=="#"){nt.value=la(window.location.hash);return}const t=Xr(window.location.pathname,window.location.search);if(t){nt.value=t;const e=Co(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",nt.value=la(window.location.hash)}const Ii="masc_dashboard_sse_session_id",el=1e3,nl=15e3,Ft=f(!1),In=f(0),wo=f(null),ca=f([]);function al(){let t=sessionStorage.getItem(Ii);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Ii,t)),t}const sl=200;function il(t,e,n="system",a={}){const i={agent:t,text:e,timestamp:Date.now(),kind:n,...a};ca.value=[i,...ca.value].slice(0,sl)}function Ns(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Mi(t,e){const n=Ns(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function wt(t,e,n,a,i={}){il(t,e,n,{eventType:a,...i})}let Ot=null,Ee=null,Rs=0;function To(){Ee&&(clearTimeout(Ee),Ee=null)}function ol(){if(Ee)return;Rs++;const t=Math.min(Rs,5),e=Math.min(nl,el*Math.pow(2,t));Ee=setTimeout(()=>{Ee=null,No()},e)}function No(){To(),Ot&&(Ot.close(),Ot=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",al());const i=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(i);Ot=o,o.onopen=()=>{Ot===o&&(Rs=0,Ft.value=!0)},o.onerror=()=>{Ot===o&&(Ft.value=!1,o.close(),Ot=null,ol())},o.onmessage=r=>{try{const l=JSON.parse(r.data);In.value++,wo.value=l,rl(l)}catch{}}}function rl(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":wt(n,"Joined","system","agent_joined");break;case"agent_left":wt(n,"Left","system","agent_left");break;case"broadcast":wt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":wt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":wt(n,Mi("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Ns(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":wt(n,Mi("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Ns(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":wt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":wt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":wt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":wt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:wt(n,e,"system","unknown")}}function ll(){To(),Ot&&(Ot.close(),Ot=null),Ft.value=!1}function Ro(){return new URLSearchParams(window.location.search)}function Lo(){const t=Ro(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Po(){return{...Lo(),"Content-Type":"application/json"}}const cl=15e3,vi=3e4,dl=6e4,Oi=new Set([408,425,429,500,502,503,504]);class Mn extends Error{constructor(n){const a=n.method.toUpperCase(),i=n.timeout===!0,o=i?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);xe(this,"method");xe(this,"path");xe(this,"status");xe(this,"statusText");xe(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=i}}async function fi(t,e,n){const a=new AbortController,i=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Mn({method:r,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(i)}}function ul(){var e,n;const t=Ro();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function et(t){const e=await fi(t,{headers:Lo()},cl);if(!e.ok)throw new Mn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function pl(t){return new Promise(e=>setTimeout(e,t))}function ml(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function vl(t){if(t instanceof Mn)return t.timeout||typeof t.status=="number"&&Oi.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=ml(t.message);return e!==null&&Oi.has(e)}async function Ue(t,e,n=2){let a=0;for(;;)try{return await e()}catch(i){if(!vl(i)||a>=n)throw i;const o=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${o}ms`,i),await pl(o),a+=1}}async function Kt(t,e,n,a=vi){const i=await fi(t,{method:"POST",headers:{...Po(),...n??{}},body:JSON.stringify(e)},a);if(!i.ok)throw new Mn({method:"POST",path:t,status:i.status,statusText:i.statusText});return i.json()}async function fl(t,e,n,a=vi){const i=await fi(t,{method:"POST",headers:{...Po(),...n??{}},body:JSON.stringify(e)},a);if(!i.ok)throw new Mn({method:"POST",path:t,status:i.status,statusText:i.statusText});return i.text()}function gl(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function _l(t){var e,n,a,i,o,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const p=((i=(a=t.result.content)==null?void 0:a[0])==null?void 0:i.text)??"MCP tool call failed";throw new Error(p)}return((l=(r=(o=t.result)==null?void 0:o.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function bt(t,e){const n=await fl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},dl),a=gl(n);return _l(a)}function $l(t="compact"){return et(`/api/v1/dashboard?mode=${t}`)}function hl(){return et("/api/v1/agents?limit=100")}function yl(t){const e=new URLSearchParams({limit:"200"});return e.set("include_done","true"),e.set("include_cancelled","true"),et(`/api/v1/tasks?${e}`)}function bl(t){const e=new URLSearchParams({limit:"50"});return t!=null&&t>0&&e.set("since_seq",String(t)),et(`/api/v1/messages?${e}`)}function kl(t={}){return Ue("fetchMdalLoops",async()=>{const e=new URLSearchParams;t.limit!=null&&e.set("limit",String(t.limit)),t.historyLimit!=null&&e.set("history_limit",String(t.historyLimit)),t.status&&e.set("status",t.status);const n=e.toString();return et(`/api/v1/mdal/loops${n?`?${n}`:""}`)})}function xl(){return et("/api/v1/operator")}function Sl(){return et("/api/v1/command-plane")}function Al(){return et("/api/v1/command-plane/summary")}function Cl(){return et("/api/v1/chains/summary")}function wl(t){return et(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Tl(){return et("/api/v1/command-plane/help")}function Nl(t){const e=new URLSearchParams;t&&e.set("run_id",t);const n=e.toString();return et(`/api/v1/command-plane/swarm${n?`?${n}`:""}`)}function Rl(t,e){return Kt(t,e)}function Ll(t){switch(t.action_type){case"keeper_msg":case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return vi}}function On(t){return Kt("/api/v1/operator/action",t,void 0,Ll(t))}function Pl(t,e){return Kt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const Dl=new Set(["lodge-system","team-session"]);function ze(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function El(t){return Dl.has(t.trim().toLowerCase())}function Il(t){return t.filter(e=>!El(e.author))}function Ml(t){var i;const e=t.trim(),a=((i=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:i.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function Do(t){if(!O(t))return null;const e=$(t.id,"").trim(),n=$(t.author,"").trim(),a=$(t.content,"").trim();if(!e||!n)return null;const i=q(t.score,0),o=q(t.votes_up,0),r=q(t.votes_down,0),l=q(t.votes,i||o-r),p=q(t.comment_count,q(t.reply_count,0)),_=(()=>{const y=t.flair;if(typeof y=="string"&&y.trim())return y.trim();if(O(y)){const T=$(y.name,"").trim();if(T)return T}return $(t.flair_name,"").trim()||void 0})(),m=$(t.created_at_iso,"").trim()||ze(t.created_at),d=$(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?ze(t.updated_at):m),g=$(t.title,"").trim()||Ml(a);return{id:e,author:n,title:g,content:a,tags:[],votes:l,vote_balance:i,comment_count:p,created_at:m,updated_at:d,flair:_,hearth_count:q(t.hearth_count,0)}}function Ol(t){if(!O(t))return null;const e=$(t.id,"").trim(),n=$(t.post_id,"").trim(),a=$(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:$(t.content,""),created_at:ze(t.created_at)}}async function zl(t,e){return Ue("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const a=n.toString(),i=await et(`/api/v1/board${a?`?${a}`:""}`),o=Array.isArray(i.posts)?i.posts.map(Do).filter(l=>l!==null):[];return{posts:e!=null&&e.excludeSystem?Il(o):o}})}async function ql(t){return Ue("fetchBoardPost",async()=>{const e=await et(`/api/v1/board/${t}?format=flat`),n=O(e.post)?e.post:e,a=Do(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},o=(Array.isArray(e.comments)?e.comments:[]).map(Ol).filter(r=>r!==null);return{...a,comments:o}})}function Eo(t,e){return Kt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:ul()})}function jl(t,e,n){return Kt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Fl(t){const e=$(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function lt(...t){for(const e of t){const n=$(e,"");if(n.trim())return n.trim()}return""}function zi(t){const e=Fl(lt(t.outcome,t.result,t.result_code));if(!e)return;const n=lt(t.reason,t.reason_code,t.description,t.detail),a=lt(t.summary,t.summary_ko,t.summary_en,t.note),i=lt(t.details,t.details_text,t.text,t.note),o=lt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=lt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=lt(t.raw_reason,t.raw_reason_code,t.error_message),p=(()=>{const d=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof d=="string"?[d]:Array.isArray(d)?d.map(c=>{if(typeof c=="string")return c.trim();if(O(c)){const g=$(c.summary,"").trim();if(g)return g;const y=$(c.text,"").trim();if(y)return y;const S=$(c.type,"").trim();return S||$(c.event_id,"").trim()}return""}).filter(c=>c.length>0):[]})(),_=(()=>{const d=q(t.turn,Number.NaN);if(Number.isFinite(d))return d;const c=q(t.turn_number,Number.NaN);if(Number.isFinite(c))return c;const g=q(t.current_turn,Number.NaN);if(Number.isFinite(g))return g;const y=q(t.round,Number.NaN);return Number.isFinite(y)?y:void 0})(),m=lt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:i||void 0,winner:o||void 0,winner_actor_id:r||void 0,evidence:p.length>0?p:void 0,raw_reason:l||void 0,turn:_,phase:m||void 0}}function Kl(t,e){const n=O(t.state)?t.state:{};if($(n.status,"active").toLowerCase()!=="ended")return;const i=[...e].reverse().find(r=>O(r)?$(r.type,"")==="session.outcome":!1),o=O(n.session_outcome)?n.session_outcome:{};if(O(o)&&Object.keys(o).length>0){const r=zi(o);if(r)return r}if(O(i))return zi(O(i.payload)?i.payload:{})}function O(t){return typeof t=="object"&&t!==null}function $(t,e=""){return typeof t=="string"?t:e}function q(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Hl(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Ls(t,e=!1){return typeof t=="boolean"?t:e}function Qe(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(O(e)){const n=$(e.name,"").trim(),a=$(e.id,"").trim(),i=$(e.skill,"").trim();return n||a||i}return""}).filter(e=>e.length>0):[]}function Ul(t){const e={};if(!O(t)&&!Array.isArray(t))return e;if(O(t))return Object.entries(t).forEach(([n,a])=>{const i=n.trim(),o=$(a,"").trim();!i||!o||(e[i]=o)}),e;for(const n of t){if(!O(n))continue;const a=lt(n.to,n.target,n.actor_id,n.name,n.id),i=lt(n.relationship,n.relation,n.type,n.kind);!a||!i||(e[a]=i)}return e}function Bl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function xt(t,e,n,a=0){const i=t[e];if(typeof i=="number"&&Number.isFinite(i))return i;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return a}const Wl=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Gl(t){const e=O(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,i])=>{const o=a.trim();o&&(Wl.has(o.toLowerCase())||typeof i=="number"&&Number.isFinite(i)&&(n[o]=i))}),n}function Jl(t,e){if(t!=="dice.rolled")return;const n=q(e.raw_d20,0),a=q(e.total,0),i=q(e.bonus,0),o=$(e.action,"roll"),r=q(e.dc,0);return{notation:r>0?`${o} (DC ${r})`:o,rolls:n>0?[n]:[],total:a,modifier:i}}function Vl(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Ql(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Yl(t,e,n,a){const i=n||e||$(a.actor_id,"")||$(a.actor_name,"");switch(t){case"turn.action.proposed":{const o=$(a.proposed_action,$(a.reply,""));return o?`${i||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=$(a.reply,$(a.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return $(a.reply,$(a.content,$(a.text,"Narration")));case"dice.rolled":{const o=$(a.action,"roll"),r=q(a.total,0),l=q(a.dc,0),p=$(a.label,""),_=i||"actor",m=l>0?` vs DC ${l}`:"",d=p?` (${p})`:"";return`${_} ${o}: ${r}${m}${d}`}case"turn.started":return`Turn ${q(a.turn,1)} started`;case"phase.changed":return`Phase: ${$(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${$(a.name,O(a.actor)?$(a.actor.name,i||"unknown"):i||"unknown")}`;case"actor.claimed":return`${$(a.keeper_name,$(a.keeper,"keeper"))} claimed ${i||"actor"}`;case"actor.released":return`${$(a.keeper_name,$(a.keeper,"keeper"))} released ${i||"actor"}`;case"join.window.opened":return`Join window opened (turn ${q(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${q(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${i||$(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${i||$(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${$(a.reason_code,"unknown")}`;case"memory.signal":{const o=O(a.entity_refs)?a.entity_refs:{},r=$(o.requested_tier,""),l=$(o.effective_tier,""),p=Ls(o.guardrail_applied,!1),_=$(a.summary_en,$(a.summary_ko,"Memory signal"));if(!r&&!l)return _;const m=r&&l?`${r}->${l}`:l||r;return`${_} [${m}${p?" (guardrail)":""}]`}case"world.event":{if($(a.event_type,"")==="canon.check"){const r=$(a.status,"unknown"),l=$(a.contract_id,"n/a");return`Canon ${r}: ${l}`}return $(a.description,$(a.summary,"World event"))}case"combat.attack":return $(a.summary,$(a.result,"Attack resolved"));case"combat.defense":return $(a.summary,$(a.result,"Defense resolved"));case"session.outcome":return $(a.summary,$(a.outcome,"Session ended"));default:{const o=Vl(a);return o?`${t}: ${o}`:t}}}function Xl(t,e){const n=O(t)?t:{},a=$(n.type,"event"),i=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=$(n.actor_name,"").trim()||e[i]||$(O(n.payload)?n.payload.actor_name:"",""),r=O(n.payload)?n.payload:{},l=$(n.ts,$(n.timestamp,new Date().toISOString())),p=$(n.phase,$(r.phase,"")),_=$(n.category,"");return{type:a,actor:o||i||$(r.actor_name,""),actor_id:i||$(r.actor_id,""),actor_name:o,seq:n.seq,room_id:$(n.room_id,""),phase:p||void 0,category:_||Ql(a),visibility:$(n.visibility,$(r.visibility,"public")),event_id:$(n.event_id,""),content:Yl(a,i,o,r),dice_roll:Jl(a,r),timestamp:l}}function Zl(t,e,n){var mt,vt;const a=$(t.room_id,"")||n||"default",i=O(t.state)?t.state:{},o=O(i.party)?i.party:{},r=O(i.actor_control)?i.actor_control:{},l=O(i.join_gate)?i.join_gate:{},p=O(i.contribution_ledger)?i.contribution_ledger:{},_=Object.entries(o).map(([B,M])=>{const k=O(M)?M:{},Dt=xt(k,"max_hp",void 0,10),Vt=xt(k,"hp",void 0,Dt),oe=xt(k,"max_mp",void 0,0),re=xt(k,"mp",void 0,0),E=xt(k,"level",void 0,1),Et=xt(k,"xp",void 0,0),le=Ls(k.alive,Vt>0),Je=r[B],Ve=typeof Je=="string"?Je:void 0,v=Bl(k.role,B,Ve),L=Hl(k.generation),j=lt(k.joined_at,k.joinedAt,k.started_at,k.startedAt),at=lt(k.claimed_at,k.claimedAt,k.assigned_at,k.assignedAt,k.assigned_time),z=lt(k.last_seen,k.lastSeen,k.last_seen_at,k.lastSeenAt,k.last_active,k.lastActive),ft=lt(k.scene,k.current_scene,k.currentScene,k.world_scene,k.scene_name,k.sceneName),Q=lt(k.location,k.current_location,k.currentLocation,k.position,k.zone,k.area);return{id:B,name:$(k.name,B),role:v,keeper:Ve,archetype:$(k.archetype,""),persona:$(k.persona,""),portrait:$(k.portrait,"")||void 0,background:$(k.background,"")||void 0,traits:Qe(k.traits),skills:Qe(k.skills),stats_raw:Gl(k),status:le?"active":"dead",generation:L,joined_at:j||void 0,claimed_at:at||void 0,last_seen:z||void 0,scene:ft||void 0,location:Q||void 0,inventory:Qe(k.inventory),notes:Qe(k.notes),relationships:Ul(k.relationships),stats:{hp:Vt,max_hp:Dt,mp:re,max_mp:oe,level:E,xp:Et,strength:xt(k,"strength","str",10),dexterity:xt(k,"dexterity","dex",10),constitution:xt(k,"constitution","con",10),intelligence:xt(k,"intelligence","int",10),wisdom:xt(k,"wisdom","wis",10),charisma:xt(k,"charisma","cha",10)}}}),m=_.filter(B=>B.status!=="dead"),d=Kl(t,e),c={phase_open:Ls(l.phase_open,!0),min_points:q(l.min_points,3),window:$(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},g=Object.entries(p).map(([B,M])=>{const k=O(M)?M:{};return{actor_id:B,score:q(k.score,0),last_reason:$(k.last_reason,"")||null,reasons:Qe(k.reasons)}}),y=_.reduce((B,M)=>(B[M.id]=M.name,B),{}),S=e.map(B=>Xl(B,y)),T=q(i.turn,1),P=$(i.phase,"round"),K=$(i.map,""),I=O(i.world)?i.world:{},N=K||$(I.ascii_map,$(I.map,"")),R=S.filter((B,M)=>{const k=e[M];if(!O(k))return!1;const Dt=O(k.payload)?k.payload:{};return q(Dt.turn,-1)===T}),X=(R.length>0?R:S).slice(-12),H=$(i.status,"active");return{session:{id:a,room:a,status:H==="ended"?"ended":H==="paused"?"paused":"active",round:T,actors:m,created_at:((mt=S[0])==null?void 0:mt.timestamp)??new Date().toISOString()},current_round:{round_number:T,phase:P,events:X,timestamp:((vt=S[S.length-1])==null?void 0:vt.timestamp)??new Date().toISOString()},map:N||void 0,join_gate:c,contribution_ledger:g,outcome:d,party:m,story_log:S,history:[]}}async function tc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await et(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function ec(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([et(`/api/v1/trpg/state${e}`),tc(t)]);return Zl(n,a,t)}function nc(t){return Kt("/api/v1/trpg/rounds/run",{room_id:t})}function ac(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function sc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Kt("/api/v1/trpg/dice/roll",e)}function ic(t,e){const n=ac();return Kt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function oc(t,e){var i;const n=(i=e.idempotencyKey)==null?void 0:i.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),Kt("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function rc(t,e,n){return Kt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function lc(t,e,n){const a=await bt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function cc(t){const e=await bt("trpg.mid_join.request",t);return JSON.parse(e)}async function Io(t,e){await bt("masc_broadcast",{agent_name:t,message:e})}async function dc(t,e,n=1){await bt("masc_add_task",{title:t,description:e,priority:n})}async function uc(t){return bt("masc_join",{agent_name:t})}async function Mo(t){await bt("masc_leave",{agent_name:t})}async function pc(t){await bt("masc_heartbeat",{agent_name:t})}async function mc(t=40){return(await bt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function vc(t,e=20){return bt("masc_task_history",{task_id:t,limit:e})}async function fc(){return Ue("fetchDebates",async()=>{const t=await et("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!O(e))return null;const n=$(e.id,"").trim(),a=$(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:$(e.status,"open"),argument_count:q(e.argument_count,0),created_at:ze(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function gc(){return Ue("fetchCouncilSessions",async()=>{const t=await et("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!O(e))return null;const n=$(e.id,"").trim(),a=$(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:$(e.initiator,"system"),votes:q(e.votes,0),quorum:q(e.quorum,0),state:$(e.state,"open"),created_at:ze(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function _c(t){const e=await bt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function $c(t){return Ue("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await et(`/api/v1/council/debates/${e}/summary`);if(!O(n))return null;const a=$(n.id,"").trim();return a?{id:a,topic:$(n.topic,""),status:$(n.status,"open"),support_count:q(n.support_count,0),oppose_count:q(n.oppose_count,0),neutral_count:q(n.neutral_count,0),total_arguments:q(n.total_arguments,0),created_at:ze(n.created_at_iso??n.created_at),summary_text:$(n.summary_text,"")}:null})}function hc(t,e,n){return bt("masc_keeper_msg",{name:t,message:e})}async function yc(){try{const t=await bt("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const sn=f(""),Bt=f({}),dt=f({}),Ps=f({}),Ds=f({}),Es=f({}),Is=f({}),Wt=f({});function ot(t,e,n){t.value={...t.value,[e]:n}}function Gt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function U(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function Nt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Re(t){return typeof t=="boolean"?t:void 0}function Ms(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function Os(t){return Array.isArray(t)?t.map(e=>U(e)).filter(e=>!!e):[]}function bc(t){var n;const e=(n=U(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function kc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Ya(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!Gt(a))continue;const i=U(a.name);if(!i)continue;const o=U(a[e]);e==="summary"?n.push({name:i,summary:o}):n.push({name:i,reason:o})}return n}function xc(t){if(!Gt(t))return null;const e=U(t.name);return e?{name:e,trigger:U(t.trigger),outcome:U(t.outcome),summary:U(t.summary),reason:U(t.reason)}:null}function Sc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Ac(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Oo(t,e,n){return U(t)??Ac(e,n)}function zo(t,e){return typeof t=="boolean"?t:e==="recover"}function da(t){if(!Gt(t))return null;const e=U(t.health_state),n=U(t.next_action_path),a=U(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:U(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:Ms(t.last_reply_at),last_reply_preview:U(t.last_reply_preview)??null,last_error:U(t.last_error)??null,next_eligible_at_s:Nt(t.next_eligible_at_s)??null,recoverable:zo(t.recoverable,n),summary:Oo(t.summary,e,U(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function gi(t){return Gt(t)?{hour:Nt(t.hour),checked:Nt(t.checked)??0,acted:Nt(t.acted)??0,acted_names:Os(t.acted_names),activity_report:U(t.activity_report),quiet_hours_overridden:Re(t.quiet_hours_overridden),skipped_reason:U(t.skipped_reason),acted_rows:Ya(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:Ya(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:Ya(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(xc).filter(e=>e!==null):[]}:null}function Cc(t){return Gt(t)?{enabled:Re(t.enabled)??!1,interval_s:Nt(t.interval_s)??0,quiet_start:Nt(t.quiet_start),quiet_end:Nt(t.quiet_end),quiet_active:Re(t.quiet_active),use_planner:Re(t.use_planner),delegate_llm:Re(t.delegate_llm),agent_count:Nt(t.agent_count),agents:Os(t.agents),last_tick_ago_s:Nt(t.last_tick_ago_s)??null,last_tick_ago:U(t.last_tick_ago),total_ticks:Nt(t.total_ticks),total_checkins:Nt(t.total_checkins),last_skip_reason:U(t.last_skip_reason)??null,last_tick_result:gi(t.last_tick_result),active_self_heartbeats:Os(t.active_self_heartbeats)}:null}function wc(t){return Gt(t)?{status:t.status,diagnostic:da(t.diagnostic)}:null}function Tc(t){return Gt(t)?{recovered:Re(t.recovered)??!1,skipped_reason:U(t.skipped_reason)??null,before:da(t.before),after:da(t.after),down:t.down,up:t.up}:null}function Nc(t,e){var K,I;if(!(t!=null&&t.name))return null;const n=U((K=t.agent)==null?void 0:K.status)??U(t.status)??"unknown",a=U((I=t.agent)==null?void 0:I.error)??null,i=t.presence_keepalive??!0,o=t.keepalive_running??!1,r=t.turn_count??0,l=t.last_turn_ago_s??null,p=t.proactive_enabled??!1,_=t.proactive_cooldown_sec??0,m=t.last_proactive_ago_s??null,d=p&&m!=null?Math.max(0,_-m):null,c=r<=0||l==null?"never":l>900?"stale":"fresh",g=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,y=a??(i&&!o?"keeper keepalive is not running":null),S=n==="offline"||n==="inactive"?"offline":y?"degraded":c==="stale"?"stale":c==="never"?"idle":"healthy",T=y?Sc(y):e!=null&&e.quiet_active&&c!=="fresh"?"quiet_hours":i&&!o?"disabled":r<=0?"never_started":d!=null&&d>0?"min_gap":c==="fresh"||c==="stale"?"no_recent_activity":"unknown",P=S==="offline"||S==="degraded"||S==="stale"?"recover":T==="quiet_hours"?"manual_lodge_poke":T==="unknown"?"probe":"direct_message";return{health_state:S,quiet_reason:T,next_action_path:P,last_reply_status:c,last_reply_at:g,last_reply_preview:null,last_error:y,next_eligible_at_s:d!=null&&d>0?d:null,recoverable:zo(void 0,P),summary:Oo(void 0,S,T),keepalive_running:o}}function Rc(t,e){if(!Gt(t))return null;const n=bc(t.role),a=U(t.content)??U(t.preview);if(!a)return null;const i=Ms(t.ts_unix)??Ms(t.timestamp);return{id:`${n}-${i??"entry"}-${e}`,role:n,label:kc(n),text:a,timestamp:i,delivery:"history"}}function Lc(t,e,n){const a=Gt(n)?n:null,i=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((o,r)=>Rc(o,r)).filter(o=>o!==null):[];return{name:t,diagnostic:da(a==null?void 0:a.diagnostic),history:i,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function qi(t,e){const n=dt.value[t]??[];dt.value={...dt.value,[t]:[...n,e].slice(-50)}}function Pc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Dc(t,e){const a=(dt.value[t]??[]).filter(i=>i.delivery!=="history"&&!e.some(o=>Pc(i,o)));dt.value={...dt.value,[t]:[...e,...a].slice(-50)}}function Ua(t,e){Bt.value={...Bt.value,[t]:e},Dc(t,e.history)}function ji(t,e){const n=Bt.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Ua(t,{...n,diagnostic:{...a,...e}})}async function _i(){qe();try{await ne()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Yn(t){sn.value=t.trim()}async function qo(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Bt.value[n])return Bt.value[n];ot(Ps,n,!0),ot(Wt,n,null);try{const a=await bt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let i=null;try{i=JSON.parse(a)}catch{i=null}const o=Lc(n,a,i);return Ua(n,o),o}catch(a){const i=a instanceof Error?a.message:`Failed to inspect ${n}`;return ot(Wt,n,i),null}finally{ot(Ps,n,!1)}}async function Ec(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const i=`local-${Date.now()}`;qi(n,{id:i,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),ot(Ds,n,!0),ot(Wt,n,null);try{const o=await hc(n,a);dt.value={...dt.value,[n]:(dt.value[n]??[]).map(r=>r.id===i?{...r,delivery:"delivered"}:r)},qi(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),ji(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await _i()}catch(o){const r=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw dt.value={...dt.value,[n]:(dt.value[n]??[]).map(l=>l.id===i?{...l,delivery:"error",error:r}:l)},ji(n,{last_reply_status:"error",last_error:r}),ot(Wt,n,r),o}finally{ot(Ds,n,!1)}}async function Ic(t,e){const n=t.trim();if(!n)return null;ot(Es,n,!0),ot(Wt,n,null);try{const a=await On({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),i=wc(a.result),o=(i==null?void 0:i.diagnostic)??null;if(o){const r=Bt.value[n];Ua(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??dt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await _i(),o}catch(a){const i=a instanceof Error?a.message:`Failed to probe ${n}`;throw ot(Wt,n,i),a}finally{ot(Es,n,!1)}}async function Mc(t,e){const n=t.trim();if(!n)return null;ot(Is,n,!0),ot(Wt,n,null);try{const a=await On({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),i=Tc(a.result),o=(i==null?void 0:i.after)??null;if(o){const r=Bt.value[n];Ua(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??dt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await _i(),o}catch(a){const i=a instanceof Error?a.message:`Failed to recover ${n}`;throw ot(Wt,n,i),a}finally{ot(Is,n,!1)}}function ce(t){return(t??"").trim().toLowerCase()}function gt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Xn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function jn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ye(t){return t.last_heartbeat??jn(t.last_turn_ago_s)??jn(t.last_proactive_ago_s)??jn(t.last_handoff_ago_s)??jn(t.last_compaction_ago_s)}function Oc(t){const e=t.title.trim();return e||Xn(t.content)}function zc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function qc(t,e,n,a,i={}){var I;const o=ce(t),r=e.filter(N=>ce(N.assignee)===o&&(N.status==="claimed"||N.status==="in_progress")).length,l=n.filter(N=>ce(N.from)===o).sort((N,R)=>gt(R.timestamp)-gt(N.timestamp))[0],p=a.filter(N=>ce(N.agent)===o||ce(N.author)===o).sort((N,R)=>gt(R.timestamp)-gt(N.timestamp))[0],_=(i.boardPosts??[]).filter(N=>ce(N.author)===o).sort((N,R)=>gt(R.updated_at||R.created_at)-gt(N.updated_at||N.created_at))[0],m=(i.keepers??[]).filter(N=>ce(N.name)===o&&Ye(N)!==null).sort((N,R)=>gt(Ye(R)??0)-gt(Ye(N)??0))[0],d=l?gt(l.timestamp):0,c=p?gt(p.timestamp):0,g=_?gt(_.updated_at||_.created_at):0,y=m?gt(Ye(m)??0):0,S=i.lastSeen?gt(i.lastSeen):0,T=((I=i.currentTask)==null?void 0:I.trim())||(r>0?`${r} claimed tasks`:null);if(d===0&&c===0&&g===0&&y===0&&S===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:T};const K=[l?{timestamp:l.timestamp,ts:d,text:Xn(l.content)}:null,_?{timestamp:_.updated_at||_.created_at,ts:g,text:`Post: ${Xn(Oc(_))}`}:null,m?{timestamp:Ye(m),ts:y,text:zc(m)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:c,text:Xn(p.text)}:null].filter(N=>N!==null).sort((N,R)=>R.ts-N.ts)[0];return K&&K.ts>=S?{activeAssignedCount:r,lastActivityAt:K.timestamp,lastActivityText:K.text}:{activeAssignedCount:r,lastActivityAt:i.lastSeen??null,lastActivityText:T??"Presence heartbeat"}}const At=f([]),yt=f([]),Sn=f([]),Jt=f([]),se=f(null),en=f(null),zs=f(new Map),Be=f([]),An=f("hot"),ue=f(!0),jo=f(null),Ut=f(""),Cn=f([]),Le=f(!1),Fo=f(new Map),qs=f("unknown"),js=f(null),Fs=f(!1),wn=f(!1),Ks=f(!1),Pe=f(!1),jc=f(null),Hs=f(null),Ko=f(null),Ho=f(null),Fc=Ct(()=>At.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle")),Uo=Ct(()=>{const t=yt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Ba=Ct(()=>{const t=new Map,e=yt.value,n=Sn.value,a=ca.value,i=Be.value,o=Jt.value;for(const r of At.value)t.set(r.name.trim().toLowerCase(),qc(r.name,e,n,a,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:i,keepers:o}));return t});function Kc(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const i=a.context_ratio;return i>.85?"handoff-imminent":i>.7?"preparing":i>.5?"compacting":"active"}const Bo=Ct(()=>{const t=new Map;for(const e of Jt.value)t.set(e.name,Kc(e));return t}),Hc=12e4;function Uc(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const i=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof i=="number"?Date.now()-i*1e3:null}const Wo=Ct(()=>{const t=Date.now(),e=new Set,n=zs.value;for(const a of Jt.value){const i=Uc(a,n);i!=null&&t-i>Hc&&e.add(a.name)}return e}),ua={},Bc=5e3;let Xa=null;function Wc(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function qe(){delete ua.compact,delete ua.full}function ut(t){return typeof t=="object"&&t!==null}function b(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function A(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function _e(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Us(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Go(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Gc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Jo(t){if(!ut(t))return null;const e=b(t.name);return e?{name:e,status:Go(t.status),current_task:b(t.current_task)??null,last_seen:b(t.last_seen),emoji:b(t.emoji),koreanName:b(t.koreanName)??b(t.korean_name),model:b(t.model),traits:_e(t.traits),interests:_e(t.interests),activityLevel:A(t.activityLevel)??A(t.activity_level),primaryValue:b(t.primaryValue)??b(t.primary_value)}:null}function Vo(t){if(!ut(t))return null;const e=b(t.id),n=b(t.title);return!e||!n?null:{id:e,title:n,status:Gc(t.status),priority:A(t.priority),assignee:b(t.assignee),description:b(t.description),created_at:b(t.created_at),updated_at:b(t.updated_at)}}function Qo(t){if(!ut(t))return null;const e=b(t.from)??b(t.from_agent)??"system",n=b(t.content)??"",a=b(t.timestamp)??new Date().toISOString();return{id:b(t.id),seq:A(t.seq),from:e,content:n,timestamp:a,type:b(t.type)}}function Jc(t){return Array.isArray(t)?t.map(e=>{if(!ut(e))return null;const n=A(e.ts_unix);if(n==null)return null;const a=ut(e.handoff)?e.handoff:null;return{ts:n,context_ratio:A(e.context_ratio)??0,context_tokens:A(e.context_tokens)??0,context_max:A(e.context_max)??0,latency_ms:A(e.latency_ms)??0,generation:A(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:A(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:A(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?A(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function Fi(t){if(!ut(t))return null;const e=b(t.health_state),n=b(t.next_action_path),a=b(t.last_reply_status);if(!e||!n||!a)return null;const i=b(t.quiet_reason)??null,o=b(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":i==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":i==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":i==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:i,next_action_path:n,last_reply_status:a,last_reply_at:Us(t.last_reply_at)??b(t.last_reply_at)??null,last_reply_preview:b(t.last_reply_preview)??null,last_error:b(t.last_error)??null,next_eligible_at_s:A(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Vc(t,e){return(Array.isArray(t)?t:ut(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!ut(a))return null;const i=ut(a.agent)?a.agent:null,o=ut(a.context)?a.context:null,r=ut(a.metrics_window)?a.metrics_window:void 0,l=b(a.name);if(!l)return null;const p=A(a.context_ratio)??A(o==null?void 0:o.context_ratio),_=b(a.status)??b(i==null?void 0:i.status)??"offline",m=Go(_),d=b(a.model)??b(a.active_model)??b(a.primary_model),c=_e(a.skill_secondary),g=o?{source:b(o.source),context_ratio:A(o.context_ratio),context_tokens:A(o.context_tokens),context_max:A(o.context_max),message_count:A(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,y=i?{name:b(i.name),exists:typeof i.exists=="boolean"?i.exists:void 0,error:b(i.error),status:b(i.status),current_task:b(i.current_task)??null,last_seen:b(i.last_seen),last_seen_ago_s:A(i.last_seen_ago_s),is_zombie:typeof i.is_zombie=="boolean"?i.is_zombie:void 0}:void 0,S=Jc(a.metrics_series),T={name:l,emoji:b(a.emoji),koreanName:b(a.koreanName)??b(a.korean_name),agent_name:b(a.agent_name),trace_id:b(a.trace_id),model:d,primary_model:b(a.primary_model),active_model:b(a.active_model),next_model_hint:b(a.next_model_hint)??null,status:m,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:A(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:A(a.proactive_idle_sec),proactive_cooldown_sec:A(a.proactive_cooldown_sec),last_heartbeat:b(a.last_heartbeat)??b(i==null?void 0:i.last_seen),generation:A(a.generation),turn_count:A(a.turn_count)??A(a.total_turns),keeper_age_s:A(a.keeper_age_s),last_turn_ago_s:A(a.last_turn_ago_s),last_handoff_ago_s:A(a.last_handoff_ago_s),last_compaction_ago_s:A(a.last_compaction_ago_s),last_proactive_ago_s:A(a.last_proactive_ago_s),context_ratio:p,context_tokens:A(a.context_tokens)??A(o==null?void 0:o.context_tokens),context_max:A(a.context_max)??A(o==null?void 0:o.context_max),context_source:b(a.context_source)??b(o==null?void 0:o.source),context:g,traits:_e(a.traits),interests:_e(a.interests),primaryValue:b(a.primaryValue)??b(a.primary_value),activityLevel:A(a.activityLevel)??A(a.activity_level),memory_recent_note:b(a.memory_recent_note)??null,conversation_tail_count:A(a.conversation_tail_count),k2k_count:A(a.k2k_count),handoff_count_total:A(a.handoff_count_total)??A(a.trace_history_count),compaction_count:A(a.compaction_count),last_compaction_saved_tokens:A(a.last_compaction_saved_tokens),diagnostic:Fi(a.diagnostic),skill_primary:b(a.skill_primary)??null,skill_secondary:c,skill_reason:b(a.skill_reason)??null,metrics_series:S.length>0?S:void 0,metrics_window:r,agent:y};return T.diagnostic=Fi(a.diagnostic)??Nc(T,(e==null?void 0:e.lodge)??null),T}).filter(a=>a!==null)}function Qc(t){return ut(t)?{...t,lodge:Cc(t.lodge)??void 0}:null}function Yc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function Xc(t){if(!ut(t))return null;const e=A(t.iteration);if(e==null)return null;const n=A(t.metric_before)??0,a=A(t.metric_after)??n,i=ut(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:a,delta:A(t.delta)??a-n,changes:b(t.changes)??"",failed_attempts:b(t.failed_attempts)??"",next_suggestion:b(t.next_suggestion)??"",elapsed_ms:A(t.elapsed_ms)??0,cost_usd:A(t.cost_usd)??null,evidence:i?{worker_engine:(i.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:b(i.worker_model)??"",tool_call_count:A(i.tool_call_count)??0,tool_names:_e(i.tool_names)??[],session_id:b(i.session_id)??"",evidence_status:i.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function Zc(t){var o,r;if(!ut(t))return null;const e=b(t.loop_id);if(!e)return null;const n=A(t.baseline_metric)??0,a=Array.isArray(t.history)?t.history.map(Xc).filter(l=>l!==null):[],i=A(t.current_metric)??((o=a[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:b(t.profile)??"unknown",status:Yc(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:b(t.error_message)??b(t.error_reason)??null,stop_reason:b(t.stop_reason)??b(t.reason)??null,current_iteration:A(t.current_iteration)??((r=a[0])==null?void 0:r.iteration)??0,max_iterations:A(t.max_iterations)??0,baseline_metric:n,current_metric:i,target:b(t.target)??"",stagnation_streak:A(t.stagnation_streak)??0,stagnation_limit:A(t.stagnation_limit)??0,elapsed_seconds:A(t.elapsed_seconds)??0,updated_at:Us(t.updated_at)??null,stopped_at:Us(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:b(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:A(t.latest_tool_call_count)??0,latest_tool_names:_e(t.latest_tool_names)??[],session_id:b(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:a}}async function ne(t="full"){var a,i,o;const e=Date.now(),n=ua[t];if(!(n&&e-n.time<Bc)){Fs.value=!0;try{const r=await $l(t);ua[t]={data:r,time:e},At.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(Jo).filter(p=>p!==null),yt.value=(Array.isArray((i=r.tasks)==null?void 0:i.tasks)?r.tasks.tasks:[]).map(Vo).filter(p=>p!==null),Sn.value=(Array.isArray((o=r.messages)==null?void 0:o.messages)?r.messages.messages:[]).map(Qo).filter(p=>p!==null);const l=Qc(r.status);se.value=l,Jt.value=Vc(r.keepers,l),en.value=r.perpetual??null,jc.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{Fs.value=!1}}}async function td(){try{const t=await hl(),e=(Array.isArray(t.agents)?t.agents:[]).map(Jo).filter(i=>i!==null),n=At.value,a=new Map(n.map(i=>[i.name,i]));At.value=e.map(i=>{const o=a.get(i.name);return o?{...o,status:i.status,current_task:i.current_task}:i})}catch(t){console.error("Agents selective fetch error:",t)}}async function ed(){try{const t=await yl({includeDone:!0,includeCancelled:!0}),e=(Array.isArray(t.tasks)?t.tasks:[]).map(Vo).filter(i=>i!==null),n=yt.value,a=new Map(n.map(i=>[i.id,i]));yt.value=e.map(i=>{const o=a.get(i.id);return o?{...o,status:i.status,priority:i.priority??o.priority,assignee:i.assignee??o.assignee}:i})}catch(t){console.error("Tasks selective fetch error:",t)}}async function nd(){try{const t=Sn.value,e=t.reduce((l,p)=>Math.max(l,p.seq??0),0),n=await bl(e),a=(Array.isArray(n.messages)?n.messages:[]).map(Qo).filter(l=>l!==null);if(a.length===0)return;const i=new Set(t.map(l=>l.seq).filter(l=>l!=null)),o=new Set(t.filter(l=>l.seq==null).map(l=>`${l.timestamp}|${l.from}`)),r=a.filter(l=>{if(l.seq!=null)return!i.has(l.seq);const p=`${l.timestamp}|${l.from}`;return o.has(p)?!1:(o.add(p),!0)});if(r.length>0){const l=[...t,...r];Sn.value=l.length>500?l.slice(-500):l}}catch(t){console.error("Messages selective fetch error:",t)}}async function qt(){wn.value=!0;try{const t=await zl(An.value,{excludeSystem:ue.value});Be.value=t.posts??[],Hs.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{wn.value=!1}}async function jt(){var t;Ks.value=!0;try{const e=Ut.value||((t=se.value)==null?void 0:t.room)||"default";Ut.value||(Ut.value=e);const n=await ec(e);jo.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Ks.value=!1}}async function Tn(){Le.value=!0;try{const t=await yc();Cn.value=Array.isArray(t)?t:[],Ko.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Le.value=!1}}async function je(){Pe.value=!0;try{const t=await kl(),e=Array.isArray(t.loops)?t.loops:[],n=new Map;for(const a of e){const i=Zc(a);i&&n.set(i.loop_id,i)}Fo.value=n,Ho.value=new Date().toISOString(),js.value=null,qs.value=n.size===0?"idle":"ready"}catch(t){console.error("MDAL fetch error:",t),qs.value="error",js.value=t instanceof Error?t.message:String(t)}finally{Pe.value=!1}}let Zn=null;function ad(t){Zn=t}let ta=null;function sd(t){ta=t}const pe={};function de(t,e,n=500){pe[t]&&clearTimeout(pe[t]),pe[t]=setTimeout(()=>{e(),delete pe[t]},n)}function id(){const t=wo.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(zs.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),zs.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&de("agents",td),Wc(e.type)&&(qe(),Xa||(Xa=setTimeout(()=>{ne(),ta==null||ta(),Xa=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&de("tasks",ed),e.type==="broadcast"&&de("messages",nd),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&de("dashboard",()=>{qe(),ne()}),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&de("board",qt),e.type.startsWith("decision_")&&de("council",()=>Zn==null?void 0:Zn()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&de("mdal",je,350)}});return()=>{t();for(const e of Object.keys(pe))clearTimeout(pe[e]),delete pe[e]}}let on=null;function od(){on||(on=setInterval(()=>{Ft.value||qe(),ne()},1e4))}function rd(){on&&(clearInterval(on),on=null)}function w({title:t,class:e,children:n}){return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="card ${e??""}">
      ${t?s`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function Lt({status:t,label:e}){return s`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function dd(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const i=Math.floor(a/60);if(i<60)return`${i}m ago`;const o=Math.floor(i/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function F({timestamp:t}){const e=dd(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return s`<span class="time-ago" title=${n}>${e}</span>`}function V(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function st(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function me(t){return(t??"").trim().toLowerCase()}function ct(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function Ot(t){return typeof t!="number"||Number.isNaN(t)?3:t}function yi(t){const e=Ot(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}let ud=0;const ve=_([]);function w(t,e="success",n=4e3){const a=++ud;ve.value=[...ve.value,{id:a,message:t,type:e}],setTimeout(()=>{ve.value=ve.value.filter(i=>i.id!==a)},n)}function pd(t){ve.value=ve.value.filter(e=>e.id!==t)}function md(){const t=ve.value;return t.length===0?null:s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function ld(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const i=Math.floor(a/60);if(i<60)return`${i}m ago`;const o=Math.floor(i/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function F({timestamp:t}){const e=ld(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return s`<span class="time-ago" title=${n}>${e}</span>`}function V(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function st(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function me(t){return(t??"").trim().toLowerCase()}function ct(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function Ot(t){return typeof t!="number"||Number.isNaN(t)?3:t}function $i(t){const e=Ot(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}let cd=0;const ve=f([]);function w(t,e="success",n=4e3){const a=++cd;ve.value=[...ve.value,{id:a,message:t,type:e}],setTimeout(()=>{ve.value=ve.value.filter(i=>i.id!==a)},n)}function dd(t){ve.value=ve.value.filter(e=>e.id!==t)}function ud(){const t=ve.value;return t.length===0?null:s`
========
  `}function ld(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const i=Math.floor(a/60);if(i<60)return`${i}m ago`;const o=Math.floor(i/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function F({timestamp:t}){const e=ld(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return s`<span class="time-ago" title=${n}>${e}</span>`}function Y(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function st(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function me(t){return(t??"").trim().toLowerCase()}function ct(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function zt(t){return typeof t!="number"||Number.isNaN(t)?3:t}function $i(t){const e=zt(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}let cd=0;const ve=f([]);function C(t,e="success",n=4e3){const a=++cd;ve.value=[...ve.value,{id:a,message:t,type:e}],setTimeout(()=>{ve.value=ve.value.filter(i=>i.id!==a)},n)}function dd(t){ve.value=ve.value.filter(e=>e.id!==t)}function ud(){const t=ve.value;return t.length===0?null:s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="toast-container">
      ${t.map(e=>s`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>pd(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}const vd="masc_dashboard_agent_name",We=_(null),pa=_(!1),Nn=_(""),ma=_([]),Rn=_([]),Ee=_(""),ln=_(!1);function Ie(t){We.value=t,bi()}function Bi(){We.value=null,Nn.value="",ma.value=[],Rn.value=[],Ee.value=""}function fd(){const t=We.value;return t?xt.value.find(e=>e.name===t)??null:null}function tr(t){return t?$t.value.filter(e=>e.assignee===t):[]}async function bi(){const t=We.value;if(t){pa.value=!0,Nn.value="",ma.value=[],Rn.value=[];try{const e=await fc(80);ma.value=e.filter(i=>i.includes(t)).slice(0,20);const n=tr(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async i=>{try{const o=await _c(i.id,25);return{taskId:i.id,text:o.trim()}}catch(o){const r=o instanceof Error?o.message:"history load failed";return{taskId:i.id,text:`Failed to load history: ${r}`}}}));Rn.value=a}catch(e){Nn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{pa.value=!1}}}async function Wi(){var a;const t=We.value,e=Ee.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(vd))==null?void 0:a.trim())||"dashboard";ln.value=!0;try{await zo(n,`@${t} ${e}`),Ee.value="",w(`Mention sent to ${t}`,"success"),bi()}catch(i){const o=i instanceof Error?i.message:"Failed to send mention";w(o,"error")}finally{ln.value=!1}}function _d({task:t}){return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}const pd="masc_dashboard_agent_name",We=f(null),pa=f(!1),Nn=f(""),ma=f([]),Rn=f([]),Ie=f(""),rn=f(!1);function Me(t){We.value=t,hi()}function Ki(){We.value=null,Nn.value="",ma.value=[],Rn.value=[],Ie.value=""}function md(){const t=We.value;return t?xt.value.find(e=>e.name===t)??null:null}function Yo(t){return t?$t.value.filter(e=>e.assignee===t):[]}async function hi(){const t=We.value;if(t){pa.value=!0,Nn.value="",ma.value=[],Rn.value=[];try{const e=await mc(80);ma.value=e.filter(i=>i.includes(t)).slice(0,20);const n=Yo(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async i=>{try{const o=await vc(i.id,25);return{taskId:i.id,text:o.trim()}}catch(o){const r=o instanceof Error?o.message:"history load failed";return{taskId:i.id,text:`Failed to load history: ${r}`}}}));Rn.value=a}catch(e){Nn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{pa.value=!1}}}async function Hi(){var a;const t=We.value,e=Ie.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(pd))==null?void 0:a.trim())||"dashboard";rn.value=!0;try{await Io(n,`@${t} ${e}`),Ie.value="",w(`Mention sent to ${t}`,"success"),hi()}catch(i){const o=i instanceof Error?i.message:"Failed to send mention";w(o,"error")}finally{rn.value=!1}}function vd({task:t}){return s`
========
  `}const pd="masc_dashboard_agent_name",We=f(null),pa=f(!1),Nn=f(""),ma=f([]),Rn=f([]),Ie=f(""),rn=f(!1);function Me(t){We.value=t,hi()}function Ki(){We.value=null,Nn.value="",ma.value=[],Rn.value=[],Ie.value=""}function md(){const t=We.value;return t?At.value.find(e=>e.name===t)??null:null}function Yo(t){return t?yt.value.filter(e=>e.assignee===t):[]}async function hi(){const t=We.value;if(t){pa.value=!0,Nn.value="",ma.value=[],Rn.value=[];try{const e=await mc(80);ma.value=e.filter(i=>i.includes(t)).slice(0,20);const n=Yo(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async i=>{try{const o=await vc(i.id,25);return{taskId:i.id,text:o.trim()}}catch(o){const r=o instanceof Error?o.message:"history load failed";return{taskId:i.id,text:`Failed to load history: ${r}`}}}));Rn.value=a}catch(e){Nn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{pa.value=!1}}}async function Hi(){var a;const t=We.value,e=Ie.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(pd))==null?void 0:a.trim())||"dashboard";rn.value=!0;try{await Io(n,`@${t} ${e}`),Ie.value="",C(`Mention sent to ${t}`,"success"),hi()}catch(i){const o=i instanceof Error?i.message:"Failed to send mention";C(o,"error")}finally{rn.value=!1}}function vd({task:t}){return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Lt} status=${t.status} />
    </div>
  `}function gd({row:t}){return s`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function $d(){var i,o,r,l;const t=We.value;if(!t)return null;const e=fd(),n=tr(t),a=ma.value;return s`
    <div
      class="agent-detail-overlay"
      onClick=${p=>{p.target.classList.contains("agent-detail-overlay")&&Bi()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${e!=null&&e.emoji?s`<span style="font-size:2rem">${e.emoji}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${t}
                  ${e!=null&&e.koreanName?s`<span style="font-size:0.75em;color:#888">(${e.koreanName})</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  ${e?s`
                        <${Lt} status=${e.status} />
                        ${e.model?s`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                        ${e.primaryValue?s`<span style="font-size:0.75rem;color:#a78bfa">${e.primaryValue}</span>`:""}
                      `:s`<span>Agent snapshot not found in current state</span>`}
                </div>
              </div>
            </div>
            ${(e==null?void 0:e.activityLevel)!=null?s`
              <div style="display:flex;align-items:center;gap:8px;font-size:0.8rem">
                <span style="color:#888">Activity</span>
                <div style="flex:1;max-width:120px;height:6px;background:#1a1a2e;border-radius:3px;overflow:hidden">
                  <div style="width:${Math.min(e.activityLevel*10,100)}%;height:100%;background:${e.activityLevel>=8?"#22c55e":e.activityLevel>=5?"#f59e0b":"#666"};border-radius:3px"></div>
                </div>
                <span style="color:#888">${e.activityLevel}/10</span>
              </div>
            `:""}
            ${(((i=e==null?void 0:e.traits)==null?void 0:i.length)??0)>0?s`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(o=e==null?void 0:e.traits)==null?void 0:o.map(p=>s`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${p}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?s`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(l=e==null?void 0:e.interests)==null?void 0:l.map(p=>s`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${p}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?s`
                    ${e.current_task?s`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?s`<span>Last seen: <${F} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{bi()}} disabled=${pa.value}>
              ${pa.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Bi}>Close</button>
          </div>
        </div>

        ${Nn.value?s`<div class="council-error">${Nn.value}</div>`:null}

        <div class="agent-detail-grid">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
          <${C} title="Assigned Tasks">
            ${n.length===0?s`<div class="empty-state">No assigned tasks</div>`:s`<div class="agent-detail-task-list">${n.map(p=>s`<${_d} key=${p.id} task=${p} />`)}</div>`}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
          <${C} title="Assigned Tasks">
            ${n.length===0?s`<div class="empty-state">No assigned tasks</div>`:s`<div class="agent-detail-task-list">${n.map(p=>s`<${vd} key=${p.id} task=${p} />`)}</div>`}
========
          <${w} title="Assigned Tasks">
            ${n.length===0?s`<div class="empty-state">No assigned tasks</div>`:s`<div class="agent-detail-task-list">${n.map(p=>s`<${vd} key=${p.id} task=${p} />`)}</div>`}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          <//>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
          <${C} title="Recent Activity">
            ${a.length===0?s`<div class="empty-state">No recent room activity match</div>`:s`<div class="agent-activity-list">${a.map((p,$)=>s`<div key=${$} class="agent-activity-line">${p}</div>`)}</div>`}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
          <${C} title="Recent Activity">
            ${a.length===0?s`<div class="empty-state">No recent room activity match</div>`:s`<div class="agent-activity-list">${a.map((p,_)=>s`<div key=${_} class="agent-activity-line">${p}</div>`)}</div>`}
========
          <${w} title="Recent Activity">
            ${a.length===0?s`<div class="empty-state">No recent room activity match</div>`:s`<div class="agent-activity-list">${a.map((p,_)=>s`<div key=${_} class="agent-activity-line">${p}</div>`)}</div>`}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          <//>
        </div>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        <${C} title="Task History">
          ${Rn.value.length===0?s`<div class="empty-state">No task history loaded</div>`:s`<div class="agent-history-list">${Rn.value.map(p=>s`<${gd} key=${p.taskId} row=${p} />`)}</div>`}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        <${C} title="Task History">
          ${Rn.value.length===0?s`<div class="empty-state">No task history loaded</div>`:s`<div class="agent-history-list">${Rn.value.map(p=>s`<${fd} key=${p.taskId} row=${p} />`)}</div>`}
========
        <${w} title="Task History">
          ${Rn.value.length===0?s`<div class="empty-state">No task history loaded</div>`:s`<div class="agent-history-list">${Rn.value.map(p=>s`<${fd} key=${p.taskId} row=${p} />`)}</div>`}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        <//>

        <${w} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Ee.value}
              onInput=${p=>{Ee.value=p.target.value}}
              onKeyDown=${p=>{p.key==="Enter"&&Wi()}}
              disabled=${ln.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Wi()}}
              disabled=${ln.value||Ee.value.trim()===""}
            >
              ${ln.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}const va=600*1e3,ea=1200*1e3;function er(t){switch(t){case"in_progress":return"In Progress";case"claimed":return"Claimed";case"done":return"Done";case"cancelled":return"Cancelled";default:return"Todo"}}function nr(t){switch(t){case"dispatchable":return"Dispatch";case"drift":return"Drift";case"quiet":return"Quiet";case"offline":return"Offline";default:return"Loaded"}}function hd(t){return t.updated_at??t.created_at??null}function Gi(t,e,n){var T,D;const a=me(t.assignee),i=a?e.get(a)??null:null,o=i?n.get(a)??null:null,r=(o==null?void 0:o.lastActivityAt)??(i==null?void 0:i.last_seen)??null,l=r?Math.max(0,Date.now()-V(r)):Number.POSITIVE_INFINITY,p=ct(t.description),$=ct(i==null?void 0:i.current_task)??(o==null?void 0:o.lastActivityText)??null,m=t.status==="claimed"||t.status==="in_progress";let d="ok",v="Fresh owner coverage",c=$??p??t.id,y=!1,S=!1;return t.status==="todo"?t.assignee?i?i.status==="offline"||i.status==="inactive"?(y=!0,d="bad",v="Assigned owner is offline",c="Queue item is blocked until ownership changes."):l>va?(d="warn",v="Owner exists but live signal is quiet",c=$??"Owner may need a nudge before pickup."):((o==null?void 0:o.activeAssignedCount)??0)>0||(T=i.current_task)!=null&&T.trim()?(d="warn",v="Owner is already carrying active work",c=$??`${(o==null?void 0:o.activeAssignedCount)??0} active tasks already assigned.`):(v="Ready and covered by a fresh operator",c=$??p??"This can be picked up immediately."):(y=!0,d="bad",v="Assigned owner is not present in the room",c="Reassign or bring the owner back online."):(y=!0,d=Ot(t.priority)<=2?"bad":"warn",v=Ot(t.priority)<=2?"Urgent ready work has no owner":"Ready work has no owner",c="Assign an agent before this queue item slips."):m&&(t.assignee?i?i.status==="offline"||i.status==="inactive"?(y=!0,d="bad",v="Assigned owner is offline",c=$??"Execution has no live operator right now."):l>ea?(S=!0,d="bad",v="Assigned owner has gone quiet",c=$??"Fresh operator signal is missing."):l>va?(S=!0,d="warn",v="Execution has been quiet for too long",c=$??"Check whether this work is blocked."):(D=i.current_task)!=null&&D.trim()?(v="Execution has fresh owner coverage",c=$??p??t.id):(d="warn",v=t.status==="claimed"?"Claimed work is waiting for explicit focus":"Owner is live but current_task is empty",c=$??"Task state and agent focus are drifting apart."):(y=!0,d="bad",v="Assigned owner is not active in the room",c="Execution is orphaned until ownership is restored."):(y=!0,d="bad",v="Active work has no assignee",c="Claim or reassign this task immediately.")),{task:t,assigneeAgent:i,motion:o,tone:d,note:v,focus:c,lastSignalAt:r,lastTouchedAt:hd(t),ownerGap:y,quiet:S}}function yd(t,e){var v;const n=e.get(me(t.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},a=n.lastActivityAt??t.last_seen??null,i=a?Math.max(0,Date.now()-V(a)):Number.POSITIVE_INFINITY,o=!!((v=t.current_task)!=null&&v.trim()),r=n.activeAssignedCount,l=o||r>0;let p="loaded",$="ok",m="Healthy active load",d=ct(t.current_task)??n.lastActivityText??"Ready for assignment";return t.status==="offline"||t.status==="inactive"?(p="offline",$="bad",m="Agent is unavailable"):l&&i>ea?(p="quiet",$="bad",m="Working without a fresh signal"):r>0&&!o?(p="drift",$="warn",m="Claimed work exists but current_task is empty",d=`${r} active tasks need explicit focus.`):o&&r===0?(p="drift",$="warn",m="current_task has no matching claimed work",d=ct(t.current_task)??"Task metadata and operator state drifted."):!l&&i<=va?(p="dispatchable",$="ok",m="Fresh signal and no active load",d=n.lastActivityText??"Ready for assignment."):l?i>va&&(p="loaded",$="warn",m="Execution load is healthy but slightly quiet",d=ct(t.current_task)??`${r} active tasks in flight.`):(p="quiet",$=i>ea?"bad":"warn",m=i>ea?"No fresh signal while idle":"Reachable, but not freshly active",d=n.lastActivityText??"Likely available after a quick check-in."),{agent:t,motion:n,tone:$,state:p,note:m,focus:d,lastSignalAt:a,activeTaskCount:r}}function Xe({label:t,value:e,color:n,caption:a}){return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}const va=600*1e3,ea=1200*1e3;function Xo(t){switch(t){case"in_progress":return"In Progress";case"claimed":return"Claimed";case"done":return"Done";case"cancelled":return"Cancelled";default:return"Todo"}}function Zo(t){switch(t){case"dispatchable":return"Dispatch";case"drift":return"Drift";case"quiet":return"Quiet";case"offline":return"Offline";default:return"Loaded"}}function _d(t){return t.updated_at??t.created_at??null}function Ui(t,e,n){var T,D;const a=me(t.assignee),i=a?e.get(a)??null:null,o=i?n.get(a)??null:null,r=(o==null?void 0:o.lastActivityAt)??(i==null?void 0:i.last_seen)??null,l=r?Math.max(0,Date.now()-V(r)):Number.POSITIVE_INFINITY,p=ct(t.description),_=ct(i==null?void 0:i.current_task)??(o==null?void 0:o.lastActivityText)??null,m=t.status==="claimed"||t.status==="in_progress";let d="ok",c="Fresh owner coverage",g=_??p??t.id,y=!1,S=!1;return t.status==="todo"?t.assignee?i?i.status==="offline"||i.status==="inactive"?(y=!0,d="bad",c="Assigned owner is offline",g="Queue item is blocked until ownership changes."):l>va?(d="warn",c="Owner exists but live signal is quiet",g=_??"Owner may need a nudge before pickup."):((o==null?void 0:o.activeAssignedCount)??0)>0||(T=i.current_task)!=null&&T.trim()?(d="warn",c="Owner is already carrying active work",g=_??`${(o==null?void 0:o.activeAssignedCount)??0} active tasks already assigned.`):(c="Ready and covered by a fresh operator",g=_??p??"This can be picked up immediately."):(y=!0,d="bad",c="Assigned owner is not present in the room",g="Reassign or bring the owner back online."):(y=!0,d=Ot(t.priority)<=2?"bad":"warn",c=Ot(t.priority)<=2?"Urgent ready work has no owner":"Ready work has no owner",g="Assign an agent before this queue item slips."):m&&(t.assignee?i?i.status==="offline"||i.status==="inactive"?(y=!0,d="bad",c="Assigned owner is offline",g=_??"Execution has no live operator right now."):l>ea?(S=!0,d="bad",c="Assigned owner has gone quiet",g=_??"Fresh operator signal is missing."):l>va?(S=!0,d="warn",c="Execution has been quiet for too long",g=_??"Check whether this work is blocked."):(D=i.current_task)!=null&&D.trim()?(c="Execution has fresh owner coverage",g=_??p??t.id):(d="warn",c=t.status==="claimed"?"Claimed work is waiting for explicit focus":"Owner is live but current_task is empty",g=_??"Task state and agent focus are drifting apart."):(y=!0,d="bad",c="Assigned owner is not active in the room",g="Execution is orphaned until ownership is restored."):(y=!0,d="bad",c="Active work has no assignee",g="Claim or reassign this task immediately.")),{task:t,assigneeAgent:i,motion:o,tone:d,note:c,focus:g,lastSignalAt:r,lastTouchedAt:_d(t),ownerGap:y,quiet:S}}function $d(t,e){var c;const n=e.get(me(t.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},a=n.lastActivityAt??t.last_seen??null,i=a?Math.max(0,Date.now()-V(a)):Number.POSITIVE_INFINITY,o=!!((c=t.current_task)!=null&&c.trim()),r=n.activeAssignedCount,l=o||r>0;let p="loaded",_="ok",m="Healthy active load",d=ct(t.current_task)??n.lastActivityText??"Ready for assignment";return t.status==="offline"||t.status==="inactive"?(p="offline",_="bad",m="Agent is unavailable"):l&&i>ea?(p="quiet",_="bad",m="Working without a fresh signal"):r>0&&!o?(p="drift",_="warn",m="Claimed work exists but current_task is empty",d=`${r} active tasks need explicit focus.`):o&&r===0?(p="drift",_="warn",m="current_task has no matching claimed work",d=ct(t.current_task)??"Task metadata and operator state drifted."):!l&&i<=va?(p="dispatchable",_="ok",m="Fresh signal and no active load",d=n.lastActivityText??"Ready for assignment."):l?i>va&&(p="loaded",_="warn",m="Execution load is healthy but slightly quiet",d=ct(t.current_task)??`${r} active tasks in flight.`):(p="quiet",_=i>ea?"bad":"warn",m=i>ea?"No fresh signal while idle":"Reachable, but not freshly active",d=n.lastActivityText??"Likely available after a quick check-in."),{agent:t,motion:n,tone:_,state:p,note:m,focus:d,lastSignalAt:a,activeTaskCount:r}}function Xe({label:t,value:e,color:n,caption:a}){return s`
========
  `}const va=600*1e3,ea=1200*1e3;function Xo(t){switch(t){case"in_progress":return"In Progress";case"claimed":return"Claimed";case"done":return"Done";case"cancelled":return"Cancelled";default:return"Todo"}}function Zo(t){switch(t){case"dispatchable":return"Dispatch";case"drift":return"Drift";case"quiet":return"Quiet";case"offline":return"Offline";default:return"Loaded"}}function _d(t){return t.updated_at??t.created_at??null}function Ui(t,e,n){var T,P;const a=me(t.assignee),i=a?e.get(a)??null:null,o=i?n.get(a)??null:null,r=(o==null?void 0:o.lastActivityAt)??(i==null?void 0:i.last_seen)??null,l=r?Math.max(0,Date.now()-Y(r)):Number.POSITIVE_INFINITY,p=ct(t.description),_=ct(i==null?void 0:i.current_task)??(o==null?void 0:o.lastActivityText)??null,m=t.status==="claimed"||t.status==="in_progress";let d="ok",c="Fresh owner coverage",g=_??p??t.id,y=!1,S=!1;return t.status==="todo"?t.assignee?i?i.status==="offline"||i.status==="inactive"?(y=!0,d="bad",c="Assigned owner is offline",g="Queue item is blocked until ownership changes."):l>va?(d="warn",c="Owner exists but live signal is quiet",g=_??"Owner may need a nudge before pickup."):((o==null?void 0:o.activeAssignedCount)??0)>0||(T=i.current_task)!=null&&T.trim()?(d="warn",c="Owner is already carrying active work",g=_??`${(o==null?void 0:o.activeAssignedCount)??0} active tasks already assigned.`):(c="Ready and covered by a fresh operator",g=_??p??"This can be picked up immediately."):(y=!0,d="bad",c="Assigned owner is not present in the room",g="Reassign or bring the owner back online."):(y=!0,d=zt(t.priority)<=2?"bad":"warn",c=zt(t.priority)<=2?"Urgent ready work has no owner":"Ready work has no owner",g="Assign an agent before this queue item slips."):m&&(t.assignee?i?i.status==="offline"||i.status==="inactive"?(y=!0,d="bad",c="Assigned owner is offline",g=_??"Execution has no live operator right now."):l>ea?(S=!0,d="bad",c="Assigned owner has gone quiet",g=_??"Fresh operator signal is missing."):l>va?(S=!0,d="warn",c="Execution has been quiet for too long",g=_??"Check whether this work is blocked."):(P=i.current_task)!=null&&P.trim()?(c="Execution has fresh owner coverage",g=_??p??t.id):(d="warn",c=t.status==="claimed"?"Claimed work is waiting for explicit focus":"Owner is live but current_task is empty",g=_??"Task state and agent focus are drifting apart."):(y=!0,d="bad",c="Assigned owner is not active in the room",g="Execution is orphaned until ownership is restored."):(y=!0,d="bad",c="Active work has no assignee",g="Claim or reassign this task immediately.")),{task:t,assigneeAgent:i,motion:o,tone:d,note:c,focus:g,lastSignalAt:r,lastTouchedAt:_d(t),ownerGap:y,quiet:S}}function $d(t,e){var c;const n=e.get(me(t.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},a=n.lastActivityAt??t.last_seen??null,i=a?Math.max(0,Date.now()-Y(a)):Number.POSITIVE_INFINITY,o=!!((c=t.current_task)!=null&&c.trim()),r=n.activeAssignedCount,l=o||r>0;let p="loaded",_="ok",m="Healthy active load",d=ct(t.current_task)??n.lastActivityText??"Ready for assignment";return t.status==="offline"||t.status==="inactive"?(p="offline",_="bad",m="Agent is unavailable"):l&&i>ea?(p="quiet",_="bad",m="Working without a fresh signal"):r>0&&!o?(p="drift",_="warn",m="Claimed work exists but current_task is empty",d=`${r} active tasks need explicit focus.`):o&&r===0?(p="drift",_="warn",m="current_task has no matching claimed work",d=ct(t.current_task)??"Task metadata and operator state drifted."):!l&&i<=va?(p="dispatchable",_="ok",m="Fresh signal and no active load",d=n.lastActivityText??"Ready for assignment."):l?i>va&&(p="loaded",_="warn",m="Execution load is healthy but slightly quiet",d=ct(t.current_task)??`${r} active tasks in flight.`):(p="quiet",_=i>ea?"bad":"warn",m=i>ea?"No fresh signal while idle":"Reachable, but not freshly active",d=n.lastActivityText??"Likely available after a quick check-in."),{agent:t,motion:n,tone:_,state:p,note:m,focus:d,lastSignalAt:a,activeTaskCount:r}}function Xe({label:t,value:e,color:n,caption:a}){return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?s`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function bd({item:t}){return s`
    <div class="execution-alert ${t.tone}">
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="task"?yi(t.taskRow.task.priority):nr(t.agentRow.state)}
        </span>
        ${t.kind==="task"?s`<span>${er(t.taskRow.task.status)}</span>`:s`<span>${t.agentRow.agent.name}</span>`}
        ${t.timestamp?s`<span><${F} timestamp=${t.timestamp} /></span>`:s`<span>No signal</span>`}
      </div>
    </div>
  `}function Ji({row:t}){var e;return s`
    <div class="execution-task-row ${t.tone}">
      <div class="monitor-row-header">
        <span class="monitor-pill ${t.tone}">${yi(t.task.priority)}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.task.title}</span>
            <span class="monitor-sub">${t.task.id}</span>
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        ${t.assigneeAgent?s`<${Lt} status=${t.assigneeAgent.status} />`:s`<span class="monitor-sub">No owner</span>`}
        <span class="monitor-pill ${t.tone}">${er(t.task.status)}</span>
      </div>

      <div class="monitor-meta">
        ${t.task.assignee?s`<span>Owner ${t.task.assignee}</span>`:s`<span>Unassigned</span>`}
        ${t.lastTouchedAt?s`<span>Touched <${F} timestamp=${t.lastTouchedAt} /></span>`:null}
        ${t.lastSignalAt?s`<span>Signal <${F} timestamp=${t.lastSignalAt} /></span>`:s`<span>No live signal</span>`}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${(e=t.assigneeAgent)!=null&&e.current_task&&ct(t.assigneeAgent.current_task)!==t.focus?s`<div class="monitor-footnote">Owner focus: ${ct(t.assigneeAgent.current_task)}</div>`:null}
    </div>
  `}function kd({row:t}){const{agent:e}=t;return s`
    <button class="monitor-row ${t.tone}" onClick=${()=>Ie(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?s`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Lt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${nr(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?s`<span>Signal <${F} timestamp=${t.lastSignalAt} /></span>`:s`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?s`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
    </button>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function xd(){const t=xt.value,e=$t.value,n=new Map(t.map(d=>[me(d.name),d])),a=Wa.value,i=e.filter(d=>d.status==="claimed"||d.status==="in_progress").map(d=>Gi(d,n,a)).sort((d,v)=>{const c=st(v.tone)-st(d.tone);return c!==0?c:V(v.lastSignalAt??v.lastTouchedAt)-V(d.lastSignalAt??d.lastTouchedAt)}),o=e.filter(d=>d.status==="todo").map(d=>Gi(d,n,a)).sort((d,v)=>{const c=st(v.tone)-st(d.tone);if(c!==0)return c;const y=Ot(d.task.priority)-Ot(v.task.priority);return y!==0?y:V(d.lastTouchedAt)-V(v.lastTouchedAt)}),r=t.map(d=>yd(d,a)).filter(d=>d.state==="dispatchable"||d.state==="drift"||d.state==="quiet").sort((d,v)=>{if(d.state==="dispatchable"&&v.state!=="dispatchable")return-1;if(v.state==="dispatchable"&&d.state!=="dispatchable")return 1;const c=st(v.tone)-st(d.tone);return c!==0?c:V(v.lastSignalAt)-V(d.lastSignalAt)}),l=[...i.filter(d=>d.tone!=="ok").map(d=>({kind:"task",key:`active-${d.task.id}`,tone:d.tone,title:d.task.title,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt??d.lastTouchedAt,taskRow:d})),...o.filter(d=>d.tone==="bad").map(d=>({kind:"task",key:`ready-${d.task.id}`,tone:d.tone,title:d.task.title,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastTouchedAt,taskRow:d})),...r.filter(d=>d.state==="drift"||d.tone==="bad").map(d=>({kind:"agent",key:`agent-${d.agent.name}`,tone:d.tone,title:d.agent.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt,agentRow:d}))].sort((d,v)=>{const c=st(v.tone)-st(d.tone);return c!==0?c:V(v.timestamp)-V(d.timestamp)}).slice(0,8),p=r.filter(d=>d.state==="dispatchable"),$=[...i,...o].filter(d=>d.ownerGap),m=i.filter(d=>d.quiet);return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function bd(){const t=xt.value,e=$t.value,n=new Map(t.map(d=>[me(d.name),d])),a=Ba.value,i=e.filter(d=>d.status==="claimed"||d.status==="in_progress").map(d=>Ui(d,n,a)).sort((d,c)=>{const g=st(c.tone)-st(d.tone);return g!==0?g:V(c.lastSignalAt??c.lastTouchedAt)-V(d.lastSignalAt??d.lastTouchedAt)}),o=e.filter(d=>d.status==="todo").map(d=>Ui(d,n,a)).sort((d,c)=>{const g=st(c.tone)-st(d.tone);if(g!==0)return g;const y=Ot(d.task.priority)-Ot(c.task.priority);return y!==0?y:V(d.lastTouchedAt)-V(c.lastTouchedAt)}),r=t.map(d=>$d(d,a)).filter(d=>d.state==="dispatchable"||d.state==="drift"||d.state==="quiet").sort((d,c)=>{if(d.state==="dispatchable"&&c.state!=="dispatchable")return-1;if(c.state==="dispatchable"&&d.state!=="dispatchable")return 1;const g=st(c.tone)-st(d.tone);return g!==0?g:V(c.lastSignalAt)-V(d.lastSignalAt)}),l=[...i.filter(d=>d.tone!=="ok").map(d=>({kind:"task",key:`active-${d.task.id}`,tone:d.tone,title:d.task.title,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt??d.lastTouchedAt,taskRow:d})),...o.filter(d=>d.tone==="bad").map(d=>({kind:"task",key:`ready-${d.task.id}`,tone:d.tone,title:d.task.title,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastTouchedAt,taskRow:d})),...r.filter(d=>d.state==="drift"||d.tone==="bad").map(d=>({kind:"agent",key:`agent-${d.agent.name}`,tone:d.tone,title:d.agent.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt,agentRow:d}))].sort((d,c)=>{const g=st(c.tone)-st(d.tone);return g!==0?g:V(c.timestamp)-V(d.timestamp)}).slice(0,8),p=r.filter(d=>d.state==="dispatchable"),_=[...i,...o].filter(d=>d.ownerGap),m=i.filter(d=>d.quiet);return s`
========
  `}function bd(){const t=At.value,e=yt.value,n=new Map(t.map(d=>[me(d.name),d])),a=Ba.value,i=e.filter(d=>d.status==="claimed"||d.status==="in_progress").map(d=>Ui(d,n,a)).sort((d,c)=>{const g=st(c.tone)-st(d.tone);return g!==0?g:Y(c.lastSignalAt??c.lastTouchedAt)-Y(d.lastSignalAt??d.lastTouchedAt)}),o=e.filter(d=>d.status==="todo").map(d=>Ui(d,n,a)).sort((d,c)=>{const g=st(c.tone)-st(d.tone);if(g!==0)return g;const y=zt(d.task.priority)-zt(c.task.priority);return y!==0?y:Y(d.lastTouchedAt)-Y(c.lastTouchedAt)}),r=t.map(d=>$d(d,a)).filter(d=>d.state==="dispatchable"||d.state==="drift"||d.state==="quiet").sort((d,c)=>{if(d.state==="dispatchable"&&c.state!=="dispatchable")return-1;if(c.state==="dispatchable"&&d.state!=="dispatchable")return 1;const g=st(c.tone)-st(d.tone);return g!==0?g:Y(c.lastSignalAt)-Y(d.lastSignalAt)}),l=[...i.filter(d=>d.tone!=="ok").map(d=>({kind:"task",key:`active-${d.task.id}`,tone:d.tone,title:d.task.title,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt??d.lastTouchedAt,taskRow:d})),...o.filter(d=>d.tone==="bad").map(d=>({kind:"task",key:`ready-${d.task.id}`,tone:d.tone,title:d.task.title,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastTouchedAt,taskRow:d})),...r.filter(d=>d.state==="drift"||d.tone==="bad").map(d=>({kind:"agent",key:`agent-${d.agent.name}`,tone:d.tone,title:d.agent.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt,agentRow:d}))].sort((d,c)=>{const g=st(c.tone)-st(d.tone);return g!==0?g:Y(c.timestamp)-Y(d.timestamp)}).slice(0,8),p=r.filter(d=>d.state==="dispatchable"),_=[...i,...o].filter(d=>d.ownerGap),m=i.filter(d=>d.quiet);return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="agents-monitor">
      <div class="stats-grid">
        <${Xe} label="Active work" value=${i.length} color="#fbbf24" caption="claimed + in progress" />
        <${Xe} label="Needs intervention" value=${l.length} color=${l.length>0?"#fb7185":"#4ade80"} caption="stalled or drifting now" />
        <${Xe} label="Ownership gaps" value=${$.length} color=${$.length>0?"#fb7185":"#4ade80"} caption="missing or unavailable owners" />
        <${Xe} label="Dispatchable agents" value=${p.length} color="#22d3ee" caption="fresh signal, no active load" />
        <${Xe} label="Quiet execution" value=${m.length} color=${m.length>0?"#fbbf24":"#4ade80"} caption="active tasks with aging signals" />
      </div>

      <${w} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs a nudge right now</h2>
          <p class="monitor-subheadline">Severity comes first, then the freshest evidence we have about the stall or drift.</p>
        </div>
        <div class="monitor-alert-list">
          ${l.length===0?s`<div class="empty-state">No active execution risks right now</div>`:l.map(d=>s`<${bd} key=${d.key} item=${d} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${w} title="Ready Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Ready work, sorted by dispatch risk</h2>
            <p class="monitor-subheadline">Ownerless or owner-unavailable items float to the top before healthy assigned queue items.</p>
          </div>
          <div class="monitor-list">
            ${o.length===0?s`<div class="empty-state">No ready tasks in the queue</div>`:o.slice(0,10).map(d=>s`<${Ji} key=${d.task.id} row=${d} />`)}
          </div>
        <//>

        <${w} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity appears first. Task-state drift stays visible so owners can clean up metadata fast.</p>
          </div>
          <div class="monitor-list">
            ${r.length===0?s`<div class="empty-state">No agent capacity or drift signals right now</div>`:r.map(d=>s`<${kd} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>
      </div>

      <${w} title="Active Execution Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Claimed and in-progress work</h2>
          <p class="monitor-subheadline">Rows are sorted by risk first, then by the freshest operator signal tied to each task.</p>
        </div>
        <div class="monitor-list">
          ${i.length===0?s`<div class="empty-state">No active execution tasks</div>`:i.map(d=>s`<${Ji} key=${d.task.id} row=${d} />`)}
        </div>
      <//>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Sd(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Ad(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function wd(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Vi(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function ar(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Cd(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function sr(t){if(!t)return null;const e=Ut.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function ir({keeper:t,showRawStatus:e=!1}){if(rt(()=>{t!=null&&t.name&&Ko(t.name)},[t==null?void 0:t.name]),!t)return s`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Ut.value[t.name],a=sr(t),i=Es.value[t.name];return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function kd(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function xd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Sd(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Wi(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function tr(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Ad(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function er(t){if(!t)return null;const e=Ut.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function nr({keeper:t,showRawStatus:e=!1}){if(rt(()=>{t!=null&&t.name&&qo(t.name)},[t==null?void 0:t.name]),!t)return s`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Ut.value[t.name],a=er(t),i=Ps.value[t.name];return s`
========
  `}function kd(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function xd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Sd(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Wi(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function tr(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Ad(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function er(t){if(!t)return null;const e=Bt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function nr({keeper:t,showRawStatus:e=!1}){if(rt(()=>{t!=null&&t.name&&qo(t.name)},[t==null?void 0:t.name]),!t)return s`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Bt.value[t.name],a=er(t),i=Ps.value[t.name];return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(a==null?void 0:a.health_state)??"unknown"}</span>
        <span class="pill">${Sd(a==null?void 0:a.quiet_reason)}</span>
        <span class="pill">next ${Ad((a==null?void 0:a.next_action_path)??"direct_message")}</span>
        ${i?s`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(a==null?void 0:a.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(a==null?void 0:a.last_reply_status)??"unknown"}
        ${a!=null&&a.last_reply_at?s` · ${ar(a.last_reply_at)}`:null}
        ${a!=null&&a.next_eligible_at_s?s` · next eligible ${Cd(a.next_eligible_at_s)}`:null}
      </div>
      ${a!=null&&a.last_error?s`<div class="control-status-copy control-error-copy">${a.last_error}</div>`:null}
      ${e?s`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function or({keeperName:t,placeholder:e}){const[n,a]=Ua("");rt(()=>{t&&Ko(t)},[t]);const i=dt.value[t]??[],o=Is.value[t]??!1,r=Bt.value[t],l=async()=>{const p=n.trim();if(!(!t||!p)){a("");try{await Mc(t,p)}catch($){const m=$ instanceof Error?$.message:`Failed to message ${t}`;w(m,"error")}}};return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function ar({keeperName:t,placeholder:e}){const[n,a]=Ha("");rt(()=>{t&&qo(t)},[t]);const i=dt.value[t]??[],o=Ds.value[t]??!1,r=Bt.value[t],l=async()=>{const p=n.trim();if(!(!t||!p)){a("");try{await Ec(t,p)}catch(_){const m=_ instanceof Error?_.message:`Failed to message ${t}`;w(m,"error")}}};return s`
========
  `}function ar({keeperName:t,placeholder:e}){const[n,a]=Ha("");rt(()=>{t&&qo(t)},[t]);const i=dt.value[t]??[],o=Ds.value[t]??!1,r=Wt.value[t],l=async()=>{const p=n.trim();if(!(!t||!p)){a("");try{await Ec(t,p)}catch(_){const m=_ instanceof Error?_.message:`Failed to message ${t}`;C(m,"error")}}};return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${i.length===0?s`<div class="control-status-copy">No direct keeper conversation yet.</div>`:i.map(p=>s`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Vi(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${Vi(p)}`}>${wd(p)}</span>
                  ${p.timestamp?s`<span class="keeper-conversation-time">${ar(p.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${p.text}</div>
                ${p.error?s`<div class="keeper-conversation-error">${p.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${e}
          value=${n}
          onInput=${p=>{a(p.target.value)}}
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
        ${r?s`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function rr({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const a=sr(e),i=Ms.value[e.name]??!1,o=Os.value[e.name]??!1,r=(a==null?void 0:a.next_action_path)??"direct_message",l=(a==null?void 0:a.recoverable)??r==="recover";return s`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        onClick=${()=>{Oc(e.name,t).catch(p=>{const $=p instanceof Error?p.message:`Failed to probe ${e.name}`;w($,"error")})}}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        onClick=${()=>{Ic(e.name,t).catch(p=>{const _=p instanceof Error?p.message:`Failed to probe ${e.name}`;w(_,"error")})}}
========
        onClick=${()=>{Ic(e.name,t).catch(p=>{const _=p instanceof Error?p.message:`Failed to probe ${e.name}`;C(_,"error")})}}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        disabled=${i||!t.trim()}
      >
        ${i?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        onClick=${()=>{zc(e.name,t).catch(p=>{const $=p instanceof Error?p.message:`Failed to recover ${e.name}`;w($,"error")})}}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        onClick=${()=>{Mc(e.name,t).catch(p=>{const _=p instanceof Error?p.message:`Failed to recover ${e.name}`;w(_,"error")})}}
========
        onClick=${()=>{Mc(e.name,t).catch(p=>{const _=p instanceof Error?p.message:`Failed to recover ${e.name}`;C(_,"error")})}}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
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
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}const ki=_(null);function fa(t){ki.value=t,Yn(t.name)}function Qi(){ki.value=null}const we=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Td(t){if(!t)return 0;const e=we.findIndex(n=>n.level===t);return e>=0?e:0}function Nd({keeper:t}){const e=Td(t.autonomy_level),n=we[e]??we[0];if(!n)return null;const a=(e+1)/we.length*100;return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}const yi=f(null);function fa(t){yi.value=t,Yn(t.name)}function Gi(){yi.value=null}const Ce=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function wd(t){if(!t)return 0;const e=Ce.findIndex(n=>n.level===t);return e>=0?e:0}function Cd({keeper:t}){const e=wd(t.autonomy_level),n=Ce[e]??Ce[0];if(!n)return null;const a=(e+1)/Ce.length*100;return s`
========
  `}const yi=f(null);function fa(t){yi.value=t,Yn(t.name)}function Gi(){yi.value=null}const we=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Cd(t){if(!t)return 0;const e=we.findIndex(n=>n.level===t);return e>=0?e:0}function wd({keeper:t}){const e=Cd(t.autonomy_level),n=we[e]??we[0];if(!n)return null;const a=(e+1)/we.length*100;return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${we.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${we.map((i,o)=>s`
            <span style="width:8px; height:8px; border-radius:50%; background:${o<=e?i.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${t.autonomous_action_count??0}</strong>
      </div>
      ${t.last_autonomous_action_at?s`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${F} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?s`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function na(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Rd({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",i=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return s`
    <div class="keeper-kpis">
      ${i.map(o=>s`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?s`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${na(t.context_tokens)}</div>
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
        <div class="kpi-value">${a}</div>
        <div class="kpi-label">Cost (USD)</div>
      </div>
    </div>
  `}function Ld({keeper:t}){var m,d;const e=t.metrics_series??[];if(e.length<2){const v=(((m=t.context)==null?void 0:m.context_ratio)??0)*100,c=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return s`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${c}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,a=60,i=2,o=e.length,r=e.map((v,c)=>{const y=i+c/(o-1)*(n-2*i),S=a-i-(v.context_ratio??0)*(a-2*i);return{x:y,y:S,p:v}}),l=r.map(({x:v,y:c})=>`${v.toFixed(1)},${c.toFixed(1)}`).join(" "),p=(((d=e[e.length-1])==null?void 0:d.context_ratio)??0)*100,$=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return s`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${i}" y1="${(a-i-.5*(a-2*i)).toFixed(1)}" x2="${n-i}" y2="${(a-i-.5*(a-2*i)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${i}" y1="${(a-i-.7*(a-2*i)).toFixed(1)}" x2="${n-i}" y2="${(a-i-.7*(a-2*i)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${i}" y1="${(a-i-.85*(a-2*i)).toFixed(1)}" x2="${n-i}" y2="${(a-i-.85*(a-2*i)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:v})=>v.is_handoff).map(({x:v})=>s`
          <line x1="${v.toFixed(1)}" y1="${i}" x2="${v.toFixed(1)}" y2="${a-i}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${$}" stroke-width="1.5"/>
        ${r.filter(({p:v})=>v.is_compaction).map(({x:v,y:c})=>s`
          <circle cx="${v.toFixed(1)}" cy="${c.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}const ts=_("");function Pd({keeper:t}){var i,o,r,l;const e=ts.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((i=t.traits)==null?void 0:i.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],a=e?n.filter(p=>p.title.toLowerCase().includes(e)||p.key.includes(e)||p.value.toLowerCase().includes(e)):n;return s`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${ts.value}
        onInput=${p=>{ts.value=p.target.value}}
      />
      ${a.map(p=>s`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${p.title}</span>
          <span class="keeper-field-key">${p.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${p.value}</span>
        </div>
      `)}
      ${t.trace_id?s`<div class="keeper-field-row"><span class="keeper-field-title">Trace ID</span><span class="keeper-field-key mono">${t.trace_id}</span></div>`:""}
      ${t.agent_name?s`<div class="keeper-field-row"><span class="keeper-field-title">Agent</span><span style="flex:1; text-align:right; color:#ccc;">${t.agent_name}</span></div>`:""}
      ${t.primary_model?s`<div class="keeper-field-row"><span class="keeper-field-title">Primary Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.primary_model}</span></div>`:""}
      ${t.active_model?s`<div class="keeper-field-row"><span class="keeper-field-title">Active Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.active_model}</span></div>`:""}
      ${t.next_model_hint?s`<div class="keeper-field-row"><span class="keeper-field-title">Next Model Hint</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.next_model_hint}</span></div>`:""}
      ${t.skill_primary?s`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Primary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_primary}</span></div>`:""}
      ${t.skill_secondary?s`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Secondary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_secondary}</span></div>`:""}
      ${t.skill_reason?s`<div class="keeper-field-row"><span class="keeper-field-title">Skill Reason</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_reason}</span></div>`:""}
      ${t.context_source?s`<div class="keeper-field-row"><span class="keeper-field-title">Context Source</span><span style="flex:1; text-align:right; color:#ccc;">${t.context_source}</span></div>`:""}
      ${t.context_tokens!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${na(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${na(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?s`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${na(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Dd({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return s`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(a=>s`
          <div style="text-align:center; padding:6px; background:rgba(255,255,255,0.03); border-radius:6px;">
            <div style="font-size:10px; color:#888; text-transform:uppercase;">${a.label}</div>
            <div style="font-size:16px; font-weight:bold; color:#e0e0e0;">${a.value}</div>
          </div>
        `)}
      </div>
      <div style="margin-top:8px; font-size:12px; color:#888;">
        Level ${t.level} — XP ${t.xp}
      </div>
    </div>
  `}function Ed({items:t}){return t.length===0?s`<div class="empty-state" style="font-size:13px">No equipment</div>`:s`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>s`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Id({rels:t}){const e=Object.entries(t);return e.length===0?s`<div class="empty-state" style="font-size:13px">No relationships</div>`:s`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>s`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function Yi({traits:t,label:e}){return t.length===0?null:s`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>s`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function es(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Md({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:es(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:es(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:es(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return s`
    <div class="keeper-signal-list">
      ${n.map(a=>s`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function lr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function Od(){try{const t=await On({actor:lr(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=$i(t.result);qe(),await ee(),e!=null&&e.skipped_reason?w(e.skipped_reason,"warning"):w(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";w(e,"error")}}function zd({keeper:t}){return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function ir(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function Id(){try{const t=await On({actor:ir(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=gi(t.result);qe(),await ee(),e!=null&&e.skipped_reason?w(e.skipped_reason,"warning"):w(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";w(e,"error")}}function Md({keeper:t}){return s`
========
  `}function ir(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function Id(){try{const t=await On({actor:ir(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=gi(t.result);qe(),await ne(),e!=null&&e.skipped_reason?C(e.skipped_reason,"warning"):C(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";C(e,"error")}}function Md({keeper:t}){return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${ir} keeper=${t} />
          <${rr}
            actor=${lr()}
            keeper=${t}
            onPokeLodge=${()=>{Od()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${or}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function qd(){var e,n,a;const t=ki.value;return t?s`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${i=>{i.target.classList.contains("keeper-detail-overlay")&&Qi()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${""}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${t.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${t.name}</h2>
              ${t.koreanName?s`<div style="font-size:13px; color:#888;">${t.koreanName}</div>`:null}
            </div>
            <${Lt} status=${t.status} />
            ${t.model?s`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Qi()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Rd} keeper=${t} />

        ${""}
        <${Ld} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
          <${C} title="Field Dictionary">
            <${Pd} keeper=${t} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
          <${C} title="Field Dictionary">
            <${Rd} keeper=${t} />
========
          <${w} title="Field Dictionary">
            <${Rd} keeper=${t} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          <//>

          ${""}
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
          <${C} title="Profile">
            <${Yi} traits=${t.traits??[]} label="Traits" />
            <${Yi} traits=${t.interests??[]} label="Interests" />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
          <${C} title="Profile">
            <${Ji} traits=${t.traits??[]} label="Traits" />
            <${Ji} traits=${t.interests??[]} label="Interests" />
========
          <${w} title="Profile">
            <${Ji} traits=${t.traits??[]} label="Traits" />
            <${Ji} traits=${t.interests??[]} label="Interests" />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
            ${t.primaryValue?s`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?s`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?s`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?s`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${F} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?s`
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
              <${C} title="Autonomy">
                <${Nd} keeper=${t} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              <${C} title="Autonomy">
                <${Cd} keeper=${t} />
========
              <${w} title="Autonomy">
                <${wd} keeper=${t} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?s`
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
              <${C} title="TRPG Stats">
                <${Dd} stats=${t.trpg_stats} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              <${C} title="TRPG Stats">
                <${Ld} stats=${t.trpg_stats} />
========
              <${w} title="TRPG Stats">
                <${Ld} stats=${t.trpg_stats} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?s`
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
              <${C} title="Equipment (${t.inventory.length})">
                <${Ed} items=${t.inventory} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              <${C} title="Equipment (${t.inventory.length})">
                <${Pd} items=${t.inventory} />
========
              <${w} title="Equipment (${t.inventory.length})">
                <${Pd} items=${t.inventory} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?s`
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
              <${C} title="Relationships (${Object.keys(t.relationships).length})">
                <${Id} rels=${t.relationships} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              <${C} title="Relationships (${Object.keys(t.relationships).length})">
                <${Dd} rels=${t.relationships} />
========
              <${w} title="Relationships (${Object.keys(t.relationships).length})">
                <${Dd} rels=${t.relationships} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
              <//>
            `:null}

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
          <${C} title="Runtime Signals">
            <${Md} keeper=${t} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
          <${C} title="Runtime Signals">
            <${Ed} keeper=${t} />
========
          <${w} title="Runtime Signals">
            <${Ed} keeper=${t} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
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
                  ${t.context_max??((a=t.context)==null?void 0:a.context_max)??"-"}
                </strong>
              </div>
              ${t.memory_recent_note?s`
                  <div class="keeper-memory-note">
                    ${t.memory_recent_note}
                  </div>
                `:s`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${zd} keeper=${t} />
      </div>
    </div>
  `:null}const Fe=_(!1);function jd(){Fe.value=!0}function Xi(){Fe.value=!1}function Fd(){Fe.value=!Fe.value}const ns=600*1e3,as=1200*1e3,Zi=.8,ss=_("triage");function xe(t){const e=(t??"").toLowerCase();return e==="bad"?"bad":e==="warn"?"warn":"ok"}function Fn(t){switch(t){case"bad":return"#fb7185";case"warn":return"#fbbf24";default:return"#4ade80"}}function to(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function eo(t){if(t==null||!Number.isFinite(t))return"unknown";if(t<60)return`${Math.round(t)}s`;const e=Math.round(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Kd(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function is(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Hd(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Ud(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Bd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Wd(t){return t?t.enabled?t.quiet_active?`Quiet hours ${to(t.quiet_start)}-${to(t.quiet_end)} KST are active.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${eo(t.interval_s)}, but no tick has run yet.`:`Lodge ticks every ${eo(t.interval_s)} with planner ${t.use_planner?"on":"off"} and delegated LLM ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled.":"Lodge runtime status is unavailable in the current dashboard payload."}function no(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function Se({label:t,value:e,color:n,caption:a}){return s`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
      ${a?s`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Gd({item:t}){return s`
    <button class="monitor-alert ${t.tone}" onClick=${t.action}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.detail}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">${t.tone==="bad"?"Act now":t.tone==="warn"?"Watch":"Stable"}</span>
        ${t.timestamp?s`<span><${F} timestamp=${t.timestamp} /></span>`:null}
      </div>
    </button>
  `}function os({tone:t,title:e,subtitle:n,meta:a,focus:i,onClick:o}){return s`
    <button class="monitor-row ${t}" onClick=${o}>
      <div class="monitor-row-header">
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e}</span>
            <span class="monitor-sub">${n}</span>
          </div>
        </div>
        <span class="monitor-pill ${t}">${t==="bad"?"Alert":t==="warn"?"Watch":"Ready"}</span>
      </div>
      <div class="monitor-meta">
        ${a.map(r=>s`<span>${r}</span>`)}
      </div>
      <div class="monitor-focus">${i}</div>
    </button>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function ao(){var et,U,ie,At,wt,W,nt,x,Pt,Jt,oe,re,I,Dt,le,Je,Ve;const t=ae.value,e=xt.value,n=$t.value,a=Gt.value,i=Go.value,o=(et=t==null?void 0:t.monitoring)==null?void 0:et.board,r=(U=t==null?void 0:t.monitoring)==null?void 0:U.council,l=jt.value,p=new Map(e.map(f=>[me(f.name),f])),$=Wa.value,m=e.map(f=>{var Ii;const R=$.get(me(f.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},j=R.lastActivityAt??f.last_seen??null,at=j?Math.max(0,Date.now()-V(j)):Number.POSITIVE_INFINITY,z=R.activeAssignedCount,mt=!!((Ii=f.current_task)!=null&&Ii.trim()),J=mt||z>0;let Q="ok",yt="Fresh and ready",ye=!1,be=!1;return f.status==="offline"||f.status==="inactive"?(Q=J?"bad":"warn",yt=J?"Load without an available owner":"Offline"):J&&at>as?(Q="bad",yt="Execution is stale"):z>0&&!mt?(Q="warn",yt="Claimed work has no current_task",be=!0):mt&&z===0?(Q="warn",yt="current_task has no claimed work",be=!0):!J&&at<=ns?(Q="ok",yt="Dispatchable now",ye=!0):!J&&at>as?(Q="warn",yt="Idle but not freshly active"):J&&at>ns&&(Q="warn",yt="Execution is getting quiet"),{agent:f,lastSignalAt:j,activeTaskCount:z,tone:Q,note:yt,focus:ct(f.current_task)??R.lastActivityText??(ye?"Ready for assignment.":"Waiting for a clearer signal."),dispatchable:ye,drift:be}}).sort((f,R)=>{const j=st(R.tone)-st(f.tone);return j!==0?j:V(R.lastSignalAt)-V(f.lastSignalAt)}),d=a.map(f=>{var Q;const R=Jo.value.get(f.name)??"idle",j=Vo.value.has(f.name),at=f.context_ratio??0,z=f.diagnostic??null;let mt="ok",J="Healthy keeper";return j||f.status==="offline"||R==="handoff-imminent"||(z==null?void 0:z.health_state)==="offline"||(z==null?void 0:z.health_state)==="degraded"?(mt="bad",J=ct(z==null?void 0:z.summary,56)??(j?"Heartbeat stale":R==="handoff-imminent"?"Handoff imminent":(z==null?void 0:z.health_state)==="degraded"?"Keeper degraded":"Keeper offline")):((z==null?void 0:z.health_state)==="stale"||at>=Zi||R==="preparing"||R==="compacting")&&(mt="warn",J=ct(z==null?void 0:z.summary,56)??(at>=Zi?"High context pressure":`Lifecycle ${R}`)),{keeper:f,tone:mt,note:J,focus:ct(z==null?void 0:z.summary,120)??ct((Q=f.agent)==null?void 0:Q.current_task)??f.skill_primary??f.last_proactive_reason??f.memory_recent_note??"No active focus",timestamp:f.last_heartbeat??null}}).sort((f,R)=>{const j=st(R.tone)-st(f.tone);return j!==0?j:V(R.timestamp)-V(f.timestamp)}),v=n.filter(f=>f.status==="todo"||f.status==="claimed"||f.status==="in_progress").map(f=>{var ye,be;const R=f.assignee?p.get(me(f.assignee))??null:null,j=R?$.get(me(R.name))??null:null,at=(j==null?void 0:j.lastActivityAt)??(R==null?void 0:R.last_seen)??null,z=at?Math.max(0,Date.now()-V(at)):Number.POSITIVE_INFINITY,mt=f.status==="claimed"||f.status==="in_progress";let J="ok",Q="Covered",yt=!1;return f.assignee?!R||R.status==="offline"||R.status==="inactive"?(J="bad",Q="Assigned owner is unavailable",yt=!0):mt&&z>as?(J="bad",Q="Execution has lost a fresh signal"):mt&&z>ns?(J="warn",Q="Execution is drifting quiet"):f.status==="todo"&&Ot(f.priority)<=2&&!((ye=R.current_task)!=null&&ye.trim())&&((j==null?void 0:j.activeAssignedCount)??0)===0?(J="ok",Q="Ready for dispatch"):mt&&!((be=R.current_task)!=null&&be.trim())&&(J="warn",Q="Owner focus is not explicit"):(J=Ot(f.priority)<=2?"bad":"warn",Q=mt?"Active work has no owner":"Ready work has no owner",yt=!0),{task:f,owner:R,lastSignalAt:at,tone:J,note:Q,focus:ct(R==null?void 0:R.current_task)??(j==null?void 0:j.lastActivityText)??ct(f.description)??"Needs operator attention.",ownerGap:yt}}).sort((f,R)=>{const j=st(R.tone)-st(f.tone);if(j!==0)return j;const at=Ot(f.task.priority)-Ot(R.task.priority);return at!==0?at:V(R.lastSignalAt??R.task.updated_at??R.task.created_at)-V(f.lastSignalAt??f.task.updated_at??f.task.created_at)}),c=v.filter(f=>f.task.status==="todo"&&Ot(f.task.priority)<=2),y=v.filter(f=>f.ownerGap).length,S=m.filter(f=>f.dispatchable),T=m.filter(f=>f.drift||f.tone!=="ok"),D=d.filter(f=>f.tone!=="ok"),L=t!=null&&t.paused?"bad":((ie=t==null?void 0:t.data_quality)==null?void 0:ie.board_contract_ok)===!1||((At=t==null?void 0:t.data_quality)==null?void 0:At.council_feed_ok)===!1?"warn":l?"ok":"warn",M=[];t!=null&&t.paused&&M.push({key:"paused",tone:"bad",title:"Room is paused",detail:t.tempo?`Tempo is ${t.tempo}. Resume from Ops when ready.`:"Resume from Ops when ready.",timestamp:((wt=t.data_quality)==null?void 0:wt.last_sync_at)??null,action:()=>Rt("ops")}),l||M.push({key:"live-connection",tone:"warn",title:"Live feed is reconnecting",detail:"Dashboard telemetry is stale until the SSE stream recovers.",timestamp:null,action:jd}),xe(o==null?void 0:o.alert_level)!=="ok"&&M.push({key:"board-monitor",tone:xe(o==null?void 0:o.alert_level),title:"Board feed needs attention",detail:`Freshness ${is(o==null?void 0:o.last_activity_age_s)} · ${(o==null?void 0:o.unanswered_posts)??0} unanswered posts.`,timestamp:null,action:()=>Rt("board")}),xe(r==null?void 0:r.alert_level)!=="ok"&&M.push({key:"council-monitor",tone:xe(r==null?void 0:r.alert_level),title:"Council quorum risk is elevated",detail:`${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum · freshness ${is(r==null?void 0:r.last_activity_age_s)}.`,timestamp:null,action:()=>Rt("board")}),(((W=t==null?void 0:t.data_quality)==null?void 0:W.board_contract_ok)===!1||((nt=t==null?void 0:t.data_quality)==null?void 0:nt.council_feed_ok)===!1)&&M.push({key:"data-quality",tone:"warn",title:"Dashboard data quality is degraded",detail:`${((x=t.data_quality)==null?void 0:x.board_contract_ok)===!1?"Board contract":"Board contract ok"} · ${((Pt=t.data_quality)==null?void 0:Pt.council_feed_ok)===!1?"Council feed degraded":"Council feed ok"}.`,timestamp:((Jt=t.data_quality)==null?void 0:Jt.last_sync_at)??null,action:()=>Rt("ops")});const N=[...M,...v.filter(f=>f.tone!=="ok").slice(0,3).map(f=>({key:`task-${f.task.id}`,tone:f.tone,title:f.task.title,detail:`${f.note} · ${f.focus}`,timestamp:f.lastSignalAt??f.task.updated_at??f.task.created_at??null,action:()=>Rt("overview")})),...D.slice(0,2).map(f=>({key:`keeper-${f.keeper.name}`,tone:f.tone,title:f.keeper.name,detail:`${f.note} · ${f.focus}`,timestamp:f.timestamp,action:()=>fa(f.keeper)})),...T.slice(0,2).map(f=>({key:`agent-${f.agent.name}`,tone:f.tone,title:f.agent.name,detail:`${f.note} · ${f.focus}`,timestamp:f.lastSignalAt,action:()=>Ie(f.agent.name)}))].sort((f,R)=>{const j=st(R.tone)-st(f.tone);return j!==0?j:V(R.timestamp)-V(f.timestamp)}).slice(0,8),P=ss.value;return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function to(){var et,U,ie,At,wt,W,nt,k,Pt,Jt,oe,re,I,Dt,le,Je,Ve;const t=ae.value,e=xt.value,n=$t.value,a=Gt.value,i=Uo.value,o=(et=t==null?void 0:t.monitoring)==null?void 0:et.board,r=(U=t==null?void 0:t.monitoring)==null?void 0:U.council,l=jt.value,p=new Map(e.map(v=>[me(v.name),v])),_=Ba.value,m=e.map(v=>{var Pi;const R=_.get(me(v.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},j=R.lastActivityAt??v.last_seen??null,at=j?Math.max(0,Date.now()-V(j)):Number.POSITIVE_INFINITY,z=R.activeAssignedCount,mt=!!((Pi=v.current_task)!=null&&Pi.trim()),J=mt||z>0;let Q="ok",yt="Fresh and ready",be=!1,ke=!1;return v.status==="offline"||v.status==="inactive"?(Q=J?"bad":"warn",yt=J?"Load without an available owner":"Offline"):J&&at>ns?(Q="bad",yt="Execution is stale"):z>0&&!mt?(Q="warn",yt="Claimed work has no current_task",ke=!0):mt&&z===0?(Q="warn",yt="current_task has no claimed work",ke=!0):!J&&at<=es?(Q="ok",yt="Dispatchable now",be=!0):!J&&at>ns?(Q="warn",yt="Idle but not freshly active"):J&&at>es&&(Q="warn",yt="Execution is getting quiet"),{agent:v,lastSignalAt:j,activeTaskCount:z,tone:Q,note:yt,focus:ct(v.current_task)??R.lastActivityText??(be?"Ready for assignment.":"Waiting for a clearer signal."),dispatchable:be,drift:ke}}).sort((v,R)=>{const j=st(R.tone)-st(v.tone);return j!==0?j:V(R.lastSignalAt)-V(v.lastSignalAt)}),d=a.map(v=>{var Q;const R=Bo.value.get(v.name)??"idle",j=Wo.value.has(v.name),at=v.context_ratio??0,z=v.diagnostic??null;let mt="ok",J="Healthy keeper";return j||v.status==="offline"||R==="handoff-imminent"||(z==null?void 0:z.health_state)==="offline"||(z==null?void 0:z.health_state)==="degraded"?(mt="bad",J=ct(z==null?void 0:z.summary,56)??(j?"Heartbeat stale":R==="handoff-imminent"?"Handoff imminent":(z==null?void 0:z.health_state)==="degraded"?"Keeper degraded":"Keeper offline")):((z==null?void 0:z.health_state)==="stale"||at>=Qi||R==="preparing"||R==="compacting")&&(mt="warn",J=ct(z==null?void 0:z.summary,56)??(at>=Qi?"High context pressure":`Lifecycle ${R}`)),{keeper:v,tone:mt,note:J,focus:ct(z==null?void 0:z.summary,120)??ct((Q=v.agent)==null?void 0:Q.current_task)??v.skill_primary??v.last_proactive_reason??v.memory_recent_note??"No active focus",timestamp:v.last_heartbeat??null}}).sort((v,R)=>{const j=st(R.tone)-st(v.tone);return j!==0?j:V(R.timestamp)-V(v.timestamp)}),c=n.filter(v=>v.status==="todo"||v.status==="claimed"||v.status==="in_progress").map(v=>{var be,ke;const R=v.assignee?p.get(me(v.assignee))??null:null,j=R?_.get(me(R.name))??null:null,at=(j==null?void 0:j.lastActivityAt)??(R==null?void 0:R.last_seen)??null,z=at?Math.max(0,Date.now()-V(at)):Number.POSITIVE_INFINITY,mt=v.status==="claimed"||v.status==="in_progress";let J="ok",Q="Covered",yt=!1;return v.assignee?!R||R.status==="offline"||R.status==="inactive"?(J="bad",Q="Assigned owner is unavailable",yt=!0):mt&&z>ns?(J="bad",Q="Execution has lost a fresh signal"):mt&&z>es?(J="warn",Q="Execution is drifting quiet"):v.status==="todo"&&Ot(v.priority)<=2&&!((be=R.current_task)!=null&&be.trim())&&((j==null?void 0:j.activeAssignedCount)??0)===0?(J="ok",Q="Ready for dispatch"):mt&&!((ke=R.current_task)!=null&&ke.trim())&&(J="warn",Q="Owner focus is not explicit"):(J=Ot(v.priority)<=2?"bad":"warn",Q=mt?"Active work has no owner":"Ready work has no owner",yt=!0),{task:v,owner:R,lastSignalAt:at,tone:J,note:Q,focus:ct(R==null?void 0:R.current_task)??(j==null?void 0:j.lastActivityText)??ct(v.description)??"Needs operator attention.",ownerGap:yt}}).sort((v,R)=>{const j=st(R.tone)-st(v.tone);if(j!==0)return j;const at=Ot(v.task.priority)-Ot(R.task.priority);return at!==0?at:V(R.lastSignalAt??R.task.updated_at??R.task.created_at)-V(v.lastSignalAt??v.task.updated_at??v.task.created_at)}),g=c.filter(v=>v.task.status==="todo"&&Ot(v.task.priority)<=2),y=c.filter(v=>v.ownerGap).length,S=m.filter(v=>v.dispatchable),T=m.filter(v=>v.drift||v.tone!=="ok"),D=d.filter(v=>v.tone!=="ok"),L=t!=null&&t.paused?"bad":((ie=t==null?void 0:t.data_quality)==null?void 0:ie.board_contract_ok)===!1||((At=t==null?void 0:t.data_quality)==null?void 0:At.council_feed_ok)===!1?"warn":l?"ok":"warn",M=[];t!=null&&t.paused&&M.push({key:"paused",tone:"bad",title:"Room is paused",detail:t.tempo?`Tempo is ${t.tempo}. Resume from Ops when ready.`:"Resume from Ops when ready.",timestamp:((wt=t.data_quality)==null?void 0:wt.last_sync_at)??null,action:()=>Rt("ops")}),l||M.push({key:"live-connection",tone:"warn",title:"Live feed is reconnecting",detail:"Dashboard telemetry is stale until the SSE stream recovers.",timestamp:null,action:zd}),Se(o==null?void 0:o.alert_level)!=="ok"&&M.push({key:"board-monitor",tone:Se(o==null?void 0:o.alert_level),title:"Board feed needs attention",detail:`Freshness ${ss(o==null?void 0:o.last_activity_age_s)} · ${(o==null?void 0:o.unanswered_posts)??0} unanswered posts.`,timestamp:null,action:()=>Rt("board")}),Se(r==null?void 0:r.alert_level)!=="ok"&&M.push({key:"council-monitor",tone:Se(r==null?void 0:r.alert_level),title:"Council quorum risk is elevated",detail:`${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum · freshness ${ss(r==null?void 0:r.last_activity_age_s)}.`,timestamp:null,action:()=>Rt("board")}),(((W=t==null?void 0:t.data_quality)==null?void 0:W.board_contract_ok)===!1||((nt=t==null?void 0:t.data_quality)==null?void 0:nt.council_feed_ok)===!1)&&M.push({key:"data-quality",tone:"warn",title:"Dashboard data quality is degraded",detail:`${((k=t.data_quality)==null?void 0:k.board_contract_ok)===!1?"Board contract":"Board contract ok"} · ${((Pt=t.data_quality)==null?void 0:Pt.council_feed_ok)===!1?"Council feed degraded":"Council feed ok"}.`,timestamp:((Jt=t.data_quality)==null?void 0:Jt.last_sync_at)??null,action:()=>Rt("ops")});const N=[...M,...c.filter(v=>v.tone!=="ok").slice(0,3).map(v=>({key:`task-${v.task.id}`,tone:v.tone,title:v.task.title,detail:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt??v.task.updated_at??v.task.created_at??null,action:()=>Rt("overview")})),...D.slice(0,2).map(v=>({key:`keeper-${v.keeper.name}`,tone:v.tone,title:v.keeper.name,detail:`${v.note} · ${v.focus}`,timestamp:v.timestamp,action:()=>fa(v.keeper)})),...T.slice(0,2).map(v=>({key:`agent-${v.agent.name}`,tone:v.tone,title:v.agent.name,detail:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt,action:()=>Me(v.agent.name)}))].sort((v,R)=>{const j=st(R.tone)-st(v.tone);return j!==0?j:V(R.timestamp)-V(v.timestamp)}).slice(0,8),P=as.value;return s`
========
  `}function to(){var X,H,Pt,mt,vt,B,M,k,Dt,Vt,oe,re,E,Et,le,Je,Ve;const t=se.value,e=At.value,n=yt.value,a=Jt.value,i=Uo.value,o=(X=t==null?void 0:t.monitoring)==null?void 0:X.board,r=(H=t==null?void 0:t.monitoring)==null?void 0:H.council,l=Ft.value,p=new Map(e.map(v=>[me(v.name),v])),_=Ba.value,m=e.map(v=>{var Pi;const L=_.get(me(v.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},j=L.lastActivityAt??v.last_seen??null,at=j?Math.max(0,Date.now()-Y(j)):Number.POSITIVE_INFINITY,z=L.activeAssignedCount,ft=!!((Pi=v.current_task)!=null&&Pi.trim()),Q=ft||z>0;let Z="ok",kt="Fresh and ready",be=!1,ke=!1;return v.status==="offline"||v.status==="inactive"?(Z=Q?"bad":"warn",kt=Q?"Load without an available owner":"Offline"):Q&&at>ns?(Z="bad",kt="Execution is stale"):z>0&&!ft?(Z="warn",kt="Claimed work has no current_task",ke=!0):ft&&z===0?(Z="warn",kt="current_task has no claimed work",ke=!0):!Q&&at<=es?(Z="ok",kt="Dispatchable now",be=!0):!Q&&at>ns?(Z="warn",kt="Idle but not freshly active"):Q&&at>es&&(Z="warn",kt="Execution is getting quiet"),{agent:v,lastSignalAt:j,activeTaskCount:z,tone:Z,note:kt,focus:ct(v.current_task)??L.lastActivityText??(be?"Ready for assignment.":"Waiting for a clearer signal."),dispatchable:be,drift:ke}}).sort((v,L)=>{const j=st(L.tone)-st(v.tone);return j!==0?j:Y(L.lastSignalAt)-Y(v.lastSignalAt)}),d=a.map(v=>{var Z;const L=Bo.value.get(v.name)??"idle",j=Wo.value.has(v.name),at=v.context_ratio??0,z=v.diagnostic??null;let ft="ok",Q="Healthy keeper";return j||v.status==="offline"||L==="handoff-imminent"||(z==null?void 0:z.health_state)==="offline"||(z==null?void 0:z.health_state)==="degraded"?(ft="bad",Q=ct(z==null?void 0:z.summary,56)??(j?"Heartbeat stale":L==="handoff-imminent"?"Handoff imminent":(z==null?void 0:z.health_state)==="degraded"?"Keeper degraded":"Keeper offline")):((z==null?void 0:z.health_state)==="stale"||at>=Qi||L==="preparing"||L==="compacting")&&(ft="warn",Q=ct(z==null?void 0:z.summary,56)??(at>=Qi?"High context pressure":`Lifecycle ${L}`)),{keeper:v,tone:ft,note:Q,focus:ct(z==null?void 0:z.summary,120)??ct((Z=v.agent)==null?void 0:Z.current_task)??v.skill_primary??v.last_proactive_reason??v.memory_recent_note??"No active focus",timestamp:v.last_heartbeat??null}}).sort((v,L)=>{const j=st(L.tone)-st(v.tone);return j!==0?j:Y(L.timestamp)-Y(v.timestamp)}),c=n.filter(v=>v.status==="todo"||v.status==="claimed"||v.status==="in_progress").map(v=>{var be,ke;const L=v.assignee?p.get(me(v.assignee))??null:null,j=L?_.get(me(L.name))??null:null,at=(j==null?void 0:j.lastActivityAt)??(L==null?void 0:L.last_seen)??null,z=at?Math.max(0,Date.now()-Y(at)):Number.POSITIVE_INFINITY,ft=v.status==="claimed"||v.status==="in_progress";let Q="ok",Z="Covered",kt=!1;return v.assignee?!L||L.status==="offline"||L.status==="inactive"?(Q="bad",Z="Assigned owner is unavailable",kt=!0):ft&&z>ns?(Q="bad",Z="Execution has lost a fresh signal"):ft&&z>es?(Q="warn",Z="Execution is drifting quiet"):v.status==="todo"&&zt(v.priority)<=2&&!((be=L.current_task)!=null&&be.trim())&&((j==null?void 0:j.activeAssignedCount)??0)===0?(Q="ok",Z="Ready for dispatch"):ft&&!((ke=L.current_task)!=null&&ke.trim())&&(Q="warn",Z="Owner focus is not explicit"):(Q=zt(v.priority)<=2?"bad":"warn",Z=ft?"Active work has no owner":"Ready work has no owner",kt=!0),{task:v,owner:L,lastSignalAt:at,tone:Q,note:Z,focus:ct(L==null?void 0:L.current_task)??(j==null?void 0:j.lastActivityText)??ct(v.description)??"Needs operator attention.",ownerGap:kt}}).sort((v,L)=>{const j=st(L.tone)-st(v.tone);if(j!==0)return j;const at=zt(v.task.priority)-zt(L.task.priority);return at!==0?at:Y(L.lastSignalAt??L.task.updated_at??L.task.created_at)-Y(v.lastSignalAt??v.task.updated_at??v.task.created_at)}),g=c.filter(v=>v.task.status==="todo"&&zt(v.task.priority)<=2),y=c.filter(v=>v.ownerGap).length,S=m.filter(v=>v.dispatchable),T=m.filter(v=>v.drift||v.tone!=="ok"),P=d.filter(v=>v.tone!=="ok"),K=t!=null&&t.paused?"bad":((Pt=t==null?void 0:t.data_quality)==null?void 0:Pt.board_contract_ok)===!1||((mt=t==null?void 0:t.data_quality)==null?void 0:mt.council_feed_ok)===!1?"warn":l?"ok":"warn",I=[];t!=null&&t.paused&&I.push({key:"paused",tone:"bad",title:"Room is paused",detail:t.tempo?`Tempo is ${t.tempo}. Resume from Ops when ready.`:"Resume from Ops when ready.",timestamp:((vt=t.data_quality)==null?void 0:vt.last_sync_at)??null,action:()=>Rt("ops")}),l||I.push({key:"live-connection",tone:"warn",title:"Live feed is reconnecting",detail:"Dashboard telemetry is stale until the SSE stream recovers.",timestamp:null,action:zd}),Se(o==null?void 0:o.alert_level)!=="ok"&&I.push({key:"board-monitor",tone:Se(o==null?void 0:o.alert_level),title:"Board feed needs attention",detail:`Freshness ${ss(o==null?void 0:o.last_activity_age_s)} · ${(o==null?void 0:o.unanswered_posts)??0} unanswered posts.`,timestamp:null,action:()=>Rt("board")}),Se(r==null?void 0:r.alert_level)!=="ok"&&I.push({key:"council-monitor",tone:Se(r==null?void 0:r.alert_level),title:"Council quorum risk is elevated",detail:`${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum · freshness ${ss(r==null?void 0:r.last_activity_age_s)}.`,timestamp:null,action:()=>Rt("board")}),(((B=t==null?void 0:t.data_quality)==null?void 0:B.board_contract_ok)===!1||((M=t==null?void 0:t.data_quality)==null?void 0:M.council_feed_ok)===!1)&&I.push({key:"data-quality",tone:"warn",title:"Dashboard data quality is degraded",detail:`${((k=t.data_quality)==null?void 0:k.board_contract_ok)===!1?"Board contract":"Board contract ok"} · ${((Dt=t.data_quality)==null?void 0:Dt.council_feed_ok)===!1?"Council feed degraded":"Council feed ok"}.`,timestamp:((Vt=t.data_quality)==null?void 0:Vt.last_sync_at)??null,action:()=>Rt("ops")});const N=[...I,...c.filter(v=>v.tone!=="ok").slice(0,3).map(v=>({key:`task-${v.task.id}`,tone:v.tone,title:v.task.title,detail:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt??v.task.updated_at??v.task.created_at??null,action:()=>Rt("overview")})),...P.slice(0,2).map(v=>({key:`keeper-${v.keeper.name}`,tone:v.tone,title:v.keeper.name,detail:`${v.note} · ${v.focus}`,timestamp:v.timestamp,action:()=>fa(v.keeper)})),...T.slice(0,2).map(v=>({key:`agent-${v.agent.name}`,tone:v.tone,title:v.agent.name,detail:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt,action:()=>Me(v.agent.name)}))].sort((v,L)=>{const j=st(L.tone)-st(v.tone);return j!==0?j:Y(L.timestamp)-Y(v.timestamp)}).slice(0,8),R=as.value;return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="overview-sub-tabs">
      <button
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        class="sub-tab-btn ${P==="triage"?"active":""}"
        onClick=${()=>{ss.value="triage"}}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        class="sub-tab-btn ${P==="triage"?"active":""}"
        onClick=${()=>{as.value="triage"}}
========
        class="sub-tab-btn ${R==="triage"?"active":""}"
        onClick=${()=>{as.value="triage"}}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      >Triage</button>
      <button
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        class="sub-tab-btn ${P==="dispatch"?"active":""}"
        onClick=${()=>{ss.value="dispatch"}}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        class="sub-tab-btn ${P==="dispatch"?"active":""}"
        onClick=${()=>{as.value="dispatch"}}
========
        class="sub-tab-btn ${R==="dispatch"?"active":""}"
        onClick=${()=>{as.value="dispatch"}}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      >Dispatch</button>
    </div>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
    ${P==="dispatch"?s`<${xd} />`:s`<div class="stats-grid">
      <${Se}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
    ${P==="dispatch"?s`<${bd} />`:s`<div class="stats-grid">
      <${Ae}
========
    ${R==="dispatch"?s`<${bd} />`:s`<div class="stats-grid">
      <${Ae}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        label="Room State"
        value=${t!=null&&t.paused?"Paused":"Running"}
        color=${Fn(K)}
        caption=${(t==null?void 0:t.room)??(t==null?void 0:t.project)??"default room"}
      />
      <${Se}
        label="Urgent Queue"
        value=${c.length}
        color=${c.length>0?"#fb7185":"#4ade80"}
        caption="todo tasks at P1/P2"
      />
      <${Se}
        label="Active Work"
        value=${i.inProgress.length}
        color="#fbbf24"
        caption="claimed + in progress"
      />
      <${Se}
        label="Dispatchable"
        value=${S.length}
        color="#22d3ee"
        caption="fresh agents with no load"
      />
      <${Se}
        label="Keeper Pressure"
        value=${P.length}
        color=${P.length>0?"#fbbf24":"#4ade80"}
        caption="stale or high-context keepers"
      />
      <${Se}
        label="Owner Gaps"
        value=${y}
        color=${y>0?"#fb7185":"#4ade80"}
        caption="tasks missing a live owner"
      />
    </div>

    <${w} title="Room Health" class="section">
      <div class="monitor-section-head">
        <h2 class="monitor-headline">Operational health at a glance</h2>
        <p class="monitor-subheadline">The Overview now prioritizes room state, feed freshness, and immediate intervention signals over full entity dumps.</p>
      </div>
      <div class="overview-health-grid">
        <div class="stat-card">
          <div class="stat-label">Live Feed</div>
          <div class="stat-value" style=${`color:${l?"#4ade80":"#fbbf24"}`}>${l?"Online":"Retrying"}</div>
          <div class="monitor-stat-caption">${In.value} events seen in this session</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Board Feed</div>
          <div class="stat-value" style=${`color:${Fn(xe(o==null?void 0:o.alert_level))}`}>${no(o==null?void 0:o.alert_level)}</div>
          <div class="monitor-stat-caption">Freshness ${is(o==null?void 0:o.last_activity_age_s)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Council Feed</div>
          <div class="stat-value" style=${`color:${Fn(xe(r==null?void 0:r.alert_level))}`}>${no(r==null?void 0:r.alert_level)}</div>
          <div class="monitor-stat-caption">${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Runtime</div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
          <div class="stat-value" style=${`color:${Fn(L)}`}>${t!=null&&t.paused?"Paused":"Stable"}</div>
          <div class="monitor-stat-caption">Uptime ${Kd((t==null?void 0:t.uptime_seconds)??0)}</div>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
          <div class="stat-value" style=${`color:${Fn(L)}`}>${t!=null&&t.paused?"Paused":"Stable"}</div>
          <div class="monitor-stat-caption">Uptime ${jd((t==null?void 0:t.uptime_seconds)??0)}</div>
========
          <div class="stat-value" style=${`color:${Fn(K)}`}>${t!=null&&t.paused?"Paused":"Stable"}</div>
          <div class="monitor-stat-caption">Uptime ${jd((t==null?void 0:t.uptime_seconds)??0)}</div>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        </div>
      </div>
      <div class="overview-note-stack">
        <div class="overview-inline-note">
          ${(oe=t==null?void 0:t.data_quality)!=null&&oe.last_sync_at?s`Last sync <${F} timestamp=${t.data_quality.last_sync_at} />`:s`No sync metadata yet`}
        </div>
        <div class="overview-inline-note">
          ${t!=null&&t.tempo?`Tempo ${t.tempo}`:"Tempo unavailable"}${(t==null?void 0:t.tempo_interval_s)!=null?` · ${t.tempo_interval_s}s interval`:""}
        </div>
        <div class="overview-inline-note">${Wd(t==null?void 0:t.lodge)}</div>
        ${(re=t==null?void 0:t.lodge)!=null&&re.last_skip_reason?s`<div class="overview-inline-note">Last Lodge skip: ${t.lodge.last_skip_reason}</div>`:null}
      </div>
    <//>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
    <div class="overview-workbench">
      <div class="overview-column">
        <${C} title="Intervention Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">What needs intervention right now</h2>
            <p class="monitor-subheadline">Room-level risks, stalled work, and keeper/agent drift are sorted into one operator-facing queue.</p>
          </div>
          <div class="monitor-alert-list">
            ${N.length===0?s`<div class="empty-state">No immediate intervention required</div>`:N.map(f=>s`<${Gd} key=${f.key} item=${f} />`)}
          </div>
        <//>
      </div>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
    <div class="grid-2col">
      <${C} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs intervention right now</h2>
          <p class="monitor-subheadline">Room-level risks, stalled work, and keeper/agent drift are sorted into one operator-facing queue.</p>
        </div>
        <div class="monitor-alert-list">
          ${N.length===0?s`<div class="empty-state">No immediate intervention required</div>`:N.map(v=>s`<${Bd} key=${v.key} item=${v} />`)}
        </div>
      <//>
========
    <div class="grid-2col">
      <${w} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs intervention right now</h2>
          <p class="monitor-subheadline">Room-level risks, stalled work, and keeper/agent drift are sorted into one operator-facing queue.</p>
        </div>
        <div class="monitor-alert-list">
          ${N.length===0?s`<div class="empty-state">No immediate intervention required</div>`:N.map(v=>s`<${Bd} key=${v.key} item=${v} />`)}
        </div>
      <//>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
      <div class="overview-column">
        <${C} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity stays visible here so dispatch does not require opening the full Agents tab.</p>
          </div>
          <div class="monitor-list">
            ${S.length===0?s`<div class="empty-state">No fully dispatchable agents right now</div>`:S.slice(0,5).map(f=>s`
                  <${os}
                    key=${f.agent.name}
                    tone=${f.tone}
                    title=${f.agent.name}
                    subtitle=${f.note}
                    meta=${[f.lastSignalAt?`Signal ${new Date(f.lastSignalAt).toLocaleTimeString()}`:"No recent signal",f.agent.model??"model n/a",f.agent.koreanName??"room agent"]}
                    focus=${f.focus}
                    onClick=${()=>Ie(f.agent.name)}
                  />
                `)}
          </div>
        <//>

        <${C} title="Agent Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Agents with drift or aging load</h2>
            <p class="monitor-subheadline">This is the short list. Use the Agents tab when you need the full live monitor.</p>
          </div>
          <div class="monitor-list">
            ${T.length===0?s`<div class="empty-state">No agent drift or stale load right now</div>`:T.slice(0,4).map(f=>s`
                  <button class="monitor-row ${f.tone}" onClick=${()=>Ie(f.agent.name)}>
                    <div class="monitor-row-header">
                      <div class="monitor-row-title">
                        <div class="monitor-name-line">
                          <span class="monitor-title">${f.agent.name}</span>
                          ${f.agent.koreanName?s`<span class="monitor-sub">${f.agent.koreanName}</span>`:null}
                        </div>
                        <div class="monitor-note">${f.note}</div>
                      </div>
                      <${Lt} status=${f.agent.status} />
                      <span class="monitor-pill ${f.tone}">${f.dispatchable?"Ready":f.drift?"Drift":"Watch"}</span>
                    </div>
                    <div class="monitor-meta">
                      ${f.lastSignalAt?s`<span>Signal <${F} timestamp=${f.lastSignalAt} /></span>`:s`<span>No recent signal</span>`}
                      <span>${f.activeTaskCount>0?`${f.activeTaskCount} active tasks`:"No active tasks"}</span>
                      ${f.agent.model?s`<span>${f.agent.model}</span>`:null}
                    </div>
                    <div class="monitor-focus">${f.focus}</div>
                  </button>
                `)}
          </div>
        <//>
      </div>

      <div class="overview-column">
        <${C} title="Keeper Pressure" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keepers under pressure</h2>
            <p class="monitor-subheadline">Only keepers with real pressure stay in the Overview. The full keeper census still lives in the Agents tab.</p>
          </div>
          <div class="monitor-list">
            ${D.length===0?s`<div class="empty-state">No keeper pressure signals right now</div>`:D.slice(0,4).map(f=>{var R;return s`
                  <${os}
                    key=${f.keeper.name}
                    tone=${f.tone}
                    title=${f.keeper.name}
                    subtitle=${(R=f.keeper.diagnostic)!=null&&R.health_state?`${f.note} · ${f.keeper.diagnostic.health_state}`:f.note}
                    meta=${[f.timestamp?`Heartbeat ${new Date(f.timestamp).toLocaleTimeString()}`:"No heartbeat",`Context ${typeof f.keeper.context_ratio=="number"?Math.round(f.keeper.context_ratio*100):0}%`,f.keeper.model?`Model ${f.keeper.model}`:"model n/a",f.keeper.diagnostic?`${Ud(f.keeper.diagnostic.quiet_reason)} · next ${Bd(f.keeper.diagnostic.next_action_path)} · reply ${f.keeper.diagnostic.last_reply_status}`:"Diagnostic unavailable"]}
                    focus=${f.focus}
                    onClick=${()=>fa(f.keeper)}
                  />
                `})}
          </div>
        <//>

        <${C} title="Runtime Notes" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Secondary runtime context</h2>
            <p class="monitor-subheadline">This column stays compact so operators can scan triage first and drill later.</p>
          </div>
          <div class="overview-note-stack">
            <div class="overview-inline-note">
              Room ${(t==null?void 0:t.room)??"default"}${t!=null&&t.cluster?` · Cluster ${t.cluster}`:""}${t!=null&&t.project?` · Project ${t.project}`:""}
            </div>
            <div class="overview-inline-note">
              ${t!=null&&t.version?`Version ${t.version}`:"Version unavailable"} · Active agents ${Hc.value.length} · Total tasks ${n.length}
            </div>
            <div class="overview-inline-note">
              ${nn.value?`Perpetual runtime ${nn.value.running?"running":"stopped"}${nn.value.goal?` · ${ct(nn.value.goal,120)}`:""}`:"Perpetual runtime unavailable"}
            </div>
            <div class="overview-inline-note">
              Lodge ${(I=t==null?void 0:t.lodge)!=null&&I.enabled?"enabled":"disabled"} · Last tick ${((Dt=t==null?void 0:t.lodge)==null?void 0:Dt.last_tick_ago)??"never"} · Self heartbeats ${((Je=(le=t==null?void 0:t.lodge)==null?void 0:le.active_self_heartbeats)==null?void 0:Je.length)??0}${(Ve=t==null?void 0:t.lodge)!=null&&Ve.last_skip_reason?` · Skip ${t.lodge.last_skip_reason}`:""}
            </div>
            <div class="overview-inline-note">
              ${a.length>0?`Hot keepers: ${D.length} · Highest context ${Hd(Math.max(...a.map(f=>f.context_tokens??0)))}`:"No keepers registered"}
            </div>
          </div>
        <//>
      </div>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
      <${C} title="Dispatch Window" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who can pick up work next</h2>
          <p class="monitor-subheadline">Fresh capacity stays visible here so dispatch does not require opening the full Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${S.length===0?s`<div class="empty-state">No fully dispatchable agents right now</div>`:S.slice(0,5).map(v=>s`
                <${is}
                  key=${v.agent.name}
                  tone=${v.tone}
                  title=${v.agent.name}
                  subtitle=${v.note}
                  meta=${[v.lastSignalAt?`Signal ${new Date(v.lastSignalAt).toLocaleTimeString()}`:"No recent signal",v.agent.model??"model n/a",v.agent.koreanName??"room agent"]}
                  focus=${v.focus}
                  onClick=${()=>Me(v.agent.name)}
                />
              `)}
        </div>
      <//>
========
      <${w} title="Dispatch Window" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who can pick up work next</h2>
          <p class="monitor-subheadline">Fresh capacity stays visible here so dispatch does not require opening the full Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${S.length===0?s`<div class="empty-state">No fully dispatchable agents right now</div>`:S.slice(0,5).map(v=>s`
                <${is}
                  key=${v.agent.name}
                  tone=${v.tone}
                  title=${v.agent.name}
                  subtitle=${v.note}
                  meta=${[v.lastSignalAt?`Signal ${new Date(v.lastSignalAt).toLocaleTimeString()}`:"No recent signal",v.agent.model??"model n/a",v.agent.koreanName??"room agent"]}
                  focus=${v.focus}
                  onClick=${()=>Me(v.agent.name)}
                />
              `)}
        </div>
      <//>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    </div>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
    <${C} title="Execution Pulse" class="section">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
    <div class="grid-2col">
      <${C} title="Execution Pulse" class="section">
========
    <div class="grid-2col">
      <${w} title="Execution Pulse" class="section">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Priority work and ownership drift</h2>
          <p class="monitor-subheadline">Urgent ready tasks and active execution issues stay visible without duplicating the full Execution surface.</p>
        </div>
        <div class="monitor-list">
          ${v.length===0?s`<div class="empty-state">No active or ready tasks</div>`:v.slice(0,6).map(f=>s`
                <${os}
                  key=${f.task.id}
                  tone=${f.tone}
                  title=${f.task.title}
                  subtitle=${`${yi(f.task.priority)} · ${f.note}`}
                  meta=${[f.task.assignee?`Owner ${f.task.assignee}`:"Unassigned",f.lastSignalAt?`Signal ${new Date(f.lastSignalAt).toLocaleTimeString()}`:"No live signal",f.task.updated_at?`Touched ${new Date(f.task.updated_at).toLocaleTimeString()}`:"No task timestamp"]}
                  focus=${f.focus}
                  onClick=${()=>Rt("overview")}
                />
              `)}
        </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
    <//>`}
  `}const Jd="modulepreload",Vd=function(t){return"/dashboard/"+t},so={},Qd=function(e,n,a){let i=Promise.resolve();if(n&&n.length>0){let r=function($){return Promise.all($.map(m=>Promise.resolve(m).then(d=>({status:"fulfilled",value:d}),d=>({status:"rejected",reason:d}))))};document.getElementsByTagName("link");const l=document.querySelector("meta[property=csp-nonce]"),p=(l==null?void 0:l.nonce)||(l==null?void 0:l.getAttribute("nonce"));i=r(n.map($=>{if($=Vd($),$ in so)return;so[$]=!0;const m=$.endsWith(".css"),d=m?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${$}"]${d}`))return;const v=document.createElement("link");if(v.rel=m?"stylesheet":Jd,m||(v.as="script"),v.crossOrigin="",v.href=$,p&&v.setAttribute("nonce",p),document.head.appendChild(v),m)return new Promise((c,y)=>{v.addEventListener("load",c),v.addEventListener("error",()=>y(new Error(`Unable to preload CSS for ${$}`)))})}))}function o(r){const l=new Event("vite:preloadError",{cancelable:!0});if(l.payload=r,window.dispatchEvent(l),!l.defaultPrevented)throw r}return i.then(r=>{for(const l of r||[])l.status==="rejected"&&o(l.reason);return e().catch(o)})},cr=_(null),Kt=_(null),_a=_(!1),ga=_(!1),$a=_(null),ha=_(null),Gs=_(null),ya=_(null),Ke=_("summary"),zn=_(null),Js=_(!1),ba=_(null),dr=_(null),Vs=_(!1),ka=_(null),xi=_(null),Qs=_(!1),xa=_(null),Ln=_(null),Sa=_(!1),Pn=_(null),cn=_(null);let an=null;function k(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function u(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function g(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Y(t){return typeof t=="boolean"?t:void 0}function pt(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Yd(){if(typeof window>"u")return;const e=new URLSearchParams(window.location.search).get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Xd(t){if(k(t))return{policy_class:u(t.policy_class),approval_class:u(t.approval_class),tool_allowlist:pt(t.tool_allowlist),model_allowlist:pt(t.model_allowlist),requires_human_for:pt(t.requires_human_for),autonomy_level:u(t.autonomy_level),escalation_timeout_sec:g(t.escalation_timeout_sec),kill_switch:Y(t.kill_switch),frozen:Y(t.frozen)}}function Zd(t){if(k(t))return{headcount_cap:g(t.headcount_cap),active_operation_cap:g(t.active_operation_cap),max_cost_usd:g(t.max_cost_usd),max_tokens:g(t.max_tokens)}}function Si(t){if(!k(t))return null;const e=u(t.unit_id),n=u(t.label),a=u(t.kind);return!e||!n||!a?null:{unit_id:e,label:n,kind:a,parent_unit_id:u(t.parent_unit_id)??null,leader_id:u(t.leader_id)??null,roster:pt(t.roster),capability_profile:pt(t.capability_profile),source:u(t.source),created_at:u(t.created_at),updated_at:u(t.updated_at),policy:Xd(t.policy),budget:Zd(t.budget)}}function ur(t){if(!k(t))return null;const e=Si(t.unit);return e?{unit:e,leader_status:u(t.leader_status),roster_total:g(t.roster_total),roster_live:g(t.roster_live),active_operation_count:g(t.active_operation_count),health:u(t.health),reasons:pt(t.reasons),children:Array.isArray(t.children)?t.children.map(ur).filter(n=>n!==null):[]}:null}function tu(t){if(k(t))return{total_units:g(t.total_units),company_count:g(t.company_count),platoon_count:g(t.platoon_count),squad_count:g(t.squad_count),leaf_agent_unit_count:g(t.leaf_agent_unit_count),live_agent_count:g(t.live_agent_count),managed_unit_count:g(t.managed_unit_count),active_operation_count:g(t.active_operation_count)}}function pr(t){const e=k(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),source:u(e.source),summary:tu(e.summary),units:Array.isArray(e.units)?e.units.map(ur).filter(n=>n!==null):[]}}function eu(t){if(!k(t))return null;const e=u(t.kind),n=u(t.status);return!e||!n?null:{kind:e,chain_id:u(t.chain_id)??null,goal:u(t.goal)??null,run_id:u(t.run_id)??null,status:n,viewer_path:u(t.viewer_path)??null,last_sync_at:u(t.last_sync_at)??null}}function Ga(t){if(!k(t))return null;const e=u(t.operation_id),n=u(t.objective),a=u(t.assigned_unit_id),i=u(t.trace_id),o=u(t.status);return!e||!n||!a||!i||!o?null:{operation_id:e,objective:n,assigned_unit_id:a,autonomy_level:u(t.autonomy_level),policy_class:u(t.policy_class),budget_class:u(t.budget_class),detachment_session_id:u(t.detachment_session_id)??null,trace_id:i,checkpoint_ref:u(t.checkpoint_ref)??null,active_goal_ids:pt(t.active_goal_ids),note:u(t.note)??null,created_by:u(t.created_by),source:u(t.source),status:o,chain:eu(t.chain),created_at:u(t.created_at),updated_at:u(t.updated_at)}}function nu(t){if(!k(t))return null;const e=Ga(t.operation);return e?{operation:e,assigned_unit_label:u(t.assigned_unit_label)}:null}function Ze(t){if(k(t))return{tone:u(t.tone),pending_ops:g(t.pending_ops),blocked_ops:g(t.blocked_ops),in_flight_ops:g(t.in_flight_ops),pipeline_stalls:g(t.pipeline_stalls),bus_traffic:g(t.bus_traffic),l1_hit_rate:g(t.l1_hit_rate),invalidation_count:g(t.invalidation_count),current_pending:g(t.current_pending),current_in_flight:g(t.current_in_flight),cdb_wakeups:g(t.cdb_wakeups),total_stolen:g(t.total_stolen),avg_best_score:g(t.avg_best_score),avg_candidate_count:g(t.avg_candidate_count),best_first_operations:g(t.best_first_operations),active_sessions:g(t.active_sessions),commit_rate:g(t.commit_rate),total_speculations:g(t.total_speculations)}}function au(t){if(!k(t))return;const e=k(t.pipeline)?t.pipeline:void 0,n=k(t.cache)?t.cache:void 0,a=k(t.ooo)?t.ooo:void 0,i=k(t.speculative)?t.speculative:void 0,o=k(t.search_fabric)?t.search_fabric:void 0,r=k(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:g(e.total_ops),completed_ops:g(e.completed_ops),stalled_cycles:g(e.stalled_cycles),hazards_detected:g(e.hazards_detected),forwarding_used:g(e.forwarding_used),pipeline_flushes:g(e.pipeline_flushes),ipc:g(e.ipc)}:void 0,cache:n?{total_reads:g(n.total_reads),total_writes:g(n.total_writes),l1_hit_rate:g(n.l1_hit_rate),invalidation_count:g(n.invalidation_count),writeback_count:g(n.writeback_count),bus_traffic:g(n.bus_traffic)}:void 0,ooo:a?{agent_count:g(a.agent_count),total_added:g(a.total_added),total_issued:g(a.total_issued),total_completed:g(a.total_completed),total_stolen:g(a.total_stolen),cdb_wakeups:g(a.cdb_wakeups),stall_cycles:g(a.stall_cycles),global_cdb_events:g(a.global_cdb_events),current_pending:g(a.current_pending),current_in_flight:g(a.current_in_flight)}:void 0,speculative:i?{total_speculations:g(i.total_speculations),total_commits:g(i.total_commits),total_aborts:g(i.total_aborts),commit_rate:g(i.commit_rate),total_fast_calls:g(i.total_fast_calls),total_cost_usd:g(i.total_cost_usd),active_sessions:g(i.active_sessions)}:void 0,search_fabric:o?{total_operations:g(o.total_operations),best_first_operations:g(o.best_first_operations),legacy_operations:g(o.legacy_operations),blocked_operations:g(o.blocked_operations),ready_operations:g(o.ready_operations),research_pipeline_operations:g(o.research_pipeline_operations),avg_candidate_count:g(o.avg_candidate_count),avg_best_score:g(o.avg_best_score),top_stage:u(o.top_stage)??null}:void 0,signals:r?{issue_pressure:Ze(r.issue_pressure),cache_contention:Ze(r.cache_contention),scheduler_efficiency:Ze(r.scheduler_efficiency),routing_confidence:Ze(r.routing_confidence),speculative_posture:Ze(r.speculative_posture)}:void 0}}function mr(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:g(n.total),active:g(n.active),paused:g(n.paused),managed:g(n.managed),projected:g(n.projected)}:void 0,microarch:au(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(nu).filter(a=>a!==null):[]}}function vr(t){if(!k(t))return null;const e=u(t.detachment_id),n=u(t.operation_id),a=u(t.assigned_unit_id);return!e||!n||!a?null:{detachment_id:e,operation_id:n,assigned_unit_id:a,leader_id:u(t.leader_id)??null,roster:pt(t.roster),session_id:u(t.session_id)??null,checkpoint_ref:u(t.checkpoint_ref)??null,runtime_kind:u(t.runtime_kind)??null,runtime_ref:u(t.runtime_ref)??null,source:u(t.source),status:u(t.status),last_event_at:u(t.last_event_at)??null,last_progress_at:u(t.last_progress_at)??null,heartbeat_deadline:u(t.heartbeat_deadline)??null,created_at:u(t.created_at),updated_at:u(t.updated_at)}}function su(t){if(!k(t))return null;const e=vr(t.detachment);return e?{detachment:e,assigned_unit_label:u(t.assigned_unit_label),operation:Ga(t.operation)}:null}function fr(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:g(n.total),active:g(n.active),projected:g(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(su).filter(a=>a!==null):[]}}function iu(t){if(!k(t))return null;const e=u(t.decision_id),n=u(t.trace_id),a=u(t.requested_action),i=u(t.scope_type),o=u(t.scope_id);return!e||!n||!a||!i||!o?null:{decision_id:e,trace_id:n,requested_action:a,scope_type:i,scope_id:o,operation_id:u(t.operation_id)??null,target_unit_id:u(t.target_unit_id)??null,requested_by:u(t.requested_by),status:u(t.status),reason:u(t.reason)??null,source:u(t.source),detail:t.detail,created_at:u(t.created_at),decided_at:u(t.decided_at)??null,expires_at:u(t.expires_at)??null}}function _r(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:g(n.total),pending:g(n.pending),approved:g(n.approved),denied:g(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(iu).filter(a=>a!==null):[]}}function ou(t){if(!k(t))return null;const e=Si(t.unit);return e?{unit:e,roster_total:g(t.roster_total),roster_live:g(t.roster_live),headcount_cap:g(t.headcount_cap),active_operations:g(t.active_operations),active_operation_cap:g(t.active_operation_cap),utilization:g(t.utilization)}:null}function ru(t){const e=k(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(ou).filter(n=>n!==null):[]}}function lu(t){if(!k(t))return null;const e=u(t.alert_id);return e?{alert_id:e,severity:u(t.severity),kind:u(t.kind),scope_type:u(t.scope_type),scope_id:u(t.scope_id),title:u(t.title),detail:u(t.detail),timestamp:u(t.timestamp)}:null}function gr(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:g(n.total),bad:g(n.bad),warn:g(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(lu).filter(a=>a!==null):[]}}function $r(t){if(!k(t))return null;const e=u(t.event_id),n=u(t.trace_id),a=u(t.event_type);return!e||!n||!a?null:{event_id:e,trace_id:n,event_type:a,operation_id:u(t.operation_id)??null,unit_id:u(t.unit_id)??null,actor:u(t.actor)??null,source:u(t.source),timestamp:u(t.timestamp),detail:t.detail}}function cu(t){const e=k(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),events:Array.isArray(e.events)?e.events.map($r).filter(n=>n!==null):[]}}function du(t){if(!k(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a}}function uu(t){if(!k(t))return null;const e=u(t.lane_id),n=u(t.label),a=u(t.kind),i=u(t.phase),o=u(t.motion_state),r=u(t.source_of_truth),l=u(t.movement_reason),p=u(t.current_step);if(!e||!n||!a||!i||!o||!r||!l||!p)return null;const $=k(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:a,present:Y(t.present)??!1,phase:i,motion_state:o,source_of_truth:r,last_movement_at:u(t.last_movement_at)??null,movement_reason:l,current_step:p,blockers:pt(t.blockers),counts:{operations:g($.operations),detachments:g($.detachments),workers:g($.workers),approvals:g($.approvals),alerts:g($.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(du).filter(m=>m!==null):[]}}function pu(t){if(!k(t))return null;const e=u(t.event_id),n=u(t.lane_id),a=u(t.kind),i=u(t.timestamp),o=u(t.title),r=u(t.detail),l=u(t.tone),p=u(t.source);return!e||!n||!a||!i||!o||!r||!l||!p?null:{event_id:e,lane_id:n,kind:a,timestamp:i,title:o,detail:r,tone:l,source:p}}function mu(t){if(!k(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a,lane_ids:pt(t.lane_ids),count:g(t.count)??0}}function hr(t){if(!k(t))return;const e=k(t.overview)?t.overview:{},n=k(t.gaps)?t.gaps:{},a=k(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:u(t.generated_at),overview:{active_lanes:g(e.active_lanes),moving_lanes:g(e.moving_lanes),stalled_lanes:g(e.stalled_lanes),projected_lanes:g(e.projected_lanes),last_movement_at:u(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(uu).filter(i=>i!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(pu).filter(i=>i!==null):[],gaps:{count:g(n.count),items:Array.isArray(n.items)?n.items.map(mu).filter(i=>i!==null):[]},recommended_next_action:a?{tool:u(a.tool)??"masc_operator_snapshot",label:u(a.label)??"Observe operator state",reason:u(a.reason)??"",lane_id:u(a.lane_id)??null}:void 0}}function vu(t){if(!k(t))return;const e=k(t.workers)?t.workers:{},n=Y(t.pass);return{status:u(t.status)??"missing",source:u(t.source)??"none",run_id:u(t.run_id)??null,captured_at:u(t.captured_at)??null,...n!==void 0?{pass:n}:{},...g(t.peak_hot_slots)!=null?{peak_hot_slots:g(t.peak_hot_slots)}:{},...g(t.ctx_per_slot)!=null?{ctx_per_slot:g(t.ctx_per_slot)}:{},workers:{expected:g(e.expected),joined:g(e.joined),current_task_bound:g(e.current_task_bound),fresh_heartbeats:g(e.fresh_heartbeats),done:g(e.done),final:g(e.final)},artifact_ref:u(t.artifact_ref)??null,missing_reason:u(t.missing_reason)??null}}function fu(t){const e=k(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),topology:pr(e.topology),operations:mr(e.operations),detachments:fr(e.detachments),alerts:gr(e.alerts),decisions:_r(e.decisions),capacity:ru(e.capacity),traces:cu(e.traces),swarm_status:hr(e.swarm_status)}}function _u(t){const e=k(t)?t:{},n=pr(e.topology),a=mr(e.operations),i=fr(e.detachments),o=gr(e.alerts),r=_r(e.decisions);return{version:u(e.version),generated_at:u(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:a.version,generated_at:a.generated_at,summary:a.summary,microarch:a.microarch},detachments:{version:i.version,generated_at:i.generated_at,summary:i.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:hr(e.swarm_status),swarm_proof:vu(e.swarm_proof)}}function gu(t){return k(t)?{chain_id:u(t.chain_id)??null,started_at:g(t.started_at)??null,progress:g(t.progress)??null,elapsed_sec:g(t.elapsed_sec)??null}:null}function yr(t){if(!k(t))return null;const e=u(t.event);return e?{event:e,chain_id:u(t.chain_id)??null,timestamp:u(t.timestamp)??null,duration_ms:g(t.duration_ms)??null,message:u(t.message)??null,tokens:g(t.tokens)??null}:null}function $u(t){if(!k(t))return null;const e=Ga(t.operation);return e?{operation:e,runtime:gu(t.runtime),history:yr(t.history),mermaid:u(t.mermaid)??null,preview_run:br(t.preview_run)}:null}function hu(t){const e=k(t)?t:{};return{status:u(e.status)??"disconnected",base_url:u(e.base_url)??null,message:u(e.message)??null}}function yu(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),connection:hu(e.connection),summary:n?{linked_operations:g(n.linked_operations),active_chains:g(n.active_chains),running_operations:g(n.running_operations),recent_failures:g(n.recent_failures),last_history_event_at:u(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map($u).filter(a=>a!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(yr).filter(a=>a!==null):[]}}function bu(t){if(!k(t))return null;const e=u(t.id);return e?{id:e,type:u(t.type),status:u(t.status),duration_ms:g(t.duration_ms)??null,error:u(t.error)??null}:null}function br(t){if(!k(t))return null;const e=u(t.run_id),n=u(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:g(t.duration_ms),success:Y(t.success),mermaid:u(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(bu).filter(a=>a!==null):[]}:null}function ku(t){const e=k(t)?t:{};return{run:br(e.run)}}function xu(t){if(!k(t))return null;const e=u(t.title),n=u(t.path);return!e||!n?null:{title:e,path:n}}function Su(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.summary);return!e||!n||!a?null:{id:e,title:n,summary:a}}function Au(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.tool),i=u(t.summary);return!e||!n||!a||!i?null:{id:e,title:n,tool:a,summary:i,success_signals:pt(t.success_signals),pitfalls:pt(t.pitfalls)}}function wu(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.summary),i=u(t.when_to_use);return!e||!n||!a||!i?null:{id:e,title:n,summary:a,when_to_use:i,steps:Array.isArray(t.steps)?t.steps.map(Au).filter(o=>o!==null):[]}}function Cu(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.description);return!e||!n||!a?null:{id:e,title:n,description:a,tools:pt(t.tools)}}function Tu(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.symptom),i=u(t.why),o=u(t.fix_tool),r=u(t.fix_summary);return!e||!n||!a||!i||!o||!r?null:{id:e,title:n,symptom:a,why:i,fix_tool:o,fix_summary:r}}function Nu(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.path_id),i=u(t.transport);return!e||!n||!a||!i?null:{id:e,title:n,path_id:a,transport:i,request:t.request,response:t.response,notes:pt(t.notes)}}function Ru(t){const e=k(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(xu).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(Su).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(wu).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Cu).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Tu).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Nu).filter(n=>n!==null):[]}}function Lu(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.status),i=u(t.detail),o=u(t.next_tool);return!e||!n||!a||!i||!o?null:{id:e,title:n,status:a,detail:i,next_tool:o}}function Pu(t){if(!k(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.title),i=u(t.detail),o=u(t.next_tool);return!e||!n||!a||!i||!o?null:{code:e,severity:n,title:a,detail:i,next_tool:o}}function Du(t){if(!k(t))return null;const e=u(t.from),n=u(t.content),a=u(t.timestamp),i=g(t.seq);return!e||!n||!a||i==null?null:{seq:i,from:e,content:n,timestamp:a}}function Eu(t){if(!k(t))return null;const e=u(t.name),n=u(t.role),a=u(t.lane),i=u(t.status),o=u(t.claim_marker),r=u(t.done_marker),l=u(t.final_marker);if(!e||!n||!a||!i||!o||!r||!l)return null;const p=(()=>{if(!k(t.last_message))return null;const $=g(t.last_message.seq),m=u(t.last_message.content),d=u(t.last_message.timestamp);return $==null||!m||!d?null:{seq:$,content:m,timestamp:d}})();return{name:e,role:n,lane:a,joined:Y(t.joined)??!1,live_presence:Y(t.live_presence)??!1,completed:Y(t.completed)??!1,status:i,current_task:u(t.current_task)??null,bound_task_id:u(t.bound_task_id)??null,bound_task_title:u(t.bound_task_title)??null,bound_task_status:u(t.bound_task_status)??null,current_task_matches_run:Y(t.current_task_matches_run)??!1,squad_member:Y(t.squad_member)??!1,detachment_member:Y(t.detachment_member)??!1,last_seen:u(t.last_seen)??null,heartbeat_age_sec:g(t.heartbeat_age_sec)??null,heartbeat_fresh:Y(t.heartbeat_fresh)??!1,claim_marker_seen:Y(t.claim_marker_seen)??!1,done_marker_seen:Y(t.done_marker_seen)??!1,final_marker_seen:Y(t.final_marker_seen)??!1,claim_marker:o,done_marker:r,final_marker:l,last_message:p}}function Iu(t){if(!k(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!k(n))return null;const a=u(n.timestamp),i=g(n.active_slots);if(!a||i==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:a,active_slots:i,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:u(t.slot_url)??null,total_slots:g(t.total_slots),ctx_per_slot:g(t.ctx_per_slot),active_slots_now:g(t.active_slots_now),peak_active_slots:g(t.peak_active_slots),sample_count:g(t.sample_count),last_sample_at:u(t.last_sample_at)??null,timeline:e}}function Mu(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),run_id:u(e.run_id),room_id:u(e.room_id),operation_id:u(e.operation_id)??null,recommended_next_tool:u(e.recommended_next_tool),summary:n?{expected_workers:g(n.expected_workers),joined_workers:g(n.joined_workers),live_workers:g(n.live_workers),squad_roster_size:g(n.squad_roster_size),detachment_roster_size:g(n.detachment_roster_size),current_task_bound:g(n.current_task_bound),fresh_heartbeats:g(n.fresh_heartbeats),claim_markers_seen:g(n.claim_markers_seen),done_markers_seen:g(n.done_markers_seen),final_markers_seen:g(n.final_markers_seen),completed_workers:g(n.completed_workers),peak_hot_slots:g(n.peak_hot_slots),hot_window_ok:Y(n.hot_window_ok),pass_hot_concurrency:Y(n.pass_hot_concurrency),pass_end_to_end:Y(n.pass_end_to_end),pending_decisions:g(n.pending_decisions),pass:Y(n.pass)}:void 0,provider:Iu(e.provider),operation:Ga(e.operation),squad:Si(e.squad),detachment:vr(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Eu).filter(a=>a!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Lu).filter(a=>a!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Pu).filter(a=>a!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Du).filter(a=>a!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map($r).filter(a=>a!==null):[],truth_notes:pt(e.truth_notes)}}function Ai(t){Ke.value=t,t!=="summary"&&Ou()}async function wi(){_a.value=!0,$a.value=null;try{const t=await Cl();cr.value=_u(t)}catch(t){$a.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{_a.value=!1}}function Ci(t){cn.value=t}async function Ti(){ga.value=!0,ha.value=null;try{const t=await wl();Kt.value=fu(t)}catch(t){ha.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{ga.value=!1}}async function Ou(){Kt.value||ga.value||await Ti()}async function Me(){await wi(),Ke.value!=="summary"&&await Ti()}async function ge(){var t;Qs.value=!0,xa.value=null;try{const e=await Tl(),n=yu(e);xi.value=n;const a=cn.value;n.operations.length===0?cn.value=null:(!a||!n.operations.some(i=>i.operation.operation_id===a))&&(cn.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){xa.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{Qs.value=!1}}function zu(){an=null,Ln.value=null,Sa.value=!1,Pn.value=null}async function qu(t){an=t,Sa.value=!0,Pn.value=null;try{const e=await Nl(t);if(an!==t)return;Ln.value=ku(e)}catch(e){if(an!==t)return;Ln.value=null,Pn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{an===t&&(Sa.value=!1)}}async function ju(){Js.value=!0,ba.value=null;try{const t=await Rl();zn.value=Ru(t)}catch(t){ba.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Js.value=!1}}async function kr(t=Yd()){Vs.value=!0,ka.value=null;try{const e=await Ll(t);dr.value=Mu(e)}catch(e){ka.value=e instanceof Error?e.message:"Failed to load command-plane swarm view"}finally{Vs.value=!1}}async function se(t,e,n){Gs.value=t,ya.value=null;try{await Pl(e,n),await wi(),(Kt.value||Ke.value!=="summary")&&await Ti(),await kr(),await ge()}catch(a){throw ya.value=a instanceof Error?a.message:"Failed to execute command-plane action",a}finally{Gs.value=null}}function Fu(t){return se(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Ku(t){return se(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function Hu(t){return se(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Uu(t={}){return se("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function Bu(t){return se(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Wu(t){return se(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Gu(t,e){return se(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Ju(t,e){return se(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}od(()=>{wi()});function Vu(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Z(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function Qu(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Yu(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function G(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let io=!1,Xu=0,rs=null;async function Zu(){rs||(rs=Qd(()=>import("./mermaid.core-FYYajSuG.js").then(e=>e.bE),[]).then(e=>e.default));const t=await rs;return io||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),io=!0),t}function Xt(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Ni(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function tp(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function xr(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const Sr=["operations","chains","topology","alerts","trace","control"],ep=["chain_start","node_start","node_complete","chain_complete","chain_error"];function np(t){return!!t&&Sr.includes(t)}function ap(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");return n&&e.set("agent",n),a&&e.set("token",a),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function sp(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function it(t){return Gs.value===t}function Ri(){return cr.value}function ip(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function op(){if(typeof window>"u")return null;const e=new URLSearchParams(window.location.search).get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function rp(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function lp(t){return t.status==="claimed"||t.status==="in_progress"}function cp(t){const e=zn.value;if(!e)return null;for(const n of e.golden_paths){const a=n.steps.find(i=>i.tool===t);if(a)return a}return null}function ls(t){var e;return((e=zn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function dp(t){const e=zn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(a=>n.has(a.id))}async function Zt(t){try{await t()}catch{}}function up(){var d,v,c,y,S,T;const t=Ri(),e=xi.value,n=t==null?void 0:t.topology.summary,a=t==null?void 0:t.operations.summary,i=t==null?void 0:t.operations.microarch,o=t==null?void 0:t.decisions.summary,r=t==null?void 0:t.alerts.summary,l=(d=i==null?void 0:i.signals)==null?void 0:d.routing_confidence,p=(v=i==null?void 0:i.signals)==null?void 0:v.issue_pressure,$=i==null?void 0:i.search_fabric,m=i==null?void 0:i.cache;return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
      <//>

      <${C} title="Keeper Pressure" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Long-running keepers under pressure</h2>
          <p class="monitor-subheadline">Only keepers with real pressure stay in the Overview. The full keeper census still lives in the Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${D.length===0?s`<div class="empty-state">No keeper pressure signals right now</div>`:D.slice(0,5).map(v=>{var R;return s`
                <${is}
                  key=${v.keeper.name}
                  tone=${v.tone}
                  title=${v.keeper.name}
                  subtitle=${(R=v.keeper.diagnostic)!=null&&R.health_state?`${v.note} · ${v.keeper.diagnostic.health_state}`:v.note}
                  meta=${[v.timestamp?`Heartbeat ${new Date(v.timestamp).toLocaleTimeString()}`:"No heartbeat",`Context ${typeof v.keeper.context_ratio=="number"?Math.round(v.keeper.context_ratio*100):0}%`,v.keeper.model?`Model ${v.keeper.model}`:"model n/a",v.keeper.diagnostic?`${Kd(v.keeper.diagnostic.quiet_reason)} · next ${Hd(v.keeper.diagnostic.next_action_path)} · reply ${v.keeper.diagnostic.last_reply_status}`:"Diagnostic unavailable"]}
                  focus=${v.focus}
                  onClick=${()=>fa(v.keeper)}
                />
              `})}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${C} title="Agent Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Agents with drift or aging load</h2>
          <p class="monitor-subheadline">This is the short list. Use the Agents tab when you need the full live monitor.</p>
        </div>
        <div class="monitor-list">
          ${T.length===0?s`<div class="empty-state">No agent drift or stale load right now</div>`:T.slice(0,5).map(v=>s`
                <button class="monitor-row ${v.tone}" onClick=${()=>Me(v.agent.name)}>
                  <div class="monitor-row-header">
                    <div class="monitor-row-title">
                      <div class="monitor-name-line">
                        <span class="monitor-title">${v.agent.name}</span>
                        ${v.agent.koreanName?s`<span class="monitor-sub">${v.agent.koreanName}</span>`:null}
                      </div>
                      <div class="monitor-note">${v.note}</div>
                    </div>
                    <${Lt} status=${v.agent.status} />
                    <span class="monitor-pill ${v.tone}">${v.dispatchable?"Ready":v.drift?"Drift":"Watch"}</span>
                  </div>
                  <div class="monitor-meta">
                    ${v.lastSignalAt?s`<span>Signal <${F} timestamp=${v.lastSignalAt} /></span>`:s`<span>No recent signal</span>`}
                    <span>${v.activeTaskCount>0?`${v.activeTaskCount} active tasks`:"No active tasks"}</span>
                    ${v.agent.model?s`<span>${v.agent.model}</span>`:null}
                  </div>
                  <div class="monitor-focus">${v.focus}</div>
                </button>
              `)}
        </div>
      <//>

      <${C} title="Runtime Notes" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Secondary runtime context</h2>
          <p class="monitor-subheadline">This stays below the triage queue so operators can scan first and drill later.</p>
        </div>
        <div class="overview-note-stack">
          <div class="overview-inline-note">
            Room ${(t==null?void 0:t.room)??"default"}${t!=null&&t.cluster?` · Cluster ${t.cluster}`:""}${t!=null&&t.project?` · Project ${t.project}`:""}
          </div>
          <div class="overview-inline-note">
            ${t!=null&&t.version?`Version ${t.version}`:"Version unavailable"} · Active agents ${Fc.value.length} · Total tasks ${n.length}
          </div>
          <div class="overview-inline-note">
            ${en.value?`Perpetual runtime ${en.value.running?"running":"stopped"}${en.value.goal?` · ${ct(en.value.goal,120)}`:""}`:"Perpetual runtime unavailable"}
          </div>
          <div class="overview-inline-note">
            Lodge ${(I=t==null?void 0:t.lodge)!=null&&I.enabled?"enabled":"disabled"} · Last tick ${((Dt=t==null?void 0:t.lodge)==null?void 0:Dt.last_tick_ago)??"never"} · Self heartbeats ${((Je=(le=t==null?void 0:t.lodge)==null?void 0:le.active_self_heartbeats)==null?void 0:Je.length)??0}${(Ve=t==null?void 0:t.lodge)!=null&&Ve.last_skip_reason?` · Skip ${t.lodge.last_skip_reason}`:""}
          </div>
          <div class="overview-inline-note">
            ${a.length>0?`Hot keepers: ${D.length} · Highest context ${Fd(Math.max(...a.map(v=>v.context_tokens??0)))}`:"No keepers registered"}
          </div>
        </div>
      <//>
    </div>`}
  `}const Wd="modulepreload",Gd=function(t){return"/dashboard/"+t},eo={},Jd=function(e,n,a){let i=Promise.resolve();if(n&&n.length>0){let r=function(_){return Promise.all(_.map(m=>Promise.resolve(m).then(d=>({status:"fulfilled",value:d}),d=>({status:"rejected",reason:d}))))};document.getElementsByTagName("link");const l=document.querySelector("meta[property=csp-nonce]"),p=(l==null?void 0:l.nonce)||(l==null?void 0:l.getAttribute("nonce"));i=r(n.map(_=>{if(_=Gd(_),_ in eo)return;eo[_]=!0;const m=_.endsWith(".css"),d=m?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${_}"]${d}`))return;const c=document.createElement("link");if(c.rel=m?"stylesheet":Wd,m||(c.as="script"),c.crossOrigin="",c.href=_,p&&c.setAttribute("nonce",p),document.head.appendChild(c),m)return new Promise((g,y)=>{c.addEventListener("load",g),c.addEventListener("error",()=>y(new Error(`Unable to preload CSS for ${_}`)))})}))}function o(r){const l=new Event("vite:preloadError",{cancelable:!0});if(l.payload=r,window.dispatchEvent(l),!l.defaultPrevented)throw r}return i.then(r=>{for(const l of r||[])l.status==="rejected"&&o(l.reason);return e().catch(o)})},or=f(null),Kt=f(null),ln=f(!1),ga=f(!1),_a=f(null),$a=f(null),Bs=f(null),ha=f(null),Ke=f("summary"),zn=f(null),Ws=f(!1),ya=f(null),rr=f(null),Gs=f(!1),ba=f(null),bi=f(null),Js=f(!1),ka=f(null),Ln=f(null),xa=f(!1),Pn=f(null),cn=f(null);let nn=null;function x(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function u(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function h(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Y(t){return typeof t=="boolean"?t:void 0}function pt(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Vd(){if(typeof window>"u")return;const e=new URLSearchParams(window.location.search).get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Qd(t){if(x(t))return{policy_class:u(t.policy_class),approval_class:u(t.approval_class),tool_allowlist:pt(t.tool_allowlist),model_allowlist:pt(t.model_allowlist),requires_human_for:pt(t.requires_human_for),autonomy_level:u(t.autonomy_level),escalation_timeout_sec:h(t.escalation_timeout_sec),kill_switch:Y(t.kill_switch),frozen:Y(t.frozen)}}function Yd(t){if(x(t))return{headcount_cap:h(t.headcount_cap),active_operation_cap:h(t.active_operation_cap),max_cost_usd:h(t.max_cost_usd),max_tokens:h(t.max_tokens)}}function ki(t){if(!x(t))return null;const e=u(t.unit_id),n=u(t.label),a=u(t.kind);return!e||!n||!a?null:{unit_id:e,label:n,kind:a,parent_unit_id:u(t.parent_unit_id)??null,leader_id:u(t.leader_id)??null,roster:pt(t.roster),capability_profile:pt(t.capability_profile),source:u(t.source),created_at:u(t.created_at),updated_at:u(t.updated_at),policy:Qd(t.policy),budget:Yd(t.budget)}}function lr(t){if(!x(t))return null;const e=ki(t.unit);return e?{unit:e,leader_status:u(t.leader_status),roster_total:h(t.roster_total),roster_live:h(t.roster_live),active_operation_count:h(t.active_operation_count),health:u(t.health),reasons:pt(t.reasons),children:Array.isArray(t.children)?t.children.map(lr).filter(n=>n!==null):[]}:null}function Xd(t){if(x(t))return{total_units:h(t.total_units),company_count:h(t.company_count),platoon_count:h(t.platoon_count),squad_count:h(t.squad_count),leaf_agent_unit_count:h(t.leaf_agent_unit_count),live_agent_count:h(t.live_agent_count),managed_unit_count:h(t.managed_unit_count),active_operation_count:h(t.active_operation_count)}}function cr(t){const e=x(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),source:u(e.source),summary:Xd(e.summary),units:Array.isArray(e.units)?e.units.map(lr).filter(n=>n!==null):[]}}function Zd(t){if(!x(t))return null;const e=u(t.kind),n=u(t.status);return!e||!n?null:{kind:e,chain_id:u(t.chain_id)??null,goal:u(t.goal)??null,run_id:u(t.run_id)??null,status:n,viewer_path:u(t.viewer_path)??null,last_sync_at:u(t.last_sync_at)??null}}function Wa(t){if(!x(t))return null;const e=u(t.operation_id),n=u(t.objective),a=u(t.assigned_unit_id),i=u(t.trace_id),o=u(t.status);return!e||!n||!a||!i||!o?null:{operation_id:e,objective:n,assigned_unit_id:a,autonomy_level:u(t.autonomy_level),policy_class:u(t.policy_class),budget_class:u(t.budget_class),detachment_session_id:u(t.detachment_session_id)??null,trace_id:i,checkpoint_ref:u(t.checkpoint_ref)??null,active_goal_ids:pt(t.active_goal_ids),note:u(t.note)??null,created_by:u(t.created_by),source:u(t.source),status:o,chain:Zd(t.chain),created_at:u(t.created_at),updated_at:u(t.updated_at)}}function tu(t){if(!x(t))return null;const e=Wa(t.operation);return e?{operation:e,assigned_unit_label:u(t.assigned_unit_label)}:null}function dr(t){const e=x(t)?t:{},n=x(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:h(n.total),active:h(n.active),paused:h(n.paused),managed:h(n.managed),projected:h(n.projected)}:void 0,operations:Array.isArray(e.operations)?e.operations.map(tu).filter(a=>a!==null):[]}}function ur(t){if(!x(t))return null;const e=u(t.detachment_id),n=u(t.operation_id),a=u(t.assigned_unit_id);return!e||!n||!a?null:{detachment_id:e,operation_id:n,assigned_unit_id:a,leader_id:u(t.leader_id)??null,roster:pt(t.roster),session_id:u(t.session_id)??null,checkpoint_ref:u(t.checkpoint_ref)??null,runtime_kind:u(t.runtime_kind)??null,runtime_ref:u(t.runtime_ref)??null,source:u(t.source),status:u(t.status),last_event_at:u(t.last_event_at)??null,last_progress_at:u(t.last_progress_at)??null,heartbeat_deadline:u(t.heartbeat_deadline)??null,created_at:u(t.created_at),updated_at:u(t.updated_at)}}function eu(t){if(!x(t))return null;const e=ur(t.detachment);return e?{detachment:e,assigned_unit_label:u(t.assigned_unit_label),operation:Wa(t.operation)}:null}function pr(t){const e=x(t)?t:{},n=x(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:h(n.total),active:h(n.active),projected:h(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(eu).filter(a=>a!==null):[]}}function nu(t){if(!x(t))return null;const e=u(t.decision_id),n=u(t.trace_id),a=u(t.requested_action),i=u(t.scope_type),o=u(t.scope_id);return!e||!n||!a||!i||!o?null:{decision_id:e,trace_id:n,requested_action:a,scope_type:i,scope_id:o,operation_id:u(t.operation_id)??null,target_unit_id:u(t.target_unit_id)??null,requested_by:u(t.requested_by),status:u(t.status),reason:u(t.reason)??null,source:u(t.source),detail:t.detail,created_at:u(t.created_at),decided_at:u(t.decided_at)??null,expires_at:u(t.expires_at)??null}}function mr(t){const e=x(t)?t:{},n=x(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:h(n.total),pending:h(n.pending),approved:h(n.approved),denied:h(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(nu).filter(a=>a!==null):[]}}function au(t){if(!x(t))return null;const e=ki(t.unit);return e?{unit:e,roster_total:h(t.roster_total),roster_live:h(t.roster_live),headcount_cap:h(t.headcount_cap),active_operations:h(t.active_operations),active_operation_cap:h(t.active_operation_cap),utilization:h(t.utilization)}:null}function su(t){const e=x(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(au).filter(n=>n!==null):[]}}function iu(t){if(!x(t))return null;const e=u(t.alert_id);return e?{alert_id:e,severity:u(t.severity),kind:u(t.kind),scope_type:u(t.scope_type),scope_id:u(t.scope_id),title:u(t.title),detail:u(t.detail),timestamp:u(t.timestamp)}:null}function vr(t){const e=x(t)?t:{},n=x(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:h(n.total),bad:h(n.bad),warn:h(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(iu).filter(a=>a!==null):[]}}function fr(t){if(!x(t))return null;const e=u(t.event_id),n=u(t.trace_id),a=u(t.event_type);return!e||!n||!a?null:{event_id:e,trace_id:n,event_type:a,operation_id:u(t.operation_id)??null,unit_id:u(t.unit_id)??null,actor:u(t.actor)??null,source:u(t.source),timestamp:u(t.timestamp),detail:t.detail}}function ou(t){const e=x(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),events:Array.isArray(e.events)?e.events.map(fr).filter(n=>n!==null):[]}}function ru(t){if(!x(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a}}function lu(t){if(!x(t))return null;const e=u(t.lane_id),n=u(t.label),a=u(t.kind),i=u(t.phase),o=u(t.motion_state),r=u(t.source_of_truth),l=u(t.movement_reason),p=u(t.current_step);if(!e||!n||!a||!i||!o||!r||!l||!p)return null;const _=x(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:a,present:Y(t.present)??!1,phase:i,motion_state:o,source_of_truth:r,last_movement_at:u(t.last_movement_at)??null,movement_reason:l,current_step:p,blockers:pt(t.blockers),counts:{operations:h(_.operations),detachments:h(_.detachments),workers:h(_.workers),approvals:h(_.approvals),alerts:h(_.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(ru).filter(m=>m!==null):[]}}function cu(t){if(!x(t))return null;const e=u(t.event_id),n=u(t.lane_id),a=u(t.kind),i=u(t.timestamp),o=u(t.title),r=u(t.detail),l=u(t.tone),p=u(t.source);return!e||!n||!a||!i||!o||!r||!l||!p?null:{event_id:e,lane_id:n,kind:a,timestamp:i,title:o,detail:r,tone:l,source:p}}function du(t){if(!x(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a,lane_ids:pt(t.lane_ids),count:h(t.count)??0}}function gr(t){if(!x(t))return;const e=x(t.overview)?t.overview:{},n=x(t.gaps)?t.gaps:{},a=x(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:u(t.generated_at),overview:{active_lanes:h(e.active_lanes),moving_lanes:h(e.moving_lanes),stalled_lanes:h(e.stalled_lanes),projected_lanes:h(e.projected_lanes),last_movement_at:u(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(lu).filter(i=>i!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(cu).filter(i=>i!==null):[],gaps:{count:h(n.count),items:Array.isArray(n.items)?n.items.map(du).filter(i=>i!==null):[]},recommended_next_action:a?{tool:u(a.tool)??"masc_operator_snapshot",label:u(a.label)??"Observe operator state",reason:u(a.reason)??"",lane_id:u(a.lane_id)??null}:void 0}}function uu(t){if(!x(t))return;const e=x(t.workers)?t.workers:{},n=Y(t.pass);return{status:u(t.status)??"missing",source:u(t.source)??"none",run_id:u(t.run_id)??null,captured_at:u(t.captured_at)??null,...n!==void 0?{pass:n}:{},...h(t.peak_hot_slots)!=null?{peak_hot_slots:h(t.peak_hot_slots)}:{},...h(t.ctx_per_slot)!=null?{ctx_per_slot:h(t.ctx_per_slot)}:{},workers:{expected:h(e.expected),joined:h(e.joined),current_task_bound:h(e.current_task_bound),fresh_heartbeats:h(e.fresh_heartbeats),done:h(e.done),final:h(e.final)},artifact_ref:u(t.artifact_ref)??null,missing_reason:u(t.missing_reason)??null}}function pu(t){const e=x(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),topology:cr(e.topology),operations:dr(e.operations),detachments:pr(e.detachments),alerts:vr(e.alerts),decisions:mr(e.decisions),capacity:su(e.capacity),traces:ou(e.traces),swarm_status:gr(e.swarm_status)}}function mu(t){const e=x(t)?t:{},n=cr(e.topology),a=dr(e.operations),i=pr(e.detachments),o=vr(e.alerts),r=mr(e.decisions);return{version:u(e.version),generated_at:u(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:a.version,generated_at:a.generated_at,summary:a.summary},detachments:{version:i.version,generated_at:i.generated_at,summary:i.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:gr(e.swarm_status),swarm_proof:uu(e.swarm_proof)}}function vu(t){return x(t)?{chain_id:u(t.chain_id)??null,started_at:h(t.started_at)??null,progress:h(t.progress)??null,elapsed_sec:h(t.elapsed_sec)??null}:null}function _r(t){if(!x(t))return null;const e=u(t.event);return e?{event:e,chain_id:u(t.chain_id)??null,timestamp:u(t.timestamp)??null,duration_ms:h(t.duration_ms)??null,message:u(t.message)??null,tokens:h(t.tokens)??null}:null}function fu(t){if(!x(t))return null;const e=Wa(t.operation);return e?{operation:e,runtime:vu(t.runtime),history:_r(t.history),mermaid:u(t.mermaid)??null,preview_run:$r(t.preview_run)}:null}function gu(t){const e=x(t)?t:{};return{status:u(e.status)??"disconnected",base_url:u(e.base_url)??null,message:u(e.message)??null}}function _u(t){const e=x(t)?t:{},n=x(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),connection:gu(e.connection),summary:n?{linked_operations:h(n.linked_operations),active_chains:h(n.active_chains),running_operations:h(n.running_operations),recent_failures:h(n.recent_failures),last_history_event_at:u(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(fu).filter(a=>a!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(_r).filter(a=>a!==null):[]}}function $u(t){if(!x(t))return null;const e=u(t.id);return e?{id:e,type:u(t.type),status:u(t.status),duration_ms:h(t.duration_ms)??null,error:u(t.error)??null}:null}function $r(t){if(!x(t))return null;const e=u(t.run_id),n=u(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:h(t.duration_ms),success:Y(t.success),mermaid:u(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map($u).filter(a=>a!==null):[]}:null}function hu(t){const e=x(t)?t:{};return{run:$r(e.run)}}function yu(t){if(!x(t))return null;const e=u(t.title),n=u(t.path);return!e||!n?null:{title:e,path:n}}function bu(t){if(!x(t))return null;const e=u(t.id),n=u(t.title),a=u(t.summary);return!e||!n||!a?null:{id:e,title:n,summary:a}}function ku(t){if(!x(t))return null;const e=u(t.id),n=u(t.title),a=u(t.tool),i=u(t.summary);return!e||!n||!a||!i?null:{id:e,title:n,tool:a,summary:i,success_signals:pt(t.success_signals),pitfalls:pt(t.pitfalls)}}function xu(t){if(!x(t))return null;const e=u(t.id),n=u(t.title),a=u(t.summary),i=u(t.when_to_use);return!e||!n||!a||!i?null:{id:e,title:n,summary:a,when_to_use:i,steps:Array.isArray(t.steps)?t.steps.map(ku).filter(o=>o!==null):[]}}function Su(t){if(!x(t))return null;const e=u(t.id),n=u(t.title),a=u(t.description);return!e||!n||!a?null:{id:e,title:n,description:a,tools:pt(t.tools)}}function Au(t){if(!x(t))return null;const e=u(t.id),n=u(t.title),a=u(t.symptom),i=u(t.why),o=u(t.fix_tool),r=u(t.fix_summary);return!e||!n||!a||!i||!o||!r?null:{id:e,title:n,symptom:a,why:i,fix_tool:o,fix_summary:r}}function wu(t){if(!x(t))return null;const e=u(t.id),n=u(t.title),a=u(t.path_id),i=u(t.transport);return!e||!n||!a||!i?null:{id:e,title:n,path_id:a,transport:i,request:t.request,response:t.response,notes:pt(t.notes)}}function Cu(t){const e=x(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(yu).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(bu).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(xu).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Su).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Au).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(wu).filter(n=>n!==null):[]}}function Tu(t){if(!x(t))return null;const e=u(t.id),n=u(t.title),a=u(t.status),i=u(t.detail),o=u(t.next_tool);return!e||!n||!a||!i||!o?null:{id:e,title:n,status:a,detail:i,next_tool:o}}function Nu(t){if(!x(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.title),i=u(t.detail),o=u(t.next_tool);return!e||!n||!a||!i||!o?null:{code:e,severity:n,title:a,detail:i,next_tool:o}}function Ru(t){if(!x(t))return null;const e=u(t.from),n=u(t.content),a=u(t.timestamp),i=h(t.seq);return!e||!n||!a||i==null?null:{seq:i,from:e,content:n,timestamp:a}}function Lu(t){if(!x(t))return null;const e=u(t.name),n=u(t.role),a=u(t.lane),i=u(t.status),o=u(t.claim_marker),r=u(t.done_marker),l=u(t.final_marker);if(!e||!n||!a||!i||!o||!r||!l)return null;const p=(()=>{if(!x(t.last_message))return null;const _=h(t.last_message.seq),m=u(t.last_message.content),d=u(t.last_message.timestamp);return _==null||!m||!d?null:{seq:_,content:m,timestamp:d}})();return{name:e,role:n,lane:a,joined:Y(t.joined)??!1,live_presence:Y(t.live_presence)??!1,completed:Y(t.completed)??!1,status:i,current_task:u(t.current_task)??null,bound_task_id:u(t.bound_task_id)??null,bound_task_title:u(t.bound_task_title)??null,bound_task_status:u(t.bound_task_status)??null,current_task_matches_run:Y(t.current_task_matches_run)??!1,squad_member:Y(t.squad_member)??!1,detachment_member:Y(t.detachment_member)??!1,last_seen:u(t.last_seen)??null,heartbeat_age_sec:h(t.heartbeat_age_sec)??null,heartbeat_fresh:Y(t.heartbeat_fresh)??!1,claim_marker_seen:Y(t.claim_marker_seen)??!1,done_marker_seen:Y(t.done_marker_seen)??!1,final_marker_seen:Y(t.final_marker_seen)??!1,claim_marker:o,done_marker:r,final_marker:l,last_message:p}}function Pu(t){if(!x(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!x(n))return null;const a=u(n.timestamp),i=h(n.active_slots);if(!a||i==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:a,active_slots:i,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:u(t.slot_url)??null,total_slots:h(t.total_slots),ctx_per_slot:h(t.ctx_per_slot),active_slots_now:h(t.active_slots_now),peak_active_slots:h(t.peak_active_slots),sample_count:h(t.sample_count),last_sample_at:u(t.last_sample_at)??null,timeline:e}}function Du(t){const e=x(t)?t:{},n=x(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),run_id:u(e.run_id),room_id:u(e.room_id),operation_id:u(e.operation_id)??null,recommended_next_tool:u(e.recommended_next_tool),summary:n?{expected_workers:h(n.expected_workers),joined_workers:h(n.joined_workers),live_workers:h(n.live_workers),squad_roster_size:h(n.squad_roster_size),detachment_roster_size:h(n.detachment_roster_size),current_task_bound:h(n.current_task_bound),fresh_heartbeats:h(n.fresh_heartbeats),claim_markers_seen:h(n.claim_markers_seen),done_markers_seen:h(n.done_markers_seen),final_markers_seen:h(n.final_markers_seen),completed_workers:h(n.completed_workers),peak_hot_slots:h(n.peak_hot_slots),hot_window_ok:Y(n.hot_window_ok),pass_hot_concurrency:Y(n.pass_hot_concurrency),pass_end_to_end:Y(n.pass_end_to_end),pending_decisions:h(n.pending_decisions),pass:Y(n.pass)}:void 0,provider:Pu(e.provider),operation:Wa(e.operation),squad:ki(e.squad),detachment:ur(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Lu).filter(a=>a!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Tu).filter(a=>a!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Nu).filter(a=>a!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Ru).filter(a=>a!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(fr).filter(a=>a!==null):[],truth_notes:pt(e.truth_notes)}}function xi(t){Ke.value=t,t!=="summary"&&Eu()}async function Si(){ln.value=!0,_a.value=null;try{const t=await Al();or.value=mu(t)}catch(t){_a.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{ln.value=!1}}function Ai(t){cn.value=t}async function wi(){ga.value=!0,$a.value=null;try{const t=await Sl();Kt.value=pu(t)}catch(t){$a.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{ga.value=!1}}async function Eu(){Kt.value||ga.value||await wi()}async function fe(){await Si(),Ke.value!=="summary"&&await wi()}async function $e(){var t;Js.value=!0,ka.value=null;try{const e=await wl(),n=_u(e);bi.value=n;const a=cn.value;n.operations.length===0?cn.value=null:(!a||!n.operations.some(i=>i.operation.operation_id===a))&&(cn.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){ka.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{Js.value=!1}}function Iu(){nn=null,Ln.value=null,xa.value=!1,Pn.value=null}async function Mu(t){nn=t,xa.value=!0,Pn.value=null;try{const e=await Cl(t);if(nn!==t)return;Ln.value=hu(e)}catch(e){if(nn!==t)return;Ln.value=null,Pn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{nn===t&&(xa.value=!1)}}async function Ou(){Ws.value=!0,ya.value=null;try{const t=await Tl();zn.value=Cu(t)}catch(t){ya.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Ws.value=!1}}async function hr(t=Vd()){Gs.value=!0,ba.value=null;try{const e=await Nl(t);rr.value=Du(e)}catch(e){ba.value=e instanceof Error?e.message:"Failed to load command-plane swarm view"}finally{Gs.value=!1}}async function se(t,e,n){Bs.value=t,ha.value=null;try{await Rl(e,n),await Si(),(Kt.value||Ke.value!=="summary")&&await wi(),await hr(),await $e()}catch(a){throw ha.value=a instanceof Error?a.message:"Failed to execute command-plane action",a}finally{Bs.value=null}}function zu(t){return se(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function qu(t){return se(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function ju(t){return se(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Fu(t={}){return se("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function Ku(t){return se(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Hu(t){return se(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Uu(t,e){return se(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Bu(t,e){return se(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}sd(()=>{Si()});function Wu(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Z(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function Gu(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Ju(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function G(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let no=!1,Vu=0,os=null;async function Qu(){os||(os=Jd(()=>import("./mermaid.core-DAhp__TD.js").then(e=>e.bE),[]).then(e=>e.default));const t=await os;return no||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),no=!0),t}function Xt(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function yr(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function Yu(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function br(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const kr=["operations","chains","topology","alerts","trace","control"],Xu=["chain_start","node_start","node_complete","chain_complete","chain_error"];function Zu(t){return!!t&&kr.includes(t)}function tp(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");return n&&e.set("agent",n),a&&e.set("token",a),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function ep(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function it(t){return Bs.value===t}function Ci(){return or.value}function np(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function ap(){if(typeof window>"u")return null;const e=new URLSearchParams(window.location.search).get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function sp(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function ip(t){return t.status==="claimed"||t.status==="in_progress"}function op(t){const e=zn.value;if(!e)return null;for(const n of e.golden_paths){const a=n.steps.find(i=>i.tool===t);if(a)return a}return null}function rs(t){var e;return((e=zn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function rp(t){const e=zn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(a=>n.has(a.id))}async function Zt(t){try{await t()}catch{}}function lp(){var r,l,p;const t=Ci(),e=bi.value,n=t==null?void 0:t.topology.summary,a=t==null?void 0:t.operations.summary,i=t==null?void 0:t.decisions.summary,o=t==null?void 0:t.alerts.summary;return s`
========
      <//>

      <${w} title="Keeper Pressure" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Long-running keepers under pressure</h2>
          <p class="monitor-subheadline">Only keepers with real pressure stay in the Overview. The full keeper census still lives in the Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${P.length===0?s`<div class="empty-state">No keeper pressure signals right now</div>`:P.slice(0,5).map(v=>{var L;return s`
                <${is}
                  key=${v.keeper.name}
                  tone=${v.tone}
                  title=${v.keeper.name}
                  subtitle=${(L=v.keeper.diagnostic)!=null&&L.health_state?`${v.note} · ${v.keeper.diagnostic.health_state}`:v.note}
                  meta=${[v.timestamp?`Heartbeat ${new Date(v.timestamp).toLocaleTimeString()}`:"No heartbeat",`Context ${typeof v.keeper.context_ratio=="number"?Math.round(v.keeper.context_ratio*100):0}%`,v.keeper.model?`Model ${v.keeper.model}`:"model n/a",v.keeper.diagnostic?`${Kd(v.keeper.diagnostic.quiet_reason)} · next ${Hd(v.keeper.diagnostic.next_action_path)} · reply ${v.keeper.diagnostic.last_reply_status}`:"Diagnostic unavailable"]}
                  focus=${v.focus}
                  onClick=${()=>fa(v.keeper)}
                />
              `})}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${w} title="Agent Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Agents with drift or aging load</h2>
          <p class="monitor-subheadline">This is the short list. Use the Agents tab when you need the full live monitor.</p>
        </div>
        <div class="monitor-list">
          ${T.length===0?s`<div class="empty-state">No agent drift or stale load right now</div>`:T.slice(0,5).map(v=>s`
                <button class="monitor-row ${v.tone}" onClick=${()=>Me(v.agent.name)}>
                  <div class="monitor-row-header">
                    <div class="monitor-row-title">
                      <div class="monitor-name-line">
                        <span class="monitor-title">${v.agent.name}</span>
                        ${v.agent.koreanName?s`<span class="monitor-sub">${v.agent.koreanName}</span>`:null}
                      </div>
                      <div class="monitor-note">${v.note}</div>
                    </div>
                    <${Lt} status=${v.agent.status} />
                    <span class="monitor-pill ${v.tone}">${v.dispatchable?"Ready":v.drift?"Drift":"Watch"}</span>
                  </div>
                  <div class="monitor-meta">
                    ${v.lastSignalAt?s`<span>Signal <${F} timestamp=${v.lastSignalAt} /></span>`:s`<span>No recent signal</span>`}
                    <span>${v.activeTaskCount>0?`${v.activeTaskCount} active tasks`:"No active tasks"}</span>
                    ${v.agent.model?s`<span>${v.agent.model}</span>`:null}
                  </div>
                  <div class="monitor-focus">${v.focus}</div>
                </button>
              `)}
        </div>
      <//>

      <${w} title="Runtime Notes" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Secondary runtime context</h2>
          <p class="monitor-subheadline">This stays below the triage queue so operators can scan first and drill later.</p>
        </div>
        <div class="overview-note-stack">
          <div class="overview-inline-note">
            Room ${(t==null?void 0:t.room)??"default"}${t!=null&&t.cluster?` · Cluster ${t.cluster}`:""}${t!=null&&t.project?` · Project ${t.project}`:""}
          </div>
          <div class="overview-inline-note">
            ${t!=null&&t.version?`Version ${t.version}`:"Version unavailable"} · Active agents ${Fc.value.length} · Total tasks ${n.length}
          </div>
          <div class="overview-inline-note">
            ${en.value?`Perpetual runtime ${en.value.running?"running":"stopped"}${en.value.goal?` · ${ct(en.value.goal,120)}`:""}`:"Perpetual runtime unavailable"}
          </div>
          <div class="overview-inline-note">
            Lodge ${(E=t==null?void 0:t.lodge)!=null&&E.enabled?"enabled":"disabled"} · Last tick ${((Et=t==null?void 0:t.lodge)==null?void 0:Et.last_tick_ago)??"never"} · Self heartbeats ${((Je=(le=t==null?void 0:t.lodge)==null?void 0:le.active_self_heartbeats)==null?void 0:Je.length)??0}${(Ve=t==null?void 0:t.lodge)!=null&&Ve.last_skip_reason?` · Skip ${t.lodge.last_skip_reason}`:""}
          </div>
          <div class="overview-inline-note">
            ${a.length>0?`Hot keepers: ${P.length} · Highest context ${Fd(Math.max(...a.map(v=>v.context_tokens??0)))}`:"No keepers registered"}
          </div>
        </div>
      <//>
    </div>`}
  `}const Wd="modulepreload",Gd=function(t){return"/dashboard/"+t},eo={},Jd=function(e,n,a){let i=Promise.resolve();if(n&&n.length>0){let r=function(_){return Promise.all(_.map(m=>Promise.resolve(m).then(d=>({status:"fulfilled",value:d}),d=>({status:"rejected",reason:d}))))};document.getElementsByTagName("link");const l=document.querySelector("meta[property=csp-nonce]"),p=(l==null?void 0:l.nonce)||(l==null?void 0:l.getAttribute("nonce"));i=r(n.map(_=>{if(_=Gd(_),_ in eo)return;eo[_]=!0;const m=_.endsWith(".css"),d=m?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${_}"]${d}`))return;const c=document.createElement("link");if(c.rel=m?"stylesheet":Wd,m||(c.as="script"),c.crossOrigin="",c.href=_,p&&c.setAttribute("nonce",p),document.head.appendChild(c),m)return new Promise((g,y)=>{c.addEventListener("load",g),c.addEventListener("error",()=>y(new Error(`Unable to preload CSS for ${_}`)))})}))}function o(r){const l=new Event("vite:preloadError",{cancelable:!0});if(l.payload=r,window.dispatchEvent(l),!l.defaultPrevented)throw r}return i.then(r=>{for(const l of r||[])l.status==="rejected"&&o(l.reason);return e().catch(o)})},or=f(null),Ht=f(null),ln=f(!1),ga=f(!1),_a=f(null),$a=f(null),Bs=f(null),ha=f(null),Ke=f("summary"),zn=f(null),Ws=f(!1),ya=f(null),rr=f(null),Gs=f(!1),ba=f(null),bi=f(null),Js=f(!1),ka=f(null),Ln=f(null),xa=f(!1),Pn=f(null),cn=f(null);let nn=null;function x(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function u(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function h(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function V(t){return typeof t=="boolean"?t:void 0}function pt(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Vd(){if(typeof window>"u")return;const e=new URLSearchParams(window.location.search).get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Qd(t){if(x(t))return{policy_class:u(t.policy_class),approval_class:u(t.approval_class),tool_allowlist:pt(t.tool_allowlist),model_allowlist:pt(t.model_allowlist),requires_human_for:pt(t.requires_human_for),autonomy_level:u(t.autonomy_level),escalation_timeout_sec:h(t.escalation_timeout_sec),kill_switch:V(t.kill_switch),frozen:V(t.frozen)}}function Yd(t){if(x(t))return{headcount_cap:h(t.headcount_cap),active_operation_cap:h(t.active_operation_cap),max_cost_usd:h(t.max_cost_usd),max_tokens:h(t.max_tokens)}}function ki(t){if(!x(t))return null;const e=u(t.unit_id),n=u(t.label),a=u(t.kind);return!e||!n||!a?null:{unit_id:e,label:n,kind:a,parent_unit_id:u(t.parent_unit_id)??null,leader_id:u(t.leader_id)??null,roster:pt(t.roster),capability_profile:pt(t.capability_profile),source:u(t.source),created_at:u(t.created_at),updated_at:u(t.updated_at),policy:Qd(t.policy),budget:Yd(t.budget)}}function lr(t){if(!x(t))return null;const e=ki(t.unit);return e?{unit:e,leader_status:u(t.leader_status),roster_total:h(t.roster_total),roster_live:h(t.roster_live),active_operation_count:h(t.active_operation_count),health:u(t.health),reasons:pt(t.reasons),children:Array.isArray(t.children)?t.children.map(lr).filter(n=>n!==null):[]}:null}function Xd(t){if(x(t))return{total_units:h(t.total_units),company_count:h(t.company_count),platoon_count:h(t.platoon_count),squad_count:h(t.squad_count),leaf_agent_unit_count:h(t.leaf_agent_unit_count),live_agent_count:h(t.live_agent_count),managed_unit_count:h(t.managed_unit_count),active_operation_count:h(t.active_operation_count)}}function cr(t){const e=x(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),source:u(e.source),summary:Xd(e.summary),units:Array.isArray(e.units)?e.units.map(lr).filter(n=>n!==null):[]}}function Zd(t){if(!x(t))return null;const e=u(t.kind),n=u(t.status);return!e||!n?null:{kind:e,chain_id:u(t.chain_id)??null,goal:u(t.goal)??null,run_id:u(t.run_id)??null,status:n,viewer_path:u(t.viewer_path)??null,last_sync_at:u(t.last_sync_at)??null}}function Wa(t){if(!x(t))return null;const e=u(t.operation_id),n=u(t.objective),a=u(t.assigned_unit_id),i=u(t.trace_id),o=u(t.status);return!e||!n||!a||!i||!o?null:{operation_id:e,objective:n,assigned_unit_id:a,autonomy_level:u(t.autonomy_level),policy_class:u(t.policy_class),budget_class:u(t.budget_class),detachment_session_id:u(t.detachment_session_id)??null,trace_id:i,checkpoint_ref:u(t.checkpoint_ref)??null,active_goal_ids:pt(t.active_goal_ids),note:u(t.note)??null,created_by:u(t.created_by),source:u(t.source),status:o,chain:Zd(t.chain),created_at:u(t.created_at),updated_at:u(t.updated_at)}}function tu(t){if(!x(t))return null;const e=Wa(t.operation);return e?{operation:e,assigned_unit_label:u(t.assigned_unit_label)}:null}function dr(t){const e=x(t)?t:{},n=x(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:h(n.total),active:h(n.active),paused:h(n.paused),managed:h(n.managed),projected:h(n.projected)}:void 0,operations:Array.isArray(e.operations)?e.operations.map(tu).filter(a=>a!==null):[]}}function ur(t){if(!x(t))return null;const e=u(t.detachment_id),n=u(t.operation_id),a=u(t.assigned_unit_id);return!e||!n||!a?null:{detachment_id:e,operation_id:n,assigned_unit_id:a,leader_id:u(t.leader_id)??null,roster:pt(t.roster),session_id:u(t.session_id)??null,checkpoint_ref:u(t.checkpoint_ref)??null,runtime_kind:u(t.runtime_kind)??null,runtime_ref:u(t.runtime_ref)??null,source:u(t.source),status:u(t.status),last_event_at:u(t.last_event_at)??null,last_progress_at:u(t.last_progress_at)??null,heartbeat_deadline:u(t.heartbeat_deadline)??null,created_at:u(t.created_at),updated_at:u(t.updated_at)}}function eu(t){if(!x(t))return null;const e=ur(t.detachment);return e?{detachment:e,assigned_unit_label:u(t.assigned_unit_label),operation:Wa(t.operation)}:null}function pr(t){const e=x(t)?t:{},n=x(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:h(n.total),active:h(n.active),projected:h(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(eu).filter(a=>a!==null):[]}}function nu(t){if(!x(t))return null;const e=u(t.decision_id),n=u(t.trace_id),a=u(t.requested_action),i=u(t.scope_type),o=u(t.scope_id);return!e||!n||!a||!i||!o?null:{decision_id:e,trace_id:n,requested_action:a,scope_type:i,scope_id:o,operation_id:u(t.operation_id)??null,target_unit_id:u(t.target_unit_id)??null,requested_by:u(t.requested_by),status:u(t.status),reason:u(t.reason)??null,source:u(t.source),detail:t.detail,created_at:u(t.created_at),decided_at:u(t.decided_at)??null,expires_at:u(t.expires_at)??null}}function mr(t){const e=x(t)?t:{},n=x(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:h(n.total),pending:h(n.pending),approved:h(n.approved),denied:h(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(nu).filter(a=>a!==null):[]}}function au(t){if(!x(t))return null;const e=ki(t.unit);return e?{unit:e,roster_total:h(t.roster_total),roster_live:h(t.roster_live),headcount_cap:h(t.headcount_cap),active_operations:h(t.active_operations),active_operation_cap:h(t.active_operation_cap),utilization:h(t.utilization)}:null}function su(t){const e=x(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(au).filter(n=>n!==null):[]}}function iu(t){if(!x(t))return null;const e=u(t.alert_id);return e?{alert_id:e,severity:u(t.severity),kind:u(t.kind),scope_type:u(t.scope_type),scope_id:u(t.scope_id),title:u(t.title),detail:u(t.detail),timestamp:u(t.timestamp)}:null}function vr(t){const e=x(t)?t:{},n=x(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:h(n.total),bad:h(n.bad),warn:h(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(iu).filter(a=>a!==null):[]}}function fr(t){if(!x(t))return null;const e=u(t.event_id),n=u(t.trace_id),a=u(t.event_type);return!e||!n||!a?null:{event_id:e,trace_id:n,event_type:a,operation_id:u(t.operation_id)??null,unit_id:u(t.unit_id)??null,actor:u(t.actor)??null,source:u(t.source),timestamp:u(t.timestamp),detail:t.detail}}function ou(t){const e=x(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),events:Array.isArray(e.events)?e.events.map(fr).filter(n=>n!==null):[]}}function ru(t){if(!x(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a}}function lu(t){if(!x(t))return null;const e=u(t.lane_id),n=u(t.label),a=u(t.kind),i=u(t.phase),o=u(t.motion_state),r=u(t.source_of_truth),l=u(t.movement_reason),p=u(t.current_step);if(!e||!n||!a||!i||!o||!r||!l||!p)return null;const _=x(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:a,present:V(t.present)??!1,phase:i,motion_state:o,source_of_truth:r,last_movement_at:u(t.last_movement_at)??null,movement_reason:l,current_step:p,blockers:pt(t.blockers),counts:{operations:h(_.operations),detachments:h(_.detachments),workers:h(_.workers),approvals:h(_.approvals),alerts:h(_.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(ru).filter(m=>m!==null):[]}}function cu(t){if(!x(t))return null;const e=u(t.event_id),n=u(t.lane_id),a=u(t.kind),i=u(t.timestamp),o=u(t.title),r=u(t.detail),l=u(t.tone),p=u(t.source);return!e||!n||!a||!i||!o||!r||!l||!p?null:{event_id:e,lane_id:n,kind:a,timestamp:i,title:o,detail:r,tone:l,source:p}}function du(t){if(!x(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a,lane_ids:pt(t.lane_ids),count:h(t.count)??0}}function gr(t){if(!x(t))return;const e=x(t.overview)?t.overview:{},n=x(t.gaps)?t.gaps:{},a=x(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:u(t.generated_at),overview:{active_lanes:h(e.active_lanes),moving_lanes:h(e.moving_lanes),stalled_lanes:h(e.stalled_lanes),projected_lanes:h(e.projected_lanes),last_movement_at:u(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(lu).filter(i=>i!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(cu).filter(i=>i!==null):[],gaps:{count:h(n.count),items:Array.isArray(n.items)?n.items.map(du).filter(i=>i!==null):[]},recommended_next_action:a?{tool:u(a.tool)??"masc_operator_snapshot",label:u(a.label)??"Observe operator state",reason:u(a.reason)??"",lane_id:u(a.lane_id)??null}:void 0}}function uu(t){if(!x(t))return;const e=x(t.workers)?t.workers:{},n=V(t.pass);return{status:u(t.status)??"missing",source:u(t.source)??"none",run_id:u(t.run_id)??null,captured_at:u(t.captured_at)??null,...n!==void 0?{pass:n}:{},...h(t.peak_hot_slots)!=null?{peak_hot_slots:h(t.peak_hot_slots)}:{},...h(t.ctx_per_slot)!=null?{ctx_per_slot:h(t.ctx_per_slot)}:{},workers:{expected:h(e.expected),joined:h(e.joined),current_task_bound:h(e.current_task_bound),fresh_heartbeats:h(e.fresh_heartbeats),done:h(e.done),final:h(e.final)},artifact_ref:u(t.artifact_ref)??null,missing_reason:u(t.missing_reason)??null}}function pu(t){const e=x(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),topology:cr(e.topology),operations:dr(e.operations),detachments:pr(e.detachments),alerts:vr(e.alerts),decisions:mr(e.decisions),capacity:su(e.capacity),traces:ou(e.traces),swarm_status:gr(e.swarm_status)}}function mu(t){const e=x(t)?t:{},n=cr(e.topology),a=dr(e.operations),i=pr(e.detachments),o=vr(e.alerts),r=mr(e.decisions);return{version:u(e.version),generated_at:u(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:a.version,generated_at:a.generated_at,summary:a.summary},detachments:{version:i.version,generated_at:i.generated_at,summary:i.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:gr(e.swarm_status),swarm_proof:uu(e.swarm_proof)}}function vu(t){return x(t)?{chain_id:u(t.chain_id)??null,started_at:h(t.started_at)??null,progress:h(t.progress)??null,elapsed_sec:h(t.elapsed_sec)??null}:null}function _r(t){if(!x(t))return null;const e=u(t.event);return e?{event:e,chain_id:u(t.chain_id)??null,timestamp:u(t.timestamp)??null,duration_ms:h(t.duration_ms)??null,message:u(t.message)??null,tokens:h(t.tokens)??null}:null}function fu(t){if(!x(t))return null;const e=Wa(t.operation);return e?{operation:e,runtime:vu(t.runtime),history:_r(t.history),mermaid:u(t.mermaid)??null,preview_run:$r(t.preview_run)}:null}function gu(t){const e=x(t)?t:{};return{status:u(e.status)??"disconnected",base_url:u(e.base_url)??null,message:u(e.message)??null}}function _u(t){const e=x(t)?t:{},n=x(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),connection:gu(e.connection),summary:n?{linked_operations:h(n.linked_operations),active_chains:h(n.active_chains),running_operations:h(n.running_operations),recent_failures:h(n.recent_failures),last_history_event_at:u(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(fu).filter(a=>a!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(_r).filter(a=>a!==null):[]}}function $u(t){if(!x(t))return null;const e=u(t.id);return e?{id:e,type:u(t.type),status:u(t.status),duration_ms:h(t.duration_ms)??null,error:u(t.error)??null}:null}function $r(t){if(!x(t))return null;const e=u(t.run_id),n=u(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:h(t.duration_ms),success:V(t.success),mermaid:u(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map($u).filter(a=>a!==null):[]}:null}function hu(t){const e=x(t)?t:{};return{run:$r(e.run)}}function yu(t){if(!x(t))return null;const e=u(t.title),n=u(t.path);return!e||!n?null:{title:e,path:n}}function bu(t){if(!x(t))return null;const e=u(t.id),n=u(t.title),a=u(t.summary);return!e||!n||!a?null:{id:e,title:n,summary:a}}function ku(t){if(!x(t))return null;const e=u(t.id),n=u(t.title),a=u(t.tool),i=u(t.summary);return!e||!n||!a||!i?null:{id:e,title:n,tool:a,summary:i,success_signals:pt(t.success_signals),pitfalls:pt(t.pitfalls)}}function xu(t){if(!x(t))return null;const e=u(t.id),n=u(t.title),a=u(t.summary),i=u(t.when_to_use);return!e||!n||!a||!i?null:{id:e,title:n,summary:a,when_to_use:i,steps:Array.isArray(t.steps)?t.steps.map(ku).filter(o=>o!==null):[]}}function Su(t){if(!x(t))return null;const e=u(t.id),n=u(t.title),a=u(t.description);return!e||!n||!a?null:{id:e,title:n,description:a,tools:pt(t.tools)}}function Au(t){if(!x(t))return null;const e=u(t.id),n=u(t.title),a=u(t.symptom),i=u(t.why),o=u(t.fix_tool),r=u(t.fix_summary);return!e||!n||!a||!i||!o||!r?null:{id:e,title:n,symptom:a,why:i,fix_tool:o,fix_summary:r}}function Cu(t){if(!x(t))return null;const e=u(t.id),n=u(t.title),a=u(t.path_id),i=u(t.transport);return!e||!n||!a||!i?null:{id:e,title:n,path_id:a,transport:i,request:t.request,response:t.response,notes:pt(t.notes)}}function wu(t){const e=x(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(yu).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(bu).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(xu).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Su).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Au).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Cu).filter(n=>n!==null):[]}}function Tu(t){if(!x(t))return null;const e=u(t.id),n=u(t.title),a=u(t.status),i=u(t.detail),o=u(t.next_tool);return!e||!n||!a||!i||!o?null:{id:e,title:n,status:a,detail:i,next_tool:o}}function Nu(t){if(!x(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.title),i=u(t.detail),o=u(t.next_tool);return!e||!n||!a||!i||!o?null:{code:e,severity:n,title:a,detail:i,next_tool:o}}function Ru(t){if(!x(t))return null;const e=u(t.from),n=u(t.content),a=u(t.timestamp),i=h(t.seq);return!e||!n||!a||i==null?null:{seq:i,from:e,content:n,timestamp:a}}function Lu(t){if(!x(t))return null;const e=u(t.name),n=u(t.role),a=u(t.lane),i=u(t.status),o=u(t.claim_marker),r=u(t.done_marker),l=u(t.final_marker);if(!e||!n||!a||!i||!o||!r||!l)return null;const p=(()=>{if(!x(t.last_message))return null;const _=h(t.last_message.seq),m=u(t.last_message.content),d=u(t.last_message.timestamp);return _==null||!m||!d?null:{seq:_,content:m,timestamp:d}})();return{name:e,role:n,lane:a,joined:V(t.joined)??!1,live_presence:V(t.live_presence)??!1,completed:V(t.completed)??!1,status:i,current_task:u(t.current_task)??null,bound_task_id:u(t.bound_task_id)??null,bound_task_title:u(t.bound_task_title)??null,bound_task_status:u(t.bound_task_status)??null,current_task_matches_run:V(t.current_task_matches_run)??!1,squad_member:V(t.squad_member)??!1,detachment_member:V(t.detachment_member)??!1,last_seen:u(t.last_seen)??null,heartbeat_age_sec:h(t.heartbeat_age_sec)??null,heartbeat_fresh:V(t.heartbeat_fresh)??!1,claim_marker_seen:V(t.claim_marker_seen)??!1,done_marker_seen:V(t.done_marker_seen)??!1,final_marker_seen:V(t.final_marker_seen)??!1,claim_marker:o,done_marker:r,final_marker:l,last_message:p}}function Pu(t){if(!x(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!x(n))return null;const a=u(n.timestamp),i=h(n.active_slots);if(!a||i==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:a,active_slots:i,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:u(t.slot_url)??null,provider_base_url:u(t.provider_base_url)??null,provider_reachable:V(t.provider_reachable)??null,provider_status_code:h(t.provider_status_code)??null,provider_model_id:u(t.provider_model_id)??null,actual_model_id:u(t.actual_model_id)??null,expected_slots:h(t.expected_slots),actual_slots:h(t.actual_slots),expected_ctx:h(t.expected_ctx),actual_ctx:h(t.actual_ctx),slot_reachable:V(t.slot_reachable)??null,slot_status_code:h(t.slot_status_code)??null,runtime_blocker:u(t.runtime_blocker)??null,detail:u(t.detail)??null,checked_at:u(t.checked_at)??null,total_slots:h(t.total_slots),ctx_per_slot:h(t.ctx_per_slot),active_slots_now:h(t.active_slots_now),peak_active_slots:h(t.peak_active_slots),sample_count:h(t.sample_count),last_sample_at:u(t.last_sample_at)??null,timeline:e}}function Du(t){const e=x(t)?t:{},n=x(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),run_id:u(e.run_id),room_id:u(e.room_id),operation_id:u(e.operation_id)??null,recommended_next_tool:u(e.recommended_next_tool),summary:n?{expected_workers:h(n.expected_workers),joined_workers:h(n.joined_workers),live_workers:h(n.live_workers),squad_roster_size:h(n.squad_roster_size),detachment_roster_size:h(n.detachment_roster_size),current_task_bound:h(n.current_task_bound),fresh_heartbeats:h(n.fresh_heartbeats),claim_markers_seen:h(n.claim_markers_seen),done_markers_seen:h(n.done_markers_seen),final_markers_seen:h(n.final_markers_seen),completed_workers:h(n.completed_workers),peak_hot_slots:h(n.peak_hot_slots),hot_window_ok:V(n.hot_window_ok),pass_hot_concurrency:V(n.pass_hot_concurrency),pass_end_to_end:V(n.pass_end_to_end),pending_decisions:h(n.pending_decisions),pass:V(n.pass)}:void 0,provider:Pu(e.provider),operation:Wa(e.operation),squad:ki(e.squad),detachment:ur(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Lu).filter(a=>a!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Tu).filter(a=>a!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Nu).filter(a=>a!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Ru).filter(a=>a!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(fr).filter(a=>a!==null):[],truth_notes:pt(e.truth_notes)}}function xi(t){Ke.value=t,t!=="summary"&&Eu()}async function Si(){ln.value=!0,_a.value=null;try{const t=await Al();or.value=mu(t)}catch(t){_a.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{ln.value=!1}}function Ai(t){cn.value=t}async function Ci(){ga.value=!0,$a.value=null;try{const t=await Sl();Ht.value=pu(t)}catch(t){$a.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{ga.value=!1}}async function Eu(){Ht.value||ga.value||await Ci()}async function fe(){await Si(),Ke.value!=="summary"&&await Ci()}async function $e(){var t;Js.value=!0,ka.value=null;try{const e=await Cl(),n=_u(e);bi.value=n;const a=cn.value;n.operations.length===0?cn.value=null:(!a||!n.operations.some(i=>i.operation.operation_id===a))&&(cn.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){ka.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{Js.value=!1}}function Iu(){nn=null,Ln.value=null,xa.value=!1,Pn.value=null}async function Mu(t){nn=t,xa.value=!0,Pn.value=null;try{const e=await wl(t);if(nn!==t)return;Ln.value=hu(e)}catch(e){if(nn!==t)return;Ln.value=null,Pn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{nn===t&&(xa.value=!1)}}async function Ou(){Ws.value=!0,ya.value=null;try{const t=await Tl();zn.value=wu(t)}catch(t){ya.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Ws.value=!1}}async function hr(t=Vd()){Gs.value=!0,ba.value=null;try{const e=await Nl(t);rr.value=Du(e)}catch(e){ba.value=e instanceof Error?e.message:"Failed to load command-plane swarm view"}finally{Gs.value=!1}}async function ie(t,e,n){Bs.value=t,ha.value=null;try{await Rl(e,n),await Si(),(Ht.value||Ke.value!=="summary")&&await Ci(),await hr(),await $e()}catch(a){throw ha.value=a instanceof Error?a.message:"Failed to execute command-plane action",a}finally{Bs.value=null}}function zu(t){return ie(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function qu(t){return ie(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function ju(t){return ie(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Fu(t={}){return ie("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function Ku(t){return ie(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Hu(t){return ie(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Uu(t,e){return ie(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Bu(t,e){return ie(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}sd(()=>{Si()});function Wu(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function tt(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function Gu(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Ju(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function J(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let no=!1,Vu=0,os=null;async function Qu(){os||(os=Jd(()=>import("./mermaid.core-CpJLnY4a.js").then(e=>e.bE),[]).then(e=>e.default));const t=await os;return no||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),no=!0),t}function Zt(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function yr(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function Yu(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function br(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const kr=["operations","chains","topology","alerts","trace","control"],Xu=["chain_start","node_start","node_complete","chain_complete","chain_error"];function Zu(t){return!!t&&kr.includes(t)}function tp(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");return n&&e.set("agent",n),a&&e.set("token",a),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function ep(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function it(t){return Bs.value===t}function wi(){return or.value}function np(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function ap(){if(typeof window>"u")return null;const e=new URLSearchParams(window.location.search).get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function sp(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function ip(t){return t.status==="claimed"||t.status==="in_progress"}function op(t){const e=zn.value;if(!e)return null;for(const n of e.golden_paths){const a=n.steps.find(i=>i.tool===t);if(a)return a}return null}function rs(t){var e;return((e=zn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function rp(t){const e=zn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(a=>n.has(a.id))}async function te(t){try{await t()}catch{}}function lp(){var r,l,p;const t=wi(),e=bi.value,n=t==null?void 0:t.topology.summary,a=t==null?void 0:t.operations.summary,i=t==null?void 0:t.decisions.summary,o=t==null?void 0:t.alerts.summary;return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>Units</span><strong>${(n==null?void 0:n.total_units)??0}</strong><small>${(n==null?void 0:n.managed_unit_count)??0} managed</small></div>
      <div class="monitor-stat-card"><span>Ops</span><strong>${(a==null?void 0:a.active)??0}</strong><small>${((c=t==null?void 0:t.detachments.summary)==null?void 0:c.active)??0} detachments</small></div>
      <div class="monitor-stat-card"><span>Approvals</span><strong>${(o==null?void 0:o.pending)??0}</strong><small>${(o==null?void 0:o.total)??0} tracked</small></div>
      <div class="monitor-stat-card"><span>Alerts</span><strong>${(r==null?void 0:r.bad)??0}</strong><small>${(r==null?void 0:r.warn)??0} warn</small></div>
      <div class="monitor-stat-card"><span>Chains</span><strong>${((y=e==null?void 0:e.summary)==null?void 0:y.active_chains)??0}</strong><small>${((S=e==null?void 0:e.summary)==null?void 0:S.linked_operations)??0} linked</small></div>
      <div class="monitor-stat-card"><span>Routing</span><strong>${($==null?void 0:$.best_first_operations)??0}</strong><small>${(l==null?void 0:l.tone)??"n/a"} · score ${((T=$==null?void 0:$.avg_best_score)==null?void 0:T.toFixed(1))??"0.0"}</small></div>
      <div class="monitor-stat-card"><span>Microarch</span><strong>${(p==null?void 0:p.pending_ops)??0}</strong><small>${(m==null?void 0:m.l1_hit_rate)!=null?`${Ni(m.l1_hit_rate)} L1 hit`:"no cache data"} · ${(p==null?void 0:p.tone)??"n/a"}</small></div>
    </div>
  `}function pp(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function mp({lane:t}){const e=t.counts??{},n=pp(t);return s`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.label}</strong>
          <div class="command-card-sub">${t.source_of_truth}</div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${J(n)}">${t.phase}</span>
          <span class="command-chip ${J(n)}">${t.motion_state}</span>
          <span class="command-chip">${tt(t.last_movement_at)}</span>
        </div>
      </div>
      <div class="command-card-grid">
        <span>Movement</span><span>${t.movement_reason}</span>
        <span>Step</span><span>${t.current_step}</span>
        <span>Counts</span><span>${e.operations??0} ops · ${e.detachments??0} dets · ${e.workers??0} workers · ${e.approvals??0} approvals · ${e.alerts??0} alerts</span>
      </div>
      ${t.blockers.length>0?s`<div class="command-card-foot">Blockers: ${t.blockers.join(" · ")}</div>`:null}
      ${t.hard_flags.length>0?s`
            <div class="command-tag-row">
              ${t.hard_flags.map(a=>s`<span class="command-tag ${J(a.severity)}">${a.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function vp({event:t}){return s`
    <div class="command-trace-row">
      <div class="command-trace-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${J(t.tone)}">${t.lane_id}</span>
        <span class="command-chip">${t.kind}</span>
        <span class="command-chip">${tt(t.timestamp)}</span>
      </div>
      <div class="command-card-sub">${t.source}</div>
      <div class="command-card-foot">${t.detail}</div>
    </div>
  `}function fp({gap:t}){return s`
    <div class="command-guide-inline">
      <div class="command-guide-head">
        <strong>${t.code}</strong>
        <span class="command-chip ${J(t.severity)}">${t.count}</span>
      </div>
      <p>${t.summary}</p>
      ${t.lane_ids.length>0?s`<div class="command-tag-row">${t.lane_ids.map(e=>s`<span class="command-tag">${e}</span>`)}</div>`:null}
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function _p({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return s`
    <div class="command-guide-card ${G(e)}">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function mp({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return s`
    <div class="command-guide-card ${G(e)}">
========
  `}function mp({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return s`
    <div class="command-guide-card ${J(e)}">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      <div class="command-guide-head">
        <strong>Hot Proof</strong>
        <span class="command-chip ${J(e)}">${(t==null?void 0:t.status)??"missing"}</span>
      </div>
      ${t?s`
            <div class="command-card-grid">
              <span>Source</span><span>${t.source}</span>
              <span>Run</span><span>${t.run_id??"n/a"}</span>
              <span>Captured</span><span>${tt(t.captured_at)}</span>
              <span>Pass</span><span>${t.pass==null?"n/a":t.pass?"yes":"no"}</span>
              <span>Peak Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>Workers</span><span>${t.workers.expected??"n/a"} expected · ${t.workers.done??"n/a"} done · ${t.workers.final??"n/a"} final</span>
            </div>
            ${t.artifact_ref?s`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?s`<p>${t.missing_reason}</p>`:null}
          `:s`<p>No swarm proof is available yet.</p>`}
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function gp(){const t=Ri(),e=t==null?void 0:t.swarm_status,n=t==null?void 0:t.swarm_proof,a=(e==null?void 0:e.lanes.filter(p=>p.present))??[],i=(e==null?void 0:e.gaps.items)??[],o=(e==null?void 0:e.timeline.slice(0,6))??[],r=e==null?void 0:e.overview,l=e==null?void 0:e.recommended_next_action;return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function vp(){const t=Ci(),e=t==null?void 0:t.swarm_status,n=t==null?void 0:t.swarm_proof,a=(e==null?void 0:e.lanes.filter(p=>p.present))??[],i=(e==null?void 0:e.gaps.items)??[],o=(e==null?void 0:e.timeline.slice(0,6))??[],r=e==null?void 0:e.overview,l=e==null?void 0:e.recommended_next_action;return s`
========
  `}function vp(){const t=wi(),e=t==null?void 0:t.swarm_status,n=t==null?void 0:t.swarm_proof,a=(e==null?void 0:e.lanes.filter(p=>p.present))??[],i=(e==null?void 0:e.gaps.items)??[],o=(e==null?void 0:e.timeline.slice(0,6))??[],r=e==null?void 0:e.overview,l=e==null?void 0:e.recommended_next_action;return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <section class="card command-section">
      <div class="card-title">Swarm</div>
      ${e?s`
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>Active Lanes</span><strong>${(r==null?void 0:r.active_lanes)??0}</strong><small>${(r==null?void 0:r.moving_lanes)??0} moving</small></div>
              <div class="monitor-stat-card"><span>Stalled</span><strong>${(r==null?void 0:r.stalled_lanes)??0}</strong><small>${(r==null?void 0:r.projected_lanes)??0} projected</small></div>
              <div class="monitor-stat-card"><span>Last Movement</span><strong>${tt(r==null?void 0:r.last_movement_at)}</strong><small>${e.generated_at?`snapshot ${tt(e.generated_at)}`:"snapshot now"}</small></div>
              <div class="monitor-stat-card"><span>Next Action</span><strong>${(l==null?void 0:l.label)??"Observe operator state"}</strong><small>${(l==null?void 0:l.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            <div class="command-swarm-layout">
              <div class="command-card-stack">
                ${a.length>0?a.map(p=>s`<${mp} lane=${p} />`):s`<div class="empty-state">No active swarm lanes.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight">
                  <div class="command-guide-head">
                    <strong>${(l==null?void 0:l.label)??"Observe operator state"}</strong>
                    <span class="command-chip">${(l==null?void 0:l.lane_id)??"global"}</span>
                  </div>
                  <p>${(l==null?void 0:l.reason)??"No active swarm lane is visible yet."}</p>
                  <div class="command-card-foot">${(l==null?void 0:l.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${_p} proof=${n} />

                <div class="command-guide-card ${i.length>0?"warn":"ok"}">
                  <div class="command-guide-head">
                    <strong>Hard Gaps</strong>
                    <span class="command-chip ${J(i.some(p=>p.severity==="bad")?"bad":i.length>0?"warn":"ok")}">${i.length}</span>
                  </div>
                  ${i.length>0?s`<div class="command-card-stack">${i.slice(0,4).map(p=>s`<${fp} gap=${p} />`)}</div>`:s`<p>No hard gaps are currently visible.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>Movement Timeline</strong>
                    <span class="command-chip">${o.length}</span>
                  </div>
                  ${o.length>0?s`<div class="command-card-stack">${o.map(p=>s`<${vp} event=${p} />`)}</div>`:s`<p>No recent movement events are attached yet.</p>`}
                </div>
              </div>
            </div>
          `:s`<div class="empty-state">Swarm status is unavailable.</div>`}
    </section>
  `}function $p(){return s`
    <div class="command-surface-tabs">
      ${Sr.map(t=>s`
        <button
          class="command-surface-tab ${Ke.value===t?"active":""}"
          onClick=${()=>Ai(t)}
        >
          ${t}
        </button>
      `)}
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function hp(){var At,wt,W,nt,x,Pt,Jt,oe,re;const t=Ri(),e=Kt.value,n=ae.value,a=ip(),i=a?xt.value.find(I=>I.name===a)??null:null,o=a?$t.value.filter(I=>I.assignee===a&&lp(I)):[],r=((At=t==null?void 0:t.operations.summary)==null?void 0:At.active)??0,l=((wt=t==null?void 0:t.detachments.summary)==null?void 0:wt.total)??0,p=((W=t==null?void 0:t.decisions.summary)==null?void 0:W.pending)??0,$=e==null?void 0:e.detachments.detachments.find(I=>{const Dt=I.detachment.heartbeat_deadline,le=Dt?Date.parse(Dt):Number.NaN;return I.detachment.status==="stalled"||!Number.isNaN(le)&&le<=Date.now()}),m=e==null?void 0:e.alerts.alerts.find(I=>I.severity==="bad"),d=!!(n!=null&&n.room||n!=null&&n.project),v=(i==null?void 0:i.current_task)??null,c=rp(i==null?void 0:i.last_seen),y=c!=null?c<=120:null,S=[d?{title:"Room readiness",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room readiness",tone:"bad",detail:"No room snapshot yet. Set room to repo root before joining.",tool:"masc_set_room"},a?i?o.length===0?{title:"Task readiness",tone:"warn",detail:`${a} has no claimed task. Claim one or create one first.`,tool:$t.value.length>0?"masc_claim":"masc_add_task"}:v?y===!1?{title:"Task readiness",tone:"warn",detail:`${a} current_task=${v}, but heartbeat is stale (${c}s).`,tool:"masc_heartbeat"}:{title:"Task readiness",tone:"ok",detail:`${a} current_task=${v}${c!=null?` · last seen ${c}s ago`:""}`,tool:"masc_plan_get_task"}:{title:"Task readiness",tone:"bad",detail:`${a} has a claimed task but no session current_task binding.`,tool:"masc_plan_set_task"}:{title:"Task readiness",tone:"bad",detail:`${a} is not visible in the room roster.`,tool:"masc_join"}:{title:"Task readiness",tone:"warn",detail:"No ?agent= query param. Dashboard can show room health but not agent-specific next steps.",tool:"masc_join"},!t||(((nt=t.topology.summary)==null?void 0:nt.managed_unit_count)??0)===0?{title:"Operation readiness",tone:"warn",detail:"No managed units defined yet. CPv2 benchmark cannot start before hierarchy exists.",tool:"masc_unit_define"}:r===0?{title:"Operation readiness",tone:"warn",detail:`${((x=t.topology.summary)==null?void 0:x.managed_unit_count)??0} managed units are ready, but there is no active operation.`,tool:"masc_operation_start"}:{title:"Operation readiness",tone:"ok",detail:`${r} active operation(s) across ${((Pt=t.topology.summary)==null?void 0:Pt.managed_unit_count)??0} managed unit(s).`,tool:"masc_observe_operations"},p>0?{title:"Dispatch readiness",tone:"warn",detail:`${p} pending approval(s) are blocking strict actions.`,tool:"masc_policy_approve"}:r>0&&l===0?{title:"Dispatch readiness",tone:"bad",detail:"Active operation exists but no detachment has been materialized yet.",tool:"masc_dispatch_tick"}:$||m?{title:"Dispatch readiness",tone:"warn",detail:`Dispatch needs reconciliation${$?` · detachment ${$.detachment.detachment_id} is stalled`:""}${m?` · alert ${m.title??m.alert_id}`:""}${!e&&!$&&!m?" · open a detail tab to inspect the exact source.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"Dispatch readiness",tone:"ok",detail:`${l} detachment(s) visible and no strict approval backlog${e?"":" · detail panes stay lazy until opened."}.`,tool:"masc_detachment_list"}],T=d?!a||!i?"masc_join":o.length===0?$t.value.length>0?"masc_claim":"masc_add_task":v?y===!1?"masc_heartbeat":!t||(((Jt=t.topology.summary)==null?void 0:Jt.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":p>0?"masc_policy_approve":r>0&&l===0||$||m?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",D=cp(T),M=dp(T==="masc_set_room"?["repo-root-room"]:T==="masc_plan_set_task"?["claimed-not-current"]:T==="masc_heartbeat"?["heartbeat-stale"]:T==="masc_dispatch_tick"?["no-detachments"]:T==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),N=ls("room_task_hygiene"),P=ls("cpv2_benchmark"),et=ls("supervisor_session"),U=((oe=zn.value)==null?void 0:oe.docs)??[],ie=[N,P,et].filter(I=>I!==null);return s`
    <div class="command-guided-layout">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function gp(){var At,wt,W,nt,k,Pt,Jt,oe,re;const t=Ci(),e=Kt.value,n=ae.value,a=np(),i=a?xt.value.find(I=>I.name===a)??null:null,o=a?$t.value.filter(I=>I.assignee===a&&ip(I)):[],r=((At=t==null?void 0:t.operations.summary)==null?void 0:At.active)??0,l=((wt=t==null?void 0:t.detachments.summary)==null?void 0:wt.total)??0,p=((W=t==null?void 0:t.decisions.summary)==null?void 0:W.pending)??0,_=e==null?void 0:e.detachments.detachments.find(I=>{const Dt=I.detachment.heartbeat_deadline,le=Dt?Date.parse(Dt):Number.NaN;return I.detachment.status==="stalled"||!Number.isNaN(le)&&le<=Date.now()}),m=e==null?void 0:e.alerts.alerts.find(I=>I.severity==="bad"),d=!!(n!=null&&n.room||n!=null&&n.project),c=(i==null?void 0:i.current_task)??null,g=sp(i==null?void 0:i.last_seen),y=g!=null?g<=120:null,S=[d?{title:"Room readiness",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room readiness",tone:"bad",detail:"No room snapshot yet. Set room to repo root before joining.",tool:"masc_set_room"},a?i?o.length===0?{title:"Task readiness",tone:"warn",detail:`${a} has no claimed task. Claim one or create one first.`,tool:$t.value.length>0?"masc_claim":"masc_add_task"}:c?y===!1?{title:"Task readiness",tone:"warn",detail:`${a} current_task=${c}, but heartbeat is stale (${g}s).`,tool:"masc_heartbeat"}:{title:"Task readiness",tone:"ok",detail:`${a} current_task=${c}${g!=null?` · last seen ${g}s ago`:""}`,tool:"masc_plan_get_task"}:{title:"Task readiness",tone:"bad",detail:`${a} has a claimed task but no session current_task binding.`,tool:"masc_plan_set_task"}:{title:"Task readiness",tone:"bad",detail:`${a} is not visible in the room roster.`,tool:"masc_join"}:{title:"Task readiness",tone:"warn",detail:"No ?agent= query param. Dashboard can show room health but not agent-specific next steps.",tool:"masc_join"},!t||(((nt=t.topology.summary)==null?void 0:nt.managed_unit_count)??0)===0?{title:"Operation readiness",tone:"warn",detail:"No managed units defined yet. CPv2 benchmark cannot start before hierarchy exists.",tool:"masc_unit_define"}:r===0?{title:"Operation readiness",tone:"warn",detail:`${((k=t.topology.summary)==null?void 0:k.managed_unit_count)??0} managed units are ready, but there is no active operation.`,tool:"masc_operation_start"}:{title:"Operation readiness",tone:"ok",detail:`${r} active operation(s) across ${((Pt=t.topology.summary)==null?void 0:Pt.managed_unit_count)??0} managed unit(s).`,tool:"masc_observe_operations"},p>0?{title:"Dispatch readiness",tone:"warn",detail:`${p} pending approval(s) are blocking strict actions.`,tool:"masc_policy_approve"}:r>0&&l===0?{title:"Dispatch readiness",tone:"bad",detail:"Active operation exists but no detachment has been materialized yet.",tool:"masc_dispatch_tick"}:_||m?{title:"Dispatch readiness",tone:"warn",detail:`Dispatch needs reconciliation${_?` · detachment ${_.detachment.detachment_id} is stalled`:""}${m?` · alert ${m.title??m.alert_id}`:""}${!e&&!_&&!m?" · open a detail tab to inspect the exact source.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"Dispatch readiness",tone:"ok",detail:`${l} detachment(s) visible and no strict approval backlog${e?"":" · detail panes stay lazy until opened."}.`,tool:"masc_detachment_list"}],T=d?!a||!i?"masc_join":o.length===0?$t.value.length>0?"masc_claim":"masc_add_task":c?y===!1?"masc_heartbeat":!t||(((Jt=t.topology.summary)==null?void 0:Jt.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":p>0?"masc_policy_approve":r>0&&l===0||_||m?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",D=op(T),M=rp(T==="masc_set_room"?["repo-root-room"]:T==="masc_plan_set_task"?["claimed-not-current"]:T==="masc_heartbeat"?["heartbeat-stale"]:T==="masc_dispatch_tick"?["no-detachments"]:T==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),N=rs("room_task_hygiene"),P=rs("cpv2_benchmark"),et=rs("supervisor_session"),U=((oe=zn.value)==null?void 0:oe.docs)??[],ie=[N,P,et].filter(I=>I!==null);return s`
    <div class="command-guide-grid">
========
  `}function gp(){var mt,vt,B,M,k,Dt,Vt,oe,re;const t=wi(),e=Ht.value,n=se.value,a=np(),i=a?At.value.find(E=>E.name===a)??null:null,o=a?yt.value.filter(E=>E.assignee===a&&ip(E)):[],r=((mt=t==null?void 0:t.operations.summary)==null?void 0:mt.active)??0,l=((vt=t==null?void 0:t.detachments.summary)==null?void 0:vt.total)??0,p=((B=t==null?void 0:t.decisions.summary)==null?void 0:B.pending)??0,_=e==null?void 0:e.detachments.detachments.find(E=>{const Et=E.detachment.heartbeat_deadline,le=Et?Date.parse(Et):Number.NaN;return E.detachment.status==="stalled"||!Number.isNaN(le)&&le<=Date.now()}),m=e==null?void 0:e.alerts.alerts.find(E=>E.severity==="bad"),d=!!(n!=null&&n.room||n!=null&&n.project),c=(i==null?void 0:i.current_task)??null,g=sp(i==null?void 0:i.last_seen),y=g!=null?g<=120:null,S=[d?{title:"Room readiness",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room readiness",tone:"bad",detail:"No room snapshot yet. Set room to repo root before joining.",tool:"masc_set_room"},a?i?o.length===0?{title:"Task readiness",tone:"warn",detail:`${a} has no claimed task. Claim one or create one first.`,tool:yt.value.length>0?"masc_claim":"masc_add_task"}:c?y===!1?{title:"Task readiness",tone:"warn",detail:`${a} current_task=${c}, but heartbeat is stale (${g}s).`,tool:"masc_heartbeat"}:{title:"Task readiness",tone:"ok",detail:`${a} current_task=${c}${g!=null?` · last seen ${g}s ago`:""}`,tool:"masc_plan_get_task"}:{title:"Task readiness",tone:"bad",detail:`${a} has a claimed task but no session current_task binding.`,tool:"masc_plan_set_task"}:{title:"Task readiness",tone:"bad",detail:`${a} is not visible in the room roster.`,tool:"masc_join"}:{title:"Task readiness",tone:"warn",detail:"No ?agent= query param. Dashboard can show room health but not agent-specific next steps.",tool:"masc_join"},!t||(((M=t.topology.summary)==null?void 0:M.managed_unit_count)??0)===0?{title:"Operation readiness",tone:"warn",detail:"No managed units defined yet. CPv2 benchmark cannot start before hierarchy exists.",tool:"masc_unit_define"}:r===0?{title:"Operation readiness",tone:"warn",detail:`${((k=t.topology.summary)==null?void 0:k.managed_unit_count)??0} managed units are ready, but there is no active operation.`,tool:"masc_operation_start"}:{title:"Operation readiness",tone:"ok",detail:`${r} active operation(s) across ${((Dt=t.topology.summary)==null?void 0:Dt.managed_unit_count)??0} managed unit(s).`,tool:"masc_observe_operations"},p>0?{title:"Dispatch readiness",tone:"warn",detail:`${p} pending approval(s) are blocking strict actions.`,tool:"masc_policy_approve"}:r>0&&l===0?{title:"Dispatch readiness",tone:"bad",detail:"Active operation exists but no detachment has been materialized yet.",tool:"masc_dispatch_tick"}:_||m?{title:"Dispatch readiness",tone:"warn",detail:`Dispatch needs reconciliation${_?` · detachment ${_.detachment.detachment_id} is stalled`:""}${m?` · alert ${m.title??m.alert_id}`:""}${!e&&!_&&!m?" · open a detail tab to inspect the exact source.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"Dispatch readiness",tone:"ok",detail:`${l} detachment(s) visible and no strict approval backlog${e?"":" · detail panes stay lazy until opened."}.`,tool:"masc_detachment_list"}],T=d?!a||!i?"masc_join":o.length===0?yt.value.length>0?"masc_claim":"masc_add_task":c?y===!1?"masc_heartbeat":!t||(((Vt=t.topology.summary)==null?void 0:Vt.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":p>0?"masc_policy_approve":r>0&&l===0||_||m?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",P=op(T),I=rp(T==="masc_set_room"?["repo-root-room"]:T==="masc_plan_set_task"?["claimed-not-current"]:T==="masc_heartbeat"?["heartbeat-stale"]:T==="masc_dispatch_tick"?["no-detachments"]:T==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),N=rs("room_task_hygiene"),R=rs("cpv2_benchmark"),X=rs("supervisor_session"),H=((oe=zn.value)==null?void 0:oe.docs)??[],Pt=[N,R,X].filter(E=>E!==null);return s`
    <div class="command-guide-grid">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      <section class="card command-section">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        <div class="card-title">Immediate Actions</div>
        <div class="command-guide-card highlight command-next-step-card">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        <div class="card-title">Readiness</div>
        <div class="command-guide-readiness">
          ${S.map(I=>s`
            <article class="command-guide-card ${G(I.tone)}">
              <div class="command-guide-head">
                <strong>${I.title}</strong>
                <span class="command-chip ${G(I.tone)}">${I.tone}</span>
              </div>
              <p>${I.detail}</p>
              <div class="command-card-foot">Next tool: ${I.tool}</div>
            </article>
          `)}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title">Next Step</div>
        <article class="command-guide-card highlight">
========
        <div class="card-title">Readiness</div>
        <div class="command-guide-readiness">
          ${S.map(E=>s`
            <article class="command-guide-card ${J(E.tone)}">
              <div class="command-guide-head">
                <strong>${E.title}</strong>
                <span class="command-chip ${J(E.tone)}">${E.tone}</span>
              </div>
              <p>${E.detail}</p>
              <div class="command-card-foot">Next tool: ${E.tool}</div>
            </article>
          `)}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title">Next Step</div>
        <article class="command-guide-card highlight">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          <div class="command-guide-head">
            <strong>${(P==null?void 0:P.title)??T}</strong>
            <span class="command-chip ok">${T}</span>
          </div>
          <p>${(P==null?void 0:P.summary)??"Use the next tool in the canonical flow to remove the current blocker."}</p>
          ${(re=P==null?void 0:P.success_signals)!=null&&re.length?s`<div class="command-tag-row">
                ${P.success_signals.map(E=>s`<span class="command-tag ok">${E}</span>`)}
              </div>`:null}
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        </div>

        <div class="command-readiness-list">
          ${S.map(I=>s`
            <article class="command-readiness-row ${G(I.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${I.title}</strong>
                  <span class="command-chip ${G(I.tone)}">${I.tone}</span>
                </div>
                <p>${I.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${I.tool}</div>
            </article>
          `)}
        </div>

        ${M.length>0?s`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>Common Pitfalls</strong>
                  <span class="command-chip warn">${M.length}</span>
                </div>
                <div class="command-guide-list">
                  ${M.map(I=>s`
                    <article class="command-guide-inline">
                      <strong>${I.title}</strong>
                      <div>${I.symptom}</div>
                      <div class="command-card-sub">Fix with ${I.fix_tool}: ${I.fix_summary}</div>
                    </article>
                  `)}
                </div>
              </div>
            `:null}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
          ${M.length>0?s`<div class="command-guide-list">
                ${M.map(I=>s`
                  <article class="command-guide-inline">
                    <strong>${I.title}</strong>
                    <div>${I.symptom}</div>
                    <div class="command-card-sub">Fix with ${I.fix_tool}: ${I.fix_summary}</div>
                  </article>
                `)}
              </div>`:null}
        </article>
========
          ${I.length>0?s`<div class="command-guide-list">
                ${I.map(E=>s`
                  <article class="command-guide-inline">
                    <strong>${E.title}</strong>
                    <div>${E.symptom}</div>
                    <div class="command-card-sub">Fix with ${E.fix_tool}: ${E.fix_summary}</div>
                  </article>
                `)}
              </div>`:null}
        </article>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      </section>

      <section class="card command-section">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        <div class="card-title">Operating Paths</div>
        ${Js.value?s`<div class="empty-state">Loading CPv2 runbook…</div>`:ba.value?s`<div class="empty-state error">${ba.value}</div>`:s`
                <div class="command-path-grid">
                  ${ie.map(I=>s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        <div class="card-title">How It Works</div>
        ${Ws.value?s`<div class="empty-state">Loading CPv2 runbook…</div>`:ya.value?s`<div class="empty-state error">${ya.value}</div>`:s`
                <div class="command-guide-paths">
                  ${ie.map(I=>s`
========
        <div class="card-title">How It Works</div>
        ${Ws.value?s`<div class="empty-state">Loading CPv2 runbook…</div>`:ya.value?s`<div class="empty-state error">${ya.value}</div>`:s`
                <div class="command-guide-paths">
                  ${Pt.map(E=>s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${E.title}</strong>
                        <span class="command-chip">${E.id}</span>
                      </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
                      <p>${I.summary}</p>
                      <div class="command-card-sub">${I.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${I.steps.slice(0,4).map(Dt=>s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
                      <p>${I.summary}</p>
                      <div class="command-card-sub">${I.when_to_use}</div>
                      <div class="command-step-list">
                        ${I.steps.map(Dt=>s`
========
                      <p>${E.summary}</p>
                      <div class="command-card-sub">${E.when_to_use}</div>
                      <div class="command-step-list">
                        ${E.steps.map(Et=>s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                          <div class="command-step-row">
                            <span class="command-step-tool">${Et.tool}</span>
                            <span>${Et.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${H.length>0?s`<div class="command-doc-links">
                      ${H.map(E=>s`<span class="command-tag">${E.title}: ${E.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function yp(){return s`
    <${up} />
    <div class="command-primary-layout">
      <${gp} />
      <${hp} />
    </div>
  `}function bp(){return ga.value?s`<div class="empty-state">Loading command-plane detail…</div>`:ha.value?s`<div class="empty-state error">${ha.value}</div>`:s`<div class="empty-state">Select a surface to load command-plane detail.</div>`}function Ar({node:t,depth:e=0}){const n=t.roster_live??0,a=t.roster_total??t.unit.roster.length,i=t.active_operation_count??0,o=t.unit.policy;return s`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
            <span class="command-chip">${sp(t.unit.kind)}</span>
            <span class="command-chip ${G(t.health)}">${t.health??"ok"}</span>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
            <span class="command-chip">${ep(t.unit.kind)}</span>
            <span class="command-chip ${G(t.health)}">${t.health??"ok"}</span>
========
            <span class="command-chip">${ep(t.unit.kind)}</span>
            <span class="command-chip ${J(t.health)}">${t.health??"ok"}</span>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
            ${o!=null&&o.frozen?s`<span class="command-chip warn">frozen</span>`:null}
            ${o!=null&&o.kill_switch?s`<span class="command-chip bad">kill-switch</span>`:null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${t.unit.unit_id}</span>
            <span>Leader ${t.unit.leader_id??"unassigned"} / ${t.leader_status??"unknown"}</span>
            <span>Roster ${n}/${a}</span>
            <span>Ops ${i}</span>
            <span>Autonomy ${(o==null?void 0:o.autonomy_level)??"n/a"}</span>
          </div>
          ${t.reasons&&t.reasons.length>0?s`<div class="command-tag-row">
                ${t.reasons.map(r=>s`<span class="command-tag warn">${r}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?s`<div class="command-tree-children">
            ${t.children.map(r=>s`<${Ar} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function kp({source:t}){const e=wo(null),[n,a]=Ua(null);return rt(()=>{let i=!1;const o=e.current;return o?(o.innerHTML="",a(null),(async()=>{try{const l=await Zu(),{svg:p}=await l.render(`command-chain-${++Xu}`,t);if(i||!e.current)return;e.current.innerHTML=p}catch(l){if(i)return;a(l instanceof Error?l.message:"Mermaid render failed")}})(),()=>{i=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),s`
    <div class="command-chain-graph-shell">
      ${n?s`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function xp({overlay:t,selected:e,onSelect:n}){const a=t.operation.chain,i=t.runtime;return s`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${Zt(a==null?void 0:a.status)}">${(a==null?void 0:a.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(a==null?void 0:a.kind)??"chain_dsl"}</span>
        ${a!=null&&a.chain_id?s`<span class="command-tag">${a.chain_id}</span>`:null}
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        ${i?s`<span class="command-tag ${Xt(a==null?void 0:a.status)}">${Ni(i.progress)} progress</span>`:null}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        ${i?s`<span class="command-tag ${Xt(a==null?void 0:a.status)}">${yr(i.progress)} progress</span>`:null}
========
        ${i?s`<span class="command-tag ${Zt(a==null?void 0:a.status)}">${yr(i.progress)} progress</span>`:null}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      </div>
      <div class="command-card-sub">${xr(t.history)}</div>
    </button>
  `}function Sp({item:t}){return s`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${Zt(t.event)}">${t.event}</span>
      </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
      <div class="command-card-sub">${Z(t.timestamp)}</div>
      <div class="command-card-sub">${xr(t)}</div>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
      <div class="command-card-sub">${Z(t.timestamp)}</div>
      <div class="command-card-sub">${br(t)}</div>
========
      <div class="command-card-sub">${tt(t.timestamp)}</div>
      <div class="command-card-sub">${br(t)}</div>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    </article>
  `}function Ap({node:t}){return s`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${Zt(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?s`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function wp({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,a=`resume:${e.operation_id}`,i=`recall:${e.operation_id}`,o=e.chain;return s`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${J(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Autonomy</span><span>${e.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${e.budget_class??"standard"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Updated</span><span>${tt(e.updated_at)}</span>
      </div>
      ${o?s`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${Zt(o.status)}">${o.status}</span>
              ${o.chain_id?s`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?s`<span class="command-tag">run ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?s`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        ${o?s`
              <button
                class="control-btn ghost"
                onClick=${()=>{Ci(e.operation_id),Ai("chains"),Rt("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?s`
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
              <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>Zt(()=>Fu(e.operation_id))}>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>Zt(()=>zu(e.operation_id))}>
========
              <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>te(()=>zu(e.operation_id))}>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                ${it(n)?"Pausing…":"Pause"}
              </button>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
              <button class="control-btn ghost" disabled=${it(i)} onClick=${()=>Zt(()=>Hu(e.operation_id))}>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              <button class="control-btn ghost" disabled=${it(i)} onClick=${()=>Zt(()=>ju(e.operation_id))}>
========
              <button class="control-btn ghost" disabled=${it(i)} onClick=${()=>te(()=>ju(e.operation_id))}>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                ${it(i)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?s`
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
              <button class="control-btn ghost" disabled=${it(a)} onClick=${()=>Zt(()=>Ku(e.operation_id))}>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              <button class="control-btn ghost" disabled=${it(a)} onClick=${()=>Zt(()=>qu(e.operation_id))}>
========
              <button class="control-btn ghost" disabled=${it(a)} onClick=${()=>te(()=>qu(e.operation_id))}>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                ${it(a)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Cp({card:t}){var n;const e=t.detachment;return s`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${J(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        <span>Progress</span><span>${Z(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Yu(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${Z(e.updated_at)}</span>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        <span>Progress</span><span>${Z(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Ju(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${Z(e.updated_at)}</span>
========
        <span>Progress</span><span>${tt(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Ju(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${tt(e.updated_at)}</span>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?s`<span class="command-tag ${Qu(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Tp({alert:t}){return s`
    <article class="command-alert ${G(t.severity)}">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Ap({alert:t}){return s`
    <article class="command-alert ${G(t.severity)}">
========
  `}function Ap({alert:t}){return s`
    <article class="command-alert ${J(t.severity)}">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${J(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${tt(t.timestamp)}</span>
      </div>
      ${t.detail?s`<p>${t.detail}</p>`:null}
    </article>
  `}function wr({event:t}){return s`
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
      <pre class="command-trace-detail">${Vu(t.detail)}</pre>
    </article>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Np({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,a=t.source==="projected_operator";return s`
    <article class="command-card ${G(t.status)}">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function wp({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,a=t.source==="projected_operator";return s`
    <article class="command-card ${G(t.status)}">
========
  `}function Cp({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,a=t.source==="projected_operator";return s`
    <article class="command-card ${J(t.status)}">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${J(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${tt(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!a?s`
            <div class="command-action-row">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
              <button class="control-btn ghost" disabled=${it(e)} onClick=${()=>Zt(()=>Bu(t.decision_id))}>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              <button class="control-btn ghost" disabled=${it(e)} onClick=${()=>Zt(()=>Ku(t.decision_id))}>
========
              <button class="control-btn ghost" disabled=${it(e)} onClick=${()=>te(()=>Ku(t.decision_id))}>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                ${it(e)?"Approving…":"Approve"}
              </button>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
              <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>Zt(()=>Wu(t.decision_id))}>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>Zt(()=>Hu(t.decision_id))}>
========
              <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>te(()=>Hu(t.decision_id))}>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                ${it(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${a?s`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Rp({row:t}){var l,p,$;const e=t.unit,n=`freeze:${e.unit_id}`,a=`kill:${e.unit_id}`,i=!!((l=e.policy)!=null&&l.frozen),o=!!((p=e.policy)!=null&&p.kill_switch),r=Math.round((t.utilization??0)*100);return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Cp({row:t}){var l,p,_;const e=t.unit,n=`freeze:${e.unit_id}`,a=`kill:${e.unit_id}`,i=!!((l=e.policy)!=null&&l.frozen),o=!!((p=e.policy)!=null&&p.kill_switch),r=Math.round((t.utilization??0)*100);return s`
========
  `}function wp({row:t}){var l,p,_;const e=t.unit,n=`freeze:${e.unit_id}`,a=`kill:${e.unit_id}`,i=!!((l=e.policy)!=null&&l.frozen),o=!!((p=e.policy)!=null&&p.kill_switch),r=Math.round((t.utilization??0)*100);return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${J(r>100?"bad":r>70?"warn":"ok")}">${r}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>Headcount Cap</span><span>${t.headcount_cap??0}</span>
        <span>Ops</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${(($=e.policy)==null?void 0:$.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${i?"yes":"no"}</span>
        <span>Kill Switch</span><span>${o?"on":"off"}</span>
      </div>
      <div class="command-action-row">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>Zt(()=>Gu(e.unit_id,!i))}>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>Zt(()=>Uu(e.unit_id,!i))}>
========
        <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>te(()=>Uu(e.unit_id,!i))}>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          ${it(n)?"Applying…":i?"Unfreeze":"Freeze"}
        </button>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        <button class="control-btn ghost" disabled=${it(a)} onClick=${()=>Zt(()=>Ju(e.unit_id,!o))}>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        <button class="control-btn ghost" disabled=${it(a)} onClick=${()=>Zt(()=>Bu(e.unit_id,!o))}>
========
        <button class="control-btn ghost" disabled=${it(a)} onClick=${()=>te(()=>Bu(e.unit_id,!o))}>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          ${it(a)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Lp({item:t}){return s`
    <article class="command-guide-card ${G(t.status)}">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Tp({item:t}){return s`
    <article class="command-guide-card ${G(t.status)}">
========
  `}function Tp({item:t}){return s`
    <article class="command-guide-card ${J(t.status)}">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${J(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Pp({blocker:t}){return s`
    <article class="command-alert ${G(t.severity)}">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Np({blocker:t}){return s`
    <article class="command-alert ${G(t.severity)}">
========
  `}function Np({blocker:t}){return s`
    <article class="command-alert ${J(t.severity)}">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${J(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function Dp({worker:t}){return s`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${J(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${t.last_message?s`<div class="command-card-foot">${tt(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Ep(){var n,a,i,o,r,l,p,$,m,d,v,c,y,S,T,D;const t=dr.value,e=op();return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Lp(){var n,a,i,o,r,l,p,_,m,d,c,g,y,S,T,D;const t=rr.value,e=ap();return s`
========
  `}function Lp(){var l,p,_,m,d,c,g,y,S,T,P,K,I,N,R,X,H,Pt,mt,vt,B;const t=rr.value,e=ap(),n=(l=t==null?void 0:t.provider)!=null&&l.runtime_blocker?"blocked":(p=t==null?void 0:t.provider)!=null&&p.provider_reachable?"ready":"check",a=((_=t==null?void 0:t.provider)==null?void 0:_.actual_slots)??((m=t==null?void 0:t.provider)==null?void 0:m.total_slots)??0,i=((d=t==null?void 0:t.provider)==null?void 0:d.expected_slots)??"n/a",o=((c=t==null?void 0:t.provider)==null?void 0:c.actual_ctx)??((g=t==null?void 0:t.provider)==null?void 0:g.ctx_per_slot)??0,r=((y=t==null?void 0:t.provider)==null?void 0:y.expected_ctx)??"n/a";return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Swarm Live Run</div>
        ${Vs.value?s`<div class="empty-state">Loading swarm live state…</div>`:ka.value?s`<div class="empty-state error">${ka.value}</div>`:t?s`
                  <div class="command-summary-grid">
                    <div class="monitor-stat-card"><span>Run</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room n/a"}</small></div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
                    <div class="monitor-stat-card"><span>Workers</span><strong>${((n=t.summary)==null?void 0:n.joined_workers)??0}/${((a=t.summary)==null?void 0:a.expected_workers)??0}</strong><small>${((i=t.summary)==null?void 0:i.live_workers)??0} live · ${((o=t.summary)==null?void 0:o.completed_workers)??0} completed</small></div>
                    <div class="monitor-stat-card"><span>Runtime</span><strong>${((r=t.provider)==null?void 0:r.active_slots_now)??0}/${((l=t.provider)==null?void 0:l.total_slots)??0}</strong><small>peak ${((p=t.summary)==null?void 0:p.peak_hot_slots)??0} · ctx ${(($=t.provider)==null?void 0:$.ctx_per_slot)??0}</small></div>
                    <div class="monitor-stat-card"><span>Hot 10+</span><strong>${(m=t.summary)!=null&&m.pass_hot_concurrency?"pass":"check"}</strong><small>${((d=t.provider)==null?void 0:d.slot_url)??"slot n/a"}</small></div>
                    <div class="monitor-stat-card"><span>End to End</span><strong>${(v=t.summary)!=null&&v.pass_end_to_end?"pass":"check"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
                    <div class="monitor-stat-card"><span>Workers</span><strong>${((n=t.summary)==null?void 0:n.joined_workers)??0}/${((a=t.summary)==null?void 0:a.expected_workers)??0}</strong><small>${((i=t.summary)==null?void 0:i.live_workers)??0} live · ${((o=t.summary)==null?void 0:o.completed_workers)??0} completed</small></div>
                    <div class="monitor-stat-card"><span>Runtime</span><strong>${((r=t.provider)==null?void 0:r.active_slots_now)??0}/${((l=t.provider)==null?void 0:l.total_slots)??0}</strong><small>peak ${((p=t.summary)==null?void 0:p.peak_hot_slots)??0} · ctx ${((_=t.provider)==null?void 0:_.ctx_per_slot)??0}</small></div>
                    <div class="monitor-stat-card"><span>Hot 10+</span><strong>${(m=t.summary)!=null&&m.pass_hot_concurrency?"pass":"check"}</strong><small>${((d=t.provider)==null?void 0:d.slot_url)??"slot n/a"}</small></div>
                    <div class="monitor-stat-card"><span>End to End</span><strong>${(c=t.summary)!=null&&c.pass_end_to_end?"pass":"check"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
========
                    <div class="monitor-stat-card"><span>Workers</span><strong>${((S=t.summary)==null?void 0:S.joined_workers)??0}/${((T=t.summary)==null?void 0:T.expected_workers)??0}</strong><small>${((P=t.summary)==null?void 0:P.live_workers)??0} live · ${((K=t.summary)==null?void 0:K.completed_workers)??0} completed</small></div>
                    <div class="monitor-stat-card"><span>Runtime</span><strong>${n}</strong><small>slots ${a}/${i} · ctx ${o}/${r}</small></div>
                    <div class="monitor-stat-card"><span>Hot 10+</span><strong>${(I=t.summary)!=null&&I.pass_hot_concurrency?"pass":"check"}</strong><small>${((N=t.provider)==null?void 0:N.slot_url)??"slot n/a"}</small></div>
                    <div class="monitor-stat-card"><span>End to End</span><strong>${(R=t.summary)!=null&&R.pass_end_to_end?"pass":"check"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                  </div>
                  <div class="command-card-grid">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
                    <span>Operation</span><span>${((c=t.operation)==null?void 0:c.operation_id)??"none"}</span>
                    <span>Squad</span><span>${((y=t.squad)==null?void 0:y.label)??"none"}</span>
                    <span>Detachment</span><span>${((S=t.detachment)==null?void 0:S.detachment_id)??"none"}</span>
                    <span>Expected</span><span>${((T=t.summary)==null?void 0:T.expected_workers)??0} workers</span>
                    <span>Final Markers</span><span>${((D=t.summary)==null?void 0:D.final_markers_seen)??0}</span>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
                    <span>Operation</span><span>${((g=t.operation)==null?void 0:g.operation_id)??"none"}</span>
                    <span>Squad</span><span>${((y=t.squad)==null?void 0:y.label)??"none"}</span>
                    <span>Detachment</span><span>${((S=t.detachment)==null?void 0:S.detachment_id)??"none"}</span>
                    <span>Expected</span><span>${((T=t.summary)==null?void 0:T.expected_workers)??0} workers</span>
                    <span>Final Markers</span><span>${((D=t.summary)==null?void 0:D.final_markers_seen)??0}</span>
========
                    <span>Operation</span><span>${((X=t.operation)==null?void 0:X.operation_id)??"none"}</span>
                    <span>Squad</span><span>${((H=t.squad)==null?void 0:H.label)??"none"}</span>
                    <span>Detachment</span><span>${((Pt=t.detachment)==null?void 0:Pt.detachment_id)??"none"}</span>
                    <span>Expected</span><span>${((mt=t.summary)==null?void 0:mt.expected_workers)??0} workers</span>
                    <span>Final Markers</span><span>${((vt=t.summary)==null?void 0:vt.final_markers_seen)??0}</span>
                    <span>Runtime Blocker</span><span>${((B=t.provider)==null?void 0:B.runtime_blocker)??"none"}</span>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                    <span>Recommended</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                  </div>
                  ${t.truth_notes.length>0?s`<div class="command-tag-row">
                        ${t.truth_notes.map(M=>s`<span class="command-tag">${M}</span>`)}
                      </div>`:null}
                `:s`<div class="empty-state">No swarm read-model yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Checklist</div>
        ${t&&t.checklist.length>0?s`<div class="command-card-stack">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
              ${t.checklist.map(L=>s`<${Lp} item=${L} />`)}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              ${t.checklist.map(L=>s`<${Tp} item=${L} />`)}
========
              ${t.checklist.map(M=>s`<${Tp} item=${M} />`)}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
            </div>`:s`<div class="empty-state">No checklist yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Workers</div>
        ${t&&t.workers.length>0?s`<div class="command-card-stack">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
              ${t.workers.map(L=>s`<${Dp} worker=${L} />`)}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              ${t.workers.map(L=>s`<${Rp} worker=${L} />`)}
========
              ${t.workers.map(M=>s`<${Rp} worker=${M} />`)}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
            </div>`:s`<div class="empty-state">No worker rows yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Runtime</div>
        ${t!=null&&t.provider?s`
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
                <span>Runtime Blocker</span><span>${t.provider.runtime_blocker??"none"}</span>
                <span>Doctor Checked</span><span>${t.provider.checked_at?tt(t.provider.checked_at):"n/a"}</span>
              </div>
              ${t.provider.detail?s`<div class="command-card-sub">${t.provider.detail}</div>`:null}
              ${t.provider.timeline.length>0?s`<div class="command-trace-stack">
                    ${t.provider.timeline.slice(-12).map(M=>s`
                      <article class="command-trace-row">
                        <div class="command-trace-main">
                          <div class="command-trace-head">
                            <strong>${M.active_slots} active</strong>
                            <span class="command-chip">${tt(M.timestamp)}</span>
                          </div>
                          <div class="command-card-sub">slots ${M.active_slot_ids.join(", ")||"none"}</div>
                        </div>
                      </article>
                    `)}
                  </div>`:s`<div class="empty-state">No slot telemetry captured yet.</div>`}
            `:s`<div class="empty-state">No runtime telemetry yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Blockers</div>
        ${t&&t.blockers.length>0?s`<div class="command-card-stack">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
              ${t.blockers.map(L=>s`<${Pp} blocker=${L} />`)}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              ${t.blockers.map(L=>s`<${Np} blocker=${L} />`)}
========
              ${t.blockers.map(M=>s`<${Np} blocker=${M} />`)}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
            </div>`:s`<div class="empty-state">No blockers. Use ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} for the next action.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Recent Messages</div>
        ${t&&t.recent_messages.length>0?s`<div class="command-trace-stack">
              ${t.recent_messages.map(M=>s`
                <article class="command-trace-row">
                  <div class="command-trace-main">
                    <div class="command-trace-head">
                      <strong>${M.from}</strong>
                      <span class="command-chip">${tt(M.timestamp)}</span>
                    </div>
                    <div class="command-card-sub">seq ${M.seq}</div>
                  </div>
                  <pre class="command-trace-detail">${M.content}</pre>
                </article>
              `)}
            </div>`:s`<div class="empty-state">No run-scoped broadcasts captured yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Recent Trace Events</div>
        ${t&&t.recent_trace_events.length>0?s`<div class="command-trace-stack">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
              ${t.recent_trace_events.map(L=>s`<${wr} event=${L} />`)}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              ${t.recent_trace_events.map(L=>s`<${Sr} event=${L} />`)}
========
              ${t.recent_trace_events.map(M=>s`<${Sr} event=${M} />`)}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
            </div>`:s`<div class="empty-state">No run-scoped trace events captured yet.</div>`}
      </section>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Ip(){const t=Kt.value;return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Pp(){const t=Kt.value;return s`
========
  `}function Pp(){const t=Ht.value;return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Operations</div>
        ${t&&t.operations.operations.length>0?s`<div class="command-card-stack">
              ${t.operations.operations.map(e=>s`<${wp} card=${e} />`)}
            </div>`:s`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title">Detachments</div>
        ${t&&t.detachments.detachments.length>0?s`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>s`<${Cp} card=${e} />`)}
            </div>`:s`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Mp(){var l,p,$,m,d,v,c,y,S,T,D,L,M,N,P,et;const t=xi.value,e=(t==null?void 0:t.operations)??[],n=cn.value,a=e.find(U=>U.operation.operation_id===n)??e[0]??null,i=((l=a==null?void 0:a.operation.chain)==null?void 0:l.run_id)??null,o=((p=Ln.value)==null?void 0:p.run)??(a==null?void 0:a.preview_run)??null,r=!(($=Ln.value)!=null&&$.run)&&!!(a!=null&&a.preview_run);return rt(()=>{i?qu(i):zu()},[i]),s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Dp(){var l,p,_,m,d,c,g,y,S,T,D,L,M,N,P,et;const t=bi.value,e=(t==null?void 0:t.operations)??[],n=cn.value,a=e.find(U=>U.operation.operation_id===n)??e[0]??null,i=((l=a==null?void 0:a.operation.chain)==null?void 0:l.run_id)??null,o=((p=Ln.value)==null?void 0:p.run)??(a==null?void 0:a.preview_run)??null,r=!((_=Ln.value)!=null&&_.run)&&!!(a!=null&&a.preview_run);return rt(()=>{i?Mu(i):Iu()},[i]),s`
========
  `}function Dp(){var l,p,_,m,d,c,g,y,S,T,P,K,I,N,R,X;const t=bi.value,e=(t==null?void 0:t.operations)??[],n=cn.value,a=e.find(H=>H.operation.operation_id===n)??e[0]??null,i=((l=a==null?void 0:a.operation.chain)==null?void 0:l.run_id)??null,o=((p=Ln.value)==null?void 0:p.run)??(a==null?void 0:a.preview_run)??null,r=!((_=Ln.value)!=null&&_.run)&&!!(a!=null&&a.preview_run);return rt(()=>{i?Mu(i):Iu()},[i]),s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title">Chains</div>
        <article class="command-guide-card ${Zt(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${Zt(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(t==null?void 0:t.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((m=t==null?void 0:t.summary)==null?void 0:m.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((d=t==null?void 0:t.summary)==null?void 0:d.active_chains)??0}</span>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
            <span>Recent Failures</span><span>${((v=t==null?void 0:t.summary)==null?void 0:v.recent_failures)??0}</span>
            <span>Last Event</span><span>${Z((c=t==null?void 0:t.summary)==null?void 0:c.last_history_event_at)}</span>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
            <span>Recent Failures</span><span>${((c=t==null?void 0:t.summary)==null?void 0:c.recent_failures)??0}</span>
            <span>Last Event</span><span>${Z((g=t==null?void 0:t.summary)==null?void 0:g.last_history_event_at)}</span>
========
            <span>Recent Failures</span><span>${((c=t==null?void 0:t.summary)==null?void 0:c.recent_failures)??0}</span>
            <span>Last Event</span><span>${tt((g=t==null?void 0:t.summary)==null?void 0:g.last_history_event_at)}</span>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          </div>
        </article>

        ${xa.value?s`<div class="empty-state error">${xa.value}</div>`:null}

        ${Qs.value&&!t?s`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?s`
                <div class="command-chain-list">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
                  ${e.map(U=>s`
                    <${xp}
                      overlay=${U}
                      selected=${(a==null?void 0:a.operation.operation_id)===U.operation.operation_id}
                      onSelect=${()=>Ci(U.operation.operation_id)}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
                  ${e.map(U=>s`
                    <${yp}
                      overlay=${U}
                      selected=${(a==null?void 0:a.operation.operation_id)===U.operation.operation_id}
                      onSelect=${()=>Ai(U.operation.operation_id)}
========
                  ${e.map(H=>s`
                    <${yp}
                      overlay=${H}
                      selected=${(a==null?void 0:a.operation.operation_id)===H.operation.operation_id}
                      onSelect=${()=>Ai(H.operation.operation_id)}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                    />
                  `)}
                </div>
              `:s`<div class="empty-state">No chain-backed operations yet.</div>`}

        <div class="command-chain-history">
          <div class="command-guide-head">
            <strong>Recent history</strong>
            <span class="command-chip">${(t==null?void 0:t.recent_history.length)??0}</span>
          </div>
          ${t&&t.recent_history.length>0?s`
                <div class="command-card-stack">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
                  ${t.recent_history.slice(0,6).map(U=>s`<${Sp} item=${U} />`)}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
                  ${t.recent_history.slice(0,6).map(U=>s`<${bp} item=${U} />`)}
========
                  ${t.recent_history.slice(0,6).map(H=>s`<${bp} item=${H} />`)}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                </div>
              `:s`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title">Chain Detail</div>
        ${a?s`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${a.operation.objective}</strong>
                    <div class="command-card-sub">${a.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${Zt((y=a.operation.chain)==null?void 0:y.status)}">
                    ${((S=a.operation.chain)==null?void 0:S.status)??a.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((T=a.operation.chain)==null?void 0:T.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((P=a.operation.chain)==null?void 0:P.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${i??"not materialized"}</span>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
                  <span>Progress</span><span>${Ni((L=a.runtime)==null?void 0:L.progress)}</span>
                  <span>Elapsed</span><span>${tp((M=a.runtime)==null?void 0:M.elapsed_sec)}</span>
                  <span>Updated</span><span>${Z(((N=a.operation.chain)==null?void 0:N.last_sync_at)??a.operation.updated_at)}</span>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
                  <span>Progress</span><span>${yr((L=a.runtime)==null?void 0:L.progress)}</span>
                  <span>Elapsed</span><span>${Yu((M=a.runtime)==null?void 0:M.elapsed_sec)}</span>
                  <span>Updated</span><span>${Z(((N=a.operation.chain)==null?void 0:N.last_sync_at)??a.operation.updated_at)}</span>
========
                  <span>Progress</span><span>${yr((K=a.runtime)==null?void 0:K.progress)}</span>
                  <span>Elapsed</span><span>${Yu((I=a.runtime)==null?void 0:I.elapsed_sec)}</span>
                  <span>Updated</span><span>${tt(((N=a.operation.chain)==null?void 0:N.last_sync_at)??a.operation.updated_at)}</span>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                </div>
                ${(R=a.operation.chain)!=null&&R.goal?s`<div class="command-card-foot">${a.operation.chain.goal}</div>`:null}
              </article>

              ${a.mermaid?s`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((X=a.operation.chain)==null?void 0:X.chain_id)??"graph"}</span>
                      </div>
                      <${kp} source=${a.mermaid} />
                    </div>
                  `:s`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"failed":r?"preview":"captured":"pending"}
                  </span>
                </div>
                ${Sa.value?s`<div class="empty-state">Loading run detail…</div>`:Pn.value?s`<div class="empty-state error">${Pn.value}</div>`:o&&o.nodes.length>0?s`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${o.chain_id}</span>
                            <span>Run</span><span>${o.run_id??"preview only"}</span>
                            <span>Duration</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${o.nodes.length}</span>
                          </div>
                          ${r?s`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
                            ${o.nodes.map(U=>s`<${Ap} node=${U} />`)}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
                            ${o.nodes.map(U=>s`<${kp} node=${U} />`)}
========
                            ${o.nodes.map(H=>s`<${kp} node=${H} />`)}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                          </div>
                        `:s`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:s`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Op(){const t=Kt.value;return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Ep(){const t=Kt.value;return s`
========
  `}function Ep(){const t=Ht.value;return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <section class="card command-section">
      <div class="card-title">Topology</div>
      ${t&&t.topology.units.length>0?s`${t.topology.units.map(e=>s`<${Ar} node=${e} />`)}`:s`<div class="empty-state">No command topology projected yet.</div>`}
    </section>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function zp(){const t=Kt.value;return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Ip(){const t=Kt.value;return s`
========
  `}function Ip(){const t=Ht.value;return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <section class="card command-section">
      <div class="card-title">Alerts</div>
      ${t&&t.alerts.alerts.length>0?s`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>s`<${Tp} alert=${e} />`)}
          </div>`:s`<div class="empty-state">No command-plane alerts right now.</div>`}
    </section>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function qp(){const t=Kt.value;return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Mp(){const t=Kt.value;return s`
========
  `}function Mp(){const t=Ht.value;return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <section class="card command-section">
      <div class="card-title">Trace</div>
      ${t&&t.traces.events.length>0?s`<div class="command-trace-stack">
            ${t.traces.events.map(e=>s`<${wr} event=${e} />`)}
          </div>`:s`<div class="empty-state">No recent trace events.</div>`}
    </section>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function jp(){const t=Kt.value;return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Op(){const t=Kt.value;return s`
========
  `}function Op(){const t=Ht.value;return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Approval Queue</div>
        ${t&&t.decisions.decisions.length>0?s`<div class="command-card-stack">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
              ${t.decisions.decisions.map(e=>s`<${Np} decision=${e} />`)}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              ${t.decisions.decisions.map(e=>s`<${wp} decision=${e} />`)}
========
              ${t.decisions.decisions.map(e=>s`<${Cp} decision=${e} />`)}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
            </div>`:s`<div class="empty-state">No approval queue items.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Unit Controls</div>
        ${t&&t.capacity.capacity.length>0?s`<div class="command-card-stack">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
              ${t.capacity.capacity.map(e=>s`<${Rp} row=${e} />`)}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              ${t.capacity.capacity.map(e=>s`<${Cp} row=${e} />`)}
========
              ${t.capacity.capacity.map(e=>s`<${wp} row=${e} />`)}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
            </div>`:s`<div class="empty-state">No capacity rows projected.</div>`}
      </section>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Fp(){if(Ke.value==="summary")return s`<${yp} />`;if(!Kt.value)return s`<${bp} />`;switch(Ke.value){case"swarm":return s`<${Ep} />`;case"chains":return s`<${Mp} />`;case"topology":return s`<${Op} />`;case"alerts":return s`<${zp} />`;case"trace":return s`<${qp} />`;case"control":return s`<${jp} />`;case"operations":default:return s`<${Ip} />`}}function Kp(){return rt(()=>{Me(),ge(),ju(),kr()},[]),rt(()=>{if(tt.value.tab!=="command")return;const t=tt.value.params.surface,e=tt.value.params.operation;np(t)&&Ai(t),e&&Ci(e)},[tt.value.tab,tt.value.params.surface,tt.value.params.operation]),rt(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,Me(),ge()},250))},n=new EventSource(ap()),a=ep.map(i=>{const o=()=>e();return n.addEventListener(i,o),{type:i,handler:o}});return n.onerror=()=>{e()},()=>{a.forEach(({type:i,handler:o})=>{n.removeEventListener(i,o)}),n.close(),t&&window.clearTimeout(t)}},[]),s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function zp(){if(Ke.value==="summary")return s`<${_p} />`;if(!Kt.value)return s`<${$p} />`;switch(Ke.value){case"swarm":return s`<${Lp} />`;case"chains":return s`<${Dp} />`;case"topology":return s`<${Ep} />`;case"alerts":return s`<${Ip} />`;case"trace":return s`<${Mp} />`;case"control":return s`<${Op} />`;case"operations":default:return s`<${Pp} />`}}function qp(){return rt(()=>{fe(),$e(),Ou(),hr()},[]),rt(()=>{if(tt.value.tab!=="command")return;const t=tt.value.params.surface,e=tt.value.params.operation;Zu(t)&&xi(t),e&&Ai(e)},[tt.value.tab,tt.value.params.surface,tt.value.params.operation]),rt(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,fe(),$e()},250))},n=new EventSource(tp()),a=Xu.map(i=>{const o=()=>e();return n.addEventListener(i,o),{type:i,handler:o}});return n.onerror=()=>{e()},()=>{a.forEach(({type:i,handler:o})=>{n.removeEventListener(i,o)}),n.close(),t&&window.clearTimeout(t)}},[]),s`
========
  `}function zp(){if(Ke.value==="summary")return s`<${_p} />`;if(!Ht.value)return s`<${$p} />`;switch(Ke.value){case"swarm":return s`<${Lp} />`;case"chains":return s`<${Dp} />`;case"topology":return s`<${Ep} />`;case"alerts":return s`<${Ip} />`;case"trace":return s`<${Mp} />`;case"control":return s`<${Op} />`;case"operations":default:return s`<${Pp} />`}}function qp(){return rt(()=>{fe(),$e(),Ou(),hr()},[]),rt(()=>{if(nt.value.tab!=="command")return;const t=nt.value.params.surface,e=nt.value.params.operation;Zu(t)&&xi(t),e&&Ai(e)},[nt.value.tab,nt.value.params.surface,nt.value.params.operation]),rt(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,fe(),$e()},250))},n=new EventSource(tp()),a=Xu.map(i=>{const o=()=>e();return n.addEventListener(i,o),{type:i,handler:o}});return n.onerror=()=>{e()},()=>{a.forEach(({type:i,handler:o})=>{n.removeEventListener(i,o)}),n.close(),t&&window.clearTimeout(t)}},[]),s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>Command Plane</h2>
          <p>Operations-first command surface for company → platoon → squad → agent orchestration, approvals, alerts, and traceability.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
            onClick=${()=>{Zt(()=>Uu())}}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
            onClick=${()=>{Zt(()=>Fu())}}
========
            onClick=${()=>{te(()=>Fu())}}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
            disabled=${it("dispatch:tick")}
          >
            ${it("dispatch:tick")?"Reconciling…":"Run Tick"}
          </button>
          <button class="control-btn ghost" onClick=${()=>{Me(),ge()}} disabled=${_a.value}>
            ${_a.value?"Refreshing…":"Refresh"}
          </button>
        </div>
      </div>

      ${$a.value?s`<div class="empty-state error">${$a.value}</div>`:null}
      ${ya.value?s`<div class="empty-state error">${ya.value}</div>`:null}
      <${$p} />
      <${Fp} />
    </section>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}const qn=_(null),Aa=_(!1),ne=_(null),H=_(!1),wa=_([]);let Hp=1;function B(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function E(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function _t(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Cr(t){return typeof t=="boolean"?t:void 0}function Up(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Ce(t,e=[]){if(Array.isArray(t))return t;if(!B(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function Bp(t){return B(t)?{id:E(t.id),seq:_t(t.seq),from:E(t.from)??E(t.from_agent)??"system",content:E(t.content)??"",timestamp:E(t.timestamp)??new Date().toISOString(),type:E(t.type)}:null}function Wp(t){return B(t)?{room_id:E(t.room_id),current_room:E(t.current_room)??E(t.room),project:E(t.project),cluster:E(t.cluster),paused:Cr(t.paused),pause_reason:E(t.pause_reason)??null,paused_by:E(t.paused_by)??null,paused_at:E(t.paused_at)??null}:{}}function oo(t){if(!B(t))return;const e=Object.entries(t).map(([n,a])=>{const i=E(a);return i?[n,i]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Gp(t){if(!B(t))return null;const e=B(t.status)?t.status:void 0,n=B(t.summary)?t.summary:B(e==null?void 0:e.summary)?e.summary:void 0,a=B(t.session)?t.session:B(e==null?void 0:e.session)?e.session:void 0,i=E(t.session_id)??E(n==null?void 0:n.session_id)??E(a==null?void 0:a.session_id);if(!i)return null;const o=oo(t.report_paths)??oo(e==null?void 0:e.report_paths),r=Ce(t.recent_events,["events"]).filter(B);return{session_id:i,status:E(t.status)??E(n==null?void 0:n.status)??E(a==null?void 0:a.status),progress_pct:_t(t.progress_pct)??_t(n==null?void 0:n.progress_pct),elapsed_sec:_t(t.elapsed_sec)??_t(n==null?void 0:n.elapsed_sec),remaining_sec:_t(t.remaining_sec)??_t(n==null?void 0:n.remaining_sec),done_delta_total:_t(t.done_delta_total)??_t(n==null?void 0:n.done_delta_total),summary:n,team_health:B(t.team_health)?t.team_health:B(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:B(t.communication_metrics)?t.communication_metrics:B(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:B(t.orchestration_state)?t.orchestration_state:B(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:B(t.cascade_metrics)?t.cascade_metrics:B(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:a,recent_events:r}}function Jp(t){if(!B(t))return null;const e=E(t.name);if(!e)return null;const n=B(t.context)?t.context:void 0;return{name:e,agent_name:E(t.agent_name),status:E(t.status),autonomy_level:E(t.autonomy_level),context_ratio:_t(t.context_ratio)??_t(n==null?void 0:n.context_ratio),generation:_t(t.generation),active_goal_ids:Up(t.active_goal_ids),last_autonomous_action_at:E(t.last_autonomous_action_at)??null,last_turn_ago_s:_t(t.last_turn_ago_s),model:E(t.model)??E(t.active_model)??E(t.primary_model)}}function Vp(t){if(!B(t))return null;const e=E(t.confirm_token)??E(t.token);return e?{confirm_token:e,actor:E(t.actor),action_type:E(t.action_type),target_type:E(t.target_type),target_id:E(t.target_id)??null,delegated_tool:E(t.delegated_tool),created_at:E(t.created_at),preview:t.preview}:null}function Qp(t){const e=B(t)?t:{};return{room:Wp(e.room),sessions:Ce(e.sessions,["items","sessions"]).map(Gp).filter(n=>n!==null),keepers:Ce(e.keepers,["items","keepers"]).map(Jp).filter(n=>n!==null),recent_messages:Ce(e.recent_messages,["messages"]).map(Bp).filter(n=>n!==null),pending_confirms:Ce(e.pending_confirms,["items","confirms"]).map(Vp).filter(n=>n!==null),available_actions:Ce(e.available_actions,["actions"]).filter(B).map(n=>({action_type:E(n.action_type)??"unknown",target_type:E(n.target_type)??"unknown",description:E(n.description),confirm_required:Cr(n.confirm_required)}))}}function Kn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function ro(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Ca(t){wa.value=[{...t,id:Hp++,at:new Date().toISOString()},...wa.value].slice(0,20)}function Tr(t){return t.confirm_required?Kn(t.preview)||"Confirmation required":Kn(t.result)||Kn(t.executed_action)||Kn(t.delegated_tool_result)||t.status}async function He(){Aa.value=!0,ne.value=null;try{const t=await Al();qn.value=Qp(t)}catch(t){ne.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Aa.value=!1}}async function Yp(t){H.value=!0,ne.value=null;try{const e=await On(t);return Ca({actor:t.actor,action_type:t.action_type,target_label:ro(t),outcome:e.confirm_required?"preview":"executed",message:Tr(e),delegated_tool:e.delegated_tool}),await He(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw ne.value=n,Ca({actor:t.actor,action_type:t.action_type,target_label:ro(t),outcome:"error",message:n}),e}finally{H.value=!1}}async function Xp(t,e){H.value=!0,ne.value=null;try{const n=await El(t,e);return Ca({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Tr(n),delegated_tool:n.delegated_tool}),await He(),n}catch(n){const a=n instanceof Error?n.message:"Operator confirmation failed";throw ne.value=a,Ca({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),n}finally{H.value=!1}}const Nr="masc_dashboard_agent_name";function Zp(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(Nr))==null?void 0:a.trim())||"dashboard"}const Ja=_(Zp()),dn=_(""),Ys=_("Operator pause"),un=_(""),Ta=_(""),Xs=_("2"),Na=_(""),Oe=_("note"),Ra=_(""),La=_(""),Pa=_(""),Zs=_("2"),ti=_("Operator stop request"),ei=_(""),pn=_("");function tm(t){const e=t.trim()||"dashboard";Ja.value=e,localStorage.setItem(Nr,e)}function cs(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function em(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function Da(t){return typeof t=="string"?t.trim().toLowerCase():""}function nm(t){var a;const e=Da(t.status);if(e==="paused")return"bad";const n=Da((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function lo(t){const e=Da(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":(t.context_ratio??0)>=.8||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}async function he(t){const e=Ja.value.trim()||"dashboard";try{const n=await Yp({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?w("Confirmation queued","warning"):w(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return w(a,"error"),null}}async function co(){const t=dn.value.trim();if(!t)return;await he({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(dn.value="")}async function am(){await he({action_type:"room_pause",target_type:"room",payload:{reason:Ys.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function sm(){await he({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function im(){const t=un.value.trim();if(!t)return;await he({action_type:"task_inject",target_type:"room",payload:{title:t,description:Ta.value.trim()||"Injected from Ops tab",priority:Number.parseInt(Xs.value,10)||2},successMessage:"Task injection submitted"})&&(un.value="",Ta.value="")}async function om(){var o;const t=qn.value,e=Na.value||((o=t==null?void 0:t.sessions[0])==null?void 0:o.session_id)||"";if(!e){w("Select a team session first","warning");return}const n={turn_kind:Oe.value},a=Ra.value.trim();a&&(n.message=a),Oe.value==="task"&&(n.task_title=La.value.trim()||"Operator injected task",n.task_description=Pa.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(Zs.value,10)||2),await he({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(Ra.value="",Oe.value==="task"&&(La.value="",Pa.value=""))}async function rm(){var n;const t=qn.value,e=Na.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){w("Select a team session first","warning");return}await he({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:ti.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function lm(){var i;const t=qn.value,e=ei.value||((i=t==null?void 0:t.keepers[0])==null?void 0:i.name)||"",n=pn.value.trim();if(!e){w("Select a keeper first","warning");return}if(!n)return;await he({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(pn.value="")}async function uo(t){const e=Ja.value.trim()||"dashboard";try{await Xp(e,t),w("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";w(a,"error")}}function cm(){var v;const t=qn.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],a=(t==null?void 0:t.keepers)??[],i=(t==null?void 0:t.pending_confirms)??[],o=(t==null?void 0:t.recent_messages)??[],r=n.find(c=>c.session_id===Na.value)??n[0]??null,l=a.find(c=>c.name===ei.value)??a[0]??null,p=n.filter(c=>nm(c)!=="ok"),$=a.filter(c=>lo(c)!=="ok"),m=o.slice(0,5),d=[{key:"room",label:"Room Gate",value:e.paused?"Paused":"Open",detail:e.paused?`Resume gate armed${e.pause_reason?` · ${e.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:e.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:i.length,detail:i.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:i.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:p.length,detail:p.length>0?"Team sessions need steering, stop, or checkpoint attention":"Team sessions look healthy from the operator snapshot",tone:p.some(c=>Da(c.status)==="paused")?"bad":p.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:$.length,detail:$.length>0?"At least one keeper is stale, offline, or running hot":"Keepers are available for direct intervention",tone:$.some(c=>lo(c)==="bad")?"bad":$.length>0?"warn":"ok"}];return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}const qn=f(null),Sa=f(!1),ne=f(null),H=f(!1),Aa=f([]);let jp=1;function B(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function E(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function gt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ar(t){return typeof t=="boolean"?t:void 0}function Fp(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Te(t,e=[]){if(Array.isArray(t))return t;if(!B(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function Kp(t){return B(t)?{id:E(t.id),seq:gt(t.seq),from:E(t.from)??E(t.from_agent)??"system",content:E(t.content)??"",timestamp:E(t.timestamp)??new Date().toISOString(),type:E(t.type)}:null}function Hp(t){return B(t)?{room_id:E(t.room_id),current_room:E(t.current_room)??E(t.room),project:E(t.project),cluster:E(t.cluster),paused:Ar(t.paused),pause_reason:E(t.pause_reason)??null,paused_by:E(t.paused_by)??null,paused_at:E(t.paused_at)??null}:{}}function ao(t){if(!B(t))return;const e=Object.entries(t).map(([n,a])=>{const i=E(a);return i?[n,i]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Up(t){if(!B(t))return null;const e=B(t.status)?t.status:void 0,n=B(t.summary)?t.summary:B(e==null?void 0:e.summary)?e.summary:void 0,a=B(t.session)?t.session:B(e==null?void 0:e.session)?e.session:void 0,i=E(t.session_id)??E(n==null?void 0:n.session_id)??E(a==null?void 0:a.session_id);if(!i)return null;const o=ao(t.report_paths)??ao(e==null?void 0:e.report_paths),r=Te(t.recent_events,["events"]).filter(B);return{session_id:i,status:E(t.status)??E(n==null?void 0:n.status)??E(a==null?void 0:a.status),progress_pct:gt(t.progress_pct)??gt(n==null?void 0:n.progress_pct),elapsed_sec:gt(t.elapsed_sec)??gt(n==null?void 0:n.elapsed_sec),remaining_sec:gt(t.remaining_sec)??gt(n==null?void 0:n.remaining_sec),done_delta_total:gt(t.done_delta_total)??gt(n==null?void 0:n.done_delta_total),summary:n,team_health:B(t.team_health)?t.team_health:B(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:B(t.communication_metrics)?t.communication_metrics:B(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:B(t.orchestration_state)?t.orchestration_state:B(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:B(t.cascade_metrics)?t.cascade_metrics:B(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:a,recent_events:r}}function Bp(t){if(!B(t))return null;const e=E(t.name);if(!e)return null;const n=B(t.context)?t.context:void 0;return{name:e,agent_name:E(t.agent_name),status:E(t.status),autonomy_level:E(t.autonomy_level),context_ratio:gt(t.context_ratio)??gt(n==null?void 0:n.context_ratio),generation:gt(t.generation),active_goal_ids:Fp(t.active_goal_ids),last_autonomous_action_at:E(t.last_autonomous_action_at)??null,last_turn_ago_s:gt(t.last_turn_ago_s),model:E(t.model)??E(t.active_model)??E(t.primary_model)}}function Wp(t){if(!B(t))return null;const e=E(t.confirm_token)??E(t.token);return e?{confirm_token:e,actor:E(t.actor),action_type:E(t.action_type),target_type:E(t.target_type),target_id:E(t.target_id)??null,delegated_tool:E(t.delegated_tool),created_at:E(t.created_at),preview:t.preview}:null}function Gp(t){const e=B(t)?t:{};return{room:Hp(e.room),sessions:Te(e.sessions,["items","sessions"]).map(Up).filter(n=>n!==null),keepers:Te(e.keepers,["items","keepers"]).map(Bp).filter(n=>n!==null),recent_messages:Te(e.recent_messages,["messages"]).map(Kp).filter(n=>n!==null),pending_confirms:Te(e.pending_confirms,["items","confirms"]).map(Wp).filter(n=>n!==null),available_actions:Te(e.available_actions,["actions"]).filter(B).map(n=>({action_type:E(n.action_type)??"unknown",target_type:E(n.target_type)??"unknown",description:E(n.description),confirm_required:Ar(n.confirm_required)}))}}function Kn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function so(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function wa(t){Aa.value=[{...t,id:jp++,at:new Date().toISOString()},...Aa.value].slice(0,20)}function wr(t){return t.confirm_required?Kn(t.preview)||"Confirmation required":Kn(t.result)||Kn(t.executed_action)||Kn(t.delegated_tool_result)||t.status}async function He(){Sa.value=!0,ne.value=null;try{const t=await xl();qn.value=Gp(t)}catch(t){ne.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Sa.value=!1}}async function Jp(t){H.value=!0,ne.value=null;try{const e=await On(t);return wa({actor:t.actor,action_type:t.action_type,target_label:so(t),outcome:e.confirm_required?"preview":"executed",message:wr(e),delegated_tool:e.delegated_tool}),await He(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw ne.value=n,wa({actor:t.actor,action_type:t.action_type,target_label:so(t),outcome:"error",message:n}),e}finally{H.value=!1}}async function Vp(t,e){H.value=!0,ne.value=null;try{const n=await Pl(t,e);return wa({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:wr(n),delegated_tool:n.delegated_tool}),await He(),n}catch(n){const a=n instanceof Error?n.message:"Operator confirmation failed";throw ne.value=a,wa({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),n}finally{H.value=!1}}const Cr="masc_dashboard_agent_name";function Qp(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(Cr))==null?void 0:a.trim())||"dashboard"}const Ga=f(Qp()),dn=f(""),Vs=f("Operator pause"),un=f(""),Ca=f(""),Qs=f("2"),Ta=f(""),Oe=f("note"),Na=f(""),Ra=f(""),La=f(""),Ys=f("2"),Xs=f("Operator stop request"),Zs=f(""),pn=f("");function Yp(t){const e=t.trim()||"dashboard";Ga.value=e,localStorage.setItem(Cr,e)}function io(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Xp(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function Pa(t){return typeof t=="string"?t.trim().toLowerCase():""}function Zp(t){var a;const e=Pa(t.status);if(e==="paused")return"bad";const n=Pa((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function oo(t){const e=Pa(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":(t.context_ratio??0)>=.8||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}async function ye(t){const e=Ga.value.trim()||"dashboard";try{const n=await Jp({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?w("Confirmation queued","warning"):w(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return w(a,"error"),null}}async function ro(){const t=dn.value.trim();if(!t)return;await ye({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(dn.value="")}async function tm(){await ye({action_type:"room_pause",target_type:"room",payload:{reason:Vs.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function em(){await ye({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function nm(){const t=un.value.trim();if(!t)return;await ye({action_type:"task_inject",target_type:"room",payload:{title:t,description:Ca.value.trim()||"Injected from Ops tab",priority:Number.parseInt(Qs.value,10)||2},successMessage:"Task injection submitted"})&&(un.value="",Ca.value="")}async function am(){var o;const t=qn.value,e=Ta.value||((o=t==null?void 0:t.sessions[0])==null?void 0:o.session_id)||"";if(!e){w("Select a team session first","warning");return}const n={turn_kind:Oe.value},a=Na.value.trim();a&&(n.message=a),Oe.value==="task"&&(n.task_title=Ra.value.trim()||"Operator injected task",n.task_description=La.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(Ys.value,10)||2),await ye({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(Na.value="",Oe.value==="task"&&(Ra.value="",La.value=""))}async function sm(){var n;const t=qn.value,e=Ta.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){w("Select a team session first","warning");return}await ye({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Xs.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function im(){var i;const t=qn.value,e=Zs.value||((i=t==null?void 0:t.keepers[0])==null?void 0:i.name)||"",n=pn.value.trim();if(!e){w("Select a keeper first","warning");return}if(!n)return;await ye({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(pn.value="")}async function om(t){const e=Ga.value.trim()||"dashboard";try{await Vp(e,t),w("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";w(a,"error")}}function rm(){var d;const t=qn.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],a=(t==null?void 0:t.keepers)??[],i=(t==null?void 0:t.pending_confirms)??[],o=(t==null?void 0:t.recent_messages)??[],r=n.find(c=>c.session_id===Ta.value)??n[0]??null,l=a.find(c=>c.name===Zs.value)??a[0]??null,p=n.filter(c=>Zp(c)!=="ok"),_=a.filter(c=>oo(c)!=="ok"),m=[{key:"room",label:"Room Gate",value:e.paused?"Paused":"Open",detail:e.paused?`Resume gate armed${e.pause_reason?` · ${e.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:e.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:i.length,detail:i.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:i.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:p.length,detail:p.length>0?"Team sessions need steering, stop, or checkpoint attention":"Team sessions look healthy from the operator snapshot",tone:p.some(c=>Pa(c.status)==="paused")?"bad":p.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:_.length,detail:_.length>0?"At least one keeper is stale, offline, or running hot":"Keepers are available for direct intervention",tone:_.some(c=>oo(c)==="bad")?"bad":_.length>0?"warn":"ok"}];return s`
========
  `}const qn=f(null),Sa=f(!1),ae=f(null),W=f(!1),Aa=f([]);let jp=1;function G(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function D(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function $t(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ar(t){return typeof t=="boolean"?t:void 0}function Fp(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Te(t,e=[]){if(Array.isArray(t))return t;if(!G(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function Kp(t){return G(t)?{id:D(t.id),seq:$t(t.seq),from:D(t.from)??D(t.from_agent)??"system",content:D(t.content)??"",timestamp:D(t.timestamp)??new Date().toISOString(),type:D(t.type)}:null}function Hp(t){return G(t)?{room_id:D(t.room_id),current_room:D(t.current_room)??D(t.room),project:D(t.project),cluster:D(t.cluster),paused:Ar(t.paused),pause_reason:D(t.pause_reason)??null,paused_by:D(t.paused_by)??null,paused_at:D(t.paused_at)??null}:{}}function ao(t){if(!G(t))return;const e=Object.entries(t).map(([n,a])=>{const i=D(a);return i?[n,i]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Up(t){if(!G(t))return null;const e=G(t.status)?t.status:void 0,n=G(t.summary)?t.summary:G(e==null?void 0:e.summary)?e.summary:void 0,a=G(t.session)?t.session:G(e==null?void 0:e.session)?e.session:void 0,i=D(t.session_id)??D(n==null?void 0:n.session_id)??D(a==null?void 0:a.session_id);if(!i)return null;const o=ao(t.report_paths)??ao(e==null?void 0:e.report_paths),r=Te(t.recent_events,["events"]).filter(G);return{session_id:i,status:D(t.status)??D(n==null?void 0:n.status)??D(a==null?void 0:a.status),progress_pct:$t(t.progress_pct)??$t(n==null?void 0:n.progress_pct),elapsed_sec:$t(t.elapsed_sec)??$t(n==null?void 0:n.elapsed_sec),remaining_sec:$t(t.remaining_sec)??$t(n==null?void 0:n.remaining_sec),done_delta_total:$t(t.done_delta_total)??$t(n==null?void 0:n.done_delta_total),summary:n,team_health:G(t.team_health)?t.team_health:G(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:G(t.communication_metrics)?t.communication_metrics:G(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:G(t.orchestration_state)?t.orchestration_state:G(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:G(t.cascade_metrics)?t.cascade_metrics:G(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:a,recent_events:r}}function Bp(t){if(!G(t))return null;const e=D(t.name);if(!e)return null;const n=G(t.context)?t.context:void 0;return{name:e,agent_name:D(t.agent_name),status:D(t.status),autonomy_level:D(t.autonomy_level),context_ratio:$t(t.context_ratio)??$t(n==null?void 0:n.context_ratio),generation:$t(t.generation),active_goal_ids:Fp(t.active_goal_ids),last_autonomous_action_at:D(t.last_autonomous_action_at)??null,last_turn_ago_s:$t(t.last_turn_ago_s),model:D(t.model)??D(t.active_model)??D(t.primary_model)}}function Wp(t){if(!G(t))return null;const e=D(t.confirm_token)??D(t.token);return e?{confirm_token:e,actor:D(t.actor),action_type:D(t.action_type),target_type:D(t.target_type),target_id:D(t.target_id)??null,delegated_tool:D(t.delegated_tool),created_at:D(t.created_at),preview:t.preview}:null}function Gp(t){const e=G(t)?t:{};return{room:Hp(e.room),sessions:Te(e.sessions,["items","sessions"]).map(Up).filter(n=>n!==null),keepers:Te(e.keepers,["items","keepers"]).map(Bp).filter(n=>n!==null),recent_messages:Te(e.recent_messages,["messages"]).map(Kp).filter(n=>n!==null),pending_confirms:Te(e.pending_confirms,["items","confirms"]).map(Wp).filter(n=>n!==null),available_actions:Te(e.available_actions,["actions"]).filter(G).map(n=>({action_type:D(n.action_type)??"unknown",target_type:D(n.target_type)??"unknown",description:D(n.description),confirm_required:Ar(n.confirm_required)}))}}function Kn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function so(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Ca(t){Aa.value=[{...t,id:jp++,at:new Date().toISOString()},...Aa.value].slice(0,20)}function Cr(t){return t.confirm_required?Kn(t.preview)||"Confirmation required":Kn(t.result)||Kn(t.executed_action)||Kn(t.delegated_tool_result)||t.status}async function He(){Sa.value=!0,ae.value=null;try{const t=await xl();qn.value=Gp(t)}catch(t){ae.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Sa.value=!1}}async function Jp(t){W.value=!0,ae.value=null;try{const e=await On(t);return Ca({actor:t.actor,action_type:t.action_type,target_label:so(t),outcome:e.confirm_required?"preview":"executed",message:Cr(e),delegated_tool:e.delegated_tool}),await He(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw ae.value=n,Ca({actor:t.actor,action_type:t.action_type,target_label:so(t),outcome:"error",message:n}),e}finally{W.value=!1}}async function Vp(t,e){W.value=!0,ae.value=null;try{const n=await Pl(t,e);return Ca({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Cr(n),delegated_tool:n.delegated_tool}),await He(),n}catch(n){const a=n instanceof Error?n.message:"Operator confirmation failed";throw ae.value=a,Ca({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),n}finally{W.value=!1}}const wr="masc_dashboard_agent_name";function Qp(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(wr))==null?void 0:a.trim())||"dashboard"}const Ga=f(Qp()),dn=f(""),Vs=f("Operator pause"),un=f(""),wa=f(""),Qs=f("2"),Ta=f(""),Oe=f("note"),Na=f(""),Ra=f(""),La=f(""),Ys=f("2"),Xs=f("Operator stop request"),Zs=f(""),pn=f("");function Yp(t){const e=t.trim()||"dashboard";Ga.value=e,localStorage.setItem(wr,e)}function io(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Xp(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function Pa(t){return typeof t=="string"?t.trim().toLowerCase():""}function Zp(t){var a;const e=Pa(t.status);if(e==="paused")return"bad";const n=Pa((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function oo(t){const e=Pa(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":(t.context_ratio??0)>=.8||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}async function ye(t){const e=Ga.value.trim()||"dashboard";try{const n=await Jp({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?C("Confirmation queued","warning"):C(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return C(a,"error"),null}}async function ro(){const t=dn.value.trim();if(!t)return;await ye({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(dn.value="")}async function tm(){await ye({action_type:"room_pause",target_type:"room",payload:{reason:Vs.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function em(){await ye({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function nm(){const t=un.value.trim();if(!t)return;await ye({action_type:"task_inject",target_type:"room",payload:{title:t,description:wa.value.trim()||"Injected from Ops tab",priority:Number.parseInt(Qs.value,10)||2},successMessage:"Task injection submitted"})&&(un.value="",wa.value="")}async function am(){var o;const t=qn.value,e=Ta.value||((o=t==null?void 0:t.sessions[0])==null?void 0:o.session_id)||"";if(!e){C("Select a team session first","warning");return}const n={turn_kind:Oe.value},a=Na.value.trim();a&&(n.message=a),Oe.value==="task"&&(n.task_title=Ra.value.trim()||"Operator injected task",n.task_description=La.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(Ys.value,10)||2),await ye({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(Na.value="",Oe.value==="task"&&(Ra.value="",La.value=""))}async function sm(){var n;const t=qn.value,e=Ta.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){C("Select a team session first","warning");return}await ye({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Xs.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function im(){var i;const t=qn.value,e=Zs.value||((i=t==null?void 0:t.keepers[0])==null?void 0:i.name)||"",n=pn.value.trim();if(!e){C("Select a keeper first","warning");return}if(!n)return;await ye({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(pn.value="")}async function om(t){const e=Ga.value.trim()||"dashboard";try{await Vp(e,t),C("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";C(a,"error")}}function rm(){var d;const t=qn.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],a=(t==null?void 0:t.keepers)??[],i=(t==null?void 0:t.pending_confirms)??[],o=(t==null?void 0:t.recent_messages)??[],r=n.find(c=>c.session_id===Ta.value)??n[0]??null,l=a.find(c=>c.name===Zs.value)??a[0]??null,p=n.filter(c=>Zp(c)!=="ok"),_=a.filter(c=>oo(c)!=="ok"),m=[{key:"room",label:"Room Gate",value:e.paused?"Paused":"Open",detail:e.paused?`Resume gate armed${e.pause_reason?` · ${e.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:e.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:i.length,detail:i.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:i.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:p.length,detail:p.length>0?"Team sessions need steering, stop, or checkpoint attention":"Team sessions look healthy from the operator snapshot",tone:p.some(c=>Pa(c.status)==="paused")?"bad":p.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:_.length,detail:_.length>0?"At least one keeper is stale, offline, or running hot":"Keepers are available for direct intervention",tone:_.some(c=>oo(c)==="bad")?"bad":_.length>0?"warn":"ok"}];return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <section class="ops-view">
      <div class="ops-header card">
        <div>
          <div class="card-title">Operator Control</div>
          <h2 class="ops-heading">Guided control for room, sessions, and keepers</h2>
          <p class="ops-subheading">
            Structured actions only. Destructive changes remain behind confirmation tokens.
          </p>
        </div>
        <div class="ops-toolbar">
          <label class="control-label" for="ops-actor">Actor</label>
          <input
            id="ops-actor"
            class="control-input ops-actor-input"
            type="text"
            value=${Ja.value}
            onInput=${c=>tm(c.target.value)}
          />
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
          <button class="control-btn ghost" onClick=${()=>{He()}} disabled=${Aa.value||H.value}>
            ${Aa.value?"Refreshing...":"Refresh"}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
          <button class="control-btn ghost" onClick=${()=>{He()}} disabled=${Sa.value||H.value}>
            ${Sa.value?"Refreshing...":"Refresh"}
========
          <button class="control-btn ghost" onClick=${()=>{He()}} disabled=${Sa.value||W.value}>
            ${Sa.value?"Refreshing...":"Refresh"}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          </button>
        </div>
      </div>

      ${ae.value?s`
        <section class="ops-banner error">${ae.value}</section>
      `:null}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Action Priority</h2>
          <p class="monitor-subheadline">Ops is the command surface. These four signals explain when to intervene before you drop into a specific control panel.</p>
        </div>
        <div class="ops-priority-grid">
          ${d.map(c=>s`
            <div key=${c.key} class="ops-priority-card ${c.tone}">
              <span class="ops-priority-label">${c.label}</span>
              <strong>${c.value}</strong>
              <div class="ops-priority-detail">${c.detail}</div>
            </div>
          `)}
        </div>
      </section>

      ${i.length>0?s`
        <section class="card ops-confirmations">
          <div class="card-title">Pending Confirmations</div>
          <p class="ops-context-note">Only previewed actions that still need an explicit operator confirmation stay here.</p>
          <div class="ops-confirmation-list">
            ${i.map(c=>s`
              <article key=${c.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${c.action_type??"unknown"}</strong>
                  <span>${c.target_type??"target"}${c.target_id?`:${c.target_id}`:""}</span>
                  <span>${c.delegated_tool??"delegated tool pending"}</span>
                </div>
                ${c.preview?s`<pre class="ops-code-block">${cs(c.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
                  <button class="control-btn" onClick=${()=>{uo(c.confirm_token)}} disabled=${H.value}>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
                  <button class="control-btn" onClick=${()=>{om(c.confirm_token)}} disabled=${H.value}>
========
                  <button class="control-btn" onClick=${()=>{om(c.confirm_token)}} disabled=${W.value}>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                    Confirm
                  </button>
                  <span class="ops-token">${c.confirm_token}</span>
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
            ${i.length>0?s`
              <div class="ops-confirmation-list">
                ${i.map(c=>s`
                  <article key=${c.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${c.action_type??"unknown"}</strong>
                      <span>${c.target_type??"target"}${c.target_id?`:${c.target_id}`:""}</span>
                      <span>${c.delegated_tool??"delegated tool pending"}</span>
                    </div>
                    ${c.preview?s`<pre class="ops-code-block compact">${cs(c.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{uo(c.confirm_token)}} disabled=${H.value}>
                        Confirm
                      </button>
                      <span class="ops-token">${c.confirm_token}</span>
                    </div>
                  </article>
                `)}
              </div>
            `:s`<div class="ops-empty">No pending confirmations.</div>`}
          </section>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
          <section class="card ops-panel">
            <div class="card-title">Operator Log</div>
            <div class="ops-log-list">
              ${wa.value.length===0?s`
                <div class="ops-empty">No operator actions in this session yet.</div>
              `:wa.value.map(c=>s`
                <article key=${c.id} class="ops-log-entry ${c.outcome}">
                  <div class="ops-log-head">
                    <strong>${c.action_type}</strong>
                    <span>${c.target_label}</span>
                    <span>${c.at}</span>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
          <label class="control-label" for="ops-broadcast">Broadcast</label>
          <div class="control-row">
            <input
              id="ops-broadcast"
              class="control-input"
              type="text"
              placeholder="@agent or room-wide operator update"
              value=${dn.value}
              onInput=${c=>{dn.value=c.target.value}}
              onKeyDown=${c=>{c.key==="Enter"&&ro()}}
              disabled=${H.value}
            />
            <button class="control-btn" onClick=${()=>{ro()}} disabled=${H.value||dn.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${Vs.value}
              onInput=${c=>{Vs.value=c.target.value}}
              disabled=${H.value}
            />
            <button class="control-btn ghost" onClick=${()=>{tm()}} disabled=${H.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{em()}} disabled=${H.value}>
              Resume
            </button>
          </div>

          <div class="ops-section-head">Task Inject</div>
          <input
            class="control-input"
            type="text"
            placeholder="Task title"
            value=${un.value}
            onInput=${c=>{un.value=c.target.value}}
            disabled=${H.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${Ca.value}
            onInput=${c=>{Ca.value=c.target.value}}
            disabled=${H.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${Qs.value}
              onChange=${c=>{Qs.value=c.target.value}}
              disabled=${H.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{nm()}} disabled=${H.value||un.value.trim()===""}>
              Inject
            </button>
          </div>

          ${o.length>0?s`
            <div class="ops-section-head">Context Tail</div>
            <div class="ops-context-note">Recent room chatter stays available for context, but command work remains the primary focus of this tab.</div>
            <div class="ops-feed-list">
              ${o.slice(0,6).map(c=>s`
                <article key=${c.seq??c.id??c.timestamp} class="ops-feed-item">
                  <div class="ops-feed-meta">
                    <strong>${c.from}</strong>
                    <span>${c.timestamp}</span>
========
          <label class="control-label" for="ops-broadcast">Broadcast</label>
          <div class="control-row">
            <input
              id="ops-broadcast"
              class="control-input"
              type="text"
              placeholder="@agent or room-wide operator update"
              value=${dn.value}
              onInput=${c=>{dn.value=c.target.value}}
              onKeyDown=${c=>{c.key==="Enter"&&ro()}}
              disabled=${W.value}
            />
            <button class="control-btn" onClick=${()=>{ro()}} disabled=${W.value||dn.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${Vs.value}
              onInput=${c=>{Vs.value=c.target.value}}
              disabled=${W.value}
            />
            <button class="control-btn ghost" onClick=${()=>{tm()}} disabled=${W.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{em()}} disabled=${W.value}>
              Resume
            </button>
          </div>

          <div class="ops-section-head">Task Inject</div>
          <input
            class="control-input"
            type="text"
            placeholder="Task title"
            value=${un.value}
            onInput=${c=>{un.value=c.target.value}}
            disabled=${W.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${wa.value}
            onInput=${c=>{wa.value=c.target.value}}
            disabled=${W.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${Qs.value}
              onChange=${c=>{Qs.value=c.target.value}}
              disabled=${W.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{nm()}} disabled=${W.value||un.value.trim()===""}>
              Inject
            </button>
          </div>

          ${o.length>0?s`
            <div class="ops-section-head">Context Tail</div>
            <div class="ops-context-note">Recent room chatter stays available for context, but command work remains the primary focus of this tab.</div>
            <div class="ops-feed-list">
              ${o.slice(0,6).map(c=>s`
                <article key=${c.seq??c.id??c.timestamp} class="ops-feed-item">
                  <div class="ops-feed-meta">
                    <strong>${c.from}</strong>
                    <span>${c.timestamp}</span>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                  </div>
                  <div class="ops-log-body">${c.message}</div>
                </article>
              `)}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title">Room Feed</div>
            <p class="ops-context-note">Recent chatter stays available for operator context, but it is secondary to the intervention queue.</p>
            ${m.length>0?s`
              <div class="ops-feed-list">
                ${m.map(c=>s`
                  <article key=${c.seq??c.id??c.timestamp} class="ops-feed-item">
                    <div class="ops-feed-meta">
                      <strong>${c.from}</strong>
                      <span>${c.timestamp}</span>
                    </div>
                    <div class="ops-feed-content">${c.content}</div>
                  </article>
                `)}
              </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
            `:s`<div class="ops-empty">No recent room messages.</div>`}
          </section>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              ${r.recent_events&&r.recent_events.length>0?s`
                <pre class="ops-code-block compact">${io(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${Oe.value}
              onChange=${c=>{Oe.value=c.target.value}}
              disabled=${H.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{am()}} disabled=${H.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${Na.value}
            onInput=${c=>{Na.value=c.target.value}}
            disabled=${H.value||!r}
          ></textarea>
          ${Oe.value==="task"?s`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${Ra.value}
              onInput=${c=>{Ra.value=c.target.value}}
              disabled=${H.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${La.value}
              onInput=${c=>{La.value=c.target.value}}
              disabled=${H.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${Ys.value}
              onChange=${c=>{Ys.value=c.target.value}}
              disabled=${H.value||!r}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
          `:null}

          <div class="ops-section-head">Stop Session</div>
          <div class="control-row ops-split-row">
            <input
              class="control-input"
              type="text"
              value=${Xs.value}
              onInput=${c=>{Xs.value=c.target.value}}
              disabled=${H.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{sm()}} disabled=${H.value||!r}>
              Stop
            </button>
          </div>
        </section>

        <section class="card ops-panel">
          <div class="card-title">Keepers</div>
          <div class="ops-entity-list">
            ${a.length===0?s`<div class="ops-empty">No keepers available.</div>`:a.map(c=>s`
              <button
                key=${c.name}
                class="ops-entity-card ${(l==null?void 0:l.name)===c.name?"active":""}"
                onClick=${()=>{Zs.value=c.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.name}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${c.model??"model n/a"}</span>
                  <span>${typeof c.context_ratio=="number"?`${Math.round(c.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${Xp(c.last_turn_ago_s)}</span>
                </div>
              </button>
            `)}
          </div>

          ${l?s`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${l.name}</div>
              <div class="ops-detail-meta">
                <span>Autonomy: ${l.autonomy_level??"n/a"}</span>
                <span>Generation: ${l.generation??0}</span>
                <span>Goals: ${((d=l.active_goal_ids)==null?void 0:d.length)??0}</span>
              </div>
            </div>
          `:null}

          <label class="control-label" for="ops-keeper-message">Keeper Message</label>
          <textarea
            id="ops-keeper-message"
            class="control-textarea"
            rows=${6}
            placeholder="Send a structured intervention or course correction"
            value=${pn.value}
            onInput=${c=>{pn.value=c.target.value}}
            disabled=${H.value||!l}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{im()}} disabled=${H.value||!l||pn.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${Aa.value.length===0?s`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:Aa.value.map(c=>s`
            <article key=${c.id} class="ops-log-entry ${c.outcome}">
              <div class="ops-log-head">
                <strong>${c.action_type}</strong>
                <span>${c.target_label}</span>
                <span>${c.at}</span>
              </div>
              <div class="ops-log-body">${c.message}</div>
            </article>
          `)}
========
              ${r.recent_events&&r.recent_events.length>0?s`
                <pre class="ops-code-block compact">${io(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${Oe.value}
              onChange=${c=>{Oe.value=c.target.value}}
              disabled=${W.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{am()}} disabled=${W.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${Na.value}
            onInput=${c=>{Na.value=c.target.value}}
            disabled=${W.value||!r}
          ></textarea>
          ${Oe.value==="task"?s`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${Ra.value}
              onInput=${c=>{Ra.value=c.target.value}}
              disabled=${W.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${La.value}
              onInput=${c=>{La.value=c.target.value}}
              disabled=${W.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${Ys.value}
              onChange=${c=>{Ys.value=c.target.value}}
              disabled=${W.value||!r}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
          `:null}

          <div class="ops-section-head">Stop Session</div>
          <div class="control-row ops-split-row">
            <input
              class="control-input"
              type="text"
              value=${Xs.value}
              onInput=${c=>{Xs.value=c.target.value}}
              disabled=${W.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{sm()}} disabled=${W.value||!r}>
              Stop
            </button>
          </div>
        </section>

        <section class="card ops-panel">
          <div class="card-title">Keepers</div>
          <div class="ops-entity-list">
            ${a.length===0?s`<div class="ops-empty">No keepers available.</div>`:a.map(c=>s`
              <button
                key=${c.name}
                class="ops-entity-card ${(l==null?void 0:l.name)===c.name?"active":""}"
                onClick=${()=>{Zs.value=c.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.name}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${c.model??"model n/a"}</span>
                  <span>${typeof c.context_ratio=="number"?`${Math.round(c.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${Xp(c.last_turn_ago_s)}</span>
                </div>
              </button>
            `)}
          </div>

          ${l?s`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${l.name}</div>
              <div class="ops-detail-meta">
                <span>Autonomy: ${l.autonomy_level??"n/a"}</span>
                <span>Generation: ${l.generation??0}</span>
                <span>Goals: ${((d=l.active_goal_ids)==null?void 0:d.length)??0}</span>
              </div>
            </div>
          `:null}

          <label class="control-label" for="ops-keeper-message">Keeper Message</label>
          <textarea
            id="ops-keeper-message"
            class="control-textarea"
            rows=${6}
            placeholder="Send a structured intervention or course correction"
            value=${pn.value}
            onInput=${c=>{pn.value=c.target.value}}
            disabled=${W.value||!l}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{im()}} disabled=${W.value||!l||pn.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${Aa.value.length===0?s`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:Aa.value.map(c=>s`
            <article key=${c.id} class="ops-log-entry ${c.outcome}">
              <div class="ops-log-head">
                <strong>${c.action_type}</strong>
                <span>${c.target_label}</span>
                <span>${c.at}</span>
              </div>
              <div class="ops-log-body">${c.message}</div>
            </article>
          `)}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        </div>

        <div class="ops-column">
          <section class="card ops-panel">
            <div class="card-title">Session Queue</div>
            <p class="ops-context-note">Select the session that needs steering. This queue should answer which run is hot, paused, or drifting.</p>
            <div class="ops-entity-list">
              ${n.length===0?s`<div class="ops-empty">No team sessions available.</div>`:n.map(c=>{var y;return s`
                <button
                  key=${c.session_id}
                  class="ops-entity-card ${(r==null?void 0:r.session_id)===c.session_id?"active":""}"
                  onClick=${()=>{Na.value=c.session_id}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${c.session_id}</strong>
                    <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round(c.progress_pct??0)}%</span>
                    <span>${c.done_delta_total??0} done</span>
                    <span>${(y=c.team_health)!=null&&y.status?String(c.team_health.status):"health n/a"}</span>
                  </div>
                </button>
              `})}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title">Keeper Queue</div>
            <p class="ops-context-note">Keepers are long-lived operators. Pick one when you need recovery, course correction, or a direct probe.</p>
            <div class="ops-entity-list">
              ${a.length===0?s`<div class="ops-empty">No keepers available.</div>`:a.map(c=>s`
                <button
                  key=${c.name}
                  class="ops-entity-card ${(l==null?void 0:l.name)===c.name?"active":""}"
                  onClick=${()=>{ei.value=c.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${c.name}</strong>
                    <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${c.model??"model n/a"}</span>
                    <span>${typeof c.context_ratio=="number"?`${Math.round(c.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                    <span>${em(c.last_turn_ago_s)}</span>
                  </div>
                </button>
              `)}
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
                  <strong>${e.current_room??e.room_id??"default"}</strong>
                </div>
                <div class="ops-stat">
                  <span>Project</span>
                  <strong>${e.project??"n/a"}</strong>
                </div>
                <div class="ops-stat">
                  <span>Cluster</span>
                  <strong>${e.cluster??"n/a"}</strong>
                </div>
                <div class="ops-stat ${e.paused?"warn":"ok"}">
                  <span>Status</span>
                  <strong>${e.paused?"Paused":"Running"}</strong>
                </div>
              </div>

              <label class="control-label" for="ops-broadcast">Room Broadcast</label>
              <div class="control-row">
                <input
                  id="ops-broadcast"
                  class="control-input"
                  type="text"
                  placeholder="@agent or room-wide operator update"
                  value=${dn.value}
                  onInput=${c=>{dn.value=c.target.value}}
                  onKeyDown=${c=>{c.key==="Enter"&&co()}}
                  disabled=${H.value}
                />
                <button class="control-btn" onClick=${()=>{co()}} disabled=${H.value||dn.value.trim()===""}>
                  Send
                </button>
              </div>

              <label class="control-label" for="ops-pause-reason">Pause or Resume</label>
              <div class="control-row ops-split-row">
                <input
                  id="ops-pause-reason"
                  class="control-input"
                  type="text"
                  value=${Ys.value}
                  onInput=${c=>{Ys.value=c.target.value}}
                  disabled=${H.value}
                />
                <button class="control-btn ghost" onClick=${()=>{am()}} disabled=${H.value}>
                  Pause
                </button>
                <button class="control-btn ghost" onClick=${()=>{sm()}} disabled=${H.value}>
                  Resume
                </button>
              </div>

              <div class="ops-section-head">Inject Work</div>
              <input
                class="control-input"
                type="text"
                placeholder="Task title"
                value=${un.value}
                onInput=${c=>{un.value=c.target.value}}
                disabled=${H.value}
              />
              <textarea
                class="control-textarea"
                rows=${3}
                placeholder="Task description"
                value=${Ta.value}
                onInput=${c=>{Ta.value=c.target.value}}
                disabled=${H.value}
              ></textarea>
              <div class="control-row ops-split-row">
                <select
                  class="control-input ops-select"
                  value=${Xs.value}
                  onChange=${c=>{Xs.value=c.target.value}}
                  disabled=${H.value}
                >
                  <option value="1">P1</option>
                  <option value="2">P2</option>
                  <option value="3">P3</option>
                  <option value="4">P4</option>
                  <option value="5">P5</option>
                </select>
                <button class="control-btn" onClick=${()=>{im()}} disabled=${H.value||un.value.trim()===""}>
                  Inject
                </button>
              </div>
            </div>

            <div class="ops-studio-group">
              <div class="ops-section-head">Selected Session</div>
              ${r?s`
                <div class="ops-detail-card">
                  <div class="ops-detail-title">${r.session_id}</div>
                  <div class="ops-detail-meta">
                    <span>Status: ${r.status??"unknown"}</span>
                    <span>Elapsed: ${r.elapsed_sec??0}s</span>
                    <span>Remaining: ${r.remaining_sec??0}s</span>
                  </div>
                  ${r.recent_events&&r.recent_events.length>0?s`
                    <pre class="ops-code-block compact">${cs(r.recent_events.slice(-3))}</pre>
                  `:null}
                </div>
              `:s`<div class="ops-empty">Select a team session to edit notes, inject tasks, or stop the run.</div>`}

              <label class="control-label" for="ops-turn-kind">Session Action</label>
              <div class="control-row ops-split-row">
                <select
                  id="ops-turn-kind"
                  class="control-input ops-select"
                  value=${Oe.value}
                  onChange=${c=>{Oe.value=c.target.value}}
                  disabled=${H.value||!r}
                >
                  <option value="note">Note</option>
                  <option value="broadcast">Broadcast</option>
                  <option value="task">Task</option>
                  <option value="checkpoint">Checkpoint</option>
                </select>
                <button class="control-btn" onClick=${()=>{om()}} disabled=${H.value||!r}>
                  Apply
                </button>
              </div>
              <textarea
                class="control-textarea"
                rows=${3}
                placeholder="Session message"
                value=${Ra.value}
                onInput=${c=>{Ra.value=c.target.value}}
                disabled=${H.value||!r}
              ></textarea>
              ${Oe.value==="task"?s`
                <input
                  class="control-input"
                  type="text"
                  placeholder="Injected task title"
                  value=${La.value}
                  onInput=${c=>{La.value=c.target.value}}
                  disabled=${H.value||!r}
                />
                <textarea
                  class="control-textarea"
                  rows=${2}
                  placeholder="Injected task description"
                  value=${Pa.value}
                  onInput=${c=>{Pa.value=c.target.value}}
                  disabled=${H.value||!r}
                ></textarea>
                <select
                  class="control-input ops-select"
                  value=${Zs.value}
                  onChange=${c=>{Zs.value=c.target.value}}
                  disabled=${H.value||!r}
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
                  value=${ti.value}
                  onInput=${c=>{ti.value=c.target.value}}
                  disabled=${H.value||!r}
                />
                <button class="control-btn ghost" onClick=${()=>{rm()}} disabled=${H.value||!r}>
                  Stop
                </button>
              </div>
            </div>

            <div class="ops-studio-group">
              <div class="ops-section-head">Selected Keeper</div>
              ${l?s`
                <div class="ops-detail-card">
                  <div class="ops-detail-title">${l.name}</div>
                  <div class="ops-detail-meta">
                    <span>Autonomy: ${l.autonomy_level??"n/a"}</span>
                    <span>Generation: ${l.generation??0}</span>
                    <span>Goals: ${((v=l.active_goal_ids)==null?void 0:v.length)??0}</span>
                  </div>
                </div>
              `:s`<div class="ops-empty">Select a keeper to send a direct intervention.</div>`}

              <label class="control-label" for="ops-keeper-message">Keeper Message</label>
              <textarea
                id="ops-keeper-message"
                class="control-textarea"
                rows=${6}
                placeholder="Send a structured intervention or course correction"
                value=${pn.value}
                onInput=${c=>{pn.value=c.target.value}}
                disabled=${H.value||!l}
              ></textarea>
              <div class="control-row">
                <button class="control-btn" onClick=${()=>{lm()}} disabled=${H.value||!l||pn.value.trim()===""}>
                  Send Keeper Message
                </button>
              </div>
            </div>
          </section>
        </div>
      </div>
    </section>
  `}function dm({text:t}){if(!t)return null;const e=um(t);return s`<div class="markdown-content">${e}</div>`}function um(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const i=e[a];if(/^(`{3,}|~{3,})/.test(i)){const r=i.match(/^(`{3,}|~{3,})/)[0],l=i.slice(r.length).trim(),p=[];for(a++;a<e.length&&!e[a].startsWith(r);)p.push(e[a]),a++;a++,n.push(s`<pre><code class=${l?`language-${l}`:""}>${p.join(`
`)}</code></pre>`);continue}if(i.trim()==="<think>"||i.trim().startsWith("<think>")){const r=[],l=i.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const $=e[a].replace("</think>","").trim();$&&r.push($),a++}const p=r.join(`
`).trim();n.push(s`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${ds(p)}</div>
        </details>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
      `);continue}if(i.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(s`<blockquote>${ds(r.join(`
`))}</blockquote>`);continue}if(i.trim()===""){a++;continue}const o=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;o.push(r),a++}o.length>0&&n.push(s`<p>${ds(o.join(`
`))}</p>`)}return n}function ds(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,i;for(;(i=n.exec(t))!==null;){if(i.index>a&&e.push(t.slice(a,i.index)),i[1]){const o=i[1].slice(1,-1);e.push(s`<code>${o}</code>`)}else if(i[2]){const o=i[2].slice(2,-2);e.push(s`<strong>${o}</strong>`)}else if(i[3]){const o=i[3].slice(1,-1);e.push(s`<em>${o}</em>`)}else i[4]&&i[5]&&e.push(s`<a href=${i[5]} target="_blank" rel="noopener">${i[4]}</a>`);a=i.index+i[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const sn=_("posts"),ni=_([]),ai=_([]),mn=_(""),Ea=_(!1),vn=_(!1),Dn=_(""),Ia=_(null),Tt=_(null),si=_(!1),Yt=_(null),aa=_(null);async function Va(){Ea.value=!0,Dn.value="";try{const[t,e]=await Promise.all([gc(),$c()]);ni.value=t,ai.value=e,Yt.value=!0,aa.value=Date.now()}catch(t){Dn.value=t instanceof Error?t.message:"Failed to load council data",Yt.value=!1}finally{Ea.value=!1}}id(Va);async function po(){const t=mn.value.trim();if(t){vn.value=!0;try{const e=await hc(t);mn.value="",w(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Va()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";w(n,"error")}finally{vn.value=!1}}}async function pm(t){Ia.value=t,si.value=!0,Tt.value=null;try{Tt.value=await yc(t)}catch(e){Dn.value=e instanceof Error?e.message:"Failed to load debate status",Tt.value=null}finally{si.value=!1}}const Rr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],sa=_(null),fn=_([]),$e=_(!1),fe=_(null),_n=_("");function mm(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const vm=_(mm()),gn=_(!1);async function Li(t){fe.value=t,sa.value=null,fn.value=[],$e.value=!0;try{const e=await Fl(t);if(fe.value!==t)return;sa.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},fn.value=e.comments??[]}catch{fe.value===t&&(sa.value=null,fn.value=[])}finally{fe.value===t&&($e.value=!1)}}async function mo(t){const e=_n.value.trim();if(e){gn.value=!0;try{await Kl(t,vm.value,e),_n.value="",w("Comment posted","success"),await Li(t),zt()}catch{w("Failed to post comment","error")}finally{gn.value=!1}}}function fm(){const t=An.value;return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
      `);continue}if(i.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(s`<blockquote>${ls(r.join(`
`))}</blockquote>`);continue}if(i.trim()===""){a++;continue}const o=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;o.push(r),a++}o.length>0&&n.push(s`<p>${ls(o.join(`
`))}</p>`)}return n}function ls(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,i;for(;(i=n.exec(t))!==null;){if(i.index>a&&e.push(t.slice(a,i.index)),i[1]){const o=i[1].slice(1,-1);e.push(s`<code>${o}</code>`)}else if(i[2]){const o=i[2].slice(2,-2);e.push(s`<strong>${o}</strong>`)}else if(i[3]){const o=i[3].slice(1,-1);e.push(s`<em>${o}</em>`)}else i[4]&&i[5]&&e.push(s`<a href=${i[5]} target="_blank" rel="noopener">${i[4]}</a>`);a=i.index+i[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const an=f("posts"),ti=f([]),ei=f([]),mn=f(""),Da=f(!1),vn=f(!1),Dn=f(""),Ea=f(null),Tt=f(null),ni=f(!1),Yt=f(null),aa=f(null);async function Ja(){Da.value=!0,Dn.value="";try{const[t,e]=await Promise.all([fc(),gc()]);ti.value=t,ei.value=e,Yt.value=!0,aa.value=Date.now()}catch(t){Dn.value=t instanceof Error?t.message:"Failed to load council data",Yt.value=!1}finally{Da.value=!1}}ad(Ja);async function lo(){const t=mn.value.trim();if(t){vn.value=!0;try{const e=await _c(t);mn.value="",w(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Ja()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";w(n,"error")}finally{vn.value=!1}}}async function dm(t){Ea.value=t,ni.value=!0,Tt.value=null;try{Tt.value=await $c(t)}catch(e){Dn.value=e instanceof Error?e.message:"Failed to load debate status",Tt.value=null}finally{ni.value=!1}}const Tr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],sa=f(null),fn=f([]),he=f(!1),ge=f(null),gn=f("");function um(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const pm=f(um()),_n=f(!1);async function Ti(t){ge.value=t,sa.value=null,fn.value=[],he.value=!0;try{const e=await ql(t);if(ge.value!==t)return;sa.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},fn.value=e.comments??[]}catch{ge.value===t&&(sa.value=null,fn.value=[])}finally{ge.value===t&&(he.value=!1)}}async function co(t){const e=gn.value.trim();if(e){_n.value=!0;try{await jl(t,pm.value,e),gn.value="",w("Comment posted","success"),await Ti(t),zt()}catch{w("Failed to post comment","error")}finally{_n.value=!1}}}function mm(){const t=An.value;return s`
========
      `);continue}if(i.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(s`<blockquote>${ls(r.join(`
`))}</blockquote>`);continue}if(i.trim()===""){a++;continue}const o=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;o.push(r),a++}o.length>0&&n.push(s`<p>${ls(o.join(`
`))}</p>`)}return n}function ls(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,i;for(;(i=n.exec(t))!==null;){if(i.index>a&&e.push(t.slice(a,i.index)),i[1]){const o=i[1].slice(1,-1);e.push(s`<code>${o}</code>`)}else if(i[2]){const o=i[2].slice(2,-2);e.push(s`<strong>${o}</strong>`)}else if(i[3]){const o=i[3].slice(1,-1);e.push(s`<em>${o}</em>`)}else i[4]&&i[5]&&e.push(s`<a href=${i[5]} target="_blank" rel="noopener">${i[4]}</a>`);a=i.index+i[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const an=f("posts"),ti=f([]),ei=f([]),mn=f(""),Da=f(!1),vn=f(!1),Dn=f(""),Ea=f(null),Tt=f(null),ni=f(!1),Xt=f(null),aa=f(null);async function Ja(){Da.value=!0,Dn.value="";try{const[t,e]=await Promise.all([fc(),gc()]);ti.value=t,ei.value=e,Xt.value=!0,aa.value=Date.now()}catch(t){Dn.value=t instanceof Error?t.message:"Failed to load council data",Xt.value=!1}finally{Da.value=!1}}ad(Ja);async function lo(){const t=mn.value.trim();if(t){vn.value=!0;try{const e=await _c(t);mn.value="",C(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Ja()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";C(n,"error")}finally{vn.value=!1}}}async function dm(t){Ea.value=t,ni.value=!0,Tt.value=null;try{Tt.value=await $c(t)}catch(e){Dn.value=e instanceof Error?e.message:"Failed to load debate status",Tt.value=null}finally{ni.value=!1}}const Tr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],sa=f(null),fn=f([]),he=f(!1),ge=f(null),gn=f("");function um(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const pm=f(um()),_n=f(!1);async function Ti(t){ge.value=t,sa.value=null,fn.value=[],he.value=!0;try{const e=await ql(t);if(ge.value!==t)return;sa.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},fn.value=e.comments??[]}catch{ge.value===t&&(sa.value=null,fn.value=[])}finally{ge.value===t&&(he.value=!1)}}async function co(t){const e=gn.value.trim();if(e){_n.value=!0;try{await jl(t,pm.value,e),gn.value="",C("Comment posted","success"),await Ti(t),qt()}catch{C("Failed to post comment","error")}finally{_n.value=!1}}}function mm(){const t=An.value;return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="board-toolbar">
      <div class="board-controls">
        ${Rr.map(e=>s`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{An.value=e.id,qt()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${ue.value?"is-active":""}"
          onClick=${()=>{ue.value=!ue.value,qt()}}
        >
          ${ue.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${qt} disabled=${wn.value}>
          ${wn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function ii(){var e;const t=(e=ae.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function ai(){var e;const t=(e=ae.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:s`
========
  `}function ai(){var e;const t=(e=se.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?s`<span class="feed-health-meta">Last sync: <${F} timestamp=${t.last_sync_at} /></span>`:s`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Lr({flair:t}){return t?s`<span class="post-flair ${t}">${t}</span>`:null}function _m(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function vo(t){return t.updated_at!==t.created_at}function oi(){var n;const t=((n=Rr.find(a=>a.id===An.value))==null?void 0:n.label)??An.value,e=Be.value.length;return s`
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
        <strong>${ue.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Bs.value?s`<${F} timestamp=${Bs.value} />`:"Not loaded"}</strong>
      </div>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function gm({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await Oo(t.id,n),zt()}catch{w("Failed to vote","error")}};return s`
    <div class="board-post" onClick=${()=>el(t.id)}>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function fm({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await Eo(t.id,n),zt()}catch{w("Failed to vote","error")}};return s`
    <div class="board-post" onClick=${()=>Zr(t.id)}>
========
  `}function fm({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await Eo(t.id,n),qt()}catch{C("Failed to vote","error")}};return s`
    <div class="board-post" onClick=${()=>Zr(t.id)}>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
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
              <${Lr} flair=${t.flair} />
              ${vo(t)?s`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${F} timestamp=${t.created_at} /></span>
            ${vo(t)?s`<span>Updated <${F} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?s`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${_m(t.content)}</div>
      </div>
    </div>
  `}function $m({comments:t}){return t.length===0?s`<div class="empty-state" style="font-size:13px">No comments yet</div>`:s`
    <div class="comment-thread">
      ${t.map(e=>s`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${F} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function hm({postId:t}){return s`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${_n.value}
        onInput=${e=>{_n.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&mo(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${gn.value}
      />
      <button
        onClick=${()=>mo(t)}
        disabled=${gn.value||_n.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${gn.value?"...":"Post"}
      </button>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function ym({post:t}){fe.value!==t.id&&!$e.value&&Li(t.id);const e=async n=>{try{await Oo(t.id,n),zt()}catch{w("Failed to vote","error")}};return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function $m({post:t}){ge.value!==t.id&&!he.value&&Ti(t.id);const e=async n=>{try{await Eo(t.id,n),zt()}catch{w("Failed to vote","error")}};return s`
========
  `}function $m({post:t}){ge.value!==t.id&&!he.value&&Ti(t.id);const e=async n=>{try{await Eo(t.id,n),qt()}catch{C("Failed to vote","error")}};return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div>
      <button class="back-btn" onClick=${()=>Rt("board")}>← Back to Board</button>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
      <${C} title=${s`${t.title} <${Lr} flair=${t.flair} />`}>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
      <${C} title=${s`${t.title} <${Nr} flair=${t.flair} />`}>
========
      <${w} title=${s`${t.title} <${Nr} flair=${t.flair} />`}>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        <div class="board-detail">
          <div class="post-body">
            <${dm} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${F} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?s`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
      <${C} title="Comments (${$e.value?"...":fn.value.length})">
        ${$e.value?s`<div class="loading-indicator">Loading comments...</div>`:s`<${$m} comments=${fn.value} />`}
        <${hm} postId=${t.id} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
      <${C} title="Comments (${he.value?"...":fn.value.length})">
        ${he.value?s`<div class="loading-indicator">Loading comments...</div>`:s`<${gm} comments=${fn.value} />`}
        <${_m} postId=${t.id} />
========
      <${w} title="Comments (${he.value?"...":fn.value.length})">
        ${he.value?s`<div class="loading-indicator">Loading comments...</div>`:s`<${gm} comments=${fn.value} />`}
        <${_m} postId=${t.id} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      <//>
    </div>
  `}function bm({debate:t}){const e=Ia.value===t.id;return s`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>pm(t.id)}
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
  `}function km({session:t}){return s`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.state?s`<span>State: ${t.state}</span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Pr(){return Yt.value===null||Yt.value&&!aa.value?null:s`
    <div class="feed-health-banner ${Yt.value===!1?"degraded":"ok"}">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Rr(){return Yt.value===null||Yt.value&&!aa.value?null:s`
    <div class="feed-health-banner ${Yt.value===!1?"degraded":"ok"}">
========
  `}function Rr(){return Xt.value===null||Xt.value&&!aa.value?null:s`
    <div class="feed-health-banner ${Xt.value===!1?"degraded":"ok"}">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      <span class="feed-health-title">
        ${Xt.value===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${aa.value?s`<span class="feed-health-meta">Last sync: <${F} timestamp=${aa.value} /></span>`:s`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function xm(){const t=Yt.value===!1;return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function bm(){const t=Yt.value===!1;return s`
========
  `}function bm(){const t=Xt.value===!1;return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
      <${Pr} />
      <${C} title="Start Debate" class="section">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
      <${Rr} />
      <${C} title="Start Debate" class="section">
========
      <${Rr} />
      <${w} title="Start Debate" class="section">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${mn.value}
            onInput=${e=>{mn.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&po()}}
            disabled=${vn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${po}
            disabled=${vn.value||mn.value.trim()===""}
          >
            ${vn.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Va} disabled=${Ea.value}>
            ${Ea.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Dn.value?s`<div class="council-error">${Dn.value}</div>`:null}
      <//>

      <${w} title="Debates" class="section">
        <div class="council-list">
          ${ni.value.length===0?s`<div class="empty-state">${t?"No debates loaded (council feed degraded).":"No debates yet"}</div>`:ni.value.map(e=>s`<${bm} key=${e.id} debate=${e} />`)}
        </div>
      <//>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
      <${C} title=${Ia.value?`Debate Detail (${Ia.value})`:"Debate Detail"} class="section">
        ${si.value?s`<div class="loading-indicator">Loading debate detail...</div>`:Tt.value?s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
      <${C} title=${Ea.value?`Debate Detail (${Ea.value})`:"Debate Detail"} class="section">
        ${ni.value?s`<div class="loading-indicator">Loading debate detail...</div>`:Tt.value?s`
========
      <${w} title=${Ea.value?`Debate Detail (${Ea.value})`:"Debate Detail"} class="section">
        ${ni.value?s`<div class="loading-indicator">Loading debate detail...</div>`:Tt.value?s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${Tt.value.status}</span>
                  <span>Total arguments: ${Tt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${Tt.value.support_count}</span>
                  <span>Oppose: ${Tt.value.oppose_count}</span>
                  <span>Neutral: ${Tt.value.neutral_count}</span>
                </div>
                ${Tt.value.summary_text?s`<pre class="council-detail">${Tt.value.summary_text}</pre>`:null}
              `:s`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Sm(){const t=Yt.value===!1;return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function km(){const t=Yt.value===!1;return s`
========
  `}function km(){const t=Xt.value===!1;return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
      <${Pr} />
      <${C} title="Voting Sessions" class="section">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
      <${Rr} />
      <${C} title="Voting Sessions" class="section">
========
      <${Rr} />
      <${w} title="Voting Sessions" class="section">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        <div class="council-list">
          ${ai.value.length===0?s`<div class="empty-state">${t?"No sessions loaded (council feed degraded).":"No active sessions"}</div>`:ai.value.map(e=>s`<${km} key=${e.id} session=${e} />`)}
        </div>
      <//>
    </div>
  `}function Am(){const t=sn.value;return s`
    <div class="overview-sub-tabs" style="margin-bottom: 12px;">
      <button class="sub-tab-btn ${t==="posts"?"active":""}" onClick=${()=>{sn.value="posts"}}>Posts</button>
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{sn.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{sn.value="voting"}}>Voting</button>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function wm(){var a,i;const t=Be.value,e=Cn.value,n=((i=(a=ae.value)==null?void 0:a.data_quality)==null?void 0:i.board_contract_ok)===!1;return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Sm(){var a,i;const t=Be.value,e=Cn.value,n=((i=(a=ae.value)==null?void 0:a.data_quality)==null?void 0:i.board_contract_ok)===!1;return s`
========
  `}function Sm(){var a,i;const t=Be.value,e=wn.value,n=((i=(a=se.value)==null?void 0:a.data_quality)==null?void 0:i.board_contract_ok)===!1;return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div>
      <${ii} />
      <${oi} />
      <${fm} />
      ${e?s`<div class="loading-indicator">Loading board...</div>`:t.length===0?s`
              <div class="empty-state">
                ${n?"No posts loaded (board feed degraded). Check board contract sync.":ue.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
              </div>
            `:s`<div class="board-post-list">
              ${t.map(o=>s`<${gm} key=${o.id} post=${o} />`)}
            </div>`}
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Cm(){var i,o;const t=Be.value,e=tt.value.postId,n=((o=(i=ae.value)==null?void 0:i.data_quality)==null?void 0:o.board_contract_ok)===!1,a=sn.value;if(rt(()=>{(a==="debates"||a==="voting")&&Va()},[a]),e){const r=t.find(l=>l.id===e)??(fe.value===e?sa.value:null);return!r&&fe.value!==e&&!$e.value&&Li(e),r?s`
          <${ii} />
          <${oi} />
          <${ym} post=${r} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Am(){var i,o;const t=Be.value,e=tt.value.postId,n=((o=(i=ae.value)==null?void 0:i.data_quality)==null?void 0:o.board_contract_ok)===!1,a=an.value;if(rt(()=>{(a==="debates"||a==="voting")&&Ja()},[a]),e){const r=t.find(l=>l.id===e)??(ge.value===e?sa.value:null);return!r&&ge.value!==e&&!he.value&&Ti(e),r?s`
          <${ai} />
          <${si} />
          <${$m} post=${r} />
========
  `}function Am(){var i,o;const t=Be.value,e=nt.value.postId,n=((o=(i=se.value)==null?void 0:i.data_quality)==null?void 0:o.board_contract_ok)===!1,a=an.value;if(rt(()=>{(a==="debates"||a==="voting")&&Ja()},[a]),e){const r=t.find(l=>l.id===e)??(ge.value===e?sa.value:null);return!r&&ge.value!==e&&!he.value&&Ti(e),r?s`
          <${ai} />
          <${si} />
          <${$m} post=${r} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        `:s`
          <div>
            <${ii} />
            <${oi} />
            <button class="back-btn" onClick=${()=>Rt("board")}>← Back to Board</button>
            ${$e.value?s`<div class="loading-indicator">Loading post...</div>`:s`
                  <div class="empty-state">
                    ${n?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return s`
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
    <${Am} />
    ${a==="debates"?s`<${xm} />`:a==="voting"?s`<${Sm} />`:s`<${wm} />`}
  `}const Tm=40;function Nm({items:t,itemHeight:e,overscan:n=5,renderItem:a,getKey:i,className:o=""}){const r=wo(null),[l,p]=Ua({start:0,end:30}),$=t.length>Tm;if(rt(()=>{if(!$)return;const c=r.current;if(!c)return;let y=!1;const S=()=>{const{scrollTop:M,clientHeight:N}=c,P=Math.max(0,Math.floor(M/e)-n),et=Math.min(t.length,Math.ceil((M+N)/e)+n);p(U=>U.start===P&&U.end===et?U:{start:P,end:et})};let T=!1;const D=()=>{T||y||(T=!0,requestAnimationFrame(()=>{y||S(),T=!1}))},L=new ResizeObserver(()=>{y||S()});return S(),c.addEventListener("scroll",D,{passive:!0}),L.observe(c),()=>{y=!0,c.removeEventListener("scroll",D),L.disconnect()}},[$,t.length,e,n]),!$)return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
    <${xm} />
    ${a==="debates"?s`<${bm} />`:a==="voting"?s`<${km} />`:s`<${Sm} />`}
  `}const wm=40;function Cm({items:t,itemHeight:e,overscan:n=5,renderItem:a,getKey:i,className:o=""}){const r=xo(null),[l,p]=Ha({start:0,end:30}),_=t.length>wm;if(rt(()=>{if(!_)return;const g=r.current;if(!g)return;let y=!1;const S=()=>{const{scrollTop:M,clientHeight:N}=g,P=Math.max(0,Math.floor(M/e)-n),et=Math.min(t.length,Math.ceil((M+N)/e)+n);p(U=>U.start===P&&U.end===et?U:{start:P,end:et})};let T=!1;const D=()=>{T||y||(T=!0,requestAnimationFrame(()=>{y||S(),T=!1}))},L=new ResizeObserver(()=>{y||S()});return S(),g.addEventListener("scroll",D,{passive:!0}),L.observe(g),()=>{y=!0,g.removeEventListener("scroll",D),L.disconnect()}},[_,t.length,e,n]),!_)return s`
========
    <${xm} />
    ${a==="debates"?s`<${bm} />`:a==="voting"?s`<${km} />`:s`<${Sm} />`}
  `}const Cm=40;function wm({items:t,itemHeight:e,overscan:n=5,renderItem:a,getKey:i,className:o=""}){const r=xo(null),[l,p]=Ha({start:0,end:30}),_=t.length>Cm;if(rt(()=>{if(!_)return;const g=r.current;if(!g)return;let y=!1;const S=()=>{const{scrollTop:I,clientHeight:N}=g,R=Math.max(0,Math.floor(I/e)-n),X=Math.min(t.length,Math.ceil((I+N)/e)+n);p(H=>H.start===R&&H.end===X?H:{start:R,end:X})};let T=!1;const P=()=>{T||y||(T=!0,requestAnimationFrame(()=>{y||S(),T=!1}))},K=new ResizeObserver(()=>{y||S()});return S(),g.addEventListener("scroll",P,{passive:!0}),K.observe(g),()=>{y=!0,g.removeEventListener("scroll",P),K.disconnect()}},[_,t.length,e,n]),!_)return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      <div class=${o}>
        ${t.map((c,y)=>a(c,y))}
      </div>
    `;const m=t.length*e,d=l.start*e,v=t.slice(l.start,l.end);return s`
    <div ref=${r} class=${o}>
      <div class="virtual-list-spacer" style=${{height:`${m}px`,position:"relative"}}>
        <div
          class="virtual-list-viewport"
          style=${{position:"absolute",top:0,left:0,right:0,willChange:"transform",transform:`translateY(${d}px)`}}
        >
          ${v.map((c,y)=>{const S=l.start+y;return s`<div key=${i(c)}>${a(c,S)}</div>`})}
        </div>
      </div>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Rm(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function Lm(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function Pm(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const Dr=120,Dm=12,Em=16,Im=12,ri=_("all"),Mm={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},Om={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function zm(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function qm(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:Rm(t),actor:Lm(t),content:Pm(t),timestamp:new Date(t.timestamp).toISOString()}}function jm(t,e){var i;const n=(i=t.assignee)==null?void 0:i.trim(),a=t.updated_at??t.created_at;return!n||!a?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:a}}function Fm(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function Hn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function li(t){return t.last_heartbeat??Hn(t.last_turn_ago_s)??Hn(t.last_proactive_ago_s)??Hn(t.last_handoff_ago_s)??Hn(t.last_compaction_ago_s)}function Km(t,e){const n=li(t);if(!n)return null;const a=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${a}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${a}`,timestamp:n}}function Et(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const ci=St(()=>{const t=Sn.value.map(zm),e=ca.value.map(qm),n=[...$t.value].sort((o,r)=>Et(r.updated_at??r.created_at??0)-Et(o.updated_at??o.created_at??0)).slice(0,Dm).map(jm).filter(o=>o!==null),a=[...Be.value].sort((o,r)=>Et(r.updated_at||r.created_at)-Et(o.updated_at||o.created_at)).slice(0,Em).map(Fm),i=[...Gt.value].sort((o,r)=>Et(li(r)??0)-Et(li(o)??0)).slice(0,Im).map(Km).filter(o=>o!==null);return[...t,...e,...n,...a,...i].sort((o,r)=>Et(r.timestamp)-Et(o.timestamp))}),Hm=St(()=>{const t=ci.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),Um=St(()=>{const t=ri.value;return(t==="all"?ci.value:ci.value.filter(n=>n.kind===t)).slice(0,Dr)}),Bm=St(()=>{const t=Wa.value,e={activeAssignedCount:0,lastActivityAt:null,lastActivityText:null};return xt.value.map(n=>({agent:n,motion:t.get(n.name.trim().toLowerCase())??e})).sort((n,a)=>{const i=a.motion.activeAssignedCount-n.motion.activeAssignedCount;return i!==0?i:Et(a.motion.lastActivityAt??0)-Et(n.motion.lastActivityAt??0)})});function Wm(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function tn({label:t,value:e,color:n}){return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Tm(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function Nm(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function Rm(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const Lr=120,Lm=12,Pm=16,Dm=12,ii=f("all"),Em={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},Im={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function Mm(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Om(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:Tm(t),actor:Nm(t),content:Rm(t),timestamp:new Date(t.timestamp).toISOString()}}function zm(t,e){var i;const n=(i=t.assignee)==null?void 0:i.trim(),a=t.updated_at??t.created_at;return!n||!a?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:a}}function qm(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function Hn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function oi(t){return t.last_heartbeat??Hn(t.last_turn_ago_s)??Hn(t.last_proactive_ago_s)??Hn(t.last_handoff_ago_s)??Hn(t.last_compaction_ago_s)}function jm(t,e){const n=oi(t);if(!n)return null;const a=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${a}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${a}`,timestamp:n}}function Et(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const ri=St(()=>{const t=Sn.value.map(Mm),e=ca.value.map(Om),n=[...$t.value].sort((o,r)=>Et(r.updated_at??r.created_at??0)-Et(o.updated_at??o.created_at??0)).slice(0,Lm).map(zm).filter(o=>o!==null),a=[...Be.value].sort((o,r)=>Et(r.updated_at||r.created_at)-Et(o.updated_at||o.created_at)).slice(0,Pm).map(qm),i=[...Gt.value].sort((o,r)=>Et(oi(r)??0)-Et(oi(o)??0)).slice(0,Dm).map(jm).filter(o=>o!==null);return[...t,...e,...n,...a,...i].sort((o,r)=>Et(r.timestamp)-Et(o.timestamp))}),Fm=St(()=>{const t=ri.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),Km=St(()=>{const t=ii.value;return(t==="all"?ri.value:ri.value.filter(n=>n.kind===t)).slice(0,Lr)}),Hm=St(()=>{const t=Ba.value,e={activeAssignedCount:0,lastActivityAt:null,lastActivityText:null};return xt.value.map(n=>({agent:n,motion:t.get(n.name.trim().toLowerCase())??e})).sort((n,a)=>{const i=a.motion.activeAssignedCount-n.motion.activeAssignedCount;return i!==0?i:Et(a.motion.lastActivityAt??0)-Et(n.motion.lastActivityAt??0)})});function Um(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function Ze({label:t,value:e,color:n}){return s`
========
  `}function Tm(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function Nm(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function Rm(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const Lr=120,Lm=12,Pm=16,Dm=12,ii=f("all"),Em={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},Im={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function Mm(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Om(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:Tm(t),actor:Nm(t),content:Rm(t),timestamp:new Date(t.timestamp).toISOString()}}function zm(t,e){var i;const n=(i=t.assignee)==null?void 0:i.trim(),a=t.updated_at??t.created_at;return!n||!a?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:a}}function qm(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function Hn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function oi(t){return t.last_heartbeat??Hn(t.last_turn_ago_s)??Hn(t.last_proactive_ago_s)??Hn(t.last_handoff_ago_s)??Hn(t.last_compaction_ago_s)}function jm(t,e){const n=oi(t);if(!n)return null;const a=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${a}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${a}`,timestamp:n}}function It(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const ri=Ct(()=>{const t=Sn.value.map(Mm),e=ca.value.map(Om),n=[...yt.value].sort((o,r)=>It(r.updated_at??r.created_at??0)-It(o.updated_at??o.created_at??0)).slice(0,Lm).map(zm).filter(o=>o!==null),a=[...Be.value].sort((o,r)=>It(r.updated_at||r.created_at)-It(o.updated_at||o.created_at)).slice(0,Pm).map(qm),i=[...Jt.value].sort((o,r)=>It(oi(r)??0)-It(oi(o)??0)).slice(0,Dm).map(jm).filter(o=>o!==null);return[...t,...e,...n,...a,...i].sort((o,r)=>It(r.timestamp)-It(o.timestamp))}),Fm=Ct(()=>{const t=ri.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),Km=Ct(()=>{const t=ii.value;return(t==="all"?ri.value:ri.value.filter(n=>n.kind===t)).slice(0,Lr)}),Hm=Ct(()=>{const t=Ba.value,e={activeAssignedCount:0,lastActivityAt:null,lastActivityText:null};return At.value.map(n=>({agent:n,motion:t.get(n.name.trim().toLowerCase())??e})).sort((n,a)=>{const i=a.motion.activeAssignedCount-n.motion.activeAssignedCount;return i!==0?i:It(a.motion.lastActivityAt??0)-It(n.motion.lastActivityAt??0)})});function Um(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function Ze({label:t,value:e,color:n}){return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function Gm({row:t}){return s`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${Wm(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${Om[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function Jm(){const t=Hm.value,e=Um.value,n=e[0],a=Bm.value;return s`
    <div class="stats-grid">
      <${tn} label="Visible rows" value=${e.length} />
      <${tn} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${tn} label="Keeper signals" value=${t.keepers} color="#4ade80" />
      <${tn} label="Board signals" value=${t.board} color="#fbbf24" />
      <${tn} label="SSE events" value=${In.value} color="#c084fc" />
    </div>

    <${w} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(i=>s`
            <button
              class="goal-filter-btn ${ri.value===i?"active":""}"
              onClick=${()=>{ri.value=i}}
            >
              ${Mm[i]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${Ft.value?"":"pill-stale"}">
            ${Ft.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?s`Latest: <${F} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${Dr} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
      ${e.length===0?s`<div class="terminal-feed"><div class="empty-state">Waiting for live or snapshot signals...</div></div>`:s`<${Nm}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
      ${e.length===0?s`<div class="terminal-feed"><div class="empty-state">Waiting for live or snapshot signals...</div></div>`:s`<${Cm}
========
      ${e.length===0?s`<div class="terminal-feed"><div class="empty-state">Waiting for live or snapshot signals...</div></div>`:s`<${wm}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
            items=${e}
            itemHeight=${28}
            overscan=${8}
            getKey=${i=>i.id}
            renderItem=${i=>s`<${Gm} row=${i} />`}
            className="terminal-feed"
          />`}
    <//>

    <${w} title="Agent Motion" class="section">
      <div class="activity-motion-list">
        ${a.length===0?s`<div class="empty-state">No active agents</div>`:a.map(({agent:i,motion:o})=>s`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${i.name}</div>
                  <div class="activity-motion-meta">
                    ${o.activeAssignedCount>0?`${o.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${o.lastActivityAt?s` · <${F} timestamp=${o.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${o.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function Er({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,i=e/2,o=2*Math.PI*a,r=o*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),s`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${i}" cy="${i}" r="${a}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${l}" 
          cx="${i}" cy="${i}" r="${a}" 
          stroke-width="${n}" 
          stroke-dasharray="${o}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${l}">${Math.round(t*100)}%</span>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}const us=600*1e3,Vm=1200*1e3,fo=.8;function Vt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Ae(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Qm(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function Ym(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Xm(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Zm(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function tv(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function ev(t){var p,$;const e=Wa.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-Vt(n)):Number.POSITIVE_INFINITY,i=!!((p=t.current_task)!=null&&p.trim())||e.activeAssignedCount>0;let o="watching",r="ok",l="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",r="bad",l=n?"Offline or inactive":"No recent presence"):a>Vm?(o="quiet",r="bad",l=i?"Working without a fresh signal":"No fresh agent signal"):i?(o="working",r=a>us?"warn":"ok",l=a>us?"Execution looks quiet for too long":"Task and live signal aligned"):a>us?(o="quiet",r="warn",l="Quiet but still reachable"):t.status==="idle"&&(o="watching",r="ok",l="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:r,focus:(($=t.current_task)==null?void 0:$.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:l}}function nv(t){const e=Jo.value.get(t.name)??"idle",n=Vo.value.has(t.name),a=t.context_ratio??0;let i="healthy",o="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(i="critical",o="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=fo)&&(i="warning",o="warn",r=a>=fo?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:i,tone:o,focus:Zm(t),note:r}}function en({label:t,value:e,color:n,caption:a}){return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}const cs=600*1e3,Gm=1200*1e3,po=.8;function Vt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function we(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Jm(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function Vm(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Qm(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Ym(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function Xm(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function Zm(t){var p,_;const e=Ba.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-Vt(n)):Number.POSITIVE_INFINITY,i=!!((p=t.current_task)!=null&&p.trim())||e.activeAssignedCount>0;let o="watching",r="ok",l="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",r="bad",l=n?"Offline or inactive":"No recent presence"):a>Gm?(o="quiet",r="bad",l=i?"Working without a fresh signal":"No fresh agent signal"):i?(o="working",r=a>cs?"warn":"ok",l=a>cs?"Execution looks quiet for too long":"Task and live signal aligned"):a>cs?(o="quiet",r="warn",l="Quiet but still reachable"):t.status==="idle"&&(o="watching",r="ok",l="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:r,focus:((_=t.current_task)==null?void 0:_.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:l}}function tv(t){const e=Bo.value.get(t.name)??"idle",n=Wo.value.has(t.name),a=t.context_ratio??0;let i="healthy",o="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(i="critical",o="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=po)&&(i="warning",o="warn",r=a>=po?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:i,tone:o,focus:Ym(t),note:r}}function tn({label:t,value:e,color:n,caption:a}){return s`
========
  `}const cs=600*1e3,Gm=1200*1e3,po=.8;function Qt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Ce(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Jm(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function Vm(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Qm(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Ym(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function Xm(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function Zm(t){var p,_;const e=Ba.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-Qt(n)):Number.POSITIVE_INFINITY,i=!!((p=t.current_task)!=null&&p.trim())||e.activeAssignedCount>0;let o="watching",r="ok",l="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",r="bad",l=n?"Offline or inactive":"No recent presence"):a>Gm?(o="quiet",r="bad",l=i?"Working without a fresh signal":"No fresh agent signal"):i?(o="working",r=a>cs?"warn":"ok",l=a>cs?"Execution looks quiet for too long":"Task and live signal aligned"):a>cs?(o="quiet",r="warn",l="Quiet but still reachable"):t.status==="idle"&&(o="watching",r="ok",l="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:r,focus:((_=t.current_task)==null?void 0:_.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:l}}function tv(t){const e=Bo.value.get(t.name)??"idle",n=Wo.value.has(t.name),a=t.context_ratio??0;let i="healthy",o="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(i="critical",o="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=po)&&(i="warning",o="warn",r=a>=po?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:i,tone:o,focus:Ym(t),note:r}}function tn({label:t,value:e,color:n,caption:a}){return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?s`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function av({item:t}){const e=t.kind==="agent"?()=>Ie(t.agent.name):()=>fa(t.keeper);return s`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?s`<span><${F} timestamp=${t.timestamp} /></span>`:s`<span>No signal</span>`}
      </div>
    </button>
  `}function _o({row:t}){const{agent:e,motion:n}=t;return s`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Ie(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?s`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Er} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Lt} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${Qm(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?s`<span>Signal <${F} timestamp=${t.lastSignalAt} /></span>`:s`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?s`<span>${e.model}</span>`:null}
        ${e.last_seen?s`<span>Seen <${F} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?s`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function sv({row:t}){const{keeper:e}=t;return s`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>fa(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?s`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Er} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Lt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Ym(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?s`<span>Heartbeat <${F} timestamp=${e.last_heartbeat} /></span>`:s`<span>No heartbeat</span>`}
        <span>${tv(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${Xm(e.context_ratio)}</span>
        ${e.model?s`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?s`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function iv(){const t=[...xt.value].map(ev).sort((m,d)=>{const v=Ae(d.tone)-Ae(m.tone);if(v!==0)return v;const c=d.activeTaskCount-m.activeTaskCount;return c!==0?c:Vt(d.lastSignalAt)-Vt(m.lastSignalAt)}),e=[...Gt.value].map(nv).sort((m,d)=>{const v=Ae(d.tone)-Ae(m.tone);if(v!==0)return v;const c=(d.keeper.context_ratio??0)-(m.keeper.context_ratio??0);return c!==0?c:Vt(d.keeper.last_heartbeat)-Vt(m.keeper.last_heartbeat)}),n=t.filter(m=>m.state!=="offline"),a=t.filter(m=>m.state==="offline"),i=n.length,o=t.filter(m=>m.state==="working").length,r=t.filter(m=>m.lastSignalAt&&Date.now()-Vt(m.lastSignalAt)<=12e4).length,l=t.filter(m=>m.tone!=="ok"),p=e.filter(m=>m.tone!=="ok"),$=[...p.map(m=>({kind:"keeper",key:`keeper-${m.keeper.name}`,tone:m.tone,title:m.keeper.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.keeper.last_heartbeat??null,keeper:m.keeper})),...l.map(m=>({kind:"agent",key:`agent-${m.agent.name}`,tone:m.tone,title:m.agent.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.lastSignalAt,agent:m.agent}))].sort((m,d)=>{const v=Ae(d.tone)-Ae(m.tone);return v!==0?v:Vt(d.timestamp)-Vt(m.timestamp)}).slice(0,8);return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function av(){const t=[...xt.value].map(Zm).sort((m,d)=>{const c=we(d.tone)-we(m.tone);if(c!==0)return c;const g=d.activeTaskCount-m.activeTaskCount;return g!==0?g:Vt(d.lastSignalAt)-Vt(m.lastSignalAt)}),e=[...Gt.value].map(tv).sort((m,d)=>{const c=we(d.tone)-we(m.tone);if(c!==0)return c;const g=(d.keeper.context_ratio??0)-(m.keeper.context_ratio??0);return g!==0?g:Vt(d.keeper.last_heartbeat)-Vt(m.keeper.last_heartbeat)}),n=t.filter(m=>m.state!=="offline"),a=t.filter(m=>m.state==="offline"),i=n.length,o=t.filter(m=>m.state==="working").length,r=t.filter(m=>m.lastSignalAt&&Date.now()-Vt(m.lastSignalAt)<=12e4).length,l=t.filter(m=>m.tone!=="ok"),p=e.filter(m=>m.tone!=="ok"),_=[...p.map(m=>({kind:"keeper",key:`keeper-${m.keeper.name}`,tone:m.tone,title:m.keeper.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.keeper.last_heartbeat??null,keeper:m.keeper})),...l.map(m=>({kind:"agent",key:`agent-${m.agent.name}`,tone:m.tone,title:m.agent.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.lastSignalAt,agent:m.agent}))].sort((m,d)=>{const c=we(d.tone)-we(m.tone);return c!==0?c:Vt(d.timestamp)-Vt(m.timestamp)}).slice(0,8);return s`
========
  `}function av(){const t=[...At.value].map(Zm).sort((m,d)=>{const c=Ce(d.tone)-Ce(m.tone);if(c!==0)return c;const g=d.activeTaskCount-m.activeTaskCount;return g!==0?g:Qt(d.lastSignalAt)-Qt(m.lastSignalAt)}),e=[...Jt.value].map(tv).sort((m,d)=>{const c=Ce(d.tone)-Ce(m.tone);if(c!==0)return c;const g=(d.keeper.context_ratio??0)-(m.keeper.context_ratio??0);return g!==0?g:Qt(d.keeper.last_heartbeat)-Qt(m.keeper.last_heartbeat)}),n=t.filter(m=>m.state!=="offline"),a=t.filter(m=>m.state==="offline"),i=n.length,o=t.filter(m=>m.state==="working").length,r=t.filter(m=>m.lastSignalAt&&Date.now()-Qt(m.lastSignalAt)<=12e4).length,l=t.filter(m=>m.tone!=="ok"),p=e.filter(m=>m.tone!=="ok"),_=[...p.map(m=>({kind:"keeper",key:`keeper-${m.keeper.name}`,tone:m.tone,title:m.keeper.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.keeper.last_heartbeat??null,keeper:m.keeper})),...l.map(m=>({kind:"agent",key:`agent-${m.agent.name}`,tone:m.tone,title:m.agent.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.lastSignalAt,agent:m.agent}))].sort((m,d)=>{const c=Ce(d.tone)-Ce(m.tone);return c!==0?c:Qt(d.timestamp)-Qt(m.timestamp)}).slice(0,8);return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="agents-monitor">
      <div class="stats-grid">
        <${en} label="Agents online" value=${i} color="#4ade80" caption="active + idle" />
        <${en} label="Working now" value=${o} color="#fbbf24" caption="task or claimed load" />
        <${en} label="Fresh signals" value=${r} color="#22d3ee" caption="within last 2 minutes" />
        <${en} label="Agent alerts" value=${l.length} color=${l.length>0?"#fb7185":"#4ade80"} caption="quiet or offline" />
        <${en} label="Keeper alerts" value=${p.length} color=${p.length>0?"#fb7185":"#4ade80"} caption="stale or high pressure" />
      </div>

      <${w} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${$.length===0?s`<div class="empty-state">No agent or keeper alerts right now</div>`:$.map(m=>s`<${av} key=${m.key} item=${m} />`)}
        </div>
      <//>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
      <div class="agents-workbench">
        <${C} title="Active Agents" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Live agents stay grouped here first so execution drift is visible before you scan offline history.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?s`<div class="empty-state">No active agents visible</div>`:n.map(m=>s`<${_o} key=${m.agent.name} row=${m} />`)}
          </div>
        <//>

        <${C} title="Keeper Watch" class="section">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
      <div class="grid-2col">
        <${C} title="Keeper Watch" class="section">
========
      <div class="grid-2col">
        <${w} title="Keeper Watch" class="section">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?s`<div class="empty-state">No keepers active</div>`:e.map(m=>s`<${sv} key=${m.keeper.name} row=${m} />`)}
          </div>
        <//>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        <${C} title="Offline Agents" class="section">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        <${C} title="Agent Watch" class="section">
========
        <${w} title="Agent Watch" class="section">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who dropped out of the live loop</h2>
            <p class="monitor-subheadline">Offline rows are separated so they do not drown the active execution monitor.</p>
          </div>
          <div class="monitor-list">
            ${a.length===0?s`<div class="empty-state">No offline agents right now</div>`:a.map(m=>s`<${_o} key=${m.agent.name} row=${m} />`)}
          </div>
        <//>
      </div>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}const Ma=_("all"),Oa=_("all"),di=St(()=>{let t=wn.value;return Ma.value!=="all"&&(t=t.filter(e=>e.horizon===Ma.value)),Oa.value!=="all"&&(t=t.filter(e=>e.status===Oa.value)),t}),ov=St(()=>{const t={short:[],mid:[],long:[]};for(const e of di.value){const n=t[e.horizon];n&&n.push(e)}return t}),rv=St(()=>{const t=Array.from(Uo.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function lv(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Pi(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function ia(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function cv(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function go(t){return t.toFixed(4)}function $o(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function dv({goal:t}){return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}const Ia=f("all"),Ma=f("all"),li=St(()=>{let t=wn.value;return Ia.value!=="all"&&(t=t.filter(e=>e.horizon===Ia.value)),Ma.value!=="all"&&(t=t.filter(e=>e.status===Ma.value)),t}),sv=St(()=>{const t={short:[],mid:[],long:[]};for(const e of li.value){const n=t[e.horizon];n&&n.push(e)}return t}),iv=St(()=>{const t=Array.from(Fo.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function ov(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Ni(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function ia(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function rv(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function vo(t){return t.toFixed(4)}function fo(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function lv({goal:t}){return s`
========
  `}const Ia=f("all"),Ma=f("all"),li=Ct(()=>{let t=Cn.value;return Ia.value!=="all"&&(t=t.filter(e=>e.horizon===Ia.value)),Ma.value!=="all"&&(t=t.filter(e=>e.status===Ma.value)),t}),sv=Ct(()=>{const t={short:[],mid:[],long:[]};for(const e of li.value){const n=t[e.horizon];n&&n.push(e)}return t}),iv=Ct(()=>{const t=Array.from(Fo.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function ov(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Ni(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function ia(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function rv(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function vo(t){return t.toFixed(4)}function fo(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function lv({goal:t}){return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ia(t.horizon)}">
            ${Pi(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${lv(t.priority)}</span>
          ${t.metric?s`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?s`<span class="goal-due">Due: <${F} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?s`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${Lt} status=${t.status} />
        <div class="goal-updated">
          <${F} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function ho({label:t,timestamp:e,source:n,note:a}){return s`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${a?s`<div class="planning-freshness-source">${a}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?s`<${F} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function ps({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,i)=>i.priority-a.priority);return s`
    <${C} title="${Pi(t)} Goals (${e.length})" class="section">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function ds({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,i)=>i.priority-a.priority);return s`
    <${C} title="${Ni(t)} Goals (${e.length})" class="section">
========
  `}function ds({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,i)=>i.priority-a.priority);return s`
    <${w} title="${Ni(t)} Goals (${e.length})" class="section">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      <div class="goal-list">
        ${n.map(a=>s`<${dv} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function uv(){return s`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>s`
          <button
            class="goal-filter-btn ${Ma.value===t?"active":""}"
            onClick=${()=>{Ma.value=t}}
          >
            ${t==="all"?"All":Pi(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>s`
          <button
            class="goal-filter-btn ${Oa.value===t?"active":""}"
            onClick=${()=>{Oa.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function pv(){const t=wn.value,e=t.filter(i=>i.status==="active").length,n=t.filter(i=>i.status==="completed").length,a={short:0,mid:0,long:0};for(const i of t)i.horizon in a&&a[i.horizon]++;return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function dv(){const t=wn.value,e=t.filter(i=>i.status==="active").length,n=t.filter(i=>i.status==="completed").length,a={short:0,mid:0,long:0};for(const i of t)i.horizon in a&&a[i.horizon]++;return s`
========
  `}function dv(){const t=Cn.value,e=t.filter(i=>i.status==="active").length,n=t.filter(i=>i.status==="completed").length,a={short:0,mid:0,long:0};for(const i of t)i.horizon in a&&a[i.horizon]++;return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
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
        <div class="goal-summary-value" style="color:${ia("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ia("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ia("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function mv({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return s`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${Lt} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${go(t.baseline_metric)}</span>
          <span>Current ${go(t.current_metric)}</span>
          <span class=${$o(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${$o(t)}
          </span>
          <span>Elapsed ${cv(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"No explicit target provided"}</div>
        ${t.stop_reason||t.error_message?s`
              <div class="planning-loop-footnote">
                ${t.error_message??t.stop_reason}
              </div>
            `:null}
        <div class="planning-loop-footnote">
          ${t.strict_mode?"Strict hard evidence":"Legacy"} · ${t.worker_engine??"unknown engine"} · ${n}
        </div>
        ${e?s`
              <div class="planning-loop-footnote">
                Latest iteration #${e.iteration}: ${e.changes||e.next_suggestion||"No narrative"}
              </div>
            `:s`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function ms({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return s`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?s`<${F} timestamp=${t.created_at} />`:s`<span>-</span>`}
        ${t.assignee?s`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function vv(){const{todo:t,inProgress:e,done:n}=Go.value;return s`
    <${C} title="Task Backlog" class="section">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function pv(){const{todo:t,inProgress:e,done:n}=Uo.value;return s`
    <${C} title="Task Backlog" class="section">
========
  `}function pv(){const{todo:t,inProgress:e,done:n}=Uo.value;return s`
    <${w} title="Task Backlog" class="section">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?s`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>s`<${ms} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?s`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>s`<${ms} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?s`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>s`<${ms} key=${a.id} task=${a} />`)}
          ${n.length>20?s`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function fv(){const t=ov.value,e=rv.value,n=e.filter(l=>l.status==="running").length,a=e.filter(l=>l.recoverable).length,i=wn.value.filter(l=>l.status==="active").length,o=Fs.value,r=o==="idle"?"No loop running":o==="error"?Ks.value??"MDAL snapshot unavailable":"Current loop snapshot";return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function mv(){const t=sv.value,e=iv.value,n=e.filter(l=>l.status==="running").length,a=e.filter(l=>l.recoverable).length,i=wn.value.filter(l=>l.status==="active").length,o=qs.value,r=o==="idle"?"No loop running":o==="error"?js.value??"MDAL snapshot unavailable":"Current loop snapshot";return s`
========
  `}function mv(){const t=sv.value,e=iv.value,n=e.filter(l=>l.status==="running").length,a=e.filter(l=>l.recoverable).length,i=Cn.value.filter(l=>l.status==="active").length,o=qs.value,r=o==="idle"?"No loop running":o==="error"?js.value??"MDAL snapshot unavailable":"Current loop snapshot";return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${i}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${di.value.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Running loops</div>
          <div class="stat-value" style="color:#fbbf24">${n}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Recoverable loops</div>
          <div class="stat-value" style="color:#38bdf8">${a}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Known loops</div>
          <div class="stat-value">${e.length}</div>
        </div>
      </div>

      <${w} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>/api/v1/mdal/loops</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${Tn} disabled=${Re.value}>
              ${Re.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${je} disabled=${Le.value}>
              ${Le.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{Tn(),je()}}
              disabled=${Re.value||Le.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${ho} label="Goals" timestamp=${Bo.value} source="masc_goal_list" />
          <${ho}
            label="MDAL loops"
            timestamp=${Wo.value}
            source="/api/v1/mdal/loops"
            note=${r}
          />
        </div>
      <//>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
      <${C} title="Goal Pipeline" class="section">
        <${pv} />
        <${uv} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
      <${C} title="Goal Pipeline" class="section">
        <${dv} />
        <${cv} />
========
      <${w} title="Goal Pipeline" class="section">
        <${dv} />
        <${cv} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      <//>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
      ${Re.value&&wn.value.length===0?s`<div class="loading-indicator">Loading goals...</div>`:di.value.length===0?s`<div class="empty-state">No goals match the current filters</div>`:s`
              <${ps} horizon="short" items=${t.short??[]} />
              <${ps} horizon="mid" items=${t.mid??[]} />
              <${ps} horizon="long" items=${t.long??[]} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
      ${Le.value&&wn.value.length===0?s`<div class="loading-indicator">Loading goals...</div>`:li.value.length===0?s`<div class="empty-state">No goals match the current filters</div>`:s`
              <${ds} horizon="short" items=${t.short??[]} />
              <${ds} horizon="mid" items=${t.mid??[]} />
              <${ds} horizon="long" items=${t.long??[]} />
========
      ${Le.value&&Cn.value.length===0?s`<div class="loading-indicator">Loading goals...</div>`:li.value.length===0?s`<div class="empty-state">No goals match the current filters</div>`:s`
              <${ds} horizon="short" items=${t.short??[]} />
              <${ds} horizon="mid" items=${t.mid??[]} />
              <${ds} horizon="long" items=${t.long??[]} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
            `}

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
      <${C} title="MDAL Loops" class="section">
        ${Le.value&&e.length===0?s`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&o==="error"?s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
      <${C} title="MDAL Loops" class="section">
        ${Pe.value&&e.length===0?s`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&o==="error"?s`
========
      <${w} title="MDAL Loops" class="section">
        ${Pe.value&&e.length===0?s`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&o==="error"?s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
                <div class="empty-state">
                  MDAL snapshot could not be loaded right now. Check the backend tool contract or runtime health.
                </div>
              `:e.length===0&&o==="idle"?s`
                <div class="empty-state">
                  No loop is running right now. This section wakes up when <code>masc_mdal_start</code> exposes a live loop.
                </div>
              `:e.length===0?s`
                  <div class="empty-state">
                    No loop snapshot is visible yet. Refresh once the backend has reported a planning loop.
                  </div>
                `:s`
                <div class="planning-loop-list">
                  ${e.map(l=>s`<${mv} key=${l.loop_id} loop=${l} />`)}
                </div>
              `}
      <//>

      <${vv} />
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}const Te=_(""),vs=_("ability_check"),fs=_("10"),_s=_("12"),Un=_(""),Bn=_("idle"),Qt=_(""),Wn=_("keeper-late"),gs=_("player"),$s=_(""),kt=_("idle"),hs=_(null),Gn=_(""),ys=_(""),bs=_("player"),ks=_(""),xs=_(""),Ss=_(""),$n=_("20"),As=_("20"),ws=_(""),Jn=_("idle"),ui=_(null),Ir=_("overview"),Cs=_("all"),Ts=_("all"),Ns=_("all"),_v=12e4,Qa=_(null),yo=_(Date.now());function gv(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function $v(t,e){return e>0?Math.round(t/e*100):0}const hv={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},yv={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Vn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function bv(t){const e=t.trim().toLowerCase();return hv[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function kv(t){const e=t.trim().toLowerCase();return yv[e]??"상황에 따라 선택되는 전술 액션입니다."}function te(t){return typeof t=="object"&&t!==null}function ft(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function It(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function En(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const xv=new Set(["str","dex","con","int","wis","cha"]);function Sv(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(i){throw new Error(`능력치 JSON 파싱 실패: ${i instanceof Error?i.message:"invalid json"}`)}if(!te(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([i,o])=>{const r=i.trim();if(r){if(typeof o=="number"&&Number.isFinite(o)){a[r]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const l=Number.parseFloat(o.trim());if(Number.isFinite(l)){a[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function Av(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt($n.value.trim(),10);Number.isFinite(a)&&a>n&&($n.value=String(n))}function pi(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function wv(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Cv(t){Ir.value=t}function Mr(t){const e=Qa.value;return e==null||e<=t}function Tv(t){const e=Qa.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function za(){Qa.value=null}function Or(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Nv(t,e){Or(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Qa.value=Date.now()+_v,w("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function oa(t){return Mr(t)?(w("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function mi(t,e,n){return Or([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Rv({hp:t,max:e}){const n=$v(t,e),a=gv(t,e);return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}const Ne=f(""),ps=f("ability_check"),ms=f("10"),vs=f("12"),Un=f(""),Bn=f("idle"),Qt=f(""),Wn=f("keeper-late"),fs=f("player"),gs=f(""),kt=f("idle"),_s=f(null),Gn=f(""),$s=f(""),hs=f("player"),ys=f(""),bs=f(""),ks=f(""),$n=f("20"),xs=f("20"),Ss=f(""),Jn=f("idle"),ci=f(null),Dr=f("overview"),As=f("all"),ws=f("all"),Cs=f("all"),vv=12e4,Va=f(null),_o=f(Date.now());function fv(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function gv(t,e){return e>0?Math.round(t/e*100):0}const _v={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},$v={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Vn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function hv(t){const e=t.trim().toLowerCase();return _v[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function yv(t){const e=t.trim().toLowerCase();return $v[e]??"상황에 따라 선택되는 전술 액션입니다."}function te(t){return typeof t=="object"&&t!==null}function ft(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function It(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function En(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const bv=new Set(["str","dex","con","int","wis","cha"]);function kv(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(i){throw new Error(`능력치 JSON 파싱 실패: ${i instanceof Error?i.message:"invalid json"}`)}if(!te(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([i,o])=>{const r=i.trim();if(r){if(typeof o=="number"&&Number.isFinite(o)){a[r]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const l=Number.parseFloat(o.trim());if(Number.isFinite(l)){a[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function xv(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt($n.value.trim(),10);Number.isFinite(a)&&a>n&&($n.value=String(n))}function di(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Sv(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Av(t){Dr.value=t}function Er(t){const e=Va.value;return e==null||e<=t}function wv(t){const e=Va.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Oa(){Va.value=null}function Ir(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Cv(t,e){Ir(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Va.value=Date.now()+vv,w("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function oa(t){return Er(t)?(w("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function ui(t,e,n){return Ir([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Tv({hp:t,max:e}){const n=gv(t,e),a=fv(t,e);return s`
========
  `}const Ne=f(""),ps=f("ability_check"),ms=f("10"),vs=f("12"),Un=f(""),Bn=f("idle"),Yt=f(""),Wn=f("keeper-late"),fs=f("player"),gs=f(""),St=f("idle"),_s=f(null),Gn=f(""),$s=f(""),hs=f("player"),ys=f(""),bs=f(""),ks=f(""),$n=f("20"),xs=f("20"),Ss=f(""),Jn=f("idle"),ci=f(null),Dr=f("overview"),As=f("all"),Cs=f("all"),ws=f("all"),vv=12e4,Va=f(null),_o=f(Date.now());function fv(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function gv(t,e){return e>0?Math.round(t/e*100):0}const _v={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},$v={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Vn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function hv(t){const e=t.trim().toLowerCase();return _v[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function yv(t){const e=t.trim().toLowerCase();return $v[e]??"상황에 따라 선택되는 전술 액션입니다."}function ee(t){return typeof t=="object"&&t!==null}function _t(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function Mt(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function En(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const bv=new Set(["str","dex","con","int","wis","cha"]);function kv(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(i){throw new Error(`능력치 JSON 파싱 실패: ${i instanceof Error?i.message:"invalid json"}`)}if(!ee(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([i,o])=>{const r=i.trim();if(r){if(typeof o=="number"&&Number.isFinite(o)){a[r]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const l=Number.parseFloat(o.trim());if(Number.isFinite(l)){a[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function xv(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt($n.value.trim(),10);Number.isFinite(a)&&a>n&&($n.value=String(n))}function di(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Sv(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Av(t){Dr.value=t}function Er(t){const e=Va.value;return e==null||e<=t}function Cv(t){const e=Va.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Oa(){Va.value=null}function Ir(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function wv(t,e){Ir(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Va.value=Date.now()+vv,C("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function oa(t){return Er(t)?(C("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function ui(t,e,n){return Ir([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Tv({hp:t,max:e}){const n=gv(t,e),a=fv(t,e);return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function Lv({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return s`
    <div class="trpg-actor-stats">
      ${e.map(n=>s`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Pv({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return s`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function zr({actor:t}){var p,$,m,d;const e=(p=t.archetype)==null?void 0:p.trim(),n=($=t.persona)==null?void 0:$.trim(),a=(m=t.portrait)==null?void 0:m.trim(),i=(d=t.background)==null?void 0:d.trim(),o=t.traits??[],r=t.skills??[],l=Object.entries(t.stats_raw??{}).filter(([v,c])=>Number.isFinite(c)).filter(([v])=>!xv.has(v.toLowerCase()));return s`
    <div class="trpg-actor">
      ${a?s`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${a}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${v=>{const c=v.target;c&&(c.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${Lt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Pv} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?s`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?s`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Rv} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Lv} stats=${t.stats} />
          </div>
        `:null}
      ${e?s`<div class="trpg-actor-meta">Archetype: ${Vn(e)}</div>`:null}
      ${i?s`<div class="trpg-actor-meta">Background: ${i}</div>`:null}
      ${n?s`<div class="trpg-actor-persona">${n}</div>`:null}
      ${l.length>0?s`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${l.map(([v,c])=>s`
                <span class="trpg-custom-stat-chip">${Vn(v)} ${c}</span>
              `)}
            </div>
          </div>
        `:null}
      ${o.length>0?s`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${o.map(v=>s`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Vn(v)}</span>
                  <span class="trpg-annot-desc">${bv(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?s`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(v=>s`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Vn(v)}</span>
                  <span class="trpg-annot-desc">${kv(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Dv({mapStr:t}){return s`<pre class="trpg-map">${t}</pre>`}function qr({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?s`<div class="empty-state" style="font-size:13px">${e}</div>`:s`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var i;return s`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${wv(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${pi(n)}</strong>
            ${" "}
          ${n.dice_roll?s`<span class="trpg-dice">[${n.dice_roll.notation}: ${(i=n.dice_roll.rolls)==null?void 0:i.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${F} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Ev({events:t}){const e="__none__",n=Cs.value,a=Ts.value,i=Ns.value,o=Array.from(new Set(t.map(pi).map(d=>d.trim()).filter(d=>d!==""))).sort((d,v)=>d.localeCompare(v)),r=Array.from(new Set(t.map(d=>(d.type??"").trim()).filter(d=>d!==""))).sort((d,v)=>d.localeCompare(v)),l=t.some(d=>(d.type??"").trim()===""),p=Array.from(new Set(t.map(d=>(d.phase??"").trim()).filter(d=>d!==""))).sort((d,v)=>d.localeCompare(v)),$=t.some(d=>(d.phase??"").trim()===""),m=t.filter(d=>{if(n!=="all"&&pi(d)!==n)return!1;const v=(d.type??"").trim(),c=(d.phase??"").trim();if(a===e){if(v!=="")return!1}else if(a!=="all"&&v!==a)return!1;if(i===e){if(c!=="")return!1}else if(i!=="all"&&c!==i)return!1;return!0});return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Pv({events:t}){const e="__none__",n=As.value,a=ws.value,i=Cs.value,o=Array.from(new Set(t.map(di).map(d=>d.trim()).filter(d=>d!==""))).sort((d,c)=>d.localeCompare(c)),r=Array.from(new Set(t.map(d=>(d.type??"").trim()).filter(d=>d!==""))).sort((d,c)=>d.localeCompare(c)),l=t.some(d=>(d.type??"").trim()===""),p=Array.from(new Set(t.map(d=>(d.phase??"").trim()).filter(d=>d!==""))).sort((d,c)=>d.localeCompare(c)),_=t.some(d=>(d.phase??"").trim()===""),m=t.filter(d=>{if(n!=="all"&&di(d)!==n)return!1;const c=(d.type??"").trim(),g=(d.phase??"").trim();if(a===e){if(c!=="")return!1}else if(a!=="all"&&c!==a)return!1;if(i===e){if(g!=="")return!1}else if(i!=="all"&&g!==i)return!1;return!0});return s`
========
  `}function Pv({events:t}){const e="__none__",n=As.value,a=Cs.value,i=ws.value,o=Array.from(new Set(t.map(di).map(d=>d.trim()).filter(d=>d!==""))).sort((d,c)=>d.localeCompare(c)),r=Array.from(new Set(t.map(d=>(d.type??"").trim()).filter(d=>d!==""))).sort((d,c)=>d.localeCompare(c)),l=t.some(d=>(d.type??"").trim()===""),p=Array.from(new Set(t.map(d=>(d.phase??"").trim()).filter(d=>d!==""))).sort((d,c)=>d.localeCompare(c)),_=t.some(d=>(d.phase??"").trim()===""),m=t.filter(d=>{if(n!=="all"&&di(d)!==n)return!1;const c=(d.type??"").trim(),g=(d.phase??"").trim();if(a===e){if(c!=="")return!1}else if(a!=="all"&&c!==a)return!1;if(i===e){if(g!=="")return!1}else if(i!=="all"&&g!==i)return!1;return!0});return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${d=>{Cs.value=d.target.value}}>
          <option value="all">all</option>
          ${o.map(d=>s`<option value=${d}>${d}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        <select value=${a} onChange=${d=>{Ts.value=d.target.value}}>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        <select value=${a} onChange=${d=>{ws.value=d.target.value}}>
========
        <select value=${a} onChange=${d=>{Cs.value=d.target.value}}>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          <option value="all">all</option>
          ${l?s`<option value=${e}>(none)</option>`:null}
          ${r.map(d=>s`<option value=${d}>${d}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        <select value=${i} onChange=${d=>{Ns.value=d.target.value}}>
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        <select value=${i} onChange=${d=>{Cs.value=d.target.value}}>
========
        <select value=${i} onChange=${d=>{ws.value=d.target.value}}>
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          <option value="all">all</option>
          ${$?s`<option value=${e}>(none)</option>`:null}
          ${p.map(d=>s`<option value=${d}>${d}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        onClick=${()=>{Cs.value="all",Ts.value="all",Ns.value="all"}}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        onClick=${()=>{As.value="all",ws.value="all",Cs.value="all"}}
========
        onClick=${()=>{As.value="all",Cs.value="all",ws.value="all"}}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${m.length} / 전체 ${t.length}
      </span>
    </div>
    <${qr} events=${m.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Iv({outcome:t}){if(!t)return null;const e=o=>{const r=o.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",i=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return s`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?s`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${i?s`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${i}</div>`:null}
    </div>
  `}function jr({state:t}){const e=t.history??[];return e.length===0?null:s`
    <div class="trpg-round-list">
      ${e.slice(-10).map(n=>s`
        <div class="trpg-round-item ${n.status}">
          <span>Session ${n.id.slice(0,8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${n.round} — ${n.status}
          </span>
        </div>
      `)}
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Mv({state:t,nowMs:e}){var $;const n=Ht.value||(($=t.session)==null?void 0:$.room)||"",a=Bn.value,i=t.party??[];if(!i.find(m=>m.id===Te.value)&&i.length>0){const m=i[0];m&&(Te.value=m.id)}const r=async()=>{var d,v;if(!n){w("Room ID가 비어 있습니다.","error");return}if(!oa(e))return;const m=((d=t.current_round)==null?void 0:d.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(mi("라운드 실행",n,m)){Bn.value="running";try{const c=await sc(n);ui.value=c,Bn.value="ok";const y=te(c.summary)?c.summary:null,S=y?En(y,"advanced",!1):!1,T=y?ft(y,"progress_reason",""):"";w(S?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${T?`: ${T}`:""}`,S?"success":"warning"),qt()}catch(c){ui.value=null,Bn.value="error";const y=c instanceof Error?c.message:"라운드 실행에 실패했습니다.";w(y,"error")}finally{za()}}},l=async()=>{var d,v;if(!n||!oa(e))return;const m=((d=t.current_round)==null?void 0:d.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(mi("턴 강제 진행",n,m))try{await rc(n),w("턴을 다음 단계로 이동했습니다.","success"),qt()}catch{w("턴 이동에 실패했습니다.","error")}finally{za()}},p=async()=>{if(!n||!oa(e))return;const m=Te.value.trim();if(!m){w("먼저 Actor를 선택하세요.","warning");return}const d=Number.parseInt(fs.value,10),v=Number.parseInt(_s.value,10);if(Number.isNaN(d)||Number.isNaN(v)){w("stat/dc는 숫자여야 합니다.","warning");return}const c=Number.parseInt(Un.value,10),y=Un.value.trim()===""||Number.isNaN(c)?void 0:c;try{await oc({roomId:n,actorId:m,action:vs.value.trim()||"ability_check",statValue:d,dc:v,rawD20:y}),w("주사위 판정을 기록했습니다.","success"),qt()}catch{w("주사위 판정 기록에 실패했습니다.","error")}};return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Ev({state:t,nowMs:e}){var _;const n=Ht.value||((_=t.session)==null?void 0:_.room)||"",a=Bn.value,i=t.party??[];if(!i.find(m=>m.id===Ne.value)&&i.length>0){const m=i[0];m&&(Ne.value=m.id)}const r=async()=>{var d,c;if(!n){w("Room ID가 비어 있습니다.","error");return}if(!oa(e))return;const m=((d=t.current_round)==null?void 0:d.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(ui("라운드 실행",n,m)){Bn.value="running";try{const g=await nc(n);ci.value=g,Bn.value="ok";const y=te(g.summary)?g.summary:null,S=y?En(y,"advanced",!1):!1,T=y?ft(y,"progress_reason",""):"";w(S?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${T?`: ${T}`:""}`,S?"success":"warning"),qt()}catch(g){ci.value=null,Bn.value="error";const y=g instanceof Error?g.message:"라운드 실행에 실패했습니다.";w(y,"error")}finally{Oa()}}},l=async()=>{var d,c;if(!n||!oa(e))return;const m=((d=t.current_round)==null?void 0:d.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(ui("턴 강제 진행",n,m))try{await ic(n),w("턴을 다음 단계로 이동했습니다.","success"),qt()}catch{w("턴 이동에 실패했습니다.","error")}finally{Oa()}},p=async()=>{if(!n||!oa(e))return;const m=Ne.value.trim();if(!m){w("먼저 Actor를 선택하세요.","warning");return}const d=Number.parseInt(ms.value,10),c=Number.parseInt(vs.value,10);if(Number.isNaN(d)||Number.isNaN(c)){w("stat/dc는 숫자여야 합니다.","warning");return}const g=Number.parseInt(Un.value,10),y=Un.value.trim()===""||Number.isNaN(g)?void 0:g;try{await sc({roomId:n,actorId:m,action:ps.value.trim()||"ability_check",statValue:d,dc:c,rawD20:y}),w("주사위 판정을 기록했습니다.","success"),qt()}catch{w("주사위 판정 기록에 실패했습니다.","error")}};return s`
========
  `}function Ev({state:t,nowMs:e}){var _;const n=Ut.value||((_=t.session)==null?void 0:_.room)||"",a=Bn.value,i=t.party??[];if(!i.find(m=>m.id===Ne.value)&&i.length>0){const m=i[0];m&&(Ne.value=m.id)}const r=async()=>{var d,c;if(!n){C("Room ID가 비어 있습니다.","error");return}if(!oa(e))return;const m=((d=t.current_round)==null?void 0:d.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(ui("라운드 실행",n,m)){Bn.value="running";try{const g=await nc(n);ci.value=g,Bn.value="ok";const y=ee(g.summary)?g.summary:null,S=y?En(y,"advanced",!1):!1,T=y?_t(y,"progress_reason",""):"";C(S?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${T?`: ${T}`:""}`,S?"success":"warning"),jt()}catch(g){ci.value=null,Bn.value="error";const y=g instanceof Error?g.message:"라운드 실행에 실패했습니다.";C(y,"error")}finally{Oa()}}},l=async()=>{var d,c;if(!n||!oa(e))return;const m=((d=t.current_round)==null?void 0:d.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(ui("턴 강제 진행",n,m))try{await ic(n),C("턴을 다음 단계로 이동했습니다.","success"),jt()}catch{C("턴 이동에 실패했습니다.","error")}finally{Oa()}},p=async()=>{if(!n||!oa(e))return;const m=Ne.value.trim();if(!m){C("먼저 Actor를 선택하세요.","warning");return}const d=Number.parseInt(ms.value,10),c=Number.parseInt(vs.value,10);if(Number.isNaN(d)||Number.isNaN(c)){C("stat/dc는 숫자여야 합니다.","warning");return}const g=Number.parseInt(Un.value,10),y=Un.value.trim()===""||Number.isNaN(g)?void 0:g;try{await sc({roomId:n,actorId:m,action:ps.value.trim()||"ability_check",statValue:d,dc:c,rawD20:y}),C("주사위 판정을 기록했습니다.","success"),jt()}catch{C("주사위 판정 기록에 실패했습니다.","error")}};return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${m=>{Ut.value=m.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Te.value}
            onChange=${m=>{Te.value=m.target.value}}
          >
            <option value="">Actor 선택</option>
            ${i.map(m=>s`<option value=${m.id}>${m.name} (${m.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${vs.value}
              onInput=${m=>{vs.value=m.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${fs.value}
              onInput=${m=>{fs.value=m.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${_s.value}
              onInput=${m=>{_s.value=m.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Un.value}
              onInput=${m=>{Un.value=m.target.value}}
              onKeyDown=${m=>{m.key==="Enter"&&p()}}
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
              disabled=${a==="running"}
            >
              ${a==="running"?"실행 중...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${l}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${a!=="idle"?s`<div class="trpg-run-status ${a}">${a==="running"?"처리 중...":a==="ok"?"완료":"실패"}</div>`:null}
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Ov({state:t}){var i;const e=Ht.value||((i=t.session)==null?void 0:i.room)||"",n=Jn.value,a=async()=>{if(!e){w("Room ID가 비어 있습니다.","warning");return}const o=Gn.value.trim(),r=ys.value.trim();if(!r&&!o){w("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt($n.value.trim(),10),p=Number.parseInt(As.value.trim(),10),$=Number.isFinite(p)?Math.max(1,p):20,m=Number.isFinite(l)?Math.max(0,Math.min($,l)):$;let d={};try{d=Sv(ws.value)}catch(v){w(v instanceof Error?v.message:"능력치 JSON 오류","error");return}Jn.value="spawning";try{const v=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,c=await lc(e,{actor_id:o||void 0,name:r||void 0,role:bs.value,idempotencyKey:v,portrait:xs.value.trim()||void 0,background:Ss.value.trim()||void 0,hp:m,max_hp:$,alive:m>0,stats:Object.keys(d).length>0?d:void 0}),y=typeof c.actor_id=="string"?c.actor_id.trim():"";if(!y)throw new Error("생성 응답에 actor_id가 없습니다.");const S=ks.value.trim();S&&await cc(e,y,S),Te.value=y,Qt.value=y,o||(Gn.value=""),Jn.value="ok",w(`Actor 생성 완료: ${y}`,"success"),await qt()}catch(v){Jn.value="error",w(v instanceof Error?v.message:"Actor 생성에 실패했습니다.","error")}};return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Iv({state:t}){var i;const e=Ht.value||((i=t.session)==null?void 0:i.room)||"",n=Jn.value,a=async()=>{if(!e){w("Room ID가 비어 있습니다.","warning");return}const o=Gn.value.trim(),r=$s.value.trim();if(!r&&!o){w("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt($n.value.trim(),10),p=Number.parseInt(xs.value.trim(),10),_=Number.isFinite(p)?Math.max(1,p):20,m=Number.isFinite(l)?Math.max(0,Math.min(_,l)):_;let d={};try{d=kv(Ss.value)}catch(c){w(c instanceof Error?c.message:"능력치 JSON 오류","error");return}Jn.value="spawning";try{const c=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,g=await oc(e,{actor_id:o||void 0,name:r||void 0,role:hs.value,idempotencyKey:c,portrait:bs.value.trim()||void 0,background:ks.value.trim()||void 0,hp:m,max_hp:_,alive:m>0,stats:Object.keys(d).length>0?d:void 0}),y=typeof g.actor_id=="string"?g.actor_id.trim():"";if(!y)throw new Error("생성 응답에 actor_id가 없습니다.");const S=ys.value.trim();S&&await rc(e,y,S),Ne.value=y,Qt.value=y,o||(Gn.value=""),Jn.value="ok",w(`Actor 생성 완료: ${y}`,"success"),await qt()}catch(c){Jn.value="error",w(c instanceof Error?c.message:"Actor 생성에 실패했습니다.","error")}};return s`
========
  `}function Iv({state:t}){var i;const e=Ut.value||((i=t.session)==null?void 0:i.room)||"",n=Jn.value,a=async()=>{if(!e){C("Room ID가 비어 있습니다.","warning");return}const o=Gn.value.trim(),r=$s.value.trim();if(!r&&!o){C("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt($n.value.trim(),10),p=Number.parseInt(xs.value.trim(),10),_=Number.isFinite(p)?Math.max(1,p):20,m=Number.isFinite(l)?Math.max(0,Math.min(_,l)):_;let d={};try{d=kv(Ss.value)}catch(c){C(c instanceof Error?c.message:"능력치 JSON 오류","error");return}Jn.value="spawning";try{const c=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,g=await oc(e,{actor_id:o||void 0,name:r||void 0,role:hs.value,idempotencyKey:c,portrait:bs.value.trim()||void 0,background:ks.value.trim()||void 0,hp:m,max_hp:_,alive:m>0,stats:Object.keys(d).length>0?d:void 0}),y=typeof g.actor_id=="string"?g.actor_id.trim():"";if(!y)throw new Error("생성 응답에 actor_id가 없습니다.");const S=ys.value.trim();S&&await rc(e,y,S),Ne.value=y,Yt.value=y,o||(Gn.value=""),Jn.value="ok",C(`Actor 생성 완료: ${y}`,"success"),await jt()}catch(c){Jn.value="error",C(c instanceof Error?c.message:"Actor 생성에 실패했습니다.","error")}};return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${ys.value}
            onInput=${o=>{ys.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${bs.value}
            onChange=${o=>{bs.value=o.target.value}}
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
            value=${ks.value}
            onInput=${o=>{ks.value=o.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn recommend" onClick=${a} disabled=${n==="spawning"}>
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
              value=${Gn.value}
              onInput=${o=>{Gn.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${xs.value}
              onInput=${o=>{xs.value=o.target.value}}
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
              value=${$n.value}
              onInput=${o=>{$n.value=o.target.value}}
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
              value=${As.value}
              onInput=${o=>{const r=o.target.value;As.value=r,Av(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Ss.value}
              onInput=${o=>{Ss.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${ws.value}
              onInput=${o=>{ws.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?s`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function zv({state:t,nowMs:e}){var v;const n=Ht.value||((v=t.session)==null?void 0:v.room)||"",a=t.join_gate,i=hs.value,o=te(i)?i:null,r=(t.party??[]).filter(c=>c.role!=="dm"),l=Qt.value.trim(),p=r.some(c=>c.id===l),$=p?l:l?"__manual__":"",m=async()=>{const c=Qt.value.trim(),y=Wn.value.trim();if(!n||!c){w("Room/Actor가 필요합니다.","warning");return}kt.value="checking";try{const S=await dc(n,c,y||void 0);hs.value=S,kt.value="ok",w("참가 가능 여부를 갱신했습니다.","success")}catch(S){kt.value="error";const T=S instanceof Error?S.message:"참가 가능 여부 확인에 실패했습니다.";w(T,"error")}},d=async()=>{var D,L;const c=Qt.value.trim(),y=Wn.value.trim(),S=$s.value.trim();if(!n||!c||!y){w("Room/Actor/Keeper가 필요합니다.","warning");return}if(!oa(e))return;const T=((D=t.current_round)==null?void 0:D.phase)??((L=t.session)==null?void 0:L.status)??"unknown";if(mi("Mid-Join 승인 요청",n,T)){kt.value="requesting";try{const M=await uc({room_id:n,actor_id:c,keeper_name:y,role:gs.value,...S?{name:S}:{}});hs.value=M;const N=te(M)?En(M,"granted",!1):!1,P=te(M)?ft(M,"reason_code",""):"";N?w("Mid-Join이 승인되었습니다.","success"):w(`Mid-Join이 거절되었습니다${P?`: ${P}`:""}`,"warning"),kt.value=N?"ok":"error",qt()}catch(M){kt.value="error";const N=M instanceof Error?M.message:"Mid-Join 요청에 실패했습니다.";w(N,"error")}finally{za()}}};return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Mv({state:t,nowMs:e}){var c;const n=Ht.value||((c=t.session)==null?void 0:c.room)||"",a=t.join_gate,i=_s.value,o=te(i)?i:null,r=(t.party??[]).filter(g=>g.role!=="dm"),l=Qt.value.trim(),p=r.some(g=>g.id===l),_=p?l:l?"__manual__":"",m=async()=>{const g=Qt.value.trim(),y=Wn.value.trim();if(!n||!g){w("Room/Actor가 필요합니다.","warning");return}kt.value="checking";try{const S=await lc(n,g,y||void 0);_s.value=S,kt.value="ok",w("참가 가능 여부를 갱신했습니다.","success")}catch(S){kt.value="error";const T=S instanceof Error?S.message:"참가 가능 여부 확인에 실패했습니다.";w(T,"error")}},d=async()=>{var D,L;const g=Qt.value.trim(),y=Wn.value.trim(),S=gs.value.trim();if(!n||!g||!y){w("Room/Actor/Keeper가 필요합니다.","warning");return}if(!oa(e))return;const T=((D=t.current_round)==null?void 0:D.phase)??((L=t.session)==null?void 0:L.status)??"unknown";if(ui("Mid-Join 승인 요청",n,T)){kt.value="requesting";try{const M=await cc({room_id:n,actor_id:g,keeper_name:y,role:fs.value,...S?{name:S}:{}});_s.value=M;const N=te(M)?En(M,"granted",!1):!1,P=te(M)?ft(M,"reason_code",""):"";N?w("Mid-Join이 승인되었습니다.","success"):w(`Mid-Join이 거절되었습니다${P?`: ${P}`:""}`,"warning"),kt.value=N?"ok":"error",qt()}catch(M){kt.value="error";const N=M instanceof Error?M.message:"Mid-Join 요청에 실패했습니다.";w(N,"error")}finally{Oa()}}};return s`
========
  `}function Mv({state:t,nowMs:e}){var c;const n=Ut.value||((c=t.session)==null?void 0:c.room)||"",a=t.join_gate,i=_s.value,o=ee(i)?i:null,r=(t.party??[]).filter(g=>g.role!=="dm"),l=Yt.value.trim(),p=r.some(g=>g.id===l),_=p?l:l?"__manual__":"",m=async()=>{const g=Yt.value.trim(),y=Wn.value.trim();if(!n||!g){C("Room/Actor가 필요합니다.","warning");return}St.value="checking";try{const S=await lc(n,g,y||void 0);_s.value=S,St.value="ok",C("참가 가능 여부를 갱신했습니다.","success")}catch(S){St.value="error";const T=S instanceof Error?S.message:"참가 가능 여부 확인에 실패했습니다.";C(T,"error")}},d=async()=>{var P,K;const g=Yt.value.trim(),y=Wn.value.trim(),S=gs.value.trim();if(!n||!g||!y){C("Room/Actor/Keeper가 필요합니다.","warning");return}if(!oa(e))return;const T=((P=t.current_round)==null?void 0:P.phase)??((K=t.session)==null?void 0:K.status)??"unknown";if(ui("Mid-Join 승인 요청",n,T)){St.value="requesting";try{const I=await cc({room_id:n,actor_id:g,keeper_name:y,role:fs.value,...S?{name:S}:{}});_s.value=I;const N=ee(I)?En(I,"granted",!1):!1,R=ee(I)?_t(I,"reason_code",""):"";N?C("Mid-Join이 승인되었습니다.","success"):C(`Mid-Join이 거절되었습니다${R?`: ${R}`:""}`,"warning"),St.value=N?"ok":"error",jt()}catch(I){St.value="error";const N=I instanceof Error?I.message:"Mid-Join 요청에 실패했습니다.";C(N,"error")}finally{Oa()}}};return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${a!=null&&a.phase_open?"OPEN":"CLOSED"}</strong>
        ${a!=null&&a.window?s`<span style="margin-left:8px;">(${a.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(a==null?void 0:a.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <select
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
            value=${$}
            onChange=${c=>{const y=c.target.value;if(y==="__manual__"){(p||!l)&&(Qt.value="");return}Qt.value=y}}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
            value=${_}
            onChange=${g=>{const y=g.target.value;if(y==="__manual__"){(p||!l)&&(Qt.value="");return}Qt.value=y}}
========
            value=${_}
            onChange=${g=>{const y=g.target.value;if(y==="__manual__"){(p||!l)&&(Yt.value="");return}Yt.value=y}}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          >
            <option value="">Actor 선택</option>
            ${r.map(c=>s`
              <option value=${c.id}>${c.name} (${c.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${$==="__manual__"?s`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
                value=${Qt.value}
                onInput=${c=>{Qt.value=c.target.value}}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
                value=${Qt.value}
                onInput=${g=>{Qt.value=g.target.value}}
========
                value=${Yt.value}
                onInput=${g=>{Yt.value=g.target.value}}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
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
            value=${Wn.value}
            onInput=${c=>{Wn.value=c.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${gs.value}
            onChange=${c=>{gs.value=c.target.value}}
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
            value=${$s.value}
            onInput=${c=>{$s.value=c.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${m} disabled=${St.value==="checking"||St.value==="requesting"}>
              ${St.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${d} disabled=${St.value==="checking"||St.value==="requesting"}>
              ${St.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?s`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${En(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Mt(o,"effective_score",0)}/${Mt(o,"required_points",0)}</span>
            ${_t(o,"reason_code","")?s`<span style="margin-left:8px;">Reason: ${_t(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Fr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?s`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:s`
    <div class="trpg-round-list">
      ${e.map(n=>s`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?s`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Kr({state:t}){var n;const e=t.current_round;return e?s`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?s`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `:null}function Hr(){const t=ui.value;if(!t)return s`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=te(e)?e:null,i=(Array.isArray(t.statuses)?t.statuses:[]).filter(te).slice(-8),o=t.canon_check,r=te(o)?o:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(P=>typeof P=="string").slice(0,3):[],p=r&&Array.isArray(r.violations)?r.violations.filter(P=>typeof P=="string").slice(0,3):[],$=n?En(n,"advanced",!1):!1,m=n?ft(n,"progress_reason",""):"",d=n?ft(n,"progress_detail",""):"",v=n?It(n,"player_successes",0):0,c=n?It(n,"player_required_successes",0):0,y=n?En(n,"dm_success",!1):!1,S=n?It(n,"timeouts",0):0,T=n?It(n,"unavailable",0):0,D=n?It(n,"reprompts",0):0,L=n?It(n,"npc_attacks",0):0,M=n?It(n,"keeper_timeout_sec",0):0,N=n?It(n,"roll_audit_count",0):0;return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `:null}function Fr(){const t=ci.value;if(!t)return s`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=te(e)?e:null,i=(Array.isArray(t.statuses)?t.statuses:[]).filter(te).slice(-8),o=t.canon_check,r=te(o)?o:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(P=>typeof P=="string").slice(0,3):[],p=r&&Array.isArray(r.violations)?r.violations.filter(P=>typeof P=="string").slice(0,3):[],_=n?En(n,"advanced",!1):!1,m=n?ft(n,"progress_reason",""):"",d=n?ft(n,"progress_detail",""):"",c=n?It(n,"player_successes",0):0,g=n?It(n,"player_required_successes",0):0,y=n?En(n,"dm_success",!1):!1,S=n?It(n,"timeouts",0):0,T=n?It(n,"unavailable",0):0,D=n?It(n,"reprompts",0):0,L=n?It(n,"npc_attacks",0):0,M=n?It(n,"keeper_timeout_sec",0):0,N=n?It(n,"roll_audit_count",0):0;return s`
========
  `:null}function Fr(){const t=ci.value;if(!t)return s`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=ee(e)?e:null,i=(Array.isArray(t.statuses)?t.statuses:[]).filter(ee).slice(-8),o=t.canon_check,r=ee(o)?o:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(R=>typeof R=="string").slice(0,3):[],p=r&&Array.isArray(r.violations)?r.violations.filter(R=>typeof R=="string").slice(0,3):[],_=n?En(n,"advanced",!1):!1,m=n?_t(n,"progress_reason",""):"",d=n?_t(n,"progress_detail",""):"",c=n?Mt(n,"player_successes",0):0,g=n?Mt(n,"player_required_successes",0):0,y=n?En(n,"dm_success",!1):!1,S=n?Mt(n,"timeouts",0):0,T=n?Mt(n,"unavailable",0):0,P=n?Mt(n,"reprompts",0):0,K=n?Mt(n,"npc_attacks",0):0,I=n?Mt(n,"keeper_timeout_sec",0):0,N=n?Mt(n,"roll_audit_count",0):0;return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${$?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${$?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${y?"DM ok":"DM stalled"} / players ${v}/${c}
          </span>
        </div>
        ${m?s`<div style="margin-top:4px; font-size:12px;">${m}</div>`:null}
        ${d?s`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${d}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${P}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${K}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${I||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${N}</div></div>
      </div>

      ${i.length>0?s`
          <div class="trpg-round-list">
            ${i.map(R=>{const X=_t(R,"status","unknown"),H=_t(R,"actor_id","-"),Pt=_t(R,"role","-"),mt=_t(R,"reason",""),vt=_t(R,"action_type",""),B=_t(R,"reply","");return s`
                <div class="trpg-round-item ${X.includes("fallback")||X.includes("timeout")?"failed":"active"}">
                  <span>${H} (${Pt})</span>
                  <span style="margin-left:auto; font-size:11px;">${X}</span>
                  ${vt?s`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${vt}</div>`:null}
                  ${mt?s`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${mt}</div>`:null}
                  ${B?s`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${B.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?s`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${_t(r,"status","unknown")}</strong>
            </div>
            ${p.length>0?s`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${p.map(R=>s`<div>violation: ${R}</div>`)}
                </div>`:null}
            ${l.length>0?s`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${l.map(R=>s`<div>warning: ${R}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function qv({state:t,nowMs:e}){var r,l,p;const n=Ht.value||((r=t.session)==null?void 0:r.room)||"",a=((l=t.current_round)==null?void 0:l.phase)??((p=t.session)==null?void 0:p.status)??"unknown",i=Mr(e),o=Tv(e);return s`
    <${C} title="조작 안전 잠금" style="margin-bottom:16px;">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Ov({state:t,nowMs:e}){var r,l,p;const n=Ht.value||((r=t.session)==null?void 0:r.room)||"",a=((l=t.current_round)==null?void 0:l.phase)??((p=t.session)==null?void 0:p.status)??"unknown",i=Er(e),o=wv(e);return s`
    <${C} title="조작 안전 잠금" style="margin-bottom:16px;">
========
  `}function Ov({state:t,nowMs:e}){var r,l,p;const n=Ut.value||((r=t.session)==null?void 0:r.room)||"",a=((l=t.current_round)==null?void 0:l.phase)??((p=t.session)==null?void 0:p.status)??"unknown",i=Er(e),o=Cv(e);return s`
    <${w} title="조작 안전 잠금" style="margin-bottom:16px;">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
      <div class="trpg-control-lock ${i?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${i?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${i?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${o}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${a||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
          ${i?s`<button class="trpg-run-btn recommend" onClick=${()=>Nv(n,a)}>잠금 해제 (120초)</button>`:s`<button class="trpg-run-btn secondary" onClick=${()=>{za(),w("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
          ${i?s`<button class="trpg-run-btn recommend" onClick=${()=>Cv(n,a)}>잠금 해제 (120초)</button>`:s`<button class="trpg-run-btn secondary" onClick=${()=>{Oa(),w("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
========
          ${i?s`<button class="trpg-run-btn recommend" onClick=${()=>wv(n,a)}>잠금 해제 (120초)</button>`:s`<button class="trpg-run-btn secondary" onClick=${()=>{Oa(),C("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        </div>
      </div>
    <//>
  `}function jv({active:t}){return s`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>s`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Cv(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Fv({state:t}){const e=t.party??[],n=t.story_log??[];return s`
    <div class="trpg-layout">
      <div>
        <${w} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        <${C} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${qr} events=${n.slice(-20)} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        <${C} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${Or} events=${n.slice(-20)} />
========
        <${w} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${Or} events=${n.slice(-20)} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        <//>

        ${t.map?s`
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
            <${C} title="맵" style="margin-top:16px;">
              <${Dv} mapStr=${t.map} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
            <${C} title="맵" style="margin-top:16px;">
              <${Lv} mapStr=${t.map} />
========
            <${w} title="맵" style="margin-top:16px;">
              <${Lv} mapStr=${t.map} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        <${C} title="현재 라운드">
          <${Kr} state=${t} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        <${C} title="현재 라운드">
          <${jr} state=${t} />
========
        <${w} title="현재 라운드">
          <${jr} state=${t} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        <//>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        <${C} title="기여도" style="margin-top:16px;">
          <${Fr} state=${t} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        <${C} title="기여도" style="margin-top:16px;">
          <${qr} state=${t} />
========
        <${w} title="기여도" style="margin-top:16px;">
          <${qr} state=${t} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        <//>

        <${w} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>s`<${zr} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?s`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?s`
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
            <${C} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${jr} state=${t} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
            <${C} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${zr} state=${t} />
========
            <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${zr} state=${t} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
            <//>
          `:null}
      </div>
    </div>
  `}function Kv({state:t}){const e=t.story_log??[];return s`
    <div class="trpg-layout">
      <div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        <${C} title=${`이벤트 타임라인 (${e.length})`}>
          <${Ev} events=${e} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        <${C} title=${`이벤트 타임라인 (${e.length})`}>
          <${Pv} events=${e} />
========
        <${w} title=${`이벤트 타임라인 (${e.length})`}>
          <${Pv} events=${e} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        <//>
      </div>

      <div class="trpg-sidebar">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        <${C} title="최근 라운드 결과">
          <${Hr} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        <${C} title="최근 라운드 결과">
          <${Fr} />
========
        <${w} title="최근 라운드 결과">
          <${Fr} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        <//>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        <${C} title="현재 라운드" style="margin-top:16px;">
          <${Kr} state=${t} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        <${C} title="현재 라운드" style="margin-top:16px;">
          <${jr} state=${t} />
========
        <${w} title="현재 라운드" style="margin-top:16px;">
          <${jr} state=${t} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        <//>
      </div>
    </div>
  `}function Hv({state:t,nowMs:e}){const n=t.party??[];return s`
    <div>
      <${qv} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
          <${C} title="조작 패널">
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
          <${C} title="조작 패널">
            <${Ev} state=${t} nowMs=${e} />
          <//>

          <${C} title="Actor Spawn" style="margin-top:16px;">
            <${Iv} state=${t} />
          <//>

          <${C} title="Mid-Join Gate" style="margin-top:16px;">
========
          <${w} title="조작 패널">
            <${Ev} state=${t} nowMs=${e} />
          <//>

          <${w} title="Actor Spawn" style="margin-top:16px;">
            <${Iv} state=${t} />
          <//>

          <${w} title="Mid-Join Gate" style="margin-top:16px;">
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
            <${Mv} state=${t} nowMs=${e} />
          <//>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
          <${C} title="Actor Spawn" style="margin-top:16px;">
            <${Ov} state=${t} />
          <//>

          <${C} title="Mid-Join Gate" style="margin-top:16px;">
            <${zv} state=${t} nowMs=${e} />
          <//>

          <${C} title="최근 라운드 결과" style="margin-top:16px;">
            <${Hr} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
          <${C} title="최근 라운드 결과" style="margin-top:16px;">
            <${Fr} />
========
          <${w} title="최근 라운드 결과" style="margin-top:16px;">
            <${Fr} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          <//>
        </div>

        <div class="trpg-sidebar">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
          <${C} title="기여도" style="margin-top:0;">
            <${Fr} state=${t} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
          <${C} title="기여도" style="margin-top:0;">
            <${qr} state=${t} />
========
          <${w} title="기여도" style="margin-top:0;">
            <${qr} state=${t} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          <//>

          <${w} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>s`<${zr} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?s`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?s`
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
              <${C} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${jr} state=${t} />
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
              <${C} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${zr} state=${t} />
========
              <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${zr} state=${t} />
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Uv(){var l,p,$,m,d;const t=Ho.value,e=Us.value;if(rt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const v=window.setInterval(()=>{yo.value=Date.now()},1e3);return()=>{window.clearInterval(v)}},[]),e&&!t)return s`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return s`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>jt()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],i=t.outcome,o=Ir.value,r=yo.value;return s`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
          room: ${Ht.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((p=t.current_round)==null?void 0:p.phase)??(($=t.session)==null?void 0:$.status)??"-"}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
          room: ${Ht.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((p=t.current_round)==null?void 0:p.phase)??((_=t.session)==null?void 0:_.status)??"-"}
========
          room: ${Ut.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((p=t.current_round)==null?void 0:p.phase)??((_=t.session)==null?void 0:_.status)??"-"}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>jt()}>새로고침</button>
      </div>

      <${Iv} outcome=${i} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((m=t.session)==null?void 0:m.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((d=t.current_round)==null?void 0:d.round_number)??0}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Party</div>
          <div class="stat-value">${n.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Events</div>
          <div class="stat-value">${a.length}</div>
        </div>
      </div>

      <${jv} active=${o} />

      ${o==="overview"?s`<${Fv} state=${t} />`:o==="timeline"?s`<${Kv} state=${t} />`:s`<${Hv} state=${t} nowMs=${r} />`}
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}const Di="masc_dashboard_agent_name";function Bv(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Di);return e??n??"dashboard"}const gt=_(Bv()),hn=_(""),yn=_(""),qa=_(""),Ur=_(null),ja=_(null),bn=_(!1),Pe=_(!1),kn=_(!1),xn=_(!1),Fa=_(!1),Ka=_(!1),Ya=_(!1);function Ha(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function ra(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function Br(t){return!t||t.length===0?"none":t.join(", ")}function Wv(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Ha(t.quiet_start)}-${Ha(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${ra(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${ra(t.interval_s)}.`:`Lodge ticks every ${ra(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function Ge(){qe();try{await ee()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function Ei(t){const e=t.trim();gt.value=e,e&&localStorage.setItem(Di,e)}function Gv(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function vi(){const t=gt.value.trim();if(t){kn.value=!0;try{const e=await mc(t),n=Gv(e);n&&Ei(n),Ya.value=!0,await Ge(),w(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";w(n,"error")}finally{kn.value=!1}}}async function Jv(){const t=gt.value.trim();if(t){xn.value=!0;try{await qo(t),Ya.value=!1,await Ge(),w(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";w(n,"error")}finally{xn.value=!1}}}async function Vv(){const t=gt.value.trim();if(t)try{await qo(t)}catch{}localStorage.removeItem(Di),Ei("dashboard"),Ya.value=!1,await vi()}async function Qv(){const t=gt.value.trim();if(t){Fa.value=!0;try{await vc(t),await Ge(),w("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";w(n,"error")}finally{Fa.value=!1}}}async function bo(){const t=gt.value.trim(),e=hn.value.trim();if(!(!t||!e)){bn.value=!0;try{await zo(t,e),hn.value="",await Ge(),w("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";w(a,"error")}finally{bn.value=!1}}}async function Yv(){const t=yn.value.trim(),e=qa.value.trim()||"Created from dashboard";if(t){Pe.value=!0;try{await pc(t,e,1),yn.value="",qa.value="",await Ge(),w("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";w(a,"error")}finally{Pe.value=!1}}}async function ko(){const t=gt.value.trim()||"dashboard";Ka.value=!0,ja.value=null;try{const e=await On({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=$i(e.result);Ur.value=n,await Ge(),n!=null&&n.skipped_reason?w(n.skipped_reason,"warning"):w(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";ja.value=n,w(n,"error")}finally{Ka.value=!1}}function Xv({runtime:t}){var i,o;const e=Ur.value??(t==null?void 0:t.last_tick_result)??null;if(ja.value)return s`<div class="control-result-box is-error">${ja.value}</div>`;if(!e)return s`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((i=e.skipped_rows)==null?void 0:i.slice(0,3))??[],a=((o=e.passed_rows)==null?void 0:o.slice(0,3))??[];return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}const Ri="masc_dashboard_agent_name";function Hv(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Ri);return e??n??"dashboard"}const _t=f(Hv()),hn=f(""),yn=f(""),za=f(""),Kr=f(null),qa=f(null),bn=f(!1),De=f(!1),kn=f(!1),xn=f(!1),ja=f(!1),Fa=f(!1),Qa=f(!1);function Ka(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function ra(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function Hr(t){return!t||t.length===0?"none":t.join(", ")}function Uv(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Ka(t.quiet_start)}-${Ka(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${ra(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${ra(t.interval_s)}.`:`Lodge ticks every ${ra(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function Ge(){qe();try{await ee()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function Li(t){const e=t.trim();_t.value=e,e&&localStorage.setItem(Ri,e)}function Bv(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function pi(){const t=_t.value.trim();if(t){kn.value=!0;try{const e=await uc(t),n=Bv(e);n&&Li(n),Qa.value=!0,await Ge(),w(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";w(n,"error")}finally{kn.value=!1}}}async function Wv(){const t=_t.value.trim();if(t){xn.value=!0;try{await Mo(t),Qa.value=!1,await Ge(),w(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";w(n,"error")}finally{xn.value=!1}}}async function Gv(){const t=_t.value.trim();if(t)try{await Mo(t)}catch{}localStorage.removeItem(Ri),Li("dashboard"),Qa.value=!1,await pi()}async function Jv(){const t=_t.value.trim();if(t){ja.value=!0;try{await pc(t),await Ge(),w("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";w(n,"error")}finally{ja.value=!1}}}async function $o(){const t=_t.value.trim(),e=hn.value.trim();if(!(!t||!e)){bn.value=!0;try{await Io(t,e),hn.value="",await Ge(),w("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";w(a,"error")}finally{bn.value=!1}}}async function Vv(){const t=yn.value.trim(),e=za.value.trim()||"Created from dashboard";if(t){De.value=!0;try{await dc(t,e,1),yn.value="",za.value="",await Ge(),w("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";w(a,"error")}finally{De.value=!1}}}async function ho(){const t=_t.value.trim()||"dashboard";Fa.value=!0,qa.value=null;try{const e=await On({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=gi(e.result);Kr.value=n,await Ge(),n!=null&&n.skipped_reason?w(n.skipped_reason,"warning"):w(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";qa.value=n,w(n,"error")}finally{Fa.value=!1}}function Qv({runtime:t}){var i,o;const e=Kr.value??(t==null?void 0:t.last_tick_result)??null;if(qa.value)return s`<div class="control-result-box is-error">${qa.value}</div>`;if(!e)return s`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((i=e.skipped_rows)==null?void 0:i.slice(0,3))??[],a=((o=e.passed_rows)==null?void 0:o.slice(0,3))??[];return s`
========
  `}const Ri="masc_dashboard_agent_name";function Hv(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Ri);return e??n??"dashboard"}const ht=f(Hv()),hn=f(""),yn=f(""),za=f(""),Kr=f(null),qa=f(null),bn=f(!1),De=f(!1),kn=f(!1),xn=f(!1),ja=f(!1),Fa=f(!1),Qa=f(!1);function Ka(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function ra(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function Hr(t){return!t||t.length===0?"none":t.join(", ")}function Uv(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Ka(t.quiet_start)}-${Ka(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${ra(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${ra(t.interval_s)}.`:`Lodge ticks every ${ra(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function Ge(){qe();try{await ne()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function Li(t){const e=t.trim();ht.value=e,e&&localStorage.setItem(Ri,e)}function Bv(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function pi(){const t=ht.value.trim();if(t){kn.value=!0;try{const e=await uc(t),n=Bv(e);n&&Li(n),Qa.value=!0,await Ge(),C(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";C(n,"error")}finally{kn.value=!1}}}async function Wv(){const t=ht.value.trim();if(t){xn.value=!0;try{await Mo(t),Qa.value=!1,await Ge(),C(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";C(n,"error")}finally{xn.value=!1}}}async function Gv(){const t=ht.value.trim();if(t)try{await Mo(t)}catch{}localStorage.removeItem(Ri),Li("dashboard"),Qa.value=!1,await pi()}async function Jv(){const t=ht.value.trim();if(t){ja.value=!0;try{await pc(t),await Ge(),C("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";C(n,"error")}finally{ja.value=!1}}}async function $o(){const t=ht.value.trim(),e=hn.value.trim();if(!(!t||!e)){bn.value=!0;try{await Io(t,e),hn.value="",await Ge(),C("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";C(a,"error")}finally{bn.value=!1}}}async function Vv(){const t=yn.value.trim(),e=za.value.trim()||"Created from dashboard";if(t){De.value=!0;try{await dc(t,e,1),yn.value="",za.value="",await Ge(),C("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";C(a,"error")}finally{De.value=!1}}}async function ho(){const t=ht.value.trim()||"dashboard";Fa.value=!0,qa.value=null;try{const e=await On({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=gi(e.result);Kr.value=n,await Ge(),n!=null&&n.skipped_reason?C(n.skipped_reason,"warning"):C(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";qa.value=n,C(n,"error")}finally{Fa.value=!1}}function Qv({runtime:t}){var i,o;const e=Kr.value??(t==null?void 0:t.last_tick_result)??null;if(qa.value)return s`<div class="control-result-box is-error">${qa.value}</div>`;if(!e)return s`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((i=e.skipped_rows)==null?void 0:i.slice(0,3))??[],a=((o=e.passed_rows)==null?void 0:o.slice(0,3))??[];return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?s`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">Last acted: ${Br(e.acted_names)}</div>
      ${e.skipped_reason?s`<div class="control-status-copy">${e.skipped_reason}</div>`:null}
      ${e.activity_report?s`<pre class="control-transcript-text">${e.activity_report}</pre>`:null}
      ${n.length>0?s`
            <div class="control-result-list">
              ${n.map(r=>s`<div>${r.name}: ${r.reason??"skipped"}</div>`)}
            </div>
          `:null}
      ${a.length>0?s`
            <div class="control-result-list">
              ${a.map(r=>s`<div>${r.name}: ${r.reason??"passed"}</div>`)}
            </div>
          `:null}
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function Zv(t){return t.find(n=>n.name===on.value)??t[0]??null}function tf(){var a,i;const t=Gt.value,e=((a=ae.value)==null?void 0:a.lodge)??null,n=Zv(t);return rt(()=>{vi()},[]),rt(()=>{var r;const o=((r=t[0])==null?void 0:r.name)??"";if(!on.value&&o){Yn(o);return}on.value&&!t.some(l=>l.name===on.value)&&Yn(o)},[t.map(o=>o.name).join("|")]),s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function Yv(t){return t.find(n=>n.name===sn.value)??t[0]??null}function Xv(){var a,i;const t=Gt.value,e=((a=ae.value)==null?void 0:a.lodge)??null,n=Yv(t);return rt(()=>{pi()},[]),rt(()=>{var r;const o=((r=t[0])==null?void 0:r.name)??"";if(!sn.value&&o){Yn(o);return}sn.value&&!t.some(l=>l.name===sn.value)&&Yn(o)},[t.map(o=>o.name).join("|")]),s`
========
  `}function Yv(t){return t.find(n=>n.name===sn.value)??t[0]??null}function Xv(){var a,i;const t=Jt.value,e=((a=se.value)==null?void 0:a.lodge)??null,n=Yv(t);return rt(()=>{pi()},[]),rt(()=>{var r;const o=((r=t[0])==null?void 0:r.name)??"";if(!sn.value&&o){Yn(o);return}sn.value&&!t.some(l=>l.name===sn.value)&&Yn(o)},[t.map(o=>o.name).join("|")]),s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
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
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
          value=${gt.value}
          onInput=${o=>Ei(o.target.value)}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
          value=${_t.value}
          onInput=${o=>Li(o.target.value)}
========
          value=${ht.value}
          onInput=${o=>Li(o.target.value)}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
            onClick=${()=>{vi()}}
            disabled=${kn.value||gt.value.trim()===""}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
            onClick=${()=>{pi()}}
            disabled=${kn.value||_t.value.trim()===""}
========
            onClick=${()=>{pi()}}
            disabled=${kn.value||ht.value.trim()===""}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          >
            ${kn.value?"Joining...":Ya.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
            onClick=${()=>{Jv()}}
            disabled=${xn.value||gt.value.trim()===""}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
            onClick=${()=>{Wv()}}
            disabled=${xn.value||_t.value.trim()===""}
========
            onClick=${()=>{Wv()}}
            disabled=${xn.value||ht.value.trim()===""}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          >
            ${xn.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Vv()}}
            disabled=${kn.value||xn.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
            onClick=${()=>{Qv()}}
            disabled=${Fa.value||gt.value.trim()===""}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
            onClick=${()=>{Jv()}}
            disabled=${ja.value||_t.value.trim()===""}
========
            onClick=${()=>{Jv()}}
            disabled=${ja.value||ht.value.trim()===""}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          >
            ${Fa.value?"Pinging...":"Heartbeat"}
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
            value=${hn.value}
            onInput=${o=>{hn.value=o.target.value}}
            onKeyDown=${o=>{o.key==="Enter"&&bo()}}
            disabled=${bn.value}
          />
          <button
            class="control-btn"
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
            onClick=${()=>{bo()}}
            disabled=${bn.value||hn.value.trim()===""||gt.value.trim()===""}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
            onClick=${()=>{$o()}}
            disabled=${bn.value||hn.value.trim()===""||_t.value.trim()===""}
========
            onClick=${()=>{$o()}}
            disabled=${bn.value||hn.value.trim()===""||ht.value.trim()===""}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          >
            ${bn.value?"Sending...":"Send"}
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
          onInput=${o=>{Yn(o.target.value)}}
          disabled=${t.length===0}
        >
          ${t.length===0?s`<option value="">No keepers available</option>`:t.map(o=>s`<option value=${o.name}>${o.name}</option>`)}
        </select>

<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
        <${ir} keeper=${n} />
        <${rr}
          actor=${gt.value.trim()||"dashboard"}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
        <${nr} keeper=${n} />
        <${sr}
          actor=${_t.value.trim()||"dashboard"}
========
        <${nr} keeper=${n} />
        <${sr}
          actor=${ht.value.trim()||"dashboard"}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          keeper=${n}
          onPokeLodge=${()=>{ko()}}
        />
        <${or}
          keeperName=${(n==null?void 0:n.name)??""}
          placeholder=${t.length===0?"No keeper is active yet":"Direct prompt for the selected keeper"}
        />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${Wv(e)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${e!=null&&e.enabled?"enabled":"disabled"}</span>
          <span class="pill">every ${ra(e==null?void 0:e.interval_s)}</span>
          <span class="pill">quiet ${Ha(e==null?void 0:e.quiet_start)}-${Ha(e==null?void 0:e.quiet_end)} KST</span>
          <span class="pill">${e!=null&&e.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${e!=null&&e.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${e!=null&&e.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${Br((i=e==null?void 0:e.last_tick_result)==null?void 0:i.acted_names)}
        </div>
        ${e!=null&&e.last_skip_reason?s`<div class="control-status-copy">Last skip reason: ${e.last_skip_reason}</div>`:null}

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{ko()}}
            disabled=${Ka.value}
          >
            ${Ka.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${Xv} runtime=${e} />
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
          value=${yn.value}
          onInput=${o=>{yn.value=o.target.value}}
          disabled=${Pe.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${qa.value}
          onInput=${o=>{qa.value=o.target.value}}
          disabled=${Pe.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${()=>{Yv()}}
          disabled=${Pe.value||yn.value.trim()===""}
        >
          ${Pe.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}const xo=[{id:"observe",label:"Observe",description:"Live health, execution state, and room-wide telemetry"},{id:"coordinate",label:"Coordinate",description:"Conversation, decisions, planning, and backlog context"},{id:"command",label:"Command",description:"Direct control surfaces and intervention workflows"}],fi=[{id:"command",label:"Command",icon:"🧭",group:"command",description:"Company, platoon, squad, and agent command plane with operation and trace visibility"},{id:"overview",label:"Overview",icon:"🏠",group:"observe",description:"Room health, keeper pressure, and top-line execution status"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals, MDAL loops, and task backlog in one planning surface"},{id:"ops",label:"Ops",icon:"🎮",group:"command",description:"Guided operator controls for room, sessions, and keepers"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}],So="masc_dashboard_quick_actions_open";function ef(){const t=jt.value;return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}const yo=[{id:"observe",label:"Observe",description:"Live health, execution state, and room-wide telemetry"},{id:"coordinate",label:"Coordinate",description:"Conversation, decisions, planning, and backlog context"},{id:"command",label:"Command",description:"Direct control surfaces and intervention workflows"}],mi=[{id:"command",label:"Command",icon:"🧭",group:"command",description:"Company, platoon, squad, and agent command plane with operation and trace visibility"},{id:"overview",label:"Overview",icon:"🏠",group:"observe",description:"Room health, keeper pressure, and top-line execution status"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals, MDAL loops, and task backlog in one planning surface"},{id:"ops",label:"Ops",icon:"🎮",group:"command",description:"Guided operator controls for room, sessions, and keepers"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}],bo="masc_dashboard_quick_actions_open";function Zv(){const t=jt.value;return s`
========
  `}const yo=[{id:"observe",label:"Observe",description:"Live health, execution state, and room-wide telemetry"},{id:"coordinate",label:"Coordinate",description:"Conversation, decisions, planning, and backlog context"},{id:"command",label:"Command",description:"Direct control surfaces and intervention workflows"}],mi=[{id:"command",label:"Command",icon:"🧭",group:"command",description:"Company, platoon, squad, and agent command plane with operation and trace visibility"},{id:"overview",label:"Overview",icon:"🏠",group:"observe",description:"Room health, keeper pressure, and top-line execution status"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals, MDAL loops, and task backlog in one planning surface"},{id:"ops",label:"Ops",icon:"🎮",group:"command",description:"Guided operator controls for room, sessions, and keepers"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}],bo="masc_dashboard_quick_actions_open";function Zv(){const t=Ft.value;return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${In.value} events</span>
    </div>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function nf(){const t=tt.value.tab,e=jt.value,n=fi.find(r=>r.id===t),a=xo.find(r=>r.id===(n==null?void 0:n.group)),[i,o]=Ua(()=>{const r=localStorage.getItem(So);return r!=="0"});return rt(()=>{localStorage.setItem(So,i?"1":"0")},[i]),s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function tf(){const t=tt.value.tab,e=jt.value,n=mi.find(r=>r.id===t),a=yo.find(r=>r.id===(n==null?void 0:n.group)),[i,o]=Ha(()=>{const r=localStorage.getItem(bo);return r!=="0"});return rt(()=>{localStorage.setItem(bo,i?"1":"0")},[i]),s`
========
  `}function tf(){const t=nt.value.tab,e=Ft.value,n=mi.find(r=>r.id===t),a=yo.find(r=>r.id===(n==null?void 0:n.group)),[i,o]=Ha(()=>{const r=localStorage.getItem(bo);return r!=="0"});return rt(()=>{localStorage.setItem(bo,i?"1":"0")},[i]),s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${a?s`<span class="rail-section-chip">${a.label}</span>`:null}
        </div>
        ${xo.map(r=>s`
          <div class="rail-nav-group" key=${r.id}>
            <div class="rail-group-label">${r.label}</div>
            <div class="rail-group-copy">${r.description}</div>
            <div class="rail-tab-list">
              ${fi.filter(l=>l.group===r.id).map(l=>s`
                  <button
                    class="rail-tab-btn ${t===l.id?"active":""}"
                    onClick=${()=>Rt(l.id)}
                  >
                    <span class="rail-tab-icon">${l.icon}</span>
                    <span class="rail-tab-copy">
                      <strong>${l.label}</strong>
                      <span>${l.description}</span>
                    </span>
                  </button>
                `)}
            </div>
          </div>
        `)}
        <div class="rail-view-note">
          <div class="rail-view-note-label">Current focus</div>
          <strong>${(n==null?void 0:n.label)??t}</strong>
          <p>${(n==null?void 0:n.description)??"Live operational view"}</p>
        </div>
      </section>

      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Snapshot</h3>
          <span class="rail-section-chip ${e?"ok":"bad"}">${e?"Live":"Offline"}</span>
        </div>
        <div class="rail-stat-grid">
          <div class="rail-stat-card">
            <span>Agents</span>
            <strong>${At.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Keepers</span>
            <strong>${Jt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Tasks</span>
            <strong>${yt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Events</span>
            <strong>${In.value}</strong>
          </div>
        </div>
        <div class="rail-snapshot-copy">
          <span>Connection ${e?"healthy":"recovering"}</span>
          <span>${(a==null?void 0:a.label)??"Observe"} workspace active</span>
        </div>
        <div class="rail-inline-actions">
          <button
            class="rail-refresh-btn"
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
            onClick=${()=>{ee(),t==="command"&&(Me(),ge()),t==="ops"&&He(),t==="board"&&zt(),t==="trpg"&&qt(),t==="goals"&&(Tn(),je())}}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
            onClick=${()=>{ee(),t==="command"&&(fe(),$e()),t==="ops"&&He(),t==="board"&&zt(),t==="trpg"&&qt(),t==="goals"&&(Tn(),je())}}
========
            onClick=${()=>{ne(),t==="command"&&(fe(),$e()),t==="ops"&&He(),t==="board"&&qt(),t==="trpg"&&jt(),t==="goals"&&(Tn(),je())}}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
          >
            Refresh Now
          </button>
          <button class="rail-secondary-btn" onClick=${()=>Rt("ops")}>
            Open Ops
          </button>
        </div>
      </section>

      <section class="rail-card fold-card">
        <div class="rail-card-head">
          <h3>Quick Actions</h3>
          <span class="rail-section-chip">${i?"Open":"Closed"}</span>
        </div>
        <button class="fold-toggle" onClick=${()=>o(r=>!r)}>
          <span>${i?"Hide inline actions":"Show inline actions"}</span>
          <span class="fold-toggle-meta">Join, broadcast, keeper DM, lodge poke</span>
        </button>
        ${i?s`<div class="rail-fold-body"><${tf} /></div>`:s`<div class="rail-fold-hint">Use inline actions for quick room nudges. Open the Ops tab for structured intervention work.</div>`}
      </section>
    </aside>
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
  `}function af(){switch(tt.value.tab){case"command":return s`<${Kp} />`;case"overview":return s`<${ao} />`;case"ops":return s`<${cm} />`;case"board":return s`<${Cm} />`;case"agents":return s`<${iv} />`;case"goals":return s`<${fv} />`;case"trpg":return s`<${Uv} />`;default:return s`<${ao} />`}}function sf(){rt(()=>{nl(),Po(),ee();const n=rd();return ld(),()=>{dl(),n(),cd()}},[]),rt(()=>{const n=setInterval(()=>{const a=tt.value.tab;a==="command"?(Me(),ge()):a==="ops"?He():a==="board"?zt():a==="trpg"?qt():a==="goals"&&(Tn(),je())},15e3);return()=>{clearInterval(n)}},[]),rt(()=>{const n=tt.value.tab;n==="command"&&(Me(),ge()),n==="ops"&&He(),n==="board"&&zt(),n==="trpg"&&qt(),n==="goals"&&(Tn(),je())},[tt.value.tab]);const t=tt.value.tab,e=fi.find(n=>n.id===t);return s`
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
  `}function ef(){switch(tt.value.tab){case"command":return s`<${qp} />`;case"overview":return s`<${to} />`;case"ops":return s`<${rm} />`;case"board":return s`<${Am} />`;case"agents":return s`<${av} />`;case"goals":return s`<${mv} />`;case"trpg":return s`<${Kv} />`;default:return s`<${to} />`}}function nf(){rt(()=>{tl(),No(),ee();const n=id();return od(),()=>{ll(),n(),rd()}},[]),rt(()=>{const n=setInterval(()=>{const a=tt.value.tab;a==="command"?(fe(),$e()):a==="ops"?He():a==="board"?zt():a==="trpg"?qt():a==="goals"&&(Tn(),je())},15e3);return()=>{clearInterval(n)}},[]),rt(()=>{const n=tt.value.tab;n==="command"&&(fe(),$e()),n==="ops"&&He(),n==="board"&&zt(),n==="trpg"&&qt(),n==="goals"&&(Tn(),je())},[tt.value.tab]);const t=tt.value.tab,e=mi.find(n=>n.id===t);return s`
========
  `}function ef(){switch(nt.value.tab){case"command":return s`<${qp} />`;case"overview":return s`<${to} />`;case"ops":return s`<${rm} />`;case"board":return s`<${Am} />`;case"agents":return s`<${av} />`;case"goals":return s`<${mv} />`;case"trpg":return s`<${Kv} />`;default:return s`<${to} />`}}function nf(){rt(()=>{tl(),No(),ne();const n=id();return od(),()=>{ll(),n(),rd()}},[]),rt(()=>{const n=setInterval(()=>{const a=nt.value.tab;a==="command"?(fe(),$e()):a==="ops"?He():a==="board"?qt():a==="trpg"?jt():a==="goals"&&(Tn(),je())},15e3);return()=>{clearInterval(n)}},[]),rt(()=>{const n=nt.value.tab;n==="command"&&(fe(),$e()),n==="ops"&&He(),n==="board"&&qt(),n==="trpg"&&jt(),n==="goals"&&(Tn(),je())},[nt.value.tab]);const t=nt.value.tab,e=mi.find(n=>n.id===t);return s`
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
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
            class="activity-panel-toggle ${Fe.value?"active":""}"
            onClick=${Fd}
            title="Toggle Activity Panel"
          >
            Activity
          </button>
          <${ef} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${nf} />
        <main class="dashboard-main">
<<<<<<<< HEAD:assets/dashboard/assets/index-ndjsMVvx.js
          ${Hs.value&&!jt.value?s`<div class="loading-indicator">Loading dashboard...</div>`:s`<${af} />`}
|||||||| parent of 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-Bq1VqxND.js
          ${Fs.value&&!jt.value?s`<div class="loading-indicator">Loading dashboard...</div>`:s`<${ef} />`}
========
          ${Fs.value&&!Ft.value?s`<div class="loading-indicator">Loading dashboard...</div>`:s`<${ef} />`}
>>>>>>>> 240e63a6 (feat(command-plane): surface hot swarm runtime blockers):assets/dashboard/assets/index-7B9Iovwe.js
        </main>
      </div>

      ${Fe.value?s`
        <div class="activity-panel-backdrop" onClick=${Xi} />
        <aside class="activity-panel">
          <div class="activity-panel-header">
            <h3>Activity Feed</h3>
            <button class="activity-panel-close" onClick=${Xi}>Close</button>
          </div>
          <div class="activity-panel-body">
            <${Jm} />
          </div>
        </aside>
      `:null}

      <${qd} />
      <${$d} />
      <${md} />
    </div>
  `}const Ao=document.getElementById("app");Ao&&Qr(s`<${sf} />`,Ao);export{Qd as _};
