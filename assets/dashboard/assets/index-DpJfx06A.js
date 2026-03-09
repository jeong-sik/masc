var Wr=Object.defineProperty;var Gr=(t,e,n)=>e in t?Wr(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var ke=(t,e,n)=>Gr(t,typeof e!="symbol"?e+"":e,n);import{e as Jr,_ as Vr,c as _,b as wt,y as rt,d as Ua,A as wo,G as Qr}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const o of s)if(o.type==="childList")for(const r of o.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const o={};return s.integrity&&(o.integrity=s.integrity),s.referrerPolicy&&(o.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?o.credentials="include":s.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function a(s){if(s.ep)return;s.ep=!0;const o=n(s);fetch(s.href,o)}})();var i=Jr.bind(Vr);const Yr=["command","overview","board","goals","agents","ops","trpg"],Co={tab:"overview",params:{},postId:null},Xr={journal:"overview",mdal:"goals",tasks:"goals",execution:"overview",council:"board",activity:"overview"};function Mi(t){return!!t&&Yr.includes(t)}function Oi(t){if(t)return Xr[t]??t}function Qn(t){try{return decodeURIComponent(t)}catch{return t}}function Rs(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function Zr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function To(t,e){if(t[0]==="chains"){const r={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(r.operation=Qn(t[2])),{tab:"command",params:r,postId:null}}const n=Oi(t[0]),a=Oi(e.tab),s=Mi(n)?n:Mi(a)?a:"overview";let o=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?o=Qn(t[2]):t[0]==="post"&&t[1]&&(o=Qn(t[1]))),{tab:s,params:e,postId:o}}function la(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Co;const n=Qn(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const l=n.indexOf("?");l>=0&&(a=n.slice(0,l),s=n.slice(l+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const o=Rs(s),r=Zr(a);return To(r,o)}function tl(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...Co,params:Rs(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=Rs(e.replace(/^\?/,""));return To(a,s)}function No(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const nt=_(la(window.location.hash));window.addEventListener("hashchange",()=>{nt.value=la(window.location.hash)});function Rt(t,e){const n={tab:t,params:e??{},postId:null};window.location.hash=No(n)}function el(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function nl(){if(window.location.hash&&window.location.hash!=="#"){nt.value=la(window.location.hash);return}const t=tl(window.location.pathname,window.location.search);if(t){nt.value=t;const e=No(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",nt.value=la(window.location.hash)}const zi="masc_dashboard_sse_session_id",al=1e3,sl=15e3,Ft=_(!1),In=_(0),Ro=_(null),ca=_([]);function il(){let t=sessionStorage.getItem(zi);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(zi,t)),t}const ol=200;function rl(t,e,n="system",a={}){const s={agent:t,text:e,timestamp:Date.now(),kind:n,...a};ca.value=[s,...ca.value].slice(0,ol)}function Ls(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function qi(t,e){const n=Ls(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function Ct(t,e,n,a,s={}){rl(t,e,n,{eventType:a,...s})}let Ot=null,De=null,Ps=0;function Lo(){De&&(clearTimeout(De),De=null)}function ll(){if(De)return;Ps++;const t=Math.min(Ps,5),e=Math.min(sl,al*Math.pow(2,t));De=setTimeout(()=>{De=null,Po()},e)}function Po(){Lo(),Ot&&(Ot.close(),Ot=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",il());const s=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(s);Ot=o,o.onopen=()=>{Ot===o&&(Ps=0,Ft.value=!0)},o.onerror=()=>{Ot===o&&(Ft.value=!1,o.close(),Ot=null,ll())},o.onmessage=r=>{try{const l=JSON.parse(r.data);In.value++,Ro.value=l,cl(l)}catch{}}}function cl(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":Ct(n,"Joined","system","agent_joined");break;case"agent_left":Ct(n,"Left","system","agent_left");break;case"broadcast":Ct(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Ct(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Ct(n,qi("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Ls(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":Ct(n,qi("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Ls(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":Ct(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Ct(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Ct(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Ct(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Ct(n,e,"system","unknown")}}function dl(){Lo(),Ot&&(Ot.close(),Ot=null),Ft.value=!1}function Do(){return new URLSearchParams(window.location.search)}function Eo(){const t=Do(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Io(){return{...Eo(),"Content-Type":"application/json"}}const ul=15e3,_i=3e4,pl=6e4,ji=new Set([408,425,429,500,502,503,504]);class Mn extends Error{constructor(n){const a=n.method.toUpperCase(),s=n.timeout===!0,o=s?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);ke(this,"method");ke(this,"path");ke(this,"status");ke(this,"statusText");ke(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=s}}async function gi(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Mn({method:r,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(s)}}function ml(){var e,n;const t=Do();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function tt(t){const e=await gi(t,{headers:Eo()},ul);if(!e.ok)throw new Mn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function vl(t){return new Promise(e=>setTimeout(e,t))}function fl(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function _l(t){if(t instanceof Mn)return t.timeout||typeof t.status=="number"&&ji.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=fl(t.message);return e!==null&&ji.has(e)}async function Ue(t,e,n=2){let a=0;for(;;)try{return await e()}catch(s){if(!_l(s)||a>=n)throw s;const o=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${o}ms`,s),await vl(o),a+=1}}async function Kt(t,e,n,a=_i){const s=await gi(t,{method:"POST",headers:{...Io(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new Mn({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.json()}async function gl(t,e,n,a=_i){const s=await gi(t,{method:"POST",headers:{...Io(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new Mn({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.text()}function $l(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function hl(t){var e,n,a,s,o,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const p=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(p)}return((l=(r=(o=t.result)==null?void 0:o.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function bt(t,e){const n=await gl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},pl),a=$l(n);return hl(a)}function yl(t="compact"){return tt(`/api/v1/dashboard?mode=${t}`)}function bl(){return tt("/api/v1/agents?limit=100")}function kl(t){const e=new URLSearchParams({limit:"200"});return e.set("include_done","true"),e.set("include_cancelled","true"),tt(`/api/v1/tasks?${e}`)}function xl(t){const e=new URLSearchParams({limit:"50"});return t!=null&&t>0&&e.set("since_seq",String(t)),tt(`/api/v1/messages?${e}`)}function Sl(t={}){return Ue("fetchMdalLoops",async()=>{const e=new URLSearchParams;t.limit!=null&&e.set("limit",String(t.limit)),t.historyLimit!=null&&e.set("history_limit",String(t.historyLimit)),t.status&&e.set("status",t.status);const n=e.toString();return tt(`/api/v1/mdal/loops${n?`?${n}`:""}`)})}function Al(){return tt("/api/v1/operator")}function wl(){return tt("/api/v1/command-plane")}function Cl(){return tt("/api/v1/command-plane/summary")}function Tl(){return tt("/api/v1/chains/summary")}function Nl(t){return tt(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Rl(){return tt("/api/v1/command-plane/help")}function Ll(t){const e=new URLSearchParams;t&&e.set("run_id",t);const n=e.toString();return tt(`/api/v1/command-plane/swarm${n?`?${n}`:""}`)}function Pl(t,e){return Kt(t,e)}function Dl(t){switch(t.action_type){case"keeper_msg":case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return _i}}function On(t){return Kt("/api/v1/operator/action",t,void 0,Dl(t))}function El(t,e){return Kt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const Il=new Set(["lodge-system","team-session"]);function ze(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function Ml(t){return Il.has(t.trim().toLowerCase())}function Ol(t){return t.filter(e=>!Ml(e.author))}function zl(t){var s;const e=t.trim(),a=((s=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:s.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function Mo(t){if(!O(t))return null;const e=h(t.id,"").trim(),n=h(t.author,"").trim(),a=h(t.content,"").trim();if(!e||!n)return null;const s=q(t.score,0),o=q(t.votes_up,0),r=q(t.votes_down,0),l=q(t.votes,s||o-r),p=q(t.comment_count,q(t.reply_count,0)),$=(()=>{const y=t.flair;if(typeof y=="string"&&y.trim())return y.trim();if(O(y)){const T=h(y.name,"").trim();if(T)return T}return h(t.flair_name,"").trim()||void 0})(),m=h(t.created_at_iso,"").trim()||ze(t.created_at),d=h(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?ze(t.updated_at):m),c=h(t.title,"").trim()||zl(a);return{id:e,author:n,title:c,content:a,tags:[],votes:l,vote_balance:s,comment_count:p,created_at:m,updated_at:d,flair:$,hearth_count:q(t.hearth_count,0)}}function ql(t){if(!O(t))return null;const e=h(t.id,"").trim(),n=h(t.post_id,"").trim(),a=h(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:h(t.content,""),created_at:ze(t.created_at)}}async function jl(t,e){return Ue("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const a=n.toString(),s=await tt(`/api/v1/board${a?`?${a}`:""}`),o=Array.isArray(s.posts)?s.posts.map(Mo).filter(l=>l!==null):[];return{posts:e!=null&&e.excludeSystem?Ol(o):o}})}async function Fl(t){return Ue("fetchBoardPost",async()=>{const e=await tt(`/api/v1/board/${t}?format=flat`),n=O(e.post)?e.post:e,a=Mo(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},o=(Array.isArray(e.comments)?e.comments:[]).map(ql).filter(r=>r!==null);return{...a,comments:o}})}function Oo(t,e){return Kt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:ml()})}function Kl(t,e,n){return Kt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Hl(t){const e=h(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function lt(...t){for(const e of t){const n=h(e,"");if(n.trim())return n.trim()}return""}function Fi(t){const e=Hl(lt(t.outcome,t.result,t.result_code));if(!e)return;const n=lt(t.reason,t.reason_code,t.description,t.detail),a=lt(t.summary,t.summary_ko,t.summary_en,t.note),s=lt(t.details,t.details_text,t.text,t.note),o=lt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=lt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=lt(t.raw_reason,t.raw_reason_code,t.error_message),p=(()=>{const d=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof d=="string"?[d]:Array.isArray(d)?d.map(v=>{if(typeof v=="string")return v.trim();if(O(v)){const c=h(v.summary,"").trim();if(c)return c;const y=h(v.text,"").trim();if(y)return y;const S=h(v.type,"").trim();return S||h(v.event_id,"").trim()}return""}).filter(v=>v.length>0):[]})(),$=(()=>{const d=q(t.turn,Number.NaN);if(Number.isFinite(d))return d;const v=q(t.turn_number,Number.NaN);if(Number.isFinite(v))return v;const c=q(t.current_turn,Number.NaN);if(Number.isFinite(c))return c;const y=q(t.round,Number.NaN);return Number.isFinite(y)?y:void 0})(),m=lt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:s||void 0,winner:o||void 0,winner_actor_id:r||void 0,evidence:p.length>0?p:void 0,raw_reason:l||void 0,turn:$,phase:m||void 0}}function Ul(t,e){const n=O(t.state)?t.state:{};if(h(n.status,"active").toLowerCase()!=="ended")return;const s=[...e].reverse().find(r=>O(r)?h(r.type,"")==="session.outcome":!1),o=O(n.session_outcome)?n.session_outcome:{};if(O(o)&&Object.keys(o).length>0){const r=Fi(o);if(r)return r}if(O(s))return Fi(O(s.payload)?s.payload:{})}function O(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function q(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Bl(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Ds(t,e=!1){return typeof t=="boolean"?t:e}function Qe(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(O(e)){const n=h(e.name,"").trim(),a=h(e.id,"").trim(),s=h(e.skill,"").trim();return n||a||s}return""}).filter(e=>e.length>0):[]}function Wl(t){const e={};if(!O(t)&&!Array.isArray(t))return e;if(O(t))return Object.entries(t).forEach(([n,a])=>{const s=n.trim(),o=h(a,"").trim();!s||!o||(e[s]=o)}),e;for(const n of t){if(!O(n))continue;const a=lt(n.to,n.target,n.actor_id,n.name,n.id),s=lt(n.relationship,n.relation,n.type,n.kind);!a||!s||(e[a]=s)}return e}function Gl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function xt(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return a}const Jl=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Vl(t){const e=O(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,s])=>{const o=a.trim();o&&(Jl.has(o.toLowerCase())||typeof s=="number"&&Number.isFinite(s)&&(n[o]=s))}),n}function Ql(t,e){if(t!=="dice.rolled")return;const n=q(e.raw_d20,0),a=q(e.total,0),s=q(e.bonus,0),o=h(e.action,"roll"),r=q(e.dc,0);return{notation:r>0?`${o} (DC ${r})`:o,rolls:n>0?[n]:[],total:a,modifier:s}}function Yl(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Xl(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Zl(t,e,n,a){const s=n||e||h(a.actor_id,"")||h(a.actor_name,"");switch(t){case"turn.action.proposed":{const o=h(a.proposed_action,h(a.reply,""));return o?`${s||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=h(a.reply,h(a.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return h(a.reply,h(a.content,h(a.text,"Narration")));case"dice.rolled":{const o=h(a.action,"roll"),r=q(a.total,0),l=q(a.dc,0),p=h(a.label,""),$=s||"actor",m=l>0?` vs DC ${l}`:"",d=p?` (${p})`:"";return`${$} ${o}: ${r}${m}${d}`}case"turn.started":return`Turn ${q(a.turn,1)} started`;case"phase.changed":return`Phase: ${h(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(a.name,O(a.actor)?h(a.actor.name,s||"unknown"):s||"unknown")}`;case"actor.claimed":return`${h(a.keeper_name,h(a.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${h(a.keeper_name,h(a.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${q(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${q(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||h(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||h(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${h(a.reason_code,"unknown")}`;case"memory.signal":{const o=O(a.entity_refs)?a.entity_refs:{},r=h(o.requested_tier,""),l=h(o.effective_tier,""),p=Ds(o.guardrail_applied,!1),$=h(a.summary_en,h(a.summary_ko,"Memory signal"));if(!r&&!l)return $;const m=r&&l?`${r}->${l}`:l||r;return`${$} [${m}${p?" (guardrail)":""}]`}case"world.event":{if(h(a.event_type,"")==="canon.check"){const r=h(a.status,"unknown"),l=h(a.contract_id,"n/a");return`Canon ${r}: ${l}`}return h(a.description,h(a.summary,"World event"))}case"combat.attack":return h(a.summary,h(a.result,"Attack resolved"));case"combat.defense":return h(a.summary,h(a.result,"Defense resolved"));case"session.outcome":return h(a.summary,h(a.outcome,"Session ended"));default:{const o=Yl(a);return o?`${t}: ${o}`:t}}}function tc(t,e){const n=O(t)?t:{},a=h(n.type,"event"),s=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=h(n.actor_name,"").trim()||e[s]||h(O(n.payload)?n.payload.actor_name:"",""),r=O(n.payload)?n.payload:{},l=h(n.ts,h(n.timestamp,new Date().toISOString())),p=h(n.phase,h(r.phase,"")),$=h(n.category,"");return{type:a,actor:o||s||h(r.actor_name,""),actor_id:s||h(r.actor_id,""),actor_name:o,seq:n.seq,room_id:h(n.room_id,""),phase:p||void 0,category:$||Xl(a),visibility:h(n.visibility,h(r.visibility,"public")),event_id:h(n.event_id,""),content:Zl(a,s,o,r),dice_roll:Ql(a,r),timestamp:l}}function ec(t,e,n){var mt,vt;const a=h(t.room_id,"")||n||"default",s=O(t.state)?t.state:{},o=O(s.party)?s.party:{},r=O(s.actor_control)?s.actor_control:{},l=O(s.join_gate)?s.join_gate:{},p=O(s.contribution_ledger)?s.contribution_ledger:{},$=Object.entries(o).map(([B,M])=>{const x=O(M)?M:{},Dt=xt(x,"max_hp",void 0,10),Vt=xt(x,"hp",void 0,Dt),oe=xt(x,"max_mp",void 0,0),re=xt(x,"mp",void 0,0),I=xt(x,"level",void 0,1),Et=xt(x,"xp",void 0,0),le=Ds(x.alive,Vt>0),Je=r[B],Ve=typeof Je=="string"?Je:void 0,f=Gl(x.role,B,Ve),L=Bl(x.generation),j=lt(x.joined_at,x.joinedAt,x.started_at,x.startedAt),at=lt(x.claimed_at,x.claimedAt,x.assigned_at,x.assignedAt,x.assigned_time),z=lt(x.last_seen,x.lastSeen,x.last_seen_at,x.lastSeenAt,x.last_active,x.lastActive),ft=lt(x.scene,x.current_scene,x.currentScene,x.world_scene,x.scene_name,x.sceneName),Q=lt(x.location,x.current_location,x.currentLocation,x.position,x.zone,x.area);return{id:B,name:h(x.name,B),role:f,keeper:Ve,archetype:h(x.archetype,""),persona:h(x.persona,""),portrait:h(x.portrait,"")||void 0,background:h(x.background,"")||void 0,traits:Qe(x.traits),skills:Qe(x.skills),stats_raw:Vl(x),status:le?"active":"dead",generation:L,joined_at:j||void 0,claimed_at:at||void 0,last_seen:z||void 0,scene:ft||void 0,location:Q||void 0,inventory:Qe(x.inventory),notes:Qe(x.notes),relationships:Wl(x.relationships),stats:{hp:Vt,max_hp:Dt,mp:re,max_mp:oe,level:I,xp:Et,strength:xt(x,"strength","str",10),dexterity:xt(x,"dexterity","dex",10),constitution:xt(x,"constitution","con",10),intelligence:xt(x,"intelligence","int",10),wisdom:xt(x,"wisdom","wis",10),charisma:xt(x,"charisma","cha",10)}}}),m=$.filter(B=>B.status!=="dead"),d=Ul(t,e),v={phase_open:Ds(l.phase_open,!0),min_points:q(l.min_points,3),window:h(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},c=Object.entries(p).map(([B,M])=>{const x=O(M)?M:{};return{actor_id:B,score:q(x.score,0),last_reason:h(x.last_reason,"")||null,reasons:Qe(x.reasons)}}),y=$.reduce((B,M)=>(B[M.id]=M.name,B),{}),S=e.map(B=>tc(B,y)),T=q(s.turn,1),P=h(s.phase,"round"),K=h(s.map,""),E=O(s.world)?s.world:{},N=K||h(E.ascii_map,h(E.map,"")),R=S.filter((B,M)=>{const x=e[M];if(!O(x))return!1;const Dt=O(x.payload)?x.payload:{};return q(Dt.turn,-1)===T}),X=(R.length>0?R:S).slice(-12),H=h(s.status,"active");return{session:{id:a,room:a,status:H==="ended"?"ended":H==="paused"?"paused":"active",round:T,actors:m,created_at:((mt=S[0])==null?void 0:mt.timestamp)??new Date().toISOString()},current_round:{round_number:T,phase:P,events:X,timestamp:((vt=S[S.length-1])==null?void 0:vt.timestamp)??new Date().toISOString()},map:N||void 0,join_gate:v,contribution_ledger:c,outcome:d,party:m,story_log:S,history:[]}}async function nc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await tt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function ac(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([tt(`/api/v1/trpg/state${e}`),nc(t)]);return ec(n,a,t)}function sc(t){return Kt("/api/v1/trpg/rounds/run",{room_id:t})}function ic(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function oc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Kt("/api/v1/trpg/dice/roll",e)}function rc(t,e){const n=ic();return Kt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function lc(t,e){var s;const n=(s=e.idempotencyKey)==null?void 0:s.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),Kt("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function cc(t,e,n){return Kt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function dc(t,e,n){const a=await bt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function uc(t){const e=await bt("trpg.mid_join.request",t);return JSON.parse(e)}async function zo(t,e){await bt("masc_broadcast",{agent_name:t,message:e})}async function pc(t,e,n=1){await bt("masc_add_task",{title:t,description:e,priority:n})}async function mc(t){return bt("masc_join",{agent_name:t})}async function qo(t){await bt("masc_leave",{agent_name:t})}async function vc(t){await bt("masc_heartbeat",{agent_name:t})}async function fc(t=40){return(await bt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function _c(t,e=20){return bt("masc_task_history",{task_id:t,limit:e})}async function gc(){return Ue("fetchDebates",async()=>{const t=await tt("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!O(e))return null;const n=h(e.id,"").trim(),a=h(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:h(e.status,"open"),argument_count:q(e.argument_count,0),created_at:ze(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function $c(){return Ue("fetchCouncilSessions",async()=>{const t=await tt("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!O(e))return null;const n=h(e.id,"").trim(),a=h(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:h(e.initiator,"system"),votes:q(e.votes,0),quorum:q(e.quorum,0),state:h(e.state,"open"),created_at:ze(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function hc(t){const e=await bt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function yc(t){return Ue("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await tt(`/api/v1/council/debates/${e}/summary`);if(!O(n))return null;const a=h(n.id,"").trim();return a?{id:a,topic:h(n.topic,""),status:h(n.status,"open"),support_count:q(n.support_count,0),oppose_count:q(n.oppose_count,0),neutral_count:q(n.neutral_count,0),total_arguments:q(n.total_arguments,0),created_at:ze(n.created_at_iso??n.created_at),summary_text:h(n.summary_text,"")}:null})}function bc(t,e,n){return bt("masc_keeper_msg",{name:t,message:e})}async function kc(){try{const t=await bt("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const on=_(""),Bt=_({}),dt=_({}),Es=_({}),Is=_({}),Ms=_({}),Os=_({}),Wt=_({});function ot(t,e,n){t.value={...t.value,[e]:n}}function Gt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function U(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function Nt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ne(t){return typeof t=="boolean"?t:void 0}function zs(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function qs(t){return Array.isArray(t)?t.map(e=>U(e)).filter(e=>!!e):[]}function xc(t){var n;const e=(n=U(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Sc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Xa(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!Gt(a))continue;const s=U(a.name);if(!s)continue;const o=U(a[e]);e==="summary"?n.push({name:s,summary:o}):n.push({name:s,reason:o})}return n}function Ac(t){if(!Gt(t))return null;const e=U(t.name);return e?{name:e,trigger:U(t.trigger),outcome:U(t.outcome),summary:U(t.summary),reason:U(t.reason)}:null}function wc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Cc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function jo(t,e,n){return U(t)??Cc(e,n)}function Fo(t,e){return typeof t=="boolean"?t:e==="recover"}function da(t){if(!Gt(t))return null;const e=U(t.health_state),n=U(t.next_action_path),a=U(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:U(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:zs(t.last_reply_at),last_reply_preview:U(t.last_reply_preview)??null,last_error:U(t.last_error)??null,next_eligible_at_s:Nt(t.next_eligible_at_s)??null,recoverable:Fo(t.recoverable,n),summary:jo(t.summary,e,U(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function $i(t){return Gt(t)?{hour:Nt(t.hour),checked:Nt(t.checked)??0,acted:Nt(t.acted)??0,acted_names:qs(t.acted_names),activity_report:U(t.activity_report),quiet_hours_overridden:Ne(t.quiet_hours_overridden),skipped_reason:U(t.skipped_reason),acted_rows:Xa(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:Xa(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:Xa(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Ac).filter(e=>e!==null):[]}:null}function Tc(t){return Gt(t)?{enabled:Ne(t.enabled)??!1,interval_s:Nt(t.interval_s)??0,quiet_start:Nt(t.quiet_start),quiet_end:Nt(t.quiet_end),quiet_active:Ne(t.quiet_active),use_planner:Ne(t.use_planner),delegate_llm:Ne(t.delegate_llm),agent_count:Nt(t.agent_count),agents:qs(t.agents),last_tick_ago_s:Nt(t.last_tick_ago_s)??null,last_tick_ago:U(t.last_tick_ago),total_ticks:Nt(t.total_ticks),total_checkins:Nt(t.total_checkins),last_skip_reason:U(t.last_skip_reason)??null,last_tick_result:$i(t.last_tick_result),active_self_heartbeats:qs(t.active_self_heartbeats)}:null}function Nc(t){return Gt(t)?{status:t.status,diagnostic:da(t.diagnostic)}:null}function Rc(t){return Gt(t)?{recovered:Ne(t.recovered)??!1,skipped_reason:U(t.skipped_reason)??null,before:da(t.before),after:da(t.after),down:t.down,up:t.up}:null}function Lc(t,e){var K,E;if(!(t!=null&&t.name))return null;const n=U((K=t.agent)==null?void 0:K.status)??U(t.status)??"unknown",a=U((E=t.agent)==null?void 0:E.error)??null,s=t.presence_keepalive??!0,o=t.keepalive_running??!1,r=t.turn_count??0,l=t.last_turn_ago_s??null,p=t.proactive_enabled??!1,$=t.proactive_cooldown_sec??0,m=t.last_proactive_ago_s??null,d=p&&m!=null?Math.max(0,$-m):null,v=r<=0||l==null?"never":l>900?"stale":"fresh",c=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,y=a??(s&&!o?"keeper keepalive is not running":null),S=n==="offline"||n==="inactive"?"offline":y?"degraded":v==="stale"?"stale":v==="never"?"idle":"healthy",T=y?wc(y):e!=null&&e.quiet_active&&v!=="fresh"?"quiet_hours":s&&!o?"disabled":r<=0?"never_started":d!=null&&d>0?"min_gap":v==="fresh"||v==="stale"?"no_recent_activity":"unknown",P=S==="offline"||S==="degraded"||S==="stale"?"recover":T==="quiet_hours"?"manual_lodge_poke":T==="unknown"?"probe":"direct_message";return{health_state:S,quiet_reason:T,next_action_path:P,last_reply_status:v,last_reply_at:c,last_reply_preview:null,last_error:y,next_eligible_at_s:d!=null&&d>0?d:null,recoverable:Fo(void 0,P),summary:jo(void 0,S,T),keepalive_running:o}}function Pc(t,e){if(!Gt(t))return null;const n=xc(t.role),a=U(t.content)??U(t.preview);if(!a)return null;const s=zs(t.ts_unix)??zs(t.timestamp);return{id:`${n}-${s??"entry"}-${e}`,role:n,label:Sc(n),text:a,timestamp:s,delivery:"history"}}function Dc(t,e,n){const a=Gt(n)?n:null,s=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((o,r)=>Pc(o,r)).filter(o=>o!==null):[];return{name:t,diagnostic:da(a==null?void 0:a.diagnostic),history:s,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function Ki(t,e){const n=dt.value[t]??[];dt.value={...dt.value,[t]:[...n,e].slice(-50)}}function Ec(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Ic(t,e){const a=(dt.value[t]??[]).filter(s=>s.delivery!=="history"&&!e.some(o=>Ec(s,o)));dt.value={...dt.value,[t]:[...e,...a].slice(-50)}}function Ba(t,e){Bt.value={...Bt.value,[t]:e},Ic(t,e.history)}function Hi(t,e){const n=Bt.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Ba(t,{...n,diagnostic:{...a,...e}})}async function hi(){qe();try{await ne()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Yn(t){on.value=t.trim()}async function Ko(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Bt.value[n])return Bt.value[n];ot(Es,n,!0),ot(Wt,n,null);try{const a=await bt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let s=null;try{s=JSON.parse(a)}catch{s=null}const o=Dc(n,a,s);return Ba(n,o),o}catch(a){const s=a instanceof Error?a.message:`Failed to inspect ${n}`;return ot(Wt,n,s),null}finally{ot(Es,n,!1)}}async function Mc(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const s=`local-${Date.now()}`;Ki(n,{id:s,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),ot(Is,n,!0),ot(Wt,n,null);try{const o=await bc(n,a);dt.value={...dt.value,[n]:(dt.value[n]??[]).map(r=>r.id===s?{...r,delivery:"delivered"}:r)},Ki(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Hi(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await hi()}catch(o){const r=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw dt.value={...dt.value,[n]:(dt.value[n]??[]).map(l=>l.id===s?{...l,delivery:"error",error:r}:l)},Hi(n,{last_reply_status:"error",last_error:r}),ot(Wt,n,r),o}finally{ot(Is,n,!1)}}async function Oc(t,e){const n=t.trim();if(!n)return null;ot(Ms,n,!0),ot(Wt,n,null);try{const a=await On({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),s=Nc(a.result),o=(s==null?void 0:s.diagnostic)??null;if(o){const r=Bt.value[n];Ba(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??dt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await hi(),o}catch(a){const s=a instanceof Error?a.message:`Failed to probe ${n}`;throw ot(Wt,n,s),a}finally{ot(Ms,n,!1)}}async function zc(t,e){const n=t.trim();if(!n)return null;ot(Os,n,!0),ot(Wt,n,null);try{const a=await On({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),s=Rc(a.result),o=(s==null?void 0:s.after)??null;if(o){const r=Bt.value[n];Ba(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??dt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await hi(),o}catch(a){const s=a instanceof Error?a.message:`Failed to recover ${n}`;throw ot(Wt,n,s),a}finally{ot(Os,n,!1)}}function ce(t){return(t??"").trim().toLowerCase()}function _t(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Xn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function jn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ye(t){return t.last_heartbeat??jn(t.last_turn_ago_s)??jn(t.last_proactive_ago_s)??jn(t.last_handoff_ago_s)??jn(t.last_compaction_ago_s)}function qc(t){const e=t.title.trim();return e||Xn(t.content)}function jc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Fc(t,e,n,a,s={}){var E;const o=ce(t),r=e.filter(N=>ce(N.assignee)===o&&(N.status==="claimed"||N.status==="in_progress")).length,l=n.filter(N=>ce(N.from)===o).sort((N,R)=>_t(R.timestamp)-_t(N.timestamp))[0],p=a.filter(N=>ce(N.agent)===o||ce(N.author)===o).sort((N,R)=>_t(R.timestamp)-_t(N.timestamp))[0],$=(s.boardPosts??[]).filter(N=>ce(N.author)===o).sort((N,R)=>_t(R.updated_at||R.created_at)-_t(N.updated_at||N.created_at))[0],m=(s.keepers??[]).filter(N=>ce(N.name)===o&&Ye(N)!==null).sort((N,R)=>_t(Ye(R)??0)-_t(Ye(N)??0))[0],d=l?_t(l.timestamp):0,v=p?_t(p.timestamp):0,c=$?_t($.updated_at||$.created_at):0,y=m?_t(Ye(m)??0):0,S=s.lastSeen?_t(s.lastSeen):0,T=((E=s.currentTask)==null?void 0:E.trim())||(r>0?`${r} claimed tasks`:null);if(d===0&&v===0&&c===0&&y===0&&S===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:T};const K=[l?{timestamp:l.timestamp,ts:d,text:Xn(l.content)}:null,$?{timestamp:$.updated_at||$.created_at,ts:c,text:`Post: ${Xn(qc($))}`}:null,m?{timestamp:Ye(m),ts:y,text:jc(m)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:v,text:Xn(p.text)}:null].filter(N=>N!==null).sort((N,R)=>R.ts-N.ts)[0];return K&&K.ts>=S?{activeAssignedCount:r,lastActivityAt:K.timestamp,lastActivityText:K.text}:{activeAssignedCount:r,lastActivityAt:s.lastSeen??null,lastActivityText:T??"Presence heartbeat"}}const At=_([]),yt=_([]),Sn=_([]),Jt=_([]),se=_(null),nn=_(null),js=_(new Map),Be=_([]),An=_("hot"),ue=_(!0),Ho=_(null),Ut=_(""),wn=_([]),Re=_(!1),Uo=_(new Map),Fs=_("unknown"),Ks=_(null),Hs=_(!1),Cn=_(!1),Us=_(!1),Le=_(!1),Kc=_(null),Bs=_(null),Bo=_(null),Wo=_(null),Hc=wt(()=>At.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle")),Go=wt(()=>{const t=yt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Wa=wt(()=>{const t=new Map,e=yt.value,n=Sn.value,a=ca.value,s=Be.value,o=Jt.value;for(const r of At.value)t.set(r.name.trim().toLowerCase(),Fc(r.name,e,n,a,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:s,keepers:o}));return t});function Uc(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const s=a.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const Jo=wt(()=>{const t=new Map;for(const e of Jt.value)t.set(e.name,Uc(e));return t}),Bc=12e4;function Wc(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const s=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof s=="number"?Date.now()-s*1e3:null}const Vo=wt(()=>{const t=Date.now(),e=new Set,n=js.value;for(const a of Jt.value){const s=Wc(a,n);s!=null&&t-s>Bc&&e.add(a.name)}return e}),ua={},Gc=5e3;let Za=null;function Jc(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function qe(){delete ua.compact,delete ua.full}function ut(t){return typeof t=="object"&&t!==null}function b(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function A(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function _e(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Ws(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Qo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Vc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Yo(t){if(!ut(t))return null;const e=b(t.name);return e?{name:e,status:Qo(t.status),current_task:b(t.current_task)??null,last_seen:b(t.last_seen),emoji:b(t.emoji),koreanName:b(t.koreanName)??b(t.korean_name),model:b(t.model),traits:_e(t.traits),interests:_e(t.interests),activityLevel:A(t.activityLevel)??A(t.activity_level),primaryValue:b(t.primaryValue)??b(t.primary_value)}:null}function Xo(t){if(!ut(t))return null;const e=b(t.id),n=b(t.title);return!e||!n?null:{id:e,title:n,status:Vc(t.status),priority:A(t.priority),assignee:b(t.assignee),description:b(t.description),created_at:b(t.created_at),updated_at:b(t.updated_at)}}function Zo(t){if(!ut(t))return null;const e=b(t.from)??b(t.from_agent)??"system",n=b(t.content)??"",a=b(t.timestamp)??new Date().toISOString();return{id:b(t.id),seq:A(t.seq),from:e,content:n,timestamp:a,type:b(t.type)}}function Qc(t){return Array.isArray(t)?t.map(e=>{if(!ut(e))return null;const n=A(e.ts_unix);if(n==null)return null;const a=ut(e.handoff)?e.handoff:null;return{ts:n,context_ratio:A(e.context_ratio)??0,context_tokens:A(e.context_tokens)??0,context_max:A(e.context_max)??0,latency_ms:A(e.latency_ms)??0,generation:A(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:A(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:A(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?A(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function Ui(t){if(!ut(t))return null;const e=b(t.health_state),n=b(t.next_action_path),a=b(t.last_reply_status);if(!e||!n||!a)return null;const s=b(t.quiet_reason)??null,o=b(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":s==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":s==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":s==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:s,next_action_path:n,last_reply_status:a,last_reply_at:Ws(t.last_reply_at)??b(t.last_reply_at)??null,last_reply_preview:b(t.last_reply_preview)??null,last_error:b(t.last_error)??null,next_eligible_at_s:A(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Yc(t,e){return(Array.isArray(t)?t:ut(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!ut(a))return null;const s=ut(a.agent)?a.agent:null,o=ut(a.context)?a.context:null,r=ut(a.metrics_window)?a.metrics_window:void 0,l=b(a.name);if(!l)return null;const p=A(a.context_ratio)??A(o==null?void 0:o.context_ratio),$=b(a.status)??b(s==null?void 0:s.status)??"offline",m=Qo($),d=b(a.model)??b(a.active_model)??b(a.primary_model),v=_e(a.skill_secondary),c=o?{source:b(o.source),context_ratio:A(o.context_ratio),context_tokens:A(o.context_tokens),context_max:A(o.context_max),message_count:A(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,y=s?{name:b(s.name),exists:typeof s.exists=="boolean"?s.exists:void 0,error:b(s.error),status:b(s.status),current_task:b(s.current_task)??null,last_seen:b(s.last_seen),last_seen_ago_s:A(s.last_seen_ago_s),is_zombie:typeof s.is_zombie=="boolean"?s.is_zombie:void 0}:void 0,S=Qc(a.metrics_series),T={name:l,emoji:b(a.emoji),koreanName:b(a.koreanName)??b(a.korean_name),agent_name:b(a.agent_name),trace_id:b(a.trace_id),model:d,primary_model:b(a.primary_model),active_model:b(a.active_model),next_model_hint:b(a.next_model_hint)??null,status:m,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:A(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:A(a.proactive_idle_sec),proactive_cooldown_sec:A(a.proactive_cooldown_sec),last_heartbeat:b(a.last_heartbeat)??b(s==null?void 0:s.last_seen),generation:A(a.generation),turn_count:A(a.turn_count)??A(a.total_turns),keeper_age_s:A(a.keeper_age_s),last_turn_ago_s:A(a.last_turn_ago_s),last_handoff_ago_s:A(a.last_handoff_ago_s),last_compaction_ago_s:A(a.last_compaction_ago_s),last_proactive_ago_s:A(a.last_proactive_ago_s),context_ratio:p,context_tokens:A(a.context_tokens)??A(o==null?void 0:o.context_tokens),context_max:A(a.context_max)??A(o==null?void 0:o.context_max),context_source:b(a.context_source)??b(o==null?void 0:o.source),context:c,traits:_e(a.traits),interests:_e(a.interests),primaryValue:b(a.primaryValue)??b(a.primary_value),activityLevel:A(a.activityLevel)??A(a.activity_level),memory_recent_note:b(a.memory_recent_note)??null,conversation_tail_count:A(a.conversation_tail_count),k2k_count:A(a.k2k_count),handoff_count_total:A(a.handoff_count_total)??A(a.trace_history_count),compaction_count:A(a.compaction_count),last_compaction_saved_tokens:A(a.last_compaction_saved_tokens),diagnostic:Ui(a.diagnostic),skill_primary:b(a.skill_primary)??null,skill_secondary:v,skill_reason:b(a.skill_reason)??null,metrics_series:S.length>0?S:void 0,metrics_window:r,agent:y};return T.diagnostic=Ui(a.diagnostic)??Lc(T,(e==null?void 0:e.lodge)??null),T}).filter(a=>a!==null)}function Xc(t){return ut(t)?{...t,lodge:Tc(t.lodge)??void 0}:null}function Zc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function td(t){if(!ut(t))return null;const e=A(t.iteration);if(e==null)return null;const n=A(t.metric_before)??0,a=A(t.metric_after)??n,s=ut(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:a,delta:A(t.delta)??a-n,changes:b(t.changes)??"",failed_attempts:b(t.failed_attempts)??"",next_suggestion:b(t.next_suggestion)??"",elapsed_ms:A(t.elapsed_ms)??0,cost_usd:A(t.cost_usd)??null,evidence:s?{worker_engine:(s.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:b(s.worker_model)??"",tool_call_count:A(s.tool_call_count)??0,tool_names:_e(s.tool_names)??[],session_id:b(s.session_id)??"",evidence_status:s.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function ed(t){var o,r;if(!ut(t))return null;const e=b(t.loop_id);if(!e)return null;const n=A(t.baseline_metric)??0,a=Array.isArray(t.history)?t.history.map(td).filter(l=>l!==null):[],s=A(t.current_metric)??((o=a[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:b(t.profile)??"unknown",status:Zc(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:b(t.error_message)??b(t.error_reason)??null,stop_reason:b(t.stop_reason)??b(t.reason)??null,current_iteration:A(t.current_iteration)??((r=a[0])==null?void 0:r.iteration)??0,max_iterations:A(t.max_iterations)??0,baseline_metric:n,current_metric:s,target:b(t.target)??"",stagnation_streak:A(t.stagnation_streak)??0,stagnation_limit:A(t.stagnation_limit)??0,elapsed_seconds:A(t.elapsed_seconds)??0,updated_at:Ws(t.updated_at)??null,stopped_at:Ws(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:b(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:A(t.latest_tool_call_count)??0,latest_tool_names:_e(t.latest_tool_names)??[],session_id:b(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:a}}async function ne(t="full"){var a,s,o;const e=Date.now(),n=ua[t];if(!(n&&e-n.time<Gc)){Hs.value=!0;try{const r=await yl(t);ua[t]={data:r,time:e},At.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(Yo).filter(p=>p!==null),yt.value=(Array.isArray((s=r.tasks)==null?void 0:s.tasks)?r.tasks.tasks:[]).map(Xo).filter(p=>p!==null),Sn.value=(Array.isArray((o=r.messages)==null?void 0:o.messages)?r.messages.messages:[]).map(Zo).filter(p=>p!==null);const l=Xc(r.status);se.value=l,Jt.value=Yc(r.keepers,l),nn.value=r.perpetual??null,Kc.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{Hs.value=!1}}}async function nd(){try{const t=await bl(),e=(Array.isArray(t.agents)?t.agents:[]).map(Yo).filter(s=>s!==null),n=At.value,a=new Map(n.map(s=>[s.name,s]));At.value=e.map(s=>{const o=a.get(s.name);return o?{...o,status:s.status,current_task:s.current_task}:s})}catch(t){console.error("Agents selective fetch error:",t)}}async function ad(){try{const t=await kl({includeDone:!0,includeCancelled:!0}),e=(Array.isArray(t.tasks)?t.tasks:[]).map(Xo).filter(s=>s!==null),n=yt.value,a=new Map(n.map(s=>[s.id,s]));yt.value=e.map(s=>{const o=a.get(s.id);return o?{...o,status:s.status,priority:s.priority??o.priority,assignee:s.assignee??o.assignee}:s})}catch(t){console.error("Tasks selective fetch error:",t)}}async function sd(){try{const t=Sn.value,e=t.reduce((l,p)=>Math.max(l,p.seq??0),0),n=await xl(e),a=(Array.isArray(n.messages)?n.messages:[]).map(Zo).filter(l=>l!==null);if(a.length===0)return;const s=new Set(t.map(l=>l.seq).filter(l=>l!=null)),o=new Set(t.filter(l=>l.seq==null).map(l=>`${l.timestamp}|${l.from}`)),r=a.filter(l=>{if(l.seq!=null)return!s.has(l.seq);const p=`${l.timestamp}|${l.from}`;return o.has(p)?!1:(o.add(p),!0)});if(r.length>0){const l=[...t,...r];Sn.value=l.length>500?l.slice(-500):l}}catch(t){console.error("Messages selective fetch error:",t)}}async function qt(){Cn.value=!0;try{const t=await jl(An.value,{excludeSystem:ue.value});Be.value=t.posts??[],Bs.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Cn.value=!1}}async function jt(){var t;Us.value=!0;try{const e=Ut.value||((t=se.value)==null?void 0:t.room)||"default";Ut.value||(Ut.value=e);const n=await ac(e);Ho.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Us.value=!1}}async function Tn(){Re.value=!0;try{const t=await kc();wn.value=Array.isArray(t)?t:[],Bo.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Re.value=!1}}async function je(){Le.value=!0;try{const t=await Sl(),e=Array.isArray(t.loops)?t.loops:[],n=new Map;for(const a of e){const s=ed(a);s&&n.set(s.loop_id,s)}Uo.value=n,Wo.value=new Date().toISOString(),Ks.value=null,Fs.value=n.size===0?"idle":"ready"}catch(t){console.error("MDAL fetch error:",t),Fs.value="error",Ks.value=t instanceof Error?t.message:String(t)}finally{Le.value=!1}}let Zn=null;function id(t){Zn=t}let ta=null;function od(t){ta=t}const pe={};function de(t,e,n=500){pe[t]&&clearTimeout(pe[t]),pe[t]=setTimeout(()=>{e(),delete pe[t]},n)}function rd(){const t=Ro.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(js.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),js.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&de("agents",nd),Jc(e.type)&&(qe(),Za||(Za=setTimeout(()=>{ne(),ta==null||ta(),Za=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&de("tasks",ad),e.type==="broadcast"&&de("messages",sd),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&de("dashboard",()=>{qe(),ne()}),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&de("board",qt),e.type.startsWith("decision_")&&de("council",()=>Zn==null?void 0:Zn()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&de("mdal",je,350)}});return()=>{t();for(const e of Object.keys(pe))clearTimeout(pe[e]),delete pe[e]}}let rn=null;function ld(){rn||(rn=setInterval(()=>{Ft.value||qe(),ne()},1e4))}function cd(){rn&&(clearInterval(rn),rn=null)}function C({title:t,class:e,children:n}){return i`
    <div class="card ${e??""}">
      ${t?i`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function Lt({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function dd(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const o=Math.floor(s/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function F({timestamp:t}){const e=dd(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return i`<span class="time-ago" title=${n}>${e}</span>`}function Y(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function st(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function me(t){return(t??"").trim().toLowerCase()}function ct(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function zt(t){return typeof t!="number"||Number.isNaN(t)?3:t}function yi(t){const e=zt(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}let ud=0;const ve=_([]);function w(t,e="success",n=4e3){const a=++ud;ve.value=[...ve.value,{id:a,message:t,type:e}],setTimeout(()=>{ve.value=ve.value.filter(s=>s.id!==a)},n)}function pd(t){ve.value=ve.value.filter(e=>e.id!==t)}function md(){const t=ve.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>pd(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const vd="masc_dashboard_agent_name",We=_(null),pa=_(!1),Nn=_(""),ma=_([]),Rn=_([]),Ee=_(""),ln=_(!1);function Ie(t){We.value=t,bi()}function Bi(){We.value=null,Nn.value="",ma.value=[],Rn.value=[],Ee.value=""}function fd(){const t=We.value;return t?At.value.find(e=>e.name===t)??null:null}function tr(t){return t?yt.value.filter(e=>e.assignee===t):[]}async function bi(){const t=We.value;if(t){pa.value=!0,Nn.value="",ma.value=[],Rn.value=[];try{const e=await fc(80);ma.value=e.filter(s=>s.includes(t)).slice(0,20);const n=tr(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const o=await _c(s.id,25);return{taskId:s.id,text:o.trim()}}catch(o){const r=o instanceof Error?o.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));Rn.value=a}catch(e){Nn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{pa.value=!1}}}async function Wi(){var a;const t=We.value,e=Ee.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(vd))==null?void 0:a.trim())||"dashboard";ln.value=!0;try{await zo(n,`@${t} ${e}`),Ee.value="",w(`Mention sent to ${t}`,"success"),bi()}catch(s){const o=s instanceof Error?s.message:"Failed to send mention";w(o,"error")}finally{ln.value=!1}}function _d({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Lt} status=${t.status} />
    </div>
  `}function gd({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function $d(){var s,o,r,l;const t=We.value;if(!t)return null;const e=fd(),n=tr(t),a=ma.value;return i`
    <div
      class="agent-detail-overlay"
      onClick=${p=>{p.target.classList.contains("agent-detail-overlay")&&Bi()}}
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
                        <${Lt} status=${e.status} />
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
            ${(((s=e==null?void 0:e.traits)==null?void 0:s.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(o=e==null?void 0:e.traits)==null?void 0:o.map(p=>i`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${p}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(l=e==null?void 0:e.interests)==null?void 0:l.map(p=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${p}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?i`
                    ${e.current_task?i`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?i`<span>Last seen: <${F} timestamp=${e.last_seen} /></span>`:null}
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

        ${Nn.value?i`<div class="council-error">${Nn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${C} title="Assigned Tasks">
            ${n.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${n.map(p=>i`<${_d} key=${p.id} task=${p} />`)}</div>`}
          <//>

          <${C} title="Recent Activity">
            ${a.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${a.map((p,$)=>i`<div key=${$} class="agent-activity-line">${p}</div>`)}</div>`}
          <//>
        </div>

        <${C} title="Task History">
          ${Rn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${Rn.value.map(p=>i`<${gd} key=${p.taskId} row=${p} />`)}</div>`}
        <//>

        <${C} title="Direct Mention">
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
  `}const va=600*1e3,ea=1200*1e3;function er(t){switch(t){case"in_progress":return"In Progress";case"claimed":return"Claimed";case"done":return"Done";case"cancelled":return"Cancelled";default:return"Todo"}}function nr(t){switch(t){case"dispatchable":return"Dispatch";case"drift":return"Drift";case"quiet":return"Quiet";case"offline":return"Offline";default:return"Loaded"}}function hd(t){return t.updated_at??t.created_at??null}function Gi(t,e,n){var T,P;const a=me(t.assignee),s=a?e.get(a)??null:null,o=s?n.get(a)??null:null,r=(o==null?void 0:o.lastActivityAt)??(s==null?void 0:s.last_seen)??null,l=r?Math.max(0,Date.now()-Y(r)):Number.POSITIVE_INFINITY,p=ct(t.description),$=ct(s==null?void 0:s.current_task)??(o==null?void 0:o.lastActivityText)??null,m=t.status==="claimed"||t.status==="in_progress";let d="ok",v="Fresh owner coverage",c=$??p??t.id,y=!1,S=!1;return t.status==="todo"?t.assignee?s?s.status==="offline"||s.status==="inactive"?(y=!0,d="bad",v="Assigned owner is offline",c="Queue item is blocked until ownership changes."):l>va?(d="warn",v="Owner exists but live signal is quiet",c=$??"Owner may need a nudge before pickup."):((o==null?void 0:o.activeAssignedCount)??0)>0||(T=s.current_task)!=null&&T.trim()?(d="warn",v="Owner is already carrying active work",c=$??`${(o==null?void 0:o.activeAssignedCount)??0} active tasks already assigned.`):(v="Ready and covered by a fresh operator",c=$??p??"This can be picked up immediately."):(y=!0,d="bad",v="Assigned owner is not present in the room",c="Reassign or bring the owner back online."):(y=!0,d=zt(t.priority)<=2?"bad":"warn",v=zt(t.priority)<=2?"Urgent ready work has no owner":"Ready work has no owner",c="Assign an agent before this queue item slips."):m&&(t.assignee?s?s.status==="offline"||s.status==="inactive"?(y=!0,d="bad",v="Assigned owner is offline",c=$??"Execution has no live operator right now."):l>ea?(S=!0,d="bad",v="Assigned owner has gone quiet",c=$??"Fresh operator signal is missing."):l>va?(S=!0,d="warn",v="Execution has been quiet for too long",c=$??"Check whether this work is blocked."):(P=s.current_task)!=null&&P.trim()?(v="Execution has fresh owner coverage",c=$??p??t.id):(d="warn",v=t.status==="claimed"?"Claimed work is waiting for explicit focus":"Owner is live but current_task is empty",c=$??"Task state and agent focus are drifting apart."):(y=!0,d="bad",v="Assigned owner is not active in the room",c="Execution is orphaned until ownership is restored."):(y=!0,d="bad",v="Active work has no assignee",c="Claim or reassign this task immediately.")),{task:t,assigneeAgent:s,motion:o,tone:d,note:v,focus:c,lastSignalAt:r,lastTouchedAt:hd(t),ownerGap:y,quiet:S}}function yd(t,e){var v;const n=e.get(me(t.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},a=n.lastActivityAt??t.last_seen??null,s=a?Math.max(0,Date.now()-Y(a)):Number.POSITIVE_INFINITY,o=!!((v=t.current_task)!=null&&v.trim()),r=n.activeAssignedCount,l=o||r>0;let p="loaded",$="ok",m="Healthy active load",d=ct(t.current_task)??n.lastActivityText??"Ready for assignment";return t.status==="offline"||t.status==="inactive"?(p="offline",$="bad",m="Agent is unavailable"):l&&s>ea?(p="quiet",$="bad",m="Working without a fresh signal"):r>0&&!o?(p="drift",$="warn",m="Claimed work exists but current_task is empty",d=`${r} active tasks need explicit focus.`):o&&r===0?(p="drift",$="warn",m="current_task has no matching claimed work",d=ct(t.current_task)??"Task metadata and operator state drifted."):!l&&s<=va?(p="dispatchable",$="ok",m="Fresh signal and no active load",d=n.lastActivityText??"Ready for assignment."):l?s>va&&(p="loaded",$="warn",m="Execution load is healthy but slightly quiet",d=ct(t.current_task)??`${r} active tasks in flight.`):(p="quiet",$=s>ea?"bad":"warn",m=s>ea?"No fresh signal while idle":"Reachable, but not freshly active",d=n.lastActivityText??"Likely available after a quick check-in."),{agent:t,motion:n,tone:$,state:p,note:m,focus:d,lastSignalAt:a,activeTaskCount:r}}function Xe({label:t,value:e,color:n,caption:a}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?i`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function bd({item:t}){return i`
    <div class="execution-alert ${t.tone}">
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="task"?yi(t.taskRow.task.priority):nr(t.agentRow.state)}
        </span>
        ${t.kind==="task"?i`<span>${er(t.taskRow.task.status)}</span>`:i`<span>${t.agentRow.agent.name}</span>`}
        ${t.timestamp?i`<span><${F} timestamp=${t.timestamp} /></span>`:i`<span>No signal</span>`}
      </div>
    </div>
  `}function Ji({row:t}){var e;return i`
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
        ${t.assigneeAgent?i`<${Lt} status=${t.assigneeAgent.status} />`:i`<span class="monitor-sub">No owner</span>`}
        <span class="monitor-pill ${t.tone}">${er(t.task.status)}</span>
      </div>

      <div class="monitor-meta">
        ${t.task.assignee?i`<span>Owner ${t.task.assignee}</span>`:i`<span>Unassigned</span>`}
        ${t.lastTouchedAt?i`<span>Touched <${F} timestamp=${t.lastTouchedAt} /></span>`:null}
        ${t.lastSignalAt?i`<span>Signal <${F} timestamp=${t.lastSignalAt} /></span>`:i`<span>No live signal</span>`}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${(e=t.assigneeAgent)!=null&&e.current_task&&ct(t.assigneeAgent.current_task)!==t.focus?i`<div class="monitor-footnote">Owner focus: ${ct(t.assigneeAgent.current_task)}</div>`:null}
    </div>
  `}function kd({row:t}){const{agent:e}=t;return i`
    <button class="monitor-row ${t.tone}" onClick=${()=>Ie(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Lt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${nr(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?i`<span>Signal <${F} timestamp=${t.lastSignalAt} /></span>`:i`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
    </button>
  `}function xd(){const t=At.value,e=yt.value,n=new Map(t.map(d=>[me(d.name),d])),a=Wa.value,s=e.filter(d=>d.status==="claimed"||d.status==="in_progress").map(d=>Gi(d,n,a)).sort((d,v)=>{const c=st(v.tone)-st(d.tone);return c!==0?c:Y(v.lastSignalAt??v.lastTouchedAt)-Y(d.lastSignalAt??d.lastTouchedAt)}),o=e.filter(d=>d.status==="todo").map(d=>Gi(d,n,a)).sort((d,v)=>{const c=st(v.tone)-st(d.tone);if(c!==0)return c;const y=zt(d.task.priority)-zt(v.task.priority);return y!==0?y:Y(d.lastTouchedAt)-Y(v.lastTouchedAt)}),r=t.map(d=>yd(d,a)).filter(d=>d.state==="dispatchable"||d.state==="drift"||d.state==="quiet").sort((d,v)=>{if(d.state==="dispatchable"&&v.state!=="dispatchable")return-1;if(v.state==="dispatchable"&&d.state!=="dispatchable")return 1;const c=st(v.tone)-st(d.tone);return c!==0?c:Y(v.lastSignalAt)-Y(d.lastSignalAt)}),l=[...s.filter(d=>d.tone!=="ok").map(d=>({kind:"task",key:`active-${d.task.id}`,tone:d.tone,title:d.task.title,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt??d.lastTouchedAt,taskRow:d})),...o.filter(d=>d.tone==="bad").map(d=>({kind:"task",key:`ready-${d.task.id}`,tone:d.tone,title:d.task.title,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastTouchedAt,taskRow:d})),...r.filter(d=>d.state==="drift"||d.tone==="bad").map(d=>({kind:"agent",key:`agent-${d.agent.name}`,tone:d.tone,title:d.agent.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt,agentRow:d}))].sort((d,v)=>{const c=st(v.tone)-st(d.tone);return c!==0?c:Y(v.timestamp)-Y(d.timestamp)}).slice(0,8),p=r.filter(d=>d.state==="dispatchable"),$=[...s,...o].filter(d=>d.ownerGap),m=s.filter(d=>d.quiet);return i`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${Xe} label="Active work" value=${s.length} color="#fbbf24" caption="claimed + in progress" />
        <${Xe} label="Needs intervention" value=${l.length} color=${l.length>0?"#fb7185":"#4ade80"} caption="stalled or drifting now" />
        <${Xe} label="Ownership gaps" value=${$.length} color=${$.length>0?"#fb7185":"#4ade80"} caption="missing or unavailable owners" />
        <${Xe} label="Dispatchable agents" value=${p.length} color="#22d3ee" caption="fresh signal, no active load" />
        <${Xe} label="Quiet execution" value=${m.length} color=${m.length>0?"#fbbf24":"#4ade80"} caption="active tasks with aging signals" />
      </div>

      <${C} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs a nudge right now</h2>
          <p class="monitor-subheadline">Severity comes first, then the freshest evidence we have about the stall or drift.</p>
        </div>
        <div class="monitor-alert-list">
          ${l.length===0?i`<div class="empty-state">No active execution risks right now</div>`:l.map(d=>i`<${bd} key=${d.key} item=${d} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${C} title="Ready Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Ready work, sorted by dispatch risk</h2>
            <p class="monitor-subheadline">Ownerless or owner-unavailable items float to the top before healthy assigned queue items.</p>
          </div>
          <div class="monitor-list">
            ${o.length===0?i`<div class="empty-state">No ready tasks in the queue</div>`:o.slice(0,10).map(d=>i`<${Ji} key=${d.task.id} row=${d} />`)}
          </div>
        <//>

        <${C} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity appears first. Task-state drift stays visible so owners can clean up metadata fast.</p>
          </div>
          <div class="monitor-list">
            ${r.length===0?i`<div class="empty-state">No agent capacity or drift signals right now</div>`:r.map(d=>i`<${kd} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>
      </div>

      <${C} title="Active Execution Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Claimed and in-progress work</h2>
          <p class="monitor-subheadline">Rows are sorted by risk first, then by the freshest operator signal tied to each task.</p>
        </div>
        <div class="monitor-list">
          ${s.length===0?i`<div class="empty-state">No active execution tasks</div>`:s.map(d=>i`<${Ji} key=${d.task.id} row=${d} />`)}
        </div>
      <//>
    </div>
  `}function Sd(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Ad(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function wd(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Vi(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function ar(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Cd(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function sr(t){if(!t)return null;const e=Bt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function ir({keeper:t,showRawStatus:e=!1}){if(rt(()=>{t!=null&&t.name&&Ko(t.name)},[t==null?void 0:t.name]),!t)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Bt.value[t.name],a=sr(t),s=Es.value[t.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(a==null?void 0:a.health_state)??"unknown"}</span>
        <span class="pill">${Sd(a==null?void 0:a.quiet_reason)}</span>
        <span class="pill">next ${Ad((a==null?void 0:a.next_action_path)??"direct_message")}</span>
        ${s?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(a==null?void 0:a.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(a==null?void 0:a.last_reply_status)??"unknown"}
        ${a!=null&&a.last_reply_at?i` · ${ar(a.last_reply_at)}`:null}
        ${a!=null&&a.next_eligible_at_s?i` · next eligible ${Cd(a.next_eligible_at_s)}`:null}
      </div>
      ${a!=null&&a.last_error?i`<div class="control-status-copy control-error-copy">${a.last_error}</div>`:null}
      ${e?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function or({keeperName:t,placeholder:e}){const[n,a]=Ua("");rt(()=>{t&&Ko(t)},[t]);const s=dt.value[t]??[],o=Is.value[t]??!1,r=Wt.value[t],l=async()=>{const p=n.trim();if(!(!t||!p)){a("");try{await Mc(t,p)}catch($){const m=$ instanceof Error?$.message:`Failed to message ${t}`;w(m,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${s.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:s.map(p=>i`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Vi(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${Vi(p)}`}>${wd(p)}</span>
                  ${p.timestamp?i`<span class="keeper-conversation-time">${ar(p.timestamp)}</span>`:null}
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
        ${r?i`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function rr({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const a=sr(e),s=Ms.value[e.name]??!1,o=Os.value[e.name]??!1,r=(a==null?void 0:a.next_action_path)??"direct_message",l=(a==null?void 0:a.recoverable)??r==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{Oc(e.name,t).catch(p=>{const $=p instanceof Error?p.message:`Failed to probe ${e.name}`;w($,"error")})}}
        disabled=${s||!t.trim()}
      >
        ${s?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{zc(e.name,t).catch(p=>{const $=p instanceof Error?p.message:`Failed to recover ${e.name}`;w($,"error")})}}
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
  `}const ki=_(null);function fa(t){ki.value=t,Yn(t.name)}function Qi(){ki.value=null}const we=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Td(t){if(!t)return 0;const e=we.findIndex(n=>n.level===t);return e>=0?e:0}function Nd({keeper:t}){const e=Td(t.autonomy_level),n=we[e]??we[0];if(!n)return null;const a=(e+1)/we.length*100;return i`
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
          ${we.map((s,o)=>i`
            <span style="width:8px; height:8px; border-radius:50%; background:${o<=e?s.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${t.autonomous_action_count??0}</strong>
      </div>
      ${t.last_autonomous_action_at?i`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${F} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?i`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function na(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Rd({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",s=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${s.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
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
  `}function Ld({keeper:t}){var m,d;const e=t.metrics_series??[];if(e.length<2){const v=(((m=t.context)==null?void 0:m.context_ratio)??0)*100,c=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${c}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,o=e.length,r=e.map((v,c)=>{const y=s+c/(o-1)*(n-2*s),S=a-s-(v.context_ratio??0)*(a-2*s);return{x:y,y:S,p:v}}),l=r.map(({x:v,y:c})=>`${v.toFixed(1)},${c.toFixed(1)}`).join(" "),p=(((d=e[e.length-1])==null?void 0:d.context_ratio)??0)*100,$=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${s}" y1="${(a-s-.5*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.5*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.7*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.7*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.85*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.85*(a-2*s)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:v})=>v.is_handoff).map(({x:v})=>i`
          <line x1="${v.toFixed(1)}" y1="${s}" x2="${v.toFixed(1)}" y2="${a-s}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${$}" stroke-width="1.5"/>
        ${r.filter(({p:v})=>v.is_compaction).map(({x:v,y:c})=>i`
          <circle cx="${v.toFixed(1)}" cy="${c.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}const ts=_("");function Pd({keeper:t}){var s,o,r,l;const e=ts.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],a=e?n.filter(p=>p.title.toLowerCase().includes(e)||p.key.includes(e)||p.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${ts.value}
        onInput=${p=>{ts.value=p.target.value}}
      />
      ${a.map(p=>i`
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
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${na(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${na(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${na(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Dd({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(a=>i`
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
  `}function Ed({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Id({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function Yi({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function es(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Md({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:es(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:es(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:es(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(a=>i`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function lr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function Od(){try{const t=await On({actor:lr(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=$i(t.result);qe(),await ne(),e!=null&&e.skipped_reason?w(e.skipped_reason,"warning"):w(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";w(e,"error")}}function zd({keeper:t}){return i`
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
  `}function qd(){var e,n,a;const t=ki.value;return t?i`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&Qi()}}
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
            <${Lt} status=${t.status} />
            ${t.model?i`<span class="pill">${t.model}</span>`:null}
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
          <${C} title="Field Dictionary">
            <${Pd} keeper=${t} />
          <//>

          ${""}
          <${C} title="Profile">
            <${Yi} traits=${t.traits??[]} label="Traits" />
            <${Yi} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${F} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?i`
              <${C} title="Autonomy">
                <${Nd} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?i`
              <${C} title="TRPG Stats">
                <${Dd} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${C} title="Equipment (${t.inventory.length})">
                <${Ed} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${C} title="Relationships (${Object.keys(t.relationships).length})">
                <${Id} rels=${t.relationships} />
              <//>
            `:null}

          <${C} title="Runtime Signals">
            <${Md} keeper=${t} />
          <//>

          <${C} title="Memory & Context">
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
              ${t.memory_recent_note?i`
                  <div class="keeper-memory-note">
                    ${t.memory_recent_note}
                  </div>
                `:i`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${zd} keeper=${t} />
      </div>
    </div>
  `:null}const Fe=_(!1);function jd(){Fe.value=!0}function Xi(){Fe.value=!1}function Fd(){Fe.value=!Fe.value}const ns=600*1e3,as=1200*1e3,Zi=.8,ss=_("triage");function xe(t){const e=(t??"").toLowerCase();return e==="bad"?"bad":e==="warn"?"warn":"ok"}function Fn(t){switch(t){case"bad":return"#fb7185";case"warn":return"#fbbf24";default:return"#4ade80"}}function to(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function eo(t){if(t==null||!Number.isFinite(t))return"unknown";if(t<60)return`${Math.round(t)}s`;const e=Math.round(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Kd(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function is(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Hd(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Ud(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Bd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Wd(t){return t?t.enabled?t.quiet_active?`Quiet hours ${to(t.quiet_start)}-${to(t.quiet_end)} KST are active.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${eo(t.interval_s)}, but no tick has run yet.`:`Lodge ticks every ${eo(t.interval_s)} with planner ${t.use_planner?"on":"off"} and delegated LLM ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled.":"Lodge runtime status is unavailable in the current dashboard payload."}function no(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function Se({label:t,value:e,color:n,caption:a}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
      ${a?i`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Gd({item:t}){return i`
    <button class="monitor-alert ${t.tone}" onClick=${t.action}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.detail}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">${t.tone==="bad"?"Act now":t.tone==="warn"?"Watch":"Stable"}</span>
        ${t.timestamp?i`<span><${F} timestamp=${t.timestamp} /></span>`:null}
      </div>
    </button>
  `}function os({tone:t,title:e,subtitle:n,meta:a,focus:s,onClick:o}){return i`
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
        ${a.map(r=>i`<span>${r}</span>`)}
      </div>
      <div class="monitor-focus">${s}</div>
    </button>
  `}function ao(){var X,H,Pt,mt,vt,B,M,x,Dt,Vt,oe,re,I,Et,le,Je,Ve;const t=se.value,e=At.value,n=yt.value,a=Jt.value,s=Go.value,o=(X=t==null?void 0:t.monitoring)==null?void 0:X.board,r=(H=t==null?void 0:t.monitoring)==null?void 0:H.council,l=Ft.value,p=new Map(e.map(f=>[me(f.name),f])),$=Wa.value,m=e.map(f=>{var Ii;const L=$.get(me(f.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},j=L.lastActivityAt??f.last_seen??null,at=j?Math.max(0,Date.now()-Y(j)):Number.POSITIVE_INFINITY,z=L.activeAssignedCount,ft=!!((Ii=f.current_task)!=null&&Ii.trim()),Q=ft||z>0;let Z="ok",kt="Fresh and ready",ye=!1,be=!1;return f.status==="offline"||f.status==="inactive"?(Z=Q?"bad":"warn",kt=Q?"Load without an available owner":"Offline"):Q&&at>as?(Z="bad",kt="Execution is stale"):z>0&&!ft?(Z="warn",kt="Claimed work has no current_task",be=!0):ft&&z===0?(Z="warn",kt="current_task has no claimed work",be=!0):!Q&&at<=ns?(Z="ok",kt="Dispatchable now",ye=!0):!Q&&at>as?(Z="warn",kt="Idle but not freshly active"):Q&&at>ns&&(Z="warn",kt="Execution is getting quiet"),{agent:f,lastSignalAt:j,activeTaskCount:z,tone:Z,note:kt,focus:ct(f.current_task)??L.lastActivityText??(ye?"Ready for assignment.":"Waiting for a clearer signal."),dispatchable:ye,drift:be}}).sort((f,L)=>{const j=st(L.tone)-st(f.tone);return j!==0?j:Y(L.lastSignalAt)-Y(f.lastSignalAt)}),d=a.map(f=>{var Z;const L=Jo.value.get(f.name)??"idle",j=Vo.value.has(f.name),at=f.context_ratio??0,z=f.diagnostic??null;let ft="ok",Q="Healthy keeper";return j||f.status==="offline"||L==="handoff-imminent"||(z==null?void 0:z.health_state)==="offline"||(z==null?void 0:z.health_state)==="degraded"?(ft="bad",Q=ct(z==null?void 0:z.summary,56)??(j?"Heartbeat stale":L==="handoff-imminent"?"Handoff imminent":(z==null?void 0:z.health_state)==="degraded"?"Keeper degraded":"Keeper offline")):((z==null?void 0:z.health_state)==="stale"||at>=Zi||L==="preparing"||L==="compacting")&&(ft="warn",Q=ct(z==null?void 0:z.summary,56)??(at>=Zi?"High context pressure":`Lifecycle ${L}`)),{keeper:f,tone:ft,note:Q,focus:ct(z==null?void 0:z.summary,120)??ct((Z=f.agent)==null?void 0:Z.current_task)??f.skill_primary??f.last_proactive_reason??f.memory_recent_note??"No active focus",timestamp:f.last_heartbeat??null}}).sort((f,L)=>{const j=st(L.tone)-st(f.tone);return j!==0?j:Y(L.timestamp)-Y(f.timestamp)}),v=n.filter(f=>f.status==="todo"||f.status==="claimed"||f.status==="in_progress").map(f=>{var ye,be;const L=f.assignee?p.get(me(f.assignee))??null:null,j=L?$.get(me(L.name))??null:null,at=(j==null?void 0:j.lastActivityAt)??(L==null?void 0:L.last_seen)??null,z=at?Math.max(0,Date.now()-Y(at)):Number.POSITIVE_INFINITY,ft=f.status==="claimed"||f.status==="in_progress";let Q="ok",Z="Covered",kt=!1;return f.assignee?!L||L.status==="offline"||L.status==="inactive"?(Q="bad",Z="Assigned owner is unavailable",kt=!0):ft&&z>as?(Q="bad",Z="Execution has lost a fresh signal"):ft&&z>ns?(Q="warn",Z="Execution is drifting quiet"):f.status==="todo"&&zt(f.priority)<=2&&!((ye=L.current_task)!=null&&ye.trim())&&((j==null?void 0:j.activeAssignedCount)??0)===0?(Q="ok",Z="Ready for dispatch"):ft&&!((be=L.current_task)!=null&&be.trim())&&(Q="warn",Z="Owner focus is not explicit"):(Q=zt(f.priority)<=2?"bad":"warn",Z=ft?"Active work has no owner":"Ready work has no owner",kt=!0),{task:f,owner:L,lastSignalAt:at,tone:Q,note:Z,focus:ct(L==null?void 0:L.current_task)??(j==null?void 0:j.lastActivityText)??ct(f.description)??"Needs operator attention.",ownerGap:kt}}).sort((f,L)=>{const j=st(L.tone)-st(f.tone);if(j!==0)return j;const at=zt(f.task.priority)-zt(L.task.priority);return at!==0?at:Y(L.lastSignalAt??L.task.updated_at??L.task.created_at)-Y(f.lastSignalAt??f.task.updated_at??f.task.created_at)}),c=v.filter(f=>f.task.status==="todo"&&zt(f.task.priority)<=2),y=v.filter(f=>f.ownerGap).length,S=m.filter(f=>f.dispatchable),T=m.filter(f=>f.drift||f.tone!=="ok"),P=d.filter(f=>f.tone!=="ok"),K=t!=null&&t.paused?"bad":((Pt=t==null?void 0:t.data_quality)==null?void 0:Pt.board_contract_ok)===!1||((mt=t==null?void 0:t.data_quality)==null?void 0:mt.council_feed_ok)===!1?"warn":l?"ok":"warn",E=[];t!=null&&t.paused&&E.push({key:"paused",tone:"bad",title:"Room is paused",detail:t.tempo?`Tempo is ${t.tempo}. Resume from Ops when ready.`:"Resume from Ops when ready.",timestamp:((vt=t.data_quality)==null?void 0:vt.last_sync_at)??null,action:()=>Rt("ops")}),l||E.push({key:"live-connection",tone:"warn",title:"Live feed is reconnecting",detail:"Dashboard telemetry is stale until the SSE stream recovers.",timestamp:null,action:jd}),xe(o==null?void 0:o.alert_level)!=="ok"&&E.push({key:"board-monitor",tone:xe(o==null?void 0:o.alert_level),title:"Board feed needs attention",detail:`Freshness ${is(o==null?void 0:o.last_activity_age_s)} · ${(o==null?void 0:o.unanswered_posts)??0} unanswered posts.`,timestamp:null,action:()=>Rt("board")}),xe(r==null?void 0:r.alert_level)!=="ok"&&E.push({key:"council-monitor",tone:xe(r==null?void 0:r.alert_level),title:"Council quorum risk is elevated",detail:`${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum · freshness ${is(r==null?void 0:r.last_activity_age_s)}.`,timestamp:null,action:()=>Rt("board")}),(((B=t==null?void 0:t.data_quality)==null?void 0:B.board_contract_ok)===!1||((M=t==null?void 0:t.data_quality)==null?void 0:M.council_feed_ok)===!1)&&E.push({key:"data-quality",tone:"warn",title:"Dashboard data quality is degraded",detail:`${((x=t.data_quality)==null?void 0:x.board_contract_ok)===!1?"Board contract":"Board contract ok"} · ${((Dt=t.data_quality)==null?void 0:Dt.council_feed_ok)===!1?"Council feed degraded":"Council feed ok"}.`,timestamp:((Vt=t.data_quality)==null?void 0:Vt.last_sync_at)??null,action:()=>Rt("ops")});const N=[...E,...v.filter(f=>f.tone!=="ok").slice(0,3).map(f=>({key:`task-${f.task.id}`,tone:f.tone,title:f.task.title,detail:`${f.note} · ${f.focus}`,timestamp:f.lastSignalAt??f.task.updated_at??f.task.created_at??null,action:()=>Rt("overview")})),...P.slice(0,2).map(f=>({key:`keeper-${f.keeper.name}`,tone:f.tone,title:f.keeper.name,detail:`${f.note} · ${f.focus}`,timestamp:f.timestamp,action:()=>fa(f.keeper)})),...T.slice(0,2).map(f=>({key:`agent-${f.agent.name}`,tone:f.tone,title:f.agent.name,detail:`${f.note} · ${f.focus}`,timestamp:f.lastSignalAt,action:()=>Ie(f.agent.name)}))].sort((f,L)=>{const j=st(L.tone)-st(f.tone);return j!==0?j:Y(L.timestamp)-Y(f.timestamp)}).slice(0,8),R=ss.value;return i`
    <div class="overview-sub-tabs">
      <button
        class="sub-tab-btn ${R==="triage"?"active":""}"
        onClick=${()=>{ss.value="triage"}}
      >Triage</button>
      <button
        class="sub-tab-btn ${R==="dispatch"?"active":""}"
        onClick=${()=>{ss.value="dispatch"}}
      >Dispatch</button>
    </div>

    ${R==="dispatch"?i`<${xd} />`:i`<div class="stats-grid">
      <${Se}
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
        value=${s.inProgress.length}
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

    <${C} title="Room Health" class="section">
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
          <div class="stat-value" style=${`color:${Fn(K)}`}>${t!=null&&t.paused?"Paused":"Stable"}</div>
          <div class="monitor-stat-caption">Uptime ${Kd((t==null?void 0:t.uptime_seconds)??0)}</div>
        </div>
      </div>
      <div class="overview-note-stack">
        <div class="overview-inline-note">
          ${(oe=t==null?void 0:t.data_quality)!=null&&oe.last_sync_at?i`Last sync <${F} timestamp=${t.data_quality.last_sync_at} />`:i`No sync metadata yet`}
        </div>
        <div class="overview-inline-note">
          ${t!=null&&t.tempo?`Tempo ${t.tempo}`:"Tempo unavailable"}${(t==null?void 0:t.tempo_interval_s)!=null?` · ${t.tempo_interval_s}s interval`:""}
        </div>
        <div class="overview-inline-note">${Wd(t==null?void 0:t.lodge)}</div>
        ${(re=t==null?void 0:t.lodge)!=null&&re.last_skip_reason?i`<div class="overview-inline-note">Last Lodge skip: ${t.lodge.last_skip_reason}</div>`:null}
      </div>
    <//>

    <div class="overview-workbench">
      <div class="overview-column">
        <${C} title="Intervention Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">What needs intervention right now</h2>
            <p class="monitor-subheadline">Room-level risks, stalled work, and keeper/agent drift are sorted into one operator-facing queue.</p>
          </div>
          <div class="monitor-alert-list">
            ${N.length===0?i`<div class="empty-state">No immediate intervention required</div>`:N.map(f=>i`<${Gd} key=${f.key} item=${f} />`)}
          </div>
        <//>
      </div>

      <div class="overview-column">
        <${C} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity stays visible here so dispatch does not require opening the full Agents tab.</p>
          </div>
          <div class="monitor-list">
            ${S.length===0?i`<div class="empty-state">No fully dispatchable agents right now</div>`:S.slice(0,5).map(f=>i`
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
            ${T.length===0?i`<div class="empty-state">No agent drift or stale load right now</div>`:T.slice(0,4).map(f=>i`
                  <button class="monitor-row ${f.tone}" onClick=${()=>Ie(f.agent.name)}>
                    <div class="monitor-row-header">
                      <div class="monitor-row-title">
                        <div class="monitor-name-line">
                          <span class="monitor-title">${f.agent.name}</span>
                          ${f.agent.koreanName?i`<span class="monitor-sub">${f.agent.koreanName}</span>`:null}
                        </div>
                        <div class="monitor-note">${f.note}</div>
                      </div>
                      <${Lt} status=${f.agent.status} />
                      <span class="monitor-pill ${f.tone}">${f.dispatchable?"Ready":f.drift?"Drift":"Watch"}</span>
                    </div>
                    <div class="monitor-meta">
                      ${f.lastSignalAt?i`<span>Signal <${F} timestamp=${f.lastSignalAt} /></span>`:i`<span>No recent signal</span>`}
                      <span>${f.activeTaskCount>0?`${f.activeTaskCount} active tasks`:"No active tasks"}</span>
                      ${f.agent.model?i`<span>${f.agent.model}</span>`:null}
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
            ${P.length===0?i`<div class="empty-state">No keeper pressure signals right now</div>`:P.slice(0,4).map(f=>{var L;return i`
                  <${os}
                    key=${f.keeper.name}
                    tone=${f.tone}
                    title=${f.keeper.name}
                    subtitle=${(L=f.keeper.diagnostic)!=null&&L.health_state?`${f.note} · ${f.keeper.diagnostic.health_state}`:f.note}
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
              Lodge ${(I=t==null?void 0:t.lodge)!=null&&I.enabled?"enabled":"disabled"} · Last tick ${((Et=t==null?void 0:t.lodge)==null?void 0:Et.last_tick_ago)??"never"} · Self heartbeats ${((Je=(le=t==null?void 0:t.lodge)==null?void 0:le.active_self_heartbeats)==null?void 0:Je.length)??0}${(Ve=t==null?void 0:t.lodge)!=null&&Ve.last_skip_reason?` · Skip ${t.lodge.last_skip_reason}`:""}
            </div>
            <div class="overview-inline-note">
              ${a.length>0?`Hot keepers: ${P.length} · Highest context ${Hd(Math.max(...a.map(f=>f.context_tokens??0)))}`:"No keepers registered"}
            </div>
          </div>
        <//>
      </div>
    </div>

    <${C} title="Execution Pulse" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Priority work and ownership drift</h2>
          <p class="monitor-subheadline">Urgent ready tasks and active execution issues stay visible without duplicating the full Execution surface.</p>
        </div>
        <div class="monitor-list">
          ${v.length===0?i`<div class="empty-state">No active or ready tasks</div>`:v.slice(0,6).map(f=>i`
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
    <//>`}
  `}const Jd="modulepreload",Vd=function(t){return"/dashboard/"+t},so={},Qd=function(e,n,a){let s=Promise.resolve();if(n&&n.length>0){let r=function($){return Promise.all($.map(m=>Promise.resolve(m).then(d=>({status:"fulfilled",value:d}),d=>({status:"rejected",reason:d}))))};document.getElementsByTagName("link");const l=document.querySelector("meta[property=csp-nonce]"),p=(l==null?void 0:l.nonce)||(l==null?void 0:l.getAttribute("nonce"));s=r(n.map($=>{if($=Vd($),$ in so)return;so[$]=!0;const m=$.endsWith(".css"),d=m?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${$}"]${d}`))return;const v=document.createElement("link");if(v.rel=m?"stylesheet":Jd,m||(v.as="script"),v.crossOrigin="",v.href=$,p&&v.setAttribute("nonce",p),document.head.appendChild(v),m)return new Promise((c,y)=>{v.addEventListener("load",c),v.addEventListener("error",()=>y(new Error(`Unable to preload CSS for ${$}`)))})}))}function o(r){const l=new Event("vite:preloadError",{cancelable:!0});if(l.payload=r,window.dispatchEvent(l),!l.defaultPrevented)throw r}return s.then(r=>{for(const l of r||[])l.status==="rejected"&&o(l.reason);return e().catch(o)})},cr=_(null),Ht=_(null),_a=_(!1),ga=_(!1),$a=_(null),ha=_(null),Gs=_(null),ya=_(null),Ke=_("summary"),zn=_(null),Js=_(!1),ba=_(null),dr=_(null),Vs=_(!1),ka=_(null),xi=_(null),Qs=_(!1),xa=_(null),Ln=_(null),Sa=_(!1),Pn=_(null),cn=_(null);let an=null;function k(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function u(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function g(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function V(t){return typeof t=="boolean"?t:void 0}function pt(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Yd(){if(typeof window>"u")return;const e=new URLSearchParams(window.location.search).get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Xd(t){if(k(t))return{policy_class:u(t.policy_class),approval_class:u(t.approval_class),tool_allowlist:pt(t.tool_allowlist),model_allowlist:pt(t.model_allowlist),requires_human_for:pt(t.requires_human_for),autonomy_level:u(t.autonomy_level),escalation_timeout_sec:g(t.escalation_timeout_sec),kill_switch:V(t.kill_switch),frozen:V(t.frozen)}}function Zd(t){if(k(t))return{headcount_cap:g(t.headcount_cap),active_operation_cap:g(t.active_operation_cap),max_cost_usd:g(t.max_cost_usd),max_tokens:g(t.max_tokens)}}function Si(t){if(!k(t))return null;const e=u(t.unit_id),n=u(t.label),a=u(t.kind);return!e||!n||!a?null:{unit_id:e,label:n,kind:a,parent_unit_id:u(t.parent_unit_id)??null,leader_id:u(t.leader_id)??null,roster:pt(t.roster),capability_profile:pt(t.capability_profile),source:u(t.source),created_at:u(t.created_at),updated_at:u(t.updated_at),policy:Xd(t.policy),budget:Zd(t.budget)}}function ur(t){if(!k(t))return null;const e=Si(t.unit);return e?{unit:e,leader_status:u(t.leader_status),roster_total:g(t.roster_total),roster_live:g(t.roster_live),active_operation_count:g(t.active_operation_count),health:u(t.health),reasons:pt(t.reasons),children:Array.isArray(t.children)?t.children.map(ur).filter(n=>n!==null):[]}:null}function tu(t){if(k(t))return{total_units:g(t.total_units),company_count:g(t.company_count),platoon_count:g(t.platoon_count),squad_count:g(t.squad_count),leaf_agent_unit_count:g(t.leaf_agent_unit_count),live_agent_count:g(t.live_agent_count),managed_unit_count:g(t.managed_unit_count),active_operation_count:g(t.active_operation_count)}}function pr(t){const e=k(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),source:u(e.source),summary:tu(e.summary),units:Array.isArray(e.units)?e.units.map(ur).filter(n=>n!==null):[]}}function eu(t){if(!k(t))return null;const e=u(t.kind),n=u(t.status);return!e||!n?null:{kind:e,chain_id:u(t.chain_id)??null,goal:u(t.goal)??null,run_id:u(t.run_id)??null,status:n,viewer_path:u(t.viewer_path)??null,last_sync_at:u(t.last_sync_at)??null}}function Ga(t){if(!k(t))return null;const e=u(t.operation_id),n=u(t.objective),a=u(t.assigned_unit_id),s=u(t.trace_id),o=u(t.status);return!e||!n||!a||!s||!o?null:{operation_id:e,objective:n,assigned_unit_id:a,autonomy_level:u(t.autonomy_level),policy_class:u(t.policy_class),budget_class:u(t.budget_class),detachment_session_id:u(t.detachment_session_id)??null,trace_id:s,checkpoint_ref:u(t.checkpoint_ref)??null,active_goal_ids:pt(t.active_goal_ids),note:u(t.note)??null,created_by:u(t.created_by),source:u(t.source),status:o,chain:eu(t.chain),created_at:u(t.created_at),updated_at:u(t.updated_at)}}function nu(t){if(!k(t))return null;const e=Ga(t.operation);return e?{operation:e,assigned_unit_label:u(t.assigned_unit_label)}:null}function Ze(t){if(k(t))return{tone:u(t.tone),pending_ops:g(t.pending_ops),blocked_ops:g(t.blocked_ops),in_flight_ops:g(t.in_flight_ops),pipeline_stalls:g(t.pipeline_stalls),bus_traffic:g(t.bus_traffic),l1_hit_rate:g(t.l1_hit_rate),invalidation_count:g(t.invalidation_count),current_pending:g(t.current_pending),current_in_flight:g(t.current_in_flight),cdb_wakeups:g(t.cdb_wakeups),total_stolen:g(t.total_stolen),avg_best_score:g(t.avg_best_score),avg_candidate_count:g(t.avg_candidate_count),best_first_operations:g(t.best_first_operations),active_sessions:g(t.active_sessions),commit_rate:g(t.commit_rate),total_speculations:g(t.total_speculations)}}function au(t){if(!k(t))return;const e=k(t.pipeline)?t.pipeline:void 0,n=k(t.cache)?t.cache:void 0,a=k(t.ooo)?t.ooo:void 0,s=k(t.speculative)?t.speculative:void 0,o=k(t.search_fabric)?t.search_fabric:void 0,r=k(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:g(e.total_ops),completed_ops:g(e.completed_ops),stalled_cycles:g(e.stalled_cycles),hazards_detected:g(e.hazards_detected),forwarding_used:g(e.forwarding_used),pipeline_flushes:g(e.pipeline_flushes),ipc:g(e.ipc)}:void 0,cache:n?{total_reads:g(n.total_reads),total_writes:g(n.total_writes),l1_hit_rate:g(n.l1_hit_rate),invalidation_count:g(n.invalidation_count),writeback_count:g(n.writeback_count),bus_traffic:g(n.bus_traffic)}:void 0,ooo:a?{agent_count:g(a.agent_count),total_added:g(a.total_added),total_issued:g(a.total_issued),total_completed:g(a.total_completed),total_stolen:g(a.total_stolen),cdb_wakeups:g(a.cdb_wakeups),stall_cycles:g(a.stall_cycles),global_cdb_events:g(a.global_cdb_events),current_pending:g(a.current_pending),current_in_flight:g(a.current_in_flight)}:void 0,speculative:s?{total_speculations:g(s.total_speculations),total_commits:g(s.total_commits),total_aborts:g(s.total_aborts),commit_rate:g(s.commit_rate),total_fast_calls:g(s.total_fast_calls),total_cost_usd:g(s.total_cost_usd),active_sessions:g(s.active_sessions)}:void 0,search_fabric:o?{total_operations:g(o.total_operations),best_first_operations:g(o.best_first_operations),legacy_operations:g(o.legacy_operations),blocked_operations:g(o.blocked_operations),ready_operations:g(o.ready_operations),research_pipeline_operations:g(o.research_pipeline_operations),avg_candidate_count:g(o.avg_candidate_count),avg_best_score:g(o.avg_best_score),top_stage:u(o.top_stage)??null}:void 0,signals:r?{issue_pressure:Ze(r.issue_pressure),cache_contention:Ze(r.cache_contention),scheduler_efficiency:Ze(r.scheduler_efficiency),routing_confidence:Ze(r.routing_confidence),speculative_posture:Ze(r.speculative_posture)}:void 0}}function mr(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:g(n.total),active:g(n.active),paused:g(n.paused),managed:g(n.managed),projected:g(n.projected)}:void 0,microarch:au(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(nu).filter(a=>a!==null):[]}}function vr(t){if(!k(t))return null;const e=u(t.detachment_id),n=u(t.operation_id),a=u(t.assigned_unit_id);return!e||!n||!a?null:{detachment_id:e,operation_id:n,assigned_unit_id:a,leader_id:u(t.leader_id)??null,roster:pt(t.roster),session_id:u(t.session_id)??null,checkpoint_ref:u(t.checkpoint_ref)??null,runtime_kind:u(t.runtime_kind)??null,runtime_ref:u(t.runtime_ref)??null,source:u(t.source),status:u(t.status),last_event_at:u(t.last_event_at)??null,last_progress_at:u(t.last_progress_at)??null,heartbeat_deadline:u(t.heartbeat_deadline)??null,created_at:u(t.created_at),updated_at:u(t.updated_at)}}function su(t){if(!k(t))return null;const e=vr(t.detachment);return e?{detachment:e,assigned_unit_label:u(t.assigned_unit_label),operation:Ga(t.operation)}:null}function fr(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:g(n.total),active:g(n.active),projected:g(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(su).filter(a=>a!==null):[]}}function iu(t){if(!k(t))return null;const e=u(t.decision_id),n=u(t.trace_id),a=u(t.requested_action),s=u(t.scope_type),o=u(t.scope_id);return!e||!n||!a||!s||!o?null:{decision_id:e,trace_id:n,requested_action:a,scope_type:s,scope_id:o,operation_id:u(t.operation_id)??null,target_unit_id:u(t.target_unit_id)??null,requested_by:u(t.requested_by),status:u(t.status),reason:u(t.reason)??null,source:u(t.source),detail:t.detail,created_at:u(t.created_at),decided_at:u(t.decided_at)??null,expires_at:u(t.expires_at)??null}}function _r(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:g(n.total),pending:g(n.pending),approved:g(n.approved),denied:g(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(iu).filter(a=>a!==null):[]}}function ou(t){if(!k(t))return null;const e=Si(t.unit);return e?{unit:e,roster_total:g(t.roster_total),roster_live:g(t.roster_live),headcount_cap:g(t.headcount_cap),active_operations:g(t.active_operations),active_operation_cap:g(t.active_operation_cap),utilization:g(t.utilization)}:null}function ru(t){const e=k(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(ou).filter(n=>n!==null):[]}}function lu(t){if(!k(t))return null;const e=u(t.alert_id);return e?{alert_id:e,severity:u(t.severity),kind:u(t.kind),scope_type:u(t.scope_type),scope_id:u(t.scope_id),title:u(t.title),detail:u(t.detail),timestamp:u(t.timestamp)}:null}function gr(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:g(n.total),bad:g(n.bad),warn:g(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(lu).filter(a=>a!==null):[]}}function $r(t){if(!k(t))return null;const e=u(t.event_id),n=u(t.trace_id),a=u(t.event_type);return!e||!n||!a?null:{event_id:e,trace_id:n,event_type:a,operation_id:u(t.operation_id)??null,unit_id:u(t.unit_id)??null,actor:u(t.actor)??null,source:u(t.source),timestamp:u(t.timestamp),detail:t.detail}}function cu(t){const e=k(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),events:Array.isArray(e.events)?e.events.map($r).filter(n=>n!==null):[]}}function du(t){if(!k(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a}}function uu(t){if(!k(t))return null;const e=u(t.lane_id),n=u(t.label),a=u(t.kind),s=u(t.phase),o=u(t.motion_state),r=u(t.source_of_truth),l=u(t.movement_reason),p=u(t.current_step);if(!e||!n||!a||!s||!o||!r||!l||!p)return null;const $=k(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:a,present:V(t.present)??!1,phase:s,motion_state:o,source_of_truth:r,last_movement_at:u(t.last_movement_at)??null,movement_reason:l,current_step:p,blockers:pt(t.blockers),counts:{operations:g($.operations),detachments:g($.detachments),workers:g($.workers),approvals:g($.approvals),alerts:g($.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(du).filter(m=>m!==null):[]}}function pu(t){if(!k(t))return null;const e=u(t.event_id),n=u(t.lane_id),a=u(t.kind),s=u(t.timestamp),o=u(t.title),r=u(t.detail),l=u(t.tone),p=u(t.source);return!e||!n||!a||!s||!o||!r||!l||!p?null:{event_id:e,lane_id:n,kind:a,timestamp:s,title:o,detail:r,tone:l,source:p}}function mu(t){if(!k(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a,lane_ids:pt(t.lane_ids),count:g(t.count)??0}}function hr(t){if(!k(t))return;const e=k(t.overview)?t.overview:{},n=k(t.gaps)?t.gaps:{},a=k(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:u(t.generated_at),overview:{active_lanes:g(e.active_lanes),moving_lanes:g(e.moving_lanes),stalled_lanes:g(e.stalled_lanes),projected_lanes:g(e.projected_lanes),last_movement_at:u(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(uu).filter(s=>s!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(pu).filter(s=>s!==null):[],gaps:{count:g(n.count),items:Array.isArray(n.items)?n.items.map(mu).filter(s=>s!==null):[]},recommended_next_action:a?{tool:u(a.tool)??"masc_operator_snapshot",label:u(a.label)??"Observe operator state",reason:u(a.reason)??"",lane_id:u(a.lane_id)??null}:void 0}}function vu(t){if(!k(t))return;const e=k(t.workers)?t.workers:{},n=V(t.pass);return{status:u(t.status)??"missing",source:u(t.source)??"none",run_id:u(t.run_id)??null,captured_at:u(t.captured_at)??null,...n!==void 0?{pass:n}:{},...g(t.peak_hot_slots)!=null?{peak_hot_slots:g(t.peak_hot_slots)}:{},...g(t.ctx_per_slot)!=null?{ctx_per_slot:g(t.ctx_per_slot)}:{},workers:{expected:g(e.expected),joined:g(e.joined),current_task_bound:g(e.current_task_bound),fresh_heartbeats:g(e.fresh_heartbeats),done:g(e.done),final:g(e.final)},artifact_ref:u(t.artifact_ref)??null,missing_reason:u(t.missing_reason)??null}}function fu(t){const e=k(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),topology:pr(e.topology),operations:mr(e.operations),detachments:fr(e.detachments),alerts:gr(e.alerts),decisions:_r(e.decisions),capacity:ru(e.capacity),traces:cu(e.traces),swarm_status:hr(e.swarm_status)}}function _u(t){const e=k(t)?t:{},n=pr(e.topology),a=mr(e.operations),s=fr(e.detachments),o=gr(e.alerts),r=_r(e.decisions);return{version:u(e.version),generated_at:u(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:a.version,generated_at:a.generated_at,summary:a.summary,microarch:a.microarch},detachments:{version:s.version,generated_at:s.generated_at,summary:s.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:hr(e.swarm_status),swarm_proof:vu(e.swarm_proof)}}function gu(t){return k(t)?{chain_id:u(t.chain_id)??null,started_at:g(t.started_at)??null,progress:g(t.progress)??null,elapsed_sec:g(t.elapsed_sec)??null}:null}function yr(t){if(!k(t))return null;const e=u(t.event);return e?{event:e,chain_id:u(t.chain_id)??null,timestamp:u(t.timestamp)??null,duration_ms:g(t.duration_ms)??null,message:u(t.message)??null,tokens:g(t.tokens)??null}:null}function $u(t){if(!k(t))return null;const e=Ga(t.operation);return e?{operation:e,runtime:gu(t.runtime),history:yr(t.history),mermaid:u(t.mermaid)??null,preview_run:br(t.preview_run)}:null}function hu(t){const e=k(t)?t:{};return{status:u(e.status)??"disconnected",base_url:u(e.base_url)??null,message:u(e.message)??null}}function yu(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),connection:hu(e.connection),summary:n?{linked_operations:g(n.linked_operations),active_chains:g(n.active_chains),running_operations:g(n.running_operations),recent_failures:g(n.recent_failures),last_history_event_at:u(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map($u).filter(a=>a!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(yr).filter(a=>a!==null):[]}}function bu(t){if(!k(t))return null;const e=u(t.id);return e?{id:e,type:u(t.type),status:u(t.status),duration_ms:g(t.duration_ms)??null,error:u(t.error)??null}:null}function br(t){if(!k(t))return null;const e=u(t.run_id),n=u(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:g(t.duration_ms),success:V(t.success),mermaid:u(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(bu).filter(a=>a!==null):[]}:null}function ku(t){const e=k(t)?t:{};return{run:br(e.run)}}function xu(t){if(!k(t))return null;const e=u(t.title),n=u(t.path);return!e||!n?null:{title:e,path:n}}function Su(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.summary);return!e||!n||!a?null:{id:e,title:n,summary:a}}function Au(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.tool),s=u(t.summary);return!e||!n||!a||!s?null:{id:e,title:n,tool:a,summary:s,success_signals:pt(t.success_signals),pitfalls:pt(t.pitfalls)}}function wu(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.summary),s=u(t.when_to_use);return!e||!n||!a||!s?null:{id:e,title:n,summary:a,when_to_use:s,steps:Array.isArray(t.steps)?t.steps.map(Au).filter(o=>o!==null):[]}}function Cu(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.description);return!e||!n||!a?null:{id:e,title:n,description:a,tools:pt(t.tools)}}function Tu(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.symptom),s=u(t.why),o=u(t.fix_tool),r=u(t.fix_summary);return!e||!n||!a||!s||!o||!r?null:{id:e,title:n,symptom:a,why:s,fix_tool:o,fix_summary:r}}function Nu(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.path_id),s=u(t.transport);return!e||!n||!a||!s?null:{id:e,title:n,path_id:a,transport:s,request:t.request,response:t.response,notes:pt(t.notes)}}function Ru(t){const e=k(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(xu).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(Su).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(wu).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Cu).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Tu).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Nu).filter(n=>n!==null):[]}}function Lu(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.status),s=u(t.detail),o=u(t.next_tool);return!e||!n||!a||!s||!o?null:{id:e,title:n,status:a,detail:s,next_tool:o}}function Pu(t){if(!k(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.title),s=u(t.detail),o=u(t.next_tool);return!e||!n||!a||!s||!o?null:{code:e,severity:n,title:a,detail:s,next_tool:o}}function Du(t){if(!k(t))return null;const e=u(t.from),n=u(t.content),a=u(t.timestamp),s=g(t.seq);return!e||!n||!a||s==null?null:{seq:s,from:e,content:n,timestamp:a}}function Eu(t){if(!k(t))return null;const e=u(t.name),n=u(t.role),a=u(t.lane),s=u(t.status),o=u(t.claim_marker),r=u(t.done_marker),l=u(t.final_marker);if(!e||!n||!a||!s||!o||!r||!l)return null;const p=(()=>{if(!k(t.last_message))return null;const $=g(t.last_message.seq),m=u(t.last_message.content),d=u(t.last_message.timestamp);return $==null||!m||!d?null:{seq:$,content:m,timestamp:d}})();return{name:e,role:n,lane:a,joined:V(t.joined)??!1,live_presence:V(t.live_presence)??!1,completed:V(t.completed)??!1,status:s,current_task:u(t.current_task)??null,bound_task_id:u(t.bound_task_id)??null,bound_task_title:u(t.bound_task_title)??null,bound_task_status:u(t.bound_task_status)??null,current_task_matches_run:V(t.current_task_matches_run)??!1,squad_member:V(t.squad_member)??!1,detachment_member:V(t.detachment_member)??!1,last_seen:u(t.last_seen)??null,heartbeat_age_sec:g(t.heartbeat_age_sec)??null,heartbeat_fresh:V(t.heartbeat_fresh)??!1,claim_marker_seen:V(t.claim_marker_seen)??!1,done_marker_seen:V(t.done_marker_seen)??!1,final_marker_seen:V(t.final_marker_seen)??!1,claim_marker:o,done_marker:r,final_marker:l,last_message:p}}function Iu(t){if(!k(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!k(n))return null;const a=u(n.timestamp),s=g(n.active_slots);if(!a||s==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:a,active_slots:s,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:u(t.slot_url)??null,provider_base_url:u(t.provider_base_url)??null,provider_reachable:V(t.provider_reachable)??null,provider_status_code:g(t.provider_status_code)??null,provider_model_id:u(t.provider_model_id)??null,actual_model_id:u(t.actual_model_id)??null,expected_slots:g(t.expected_slots),actual_slots:g(t.actual_slots),expected_ctx:g(t.expected_ctx),actual_ctx:g(t.actual_ctx),slot_reachable:V(t.slot_reachable)??null,slot_status_code:g(t.slot_status_code)??null,runtime_blocker:u(t.runtime_blocker)??null,detail:u(t.detail)??null,checked_at:u(t.checked_at)??null,total_slots:g(t.total_slots),ctx_per_slot:g(t.ctx_per_slot),active_slots_now:g(t.active_slots_now),peak_active_slots:g(t.peak_active_slots),sample_count:g(t.sample_count),last_sample_at:u(t.last_sample_at)??null,timeline:e}}function Mu(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),run_id:u(e.run_id),room_id:u(e.room_id),operation_id:u(e.operation_id)??null,recommended_next_tool:u(e.recommended_next_tool),summary:n?{expected_workers:g(n.expected_workers),joined_workers:g(n.joined_workers),live_workers:g(n.live_workers),squad_roster_size:g(n.squad_roster_size),detachment_roster_size:g(n.detachment_roster_size),current_task_bound:g(n.current_task_bound),fresh_heartbeats:g(n.fresh_heartbeats),claim_markers_seen:g(n.claim_markers_seen),done_markers_seen:g(n.done_markers_seen),final_markers_seen:g(n.final_markers_seen),completed_workers:g(n.completed_workers),peak_hot_slots:g(n.peak_hot_slots),hot_window_ok:V(n.hot_window_ok),pass_hot_concurrency:V(n.pass_hot_concurrency),pass_end_to_end:V(n.pass_end_to_end),pending_decisions:g(n.pending_decisions),pass:V(n.pass)}:void 0,provider:Iu(e.provider),operation:Ga(e.operation),squad:Si(e.squad),detachment:vr(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Eu).filter(a=>a!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Lu).filter(a=>a!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Pu).filter(a=>a!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Du).filter(a=>a!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map($r).filter(a=>a!==null):[],truth_notes:pt(e.truth_notes)}}function Ai(t){Ke.value=t,t!=="summary"&&Ou()}async function wi(){_a.value=!0,$a.value=null;try{const t=await Cl();cr.value=_u(t)}catch(t){$a.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{_a.value=!1}}function Ci(t){cn.value=t}async function Ti(){ga.value=!0,ha.value=null;try{const t=await wl();Ht.value=fu(t)}catch(t){ha.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{ga.value=!1}}async function Ou(){Ht.value||ga.value||await Ti()}async function Me(){await wi(),Ke.value!=="summary"&&await Ti()}async function ge(){var t;Qs.value=!0,xa.value=null;try{const e=await Tl(),n=yu(e);xi.value=n;const a=cn.value;n.operations.length===0?cn.value=null:(!a||!n.operations.some(s=>s.operation.operation_id===a))&&(cn.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){xa.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{Qs.value=!1}}function zu(){an=null,Ln.value=null,Sa.value=!1,Pn.value=null}async function qu(t){an=t,Sa.value=!0,Pn.value=null;try{const e=await Nl(t);if(an!==t)return;Ln.value=ku(e)}catch(e){if(an!==t)return;Ln.value=null,Pn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{an===t&&(Sa.value=!1)}}async function ju(){Js.value=!0,ba.value=null;try{const t=await Rl();zn.value=Ru(t)}catch(t){ba.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Js.value=!1}}async function kr(t=Yd()){Vs.value=!0,ka.value=null;try{const e=await Ll(t);dr.value=Mu(e)}catch(e){ka.value=e instanceof Error?e.message:"Failed to load command-plane swarm view"}finally{Vs.value=!1}}async function ie(t,e,n){Gs.value=t,ya.value=null;try{await Pl(e,n),await wi(),(Ht.value||Ke.value!=="summary")&&await Ti(),await kr(),await ge()}catch(a){throw ya.value=a instanceof Error?a.message:"Failed to execute command-plane action",a}finally{Gs.value=null}}function Fu(t){return ie(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Ku(t){return ie(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function Hu(t){return ie(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Uu(t={}){return ie("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function Bu(t){return ie(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Wu(t){return ie(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Gu(t,e){return ie(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Ju(t,e){return ie(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}od(()=>{wi()});function Vu(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function et(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function Qu(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Yu(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function J(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let io=!1,Xu=0,rs=null;async function Zu(){rs||(rs=Qd(()=>import("./mermaid.core-D3q8nIuP.js").then(e=>e.bE),[]).then(e=>e.default));const t=await rs;return io||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),io=!0),t}function Zt(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Ni(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function tp(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function xr(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const Sr=["operations","chains","topology","alerts","trace","control"],ep=["chain_start","node_start","node_complete","chain_complete","chain_error"];function np(t){return!!t&&Sr.includes(t)}function ap(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");return n&&e.set("agent",n),a&&e.set("token",a),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function sp(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function it(t){return Gs.value===t}function Ri(){return cr.value}function ip(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function op(){if(typeof window>"u")return null;const e=new URLSearchParams(window.location.search).get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function rp(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function lp(t){return t.status==="claimed"||t.status==="in_progress"}function cp(t){const e=zn.value;if(!e)return null;for(const n of e.golden_paths){const a=n.steps.find(s=>s.tool===t);if(a)return a}return null}function ls(t){var e;return((e=zn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function dp(t){const e=zn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(a=>n.has(a.id))}async function te(t){try{await t()}catch{}}function up(){var d,v,c,y,S,T;const t=Ri(),e=xi.value,n=t==null?void 0:t.topology.summary,a=t==null?void 0:t.operations.summary,s=t==null?void 0:t.operations.microarch,o=t==null?void 0:t.decisions.summary,r=t==null?void 0:t.alerts.summary,l=(d=s==null?void 0:s.signals)==null?void 0:d.routing_confidence,p=(v=s==null?void 0:s.signals)==null?void 0:v.issue_pressure,$=s==null?void 0:s.search_fabric,m=s==null?void 0:s.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>Units</span><strong>${(n==null?void 0:n.total_units)??0}</strong><small>${(n==null?void 0:n.managed_unit_count)??0} managed</small></div>
      <div class="monitor-stat-card"><span>Ops</span><strong>${(a==null?void 0:a.active)??0}</strong><small>${((c=t==null?void 0:t.detachments.summary)==null?void 0:c.active)??0} detachments</small></div>
      <div class="monitor-stat-card"><span>Approvals</span><strong>${(o==null?void 0:o.pending)??0}</strong><small>${(o==null?void 0:o.total)??0} tracked</small></div>
      <div class="monitor-stat-card"><span>Alerts</span><strong>${(r==null?void 0:r.bad)??0}</strong><small>${(r==null?void 0:r.warn)??0} warn</small></div>
      <div class="monitor-stat-card"><span>Chains</span><strong>${((y=e==null?void 0:e.summary)==null?void 0:y.active_chains)??0}</strong><small>${((S=e==null?void 0:e.summary)==null?void 0:S.linked_operations)??0} linked</small></div>
      <div class="monitor-stat-card"><span>Routing</span><strong>${($==null?void 0:$.best_first_operations)??0}</strong><small>${(l==null?void 0:l.tone)??"n/a"} · score ${((T=$==null?void 0:$.avg_best_score)==null?void 0:T.toFixed(1))??"0.0"}</small></div>
      <div class="monitor-stat-card"><span>Microarch</span><strong>${(p==null?void 0:p.pending_ops)??0}</strong><small>${(m==null?void 0:m.l1_hit_rate)!=null?`${Ni(m.l1_hit_rate)} L1 hit`:"no cache data"} · ${(p==null?void 0:p.tone)??"n/a"}</small></div>
    </div>
  `}function pp(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function mp({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const s of t){const o=s.motion_state;o in e?e[o]++:e.moving++}if(t.length===0)return null;const a=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return i`
    <div>
      <div class="swarm-health-bar">
        ${a.filter(s=>s.count>0).map(s=>i`
          <div class="swarm-health-seg ${s.key}" style="flex: ${s.count}"></div>
        `)}
      </div>
      <div class="swarm-health-labels">
        ${a.filter(s=>s.count>0).map(s=>i`
          <span class="swarm-health-label">
            <span class="swarm-health-swatch" style="background: ${s.color}"></span>
            ${s.count} ${s.key}
          </span>
        `)}
      </div>
    </div>
  `}function vp({workers:t,total:e}){const a=Math.min(t,20),s=Math.min(e-t,20-a),o=e>20?e-20:0,r=[];for(let l=0;l<a;l++)r.push({active:!0});for(let l=0;l<s;l++)r.push({active:!1});return i`
    <div class="swarm-worker-grid">
      ${r.map(l=>i`<span class="swarm-worker-dot ${l.active?"active":"idle"}"></span>`)}
      ${o>0?i`<span class="swarm-worker-count">+${o}</span>`:null}
      <span class="swarm-worker-count">(${t}/${e})</span>
    </div>
  `}function fp({lane:t}){const e=t.counts??{},n=pp(t),a=e.workers??0,s=Math.max(0,a-(e.alerts??0)),o=(e.operations??0)+(e.detachments??0),r=e.operations??0,l=o>0?Math.round(r/o*100):0;return i`
    <article class="swarm-lane-strip ${J(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <strong>${t.label}</strong>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${J(n)}">${t.phase}</span>
          <span class="command-chip ${J(n)}">${t.motion_state}</span>
          <span class="command-chip">${et(t.last_movement_at)}</span>
        </div>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${a>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">Workers</span>
                <${vp} workers=${s} total=${a} />
              </div>
            `:null}
        ${o>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">Ops</span>
                <div class="swarm-mini-bar">
                  <div class="swarm-mini-bar-fill" style="width: ${l}%; background: var(--${n==="bad"?"bad":n==="warn"?"warn":"ok"})"></div>
                </div>
                <span class="swarm-worker-count">${l}%</span>
              </div>
            `:null}
      </div>
      ${t.blockers.length>0?i`<div class="swarm-lane-blockers">Blockers: ${t.blockers.join(" · ")}</div>`:null}
      ${t.hard_flags.length>0?i`
            <div class="swarm-lane-flags">
              ${t.hard_flags.map(p=>i`<span class="command-chip ${J(p.severity)}">${p.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function _p({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e?`${String(e.getHours()).padStart(2,"0")}:${String(e.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${J(t.tone)}"></span>
      <span class="swarm-event-time">${n}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?i`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function gp({gap:t}){return i`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${J(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function $p({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${J(e)}">
      <div class="command-guide-head">
        <strong>Hot Proof</strong>
        <span class="command-chip ${J(e)}">${(t==null?void 0:t.status)??"missing"}</span>
      </div>
      ${t?i`
            <div class="command-card-grid">
              <span>Source</span><span>${t.source}</span>
              <span>Run</span><span>${t.run_id??"n/a"}</span>
              <span>Captured</span><span>${et(t.captured_at)}</span>
              <span>Pass</span><span>${t.pass==null?"n/a":t.pass?"yes":"no"}</span>
              <span>Peak Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>Workers</span><span>${t.workers.expected??"n/a"} expected · ${t.workers.done??"n/a"} done · ${t.workers.final??"n/a"} final</span>
            </div>
            ${t.artifact_ref?i`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?i`<p>${t.missing_reason}</p>`:null}
          `:i`<p>No swarm proof is available yet.</p>`}
    </div>
  `}function hp(){const t=Ri(),e=t==null?void 0:t.swarm_status,n=t==null?void 0:t.swarm_proof,a=(e==null?void 0:e.lanes.filter(p=>p.present))??[],s=(e==null?void 0:e.gaps.items)??[],o=(e==null?void 0:e.timeline.slice(0,8))??[],r=e==null?void 0:e.overview,l=e==null?void 0:e.recommended_next_action;return i`
    <section class="card command-section">
      <div class="card-title">Swarm</div>
      ${e?i`
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>Active Lanes</span><strong>${(r==null?void 0:r.active_lanes)??0}</strong><small>${(r==null?void 0:r.moving_lanes)??0} moving</small></div>
              <div class="monitor-stat-card"><span>Stalled</span><strong>${(r==null?void 0:r.stalled_lanes)??0}</strong><small>${(r==null?void 0:r.projected_lanes)??0} projected</small></div>
              <div class="monitor-stat-card"><span>Last Movement</span><strong>${et(r==null?void 0:r.last_movement_at)}</strong><small>${e.generated_at?`snapshot ${et(e.generated_at)}`:"snapshot now"}</small></div>
              <div class="monitor-stat-card"><span>Next Action</span><strong>${(l==null?void 0:l.label)??"Observe operator state"}</strong><small>${(l==null?void 0:l.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${a.length>0?i`<${mp} lanes=${a} />`:null}

            <div class="command-swarm-layout">
              <div class="command-card-stack">
                ${a.length>0?a.map(p=>i`<${fp} lane=${p} />`):i`<div class="empty-state">No active swarm lanes.</div>`}
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

                <${$p} proof=${n} />

                <div class="command-guide-card ${s.length>0?"warn":"ok"}">
                  <div class="command-guide-head">
                    <strong>Hard Gaps</strong>
                    <span class="command-chip ${J(s.some(p=>p.severity==="bad")?"bad":s.length>0?"warn":"ok")}">${s.length}</span>
                  </div>
                  ${s.length>0?i`<div class="swarm-event-rail">${s.slice(0,4).map(p=>i`<${gp} gap=${p} />`)}</div>`:i`<p>No hard gaps are currently visible.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>Movement Timeline</strong>
                    <span class="command-chip">${o.length}</span>
                  </div>
                  ${o.length>0?i`<div class="swarm-event-rail">${o.map(p=>i`<${_p} event=${p} />`)}</div>`:i`<p>No recent movement events are attached yet.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">Swarm status is unavailable.</div>`}
    </section>
  `}function yp(){return i`
    <div class="command-surface-tabs">
      ${Sr.map(t=>i`
        <button
          class="command-surface-tab ${Ke.value===t?"active":""}"
          onClick=${()=>Ai(t)}
        >
          ${t}
        </button>
      `)}
    </div>
  `}function bp(){var mt,vt,B,M,x,Dt,Vt,oe,re;const t=Ri(),e=Ht.value,n=se.value,a=ip(),s=a?At.value.find(I=>I.name===a)??null:null,o=a?yt.value.filter(I=>I.assignee===a&&lp(I)):[],r=((mt=t==null?void 0:t.operations.summary)==null?void 0:mt.active)??0,l=((vt=t==null?void 0:t.detachments.summary)==null?void 0:vt.total)??0,p=((B=t==null?void 0:t.decisions.summary)==null?void 0:B.pending)??0,$=e==null?void 0:e.detachments.detachments.find(I=>{const Et=I.detachment.heartbeat_deadline,le=Et?Date.parse(Et):Number.NaN;return I.detachment.status==="stalled"||!Number.isNaN(le)&&le<=Date.now()}),m=e==null?void 0:e.alerts.alerts.find(I=>I.severity==="bad"),d=!!(n!=null&&n.room||n!=null&&n.project),v=(s==null?void 0:s.current_task)??null,c=rp(s==null?void 0:s.last_seen),y=c!=null?c<=120:null,S=[d?{title:"Room readiness",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room readiness",tone:"bad",detail:"No room snapshot yet. Set room to repo root before joining.",tool:"masc_set_room"},a?s?o.length===0?{title:"Task readiness",tone:"warn",detail:`${a} has no claimed task. Claim one or create one first.`,tool:yt.value.length>0?"masc_claim":"masc_add_task"}:v?y===!1?{title:"Task readiness",tone:"warn",detail:`${a} current_task=${v}, but heartbeat is stale (${c}s).`,tool:"masc_heartbeat"}:{title:"Task readiness",tone:"ok",detail:`${a} current_task=${v}${c!=null?` · last seen ${c}s ago`:""}`,tool:"masc_plan_get_task"}:{title:"Task readiness",tone:"bad",detail:`${a} has a claimed task but no session current_task binding.`,tool:"masc_plan_set_task"}:{title:"Task readiness",tone:"bad",detail:`${a} is not visible in the room roster.`,tool:"masc_join"}:{title:"Task readiness",tone:"warn",detail:"No ?agent= query param. Dashboard can show room health but not agent-specific next steps.",tool:"masc_join"},!t||(((M=t.topology.summary)==null?void 0:M.managed_unit_count)??0)===0?{title:"Operation readiness",tone:"warn",detail:"No managed units defined yet. CPv2 benchmark cannot start before hierarchy exists.",tool:"masc_unit_define"}:r===0?{title:"Operation readiness",tone:"warn",detail:`${((x=t.topology.summary)==null?void 0:x.managed_unit_count)??0} managed units are ready, but there is no active operation.`,tool:"masc_operation_start"}:{title:"Operation readiness",tone:"ok",detail:`${r} active operation(s) across ${((Dt=t.topology.summary)==null?void 0:Dt.managed_unit_count)??0} managed unit(s).`,tool:"masc_observe_operations"},p>0?{title:"Dispatch readiness",tone:"warn",detail:`${p} pending approval(s) are blocking strict actions.`,tool:"masc_policy_approve"}:r>0&&l===0?{title:"Dispatch readiness",tone:"bad",detail:"Active operation exists but no detachment has been materialized yet.",tool:"masc_dispatch_tick"}:$||m?{title:"Dispatch readiness",tone:"warn",detail:`Dispatch needs reconciliation${$?` · detachment ${$.detachment.detachment_id} is stalled`:""}${m?` · alert ${m.title??m.alert_id}`:""}${!e&&!$&&!m?" · open a detail tab to inspect the exact source.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"Dispatch readiness",tone:"ok",detail:`${l} detachment(s) visible and no strict approval backlog${e?"":" · detail panes stay lazy until opened."}.`,tool:"masc_detachment_list"}],T=d?!a||!s?"masc_join":o.length===0?yt.value.length>0?"masc_claim":"masc_add_task":v?y===!1?"masc_heartbeat":!t||(((Vt=t.topology.summary)==null?void 0:Vt.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":p>0?"masc_policy_approve":r>0&&l===0||$||m?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",P=cp(T),E=dp(T==="masc_set_room"?["repo-root-room"]:T==="masc_plan_set_task"?["claimed-not-current"]:T==="masc_heartbeat"?["heartbeat-stale"]:T==="masc_dispatch_tick"?["no-detachments"]:T==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),N=ls("room_task_hygiene"),R=ls("cpv2_benchmark"),X=ls("supervisor_session"),H=((oe=zn.value)==null?void 0:oe.docs)??[],Pt=[N,R,X].filter(I=>I!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title">Immediate Actions</div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(P==null?void 0:P.title)??T}</strong>
            <span class="command-chip ok">${T}</span>
          </div>
          <p>${(P==null?void 0:P.summary)??"Use the next tool in the canonical flow to remove the current blocker."}</p>
          ${(re=P==null?void 0:P.success_signals)!=null&&re.length?i`<div class="command-tag-row">
                ${P.success_signals.map(I=>i`<span class="command-tag ok">${I}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${S.map(I=>i`
            <article class="command-readiness-row ${J(I.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${I.title}</strong>
                  <span class="command-chip ${J(I.tone)}">${I.tone}</span>
                </div>
                <p>${I.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${I.tool}</div>
            </article>
          `)}
        </div>

        ${E.length>0?i`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>Common Pitfalls</strong>
                  <span class="command-chip warn">${E.length}</span>
                </div>
                <div class="command-guide-list">
                  ${E.map(I=>i`
                    <article class="command-guide-inline">
                      <strong>${I.title}</strong>
                      <div>${I.symptom}</div>
                      <div class="command-card-sub">Fix with ${I.fix_tool}: ${I.fix_summary}</div>
                    </article>
                  `)}
                </div>
              </div>
            `:null}
      </section>

      <section class="card command-section">
        <div class="card-title">Operating Paths</div>
        ${Js.value?i`<div class="empty-state">Loading CPv2 runbook…</div>`:ba.value?i`<div class="empty-state error">${ba.value}</div>`:i`
                <div class="command-path-grid">
                  ${Pt.map(I=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${I.title}</strong>
                        <span class="command-chip">${I.id}</span>
                      </div>
                      <p>${I.summary}</p>
                      <div class="command-card-sub">${I.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${I.steps.slice(0,4).map(Et=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Et.tool}</span>
                            <span>${Et.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${H.length>0?i`<div class="command-doc-links">
                      ${H.map(I=>i`<span class="command-tag">${I.title}: ${I.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function kp(){return i`
    <${up} />
    <div class="command-primary-layout">
      <${hp} />
      <${bp} />
    </div>
  `}function xp(){return ga.value?i`<div class="empty-state">Loading command-plane detail…</div>`:ha.value?i`<div class="empty-state error">${ha.value}</div>`:i`<div class="empty-state">Select a surface to load command-plane detail.</div>`}function Ar({node:t,depth:e=0}){const n=t.roster_live??0,a=t.roster_total??t.unit.roster.length,s=t.active_operation_count??0,o=t.unit.policy;return i`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${sp(t.unit.kind)}</span>
            <span class="command-chip ${J(t.health)}">${t.health??"ok"}</span>
            ${o!=null&&o.frozen?i`<span class="command-chip warn">frozen</span>`:null}
            ${o!=null&&o.kill_switch?i`<span class="command-chip bad">kill-switch</span>`:null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${t.unit.unit_id}</span>
            <span>Leader ${t.unit.leader_id??"unassigned"} / ${t.leader_status??"unknown"}</span>
            <span>Roster ${n}/${a}</span>
            <span>Ops ${s}</span>
            <span>Autonomy ${(o==null?void 0:o.autonomy_level)??"n/a"}</span>
          </div>
          ${t.reasons&&t.reasons.length>0?i`<div class="command-tag-row">
                ${t.reasons.map(r=>i`<span class="command-tag warn">${r}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?i`<div class="command-tree-children">
            ${t.children.map(r=>i`<${Ar} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function Sp({source:t}){const e=wo(null),[n,a]=Ua(null);return rt(()=>{let s=!1;const o=e.current;return o?(o.innerHTML="",a(null),(async()=>{try{const l=await Zu(),{svg:p}=await l.render(`command-chain-${++Xu}`,t);if(s||!e.current)return;e.current.innerHTML=p}catch(l){if(s)return;a(l instanceof Error?l.message:"Mermaid render failed")}})(),()=>{s=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function Ap({overlay:t,selected:e,onSelect:n}){const a=t.operation.chain,s=t.runtime;return i`
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
        ${a!=null&&a.chain_id?i`<span class="command-tag">${a.chain_id}</span>`:null}
        ${s?i`<span class="command-tag ${Zt(a==null?void 0:a.status)}">${Ni(s.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${xr(t.history)}</div>
    </button>
  `}function wp({item:t}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${Zt(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${et(t.timestamp)}</div>
      <div class="command-card-sub">${xr(t)}</div>
    </article>
  `}function Cp({node:t}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${Zt(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?i`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function Tp({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,a=`resume:${e.operation_id}`,s=`recall:${e.operation_id}`,o=e.chain;return i`
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
        <span>Updated</span><span>${et(e.updated_at)}</span>
      </div>
      ${o?i`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${Zt(o.status)}">${o.status}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">run ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?i`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{Ci(e.operation_id),Ai("chains"),Rt("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?i`
              <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>te(()=>Fu(e.operation_id))}>
                ${it(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${it(s)} onClick=${()=>te(()=>Hu(e.operation_id))}>
                ${it(s)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?i`
              <button class="control-btn ghost" disabled=${it(a)} onClick=${()=>te(()=>Ku(e.operation_id))}>
                ${it(a)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Np({card:t}){var n;const e=t.detachment;return i`
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
        <span>Progress</span><span>${et(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Yu(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${et(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?i`<span class="command-tag ${Qu(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Rp({alert:t}){return i`
    <article class="command-alert ${J(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${J(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${et(t.timestamp)}</span>
      </div>
      ${t.detail?i`<p>${t.detail}</p>`:null}
    </article>
  `}function wr({event:t}){return i`
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
      <pre class="command-trace-detail">${Vu(t.detail)}</pre>
    </article>
  `}function Lp({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,a=t.source==="projected_operator";return i`
    <article class="command-card ${J(t.status)}">
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
        <span>Created</span><span>${et(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!a?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${it(e)} onClick=${()=>te(()=>Bu(t.decision_id))}>
                ${it(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>te(()=>Wu(t.decision_id))}>
                ${it(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${a?i`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function Pp({row:t}){var l,p,$;const e=t.unit,n=`freeze:${e.unit_id}`,a=`kill:${e.unit_id}`,s=!!((l=e.policy)!=null&&l.frozen),o=!!((p=e.policy)!=null&&p.kill_switch),r=Math.round((t.utilization??0)*100);return i`
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
        <span>Frozen</span><span>${s?"yes":"no"}</span>
        <span>Kill Switch</span><span>${o?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>te(()=>Gu(e.unit_id,!s))}>
          ${it(n)?"Applying…":s?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${it(a)} onClick=${()=>te(()=>Ju(e.unit_id,!o))}>
          ${it(a)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function Dp({item:t}){return i`
    <article class="command-guide-card ${J(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${J(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Ep({blocker:t}){return i`
    <article class="command-alert ${J(t.severity)}">
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
  `}function Ip({worker:t}){return i`
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
      ${t.last_message?i`<div class="command-card-foot">${et(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function Mp(){var l,p,$,m,d,v,c,y,S,T,P,K,E,N,R,X,H,Pt,mt,vt,B;const t=dr.value,e=op(),n=(l=t==null?void 0:t.provider)!=null&&l.runtime_blocker?"blocked":(p=t==null?void 0:t.provider)!=null&&p.provider_reachable?"ready":"check",a=(($=t==null?void 0:t.provider)==null?void 0:$.actual_slots)??((m=t==null?void 0:t.provider)==null?void 0:m.total_slots)??0,s=((d=t==null?void 0:t.provider)==null?void 0:d.expected_slots)??"n/a",o=((v=t==null?void 0:t.provider)==null?void 0:v.actual_ctx)??((c=t==null?void 0:t.provider)==null?void 0:c.ctx_per_slot)??0,r=((y=t==null?void 0:t.provider)==null?void 0:y.expected_ctx)??"n/a";return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Swarm Live Run</div>
        ${Vs.value?i`<div class="empty-state">Loading swarm live state…</div>`:ka.value?i`<div class="empty-state error">${ka.value}</div>`:t?i`
                  <div class="command-summary-grid">
                    <div class="monitor-stat-card"><span>Run</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room n/a"}</small></div>
                    <div class="monitor-stat-card"><span>Workers</span><strong>${((S=t.summary)==null?void 0:S.joined_workers)??0}/${((T=t.summary)==null?void 0:T.expected_workers)??0}</strong><small>${((P=t.summary)==null?void 0:P.live_workers)??0} live · ${((K=t.summary)==null?void 0:K.completed_workers)??0} completed</small></div>
                    <div class="monitor-stat-card"><span>Runtime</span><strong>${n}</strong><small>slots ${a}/${s} · ctx ${o}/${r}</small></div>
                    <div class="monitor-stat-card"><span>Hot 10+</span><strong>${(E=t.summary)!=null&&E.pass_hot_concurrency?"pass":"check"}</strong><small>${((N=t.provider)==null?void 0:N.slot_url)??"slot n/a"}</small></div>
                    <div class="monitor-stat-card"><span>End to End</span><strong>${(R=t.summary)!=null&&R.pass_end_to_end?"pass":"check"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                  </div>
                  <div class="command-card-grid">
                    <span>Operation</span><span>${((X=t.operation)==null?void 0:X.operation_id)??"none"}</span>
                    <span>Squad</span><span>${((H=t.squad)==null?void 0:H.label)??"none"}</span>
                    <span>Detachment</span><span>${((Pt=t.detachment)==null?void 0:Pt.detachment_id)??"none"}</span>
                    <span>Expected</span><span>${((mt=t.summary)==null?void 0:mt.expected_workers)??0} workers</span>
                    <span>Final Markers</span><span>${((vt=t.summary)==null?void 0:vt.final_markers_seen)??0}</span>
                    <span>Runtime Blocker</span><span>${((B=t.provider)==null?void 0:B.runtime_blocker)??"none"}</span>
                    <span>Recommended</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                  </div>
                  ${t.truth_notes.length>0?i`<div class="command-tag-row">
                        ${t.truth_notes.map(M=>i`<span class="command-tag">${M}</span>`)}
                      </div>`:null}
                `:i`<div class="empty-state">No swarm read-model yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Checklist</div>
        ${t&&t.checklist.length>0?i`<div class="command-card-stack">
              ${t.checklist.map(M=>i`<${Dp} item=${M} />`)}
            </div>`:i`<div class="empty-state">No checklist yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Workers</div>
        ${t&&t.workers.length>0?i`<div class="command-card-stack">
              ${t.workers.map(M=>i`<${Ip} worker=${M} />`)}
            </div>`:i`<div class="empty-state">No worker rows yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Runtime</div>
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
                <span>Last Sample</span><span>${t.provider.last_sample_at?et(t.provider.last_sample_at):"n/a"}</span>
                <span>Runtime Blocker</span><span>${t.provider.runtime_blocker??"none"}</span>
                <span>Doctor Checked</span><span>${t.provider.checked_at?et(t.provider.checked_at):"n/a"}</span>
              </div>
              ${t.provider.detail?i`<div class="command-card-sub">${t.provider.detail}</div>`:null}
              ${t.provider.timeline.length>0?i`<div class="command-trace-stack">
                    ${t.provider.timeline.slice(-12).map(M=>i`
                      <article class="command-trace-row">
                        <div class="command-trace-main">
                          <div class="command-trace-head">
                            <strong>${M.active_slots} active</strong>
                            <span class="command-chip">${et(M.timestamp)}</span>
                          </div>
                          <div class="command-card-sub">slots ${M.active_slot_ids.join(", ")||"none"}</div>
                        </div>
                      </article>
                    `)}
                  </div>`:i`<div class="empty-state">No slot telemetry captured yet.</div>`}
            `:i`<div class="empty-state">No runtime telemetry yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Blockers</div>
        ${t&&t.blockers.length>0?i`<div class="command-card-stack">
              ${t.blockers.map(M=>i`<${Ep} blocker=${M} />`)}
            </div>`:i`<div class="empty-state">No blockers. Use ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} for the next action.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Recent Messages</div>
        ${t&&t.recent_messages.length>0?i`<div class="command-trace-stack">
              ${t.recent_messages.map(M=>i`
                <article class="command-trace-row">
                  <div class="command-trace-main">
                    <div class="command-trace-head">
                      <strong>${M.from}</strong>
                      <span class="command-chip">${et(M.timestamp)}</span>
                    </div>
                    <div class="command-card-sub">seq ${M.seq}</div>
                  </div>
                  <pre class="command-trace-detail">${M.content}</pre>
                </article>
              `)}
            </div>`:i`<div class="empty-state">No run-scoped broadcasts captured yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Recent Trace Events</div>
        ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
              ${t.recent_trace_events.map(M=>i`<${wr} event=${M} />`)}
            </div>`:i`<div class="empty-state">No run-scoped trace events captured yet.</div>`}
      </section>
    </div>
  `}function Op(){const t=Ht.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Operations</div>
        ${t&&t.operations.operations.length>0?i`<div class="command-card-stack">
              ${t.operations.operations.map(e=>i`<${Tp} card=${e} />`)}
            </div>`:i`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title">Detachments</div>
        ${t&&t.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>i`<${Np} card=${e} />`)}
            </div>`:i`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function zp(){var l,p,$,m,d,v,c,y,S,T,P,K,E,N,R,X;const t=xi.value,e=(t==null?void 0:t.operations)??[],n=cn.value,a=e.find(H=>H.operation.operation_id===n)??e[0]??null,s=((l=a==null?void 0:a.operation.chain)==null?void 0:l.run_id)??null,o=((p=Ln.value)==null?void 0:p.run)??(a==null?void 0:a.preview_run)??null,r=!(($=Ln.value)!=null&&$.run)&&!!(a!=null&&a.preview_run);return rt(()=>{s?qu(s):zu()},[s]),i`
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
            <span>Recent Failures</span><span>${((v=t==null?void 0:t.summary)==null?void 0:v.recent_failures)??0}</span>
            <span>Last Event</span><span>${et((c=t==null?void 0:t.summary)==null?void 0:c.last_history_event_at)}</span>
          </div>
        </article>

        ${xa.value?i`<div class="empty-state error">${xa.value}</div>`:null}

        ${Qs.value&&!t?i`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?i`
                <div class="command-chain-list">
                  ${e.map(H=>i`
                    <${Ap}
                      overlay=${H}
                      selected=${(a==null?void 0:a.operation.operation_id)===H.operation.operation_id}
                      onSelect=${()=>Ci(H.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(H=>i`<${wp} item=${H} />`)}
                </div>
              `:i`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title">Chain Detail</div>
        ${a?i`
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
                  <span>Run ID</span><span>${s??"not materialized"}</span>
                  <span>Progress</span><span>${Ni((K=a.runtime)==null?void 0:K.progress)}</span>
                  <span>Elapsed</span><span>${tp((E=a.runtime)==null?void 0:E.elapsed_sec)}</span>
                  <span>Updated</span><span>${et(((N=a.operation.chain)==null?void 0:N.last_sync_at)??a.operation.updated_at)}</span>
                </div>
                ${(R=a.operation.chain)!=null&&R.goal?i`<div class="command-card-foot">${a.operation.chain.goal}</div>`:null}
              </article>

              ${a.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((X=a.operation.chain)==null?void 0:X.chain_id)??"graph"}</span>
                      </div>
                      <${Sp} source=${a.mermaid} />
                    </div>
                  `:i`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"failed":r?"preview":"captured":"pending"}
                  </span>
                </div>
                ${Sa.value?i`<div class="empty-state">Loading run detail…</div>`:Pn.value?i`<div class="empty-state error">${Pn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${o.chain_id}</span>
                            <span>Run</span><span>${o.run_id??"preview only"}</span>
                            <span>Duration</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${o.nodes.length}</span>
                          </div>
                          ${r?i`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(H=>i`<${Cp} node=${H} />`)}
                          </div>
                        `:i`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:i`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function qp(){const t=Ht.value;return i`
    <section class="card command-section">
      <div class="card-title">Topology</div>
      ${t&&t.topology.units.length>0?i`${t.topology.units.map(e=>i`<${Ar} node=${e} />`)}`:i`<div class="empty-state">No command topology projected yet.</div>`}
    </section>
  `}function jp(){const t=Ht.value;return i`
    <section class="card command-section">
      <div class="card-title">Alerts</div>
      ${t&&t.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>i`<${Rp} alert=${e} />`)}
          </div>`:i`<div class="empty-state">No command-plane alerts right now.</div>`}
    </section>
  `}function Fp(){const t=Ht.value;return i`
    <section class="card command-section">
      <div class="card-title">Trace</div>
      ${t&&t.traces.events.length>0?i`<div class="command-trace-stack">
            ${t.traces.events.map(e=>i`<${wr} event=${e} />`)}
          </div>`:i`<div class="empty-state">No recent trace events.</div>`}
    </section>
  `}function Kp(){const t=Ht.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Approval Queue</div>
        ${t&&t.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>i`<${Lp} decision=${e} />`)}
            </div>`:i`<div class="empty-state">No approval queue items.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Unit Controls</div>
        ${t&&t.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>i`<${Pp} row=${e} />`)}
            </div>`:i`<div class="empty-state">No capacity rows projected.</div>`}
      </section>
    </div>
  `}function Hp(){if(Ke.value==="summary")return i`<${kp} />`;if(!Ht.value)return i`<${xp} />`;switch(Ke.value){case"swarm":return i`<${Mp} />`;case"chains":return i`<${zp} />`;case"topology":return i`<${qp} />`;case"alerts":return i`<${jp} />`;case"trace":return i`<${Fp} />`;case"control":return i`<${Kp} />`;case"operations":default:return i`<${Op} />`}}function Up(){return rt(()=>{Me(),ge(),ju(),kr()},[]),rt(()=>{if(nt.value.tab!=="command")return;const t=nt.value.params.surface,e=nt.value.params.operation;np(t)&&Ai(t),e&&Ci(e)},[nt.value.tab,nt.value.params.surface,nt.value.params.operation]),rt(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,Me(),ge()},250))},n=new EventSource(ap()),a=ep.map(s=>{const o=()=>e();return n.addEventListener(s,o),{type:s,handler:o}});return n.onerror=()=>{e()},()=>{a.forEach(({type:s,handler:o})=>{n.removeEventListener(s,o)}),n.close(),t&&window.clearTimeout(t)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>Command Plane</h2>
          <p>Operations-first command surface for company → platoon → squad → agent orchestration, approvals, alerts, and traceability.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{te(()=>Uu())}}
            disabled=${it("dispatch:tick")}
          >
            ${it("dispatch:tick")?"Reconciling…":"Run Tick"}
          </button>
          <button class="control-btn ghost" onClick=${()=>{Me(),ge()}} disabled=${_a.value}>
            ${_a.value?"Refreshing…":"Refresh"}
          </button>
        </div>
      </div>

      ${$a.value?i`<div class="empty-state error">${$a.value}</div>`:null}
      ${ya.value?i`<div class="empty-state error">${ya.value}</div>`:null}
      <${yp} />
      <${Hp} />
    </section>
  `}const qn=_(null),Aa=_(!1),ae=_(null),W=_(!1),wa=_([]);let Bp=1;function G(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function D(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function $t(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Cr(t){return typeof t=="boolean"?t:void 0}function Wp(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Ce(t,e=[]){if(Array.isArray(t))return t;if(!G(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function Gp(t){return G(t)?{id:D(t.id),seq:$t(t.seq),from:D(t.from)??D(t.from_agent)??"system",content:D(t.content)??"",timestamp:D(t.timestamp)??new Date().toISOString(),type:D(t.type)}:null}function Jp(t){return G(t)?{room_id:D(t.room_id),current_room:D(t.current_room)??D(t.room),project:D(t.project),cluster:D(t.cluster),paused:Cr(t.paused),pause_reason:D(t.pause_reason)??null,paused_by:D(t.paused_by)??null,paused_at:D(t.paused_at)??null}:{}}function oo(t){if(!G(t))return;const e=Object.entries(t).map(([n,a])=>{const s=D(a);return s?[n,s]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Vp(t){if(!G(t))return null;const e=G(t.status)?t.status:void 0,n=G(t.summary)?t.summary:G(e==null?void 0:e.summary)?e.summary:void 0,a=G(t.session)?t.session:G(e==null?void 0:e.session)?e.session:void 0,s=D(t.session_id)??D(n==null?void 0:n.session_id)??D(a==null?void 0:a.session_id);if(!s)return null;const o=oo(t.report_paths)??oo(e==null?void 0:e.report_paths),r=Ce(t.recent_events,["events"]).filter(G);return{session_id:s,status:D(t.status)??D(n==null?void 0:n.status)??D(a==null?void 0:a.status),progress_pct:$t(t.progress_pct)??$t(n==null?void 0:n.progress_pct),elapsed_sec:$t(t.elapsed_sec)??$t(n==null?void 0:n.elapsed_sec),remaining_sec:$t(t.remaining_sec)??$t(n==null?void 0:n.remaining_sec),done_delta_total:$t(t.done_delta_total)??$t(n==null?void 0:n.done_delta_total),summary:n,team_health:G(t.team_health)?t.team_health:G(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:G(t.communication_metrics)?t.communication_metrics:G(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:G(t.orchestration_state)?t.orchestration_state:G(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:G(t.cascade_metrics)?t.cascade_metrics:G(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:a,recent_events:r}}function Qp(t){if(!G(t))return null;const e=D(t.name);if(!e)return null;const n=G(t.context)?t.context:void 0;return{name:e,agent_name:D(t.agent_name),status:D(t.status),autonomy_level:D(t.autonomy_level),context_ratio:$t(t.context_ratio)??$t(n==null?void 0:n.context_ratio),generation:$t(t.generation),active_goal_ids:Wp(t.active_goal_ids),last_autonomous_action_at:D(t.last_autonomous_action_at)??null,last_turn_ago_s:$t(t.last_turn_ago_s),model:D(t.model)??D(t.active_model)??D(t.primary_model)}}function Yp(t){if(!G(t))return null;const e=D(t.confirm_token)??D(t.token);return e?{confirm_token:e,actor:D(t.actor),action_type:D(t.action_type),target_type:D(t.target_type),target_id:D(t.target_id)??null,delegated_tool:D(t.delegated_tool),created_at:D(t.created_at),preview:t.preview}:null}function Xp(t){const e=G(t)?t:{};return{room:Jp(e.room),sessions:Ce(e.sessions,["items","sessions"]).map(Vp).filter(n=>n!==null),keepers:Ce(e.keepers,["items","keepers"]).map(Qp).filter(n=>n!==null),recent_messages:Ce(e.recent_messages,["messages"]).map(Gp).filter(n=>n!==null),pending_confirms:Ce(e.pending_confirms,["items","confirms"]).map(Yp).filter(n=>n!==null),available_actions:Ce(e.available_actions,["actions"]).filter(G).map(n=>({action_type:D(n.action_type)??"unknown",target_type:D(n.target_type)??"unknown",description:D(n.description),confirm_required:Cr(n.confirm_required)}))}}function Kn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function ro(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Ca(t){wa.value=[{...t,id:Bp++,at:new Date().toISOString()},...wa.value].slice(0,20)}function Tr(t){return t.confirm_required?Kn(t.preview)||"Confirmation required":Kn(t.result)||Kn(t.executed_action)||Kn(t.delegated_tool_result)||t.status}async function He(){Aa.value=!0,ae.value=null;try{const t=await Al();qn.value=Xp(t)}catch(t){ae.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Aa.value=!1}}async function Zp(t){W.value=!0,ae.value=null;try{const e=await On(t);return Ca({actor:t.actor,action_type:t.action_type,target_label:ro(t),outcome:e.confirm_required?"preview":"executed",message:Tr(e),delegated_tool:e.delegated_tool}),await He(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw ae.value=n,Ca({actor:t.actor,action_type:t.action_type,target_label:ro(t),outcome:"error",message:n}),e}finally{W.value=!1}}async function tm(t,e){W.value=!0,ae.value=null;try{const n=await El(t,e);return Ca({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Tr(n),delegated_tool:n.delegated_tool}),await He(),n}catch(n){const a=n instanceof Error?n.message:"Operator confirmation failed";throw ae.value=a,Ca({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),n}finally{W.value=!1}}const Nr="masc_dashboard_agent_name";function em(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(Nr))==null?void 0:a.trim())||"dashboard"}const Ja=_(em()),dn=_(""),Ys=_("Operator pause"),un=_(""),Ta=_(""),Xs=_("2"),Na=_(""),Oe=_("note"),Ra=_(""),La=_(""),Pa=_(""),Zs=_("2"),ti=_("Operator stop request"),ei=_(""),pn=_("");function nm(t){const e=t.trim()||"dashboard";Ja.value=e,localStorage.setItem(Nr,e)}function cs(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function am(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function Da(t){return typeof t=="string"?t.trim().toLowerCase():""}function sm(t){var a;const e=Da(t.status);if(e==="paused")return"bad";const n=Da((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function lo(t){const e=Da(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":(t.context_ratio??0)>=.8||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}async function he(t){const e=Ja.value.trim()||"dashboard";try{const n=await Zp({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?w("Confirmation queued","warning"):w(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return w(a,"error"),null}}async function co(){const t=dn.value.trim();if(!t)return;await he({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(dn.value="")}async function im(){await he({action_type:"room_pause",target_type:"room",payload:{reason:Ys.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function om(){await he({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function rm(){const t=un.value.trim();if(!t)return;await he({action_type:"task_inject",target_type:"room",payload:{title:t,description:Ta.value.trim()||"Injected from Ops tab",priority:Number.parseInt(Xs.value,10)||2},successMessage:"Task injection submitted"})&&(un.value="",Ta.value="")}async function lm(){var o;const t=qn.value,e=Na.value||((o=t==null?void 0:t.sessions[0])==null?void 0:o.session_id)||"";if(!e){w("Select a team session first","warning");return}const n={turn_kind:Oe.value},a=Ra.value.trim();a&&(n.message=a),Oe.value==="task"&&(n.task_title=La.value.trim()||"Operator injected task",n.task_description=Pa.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(Zs.value,10)||2),await he({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(Ra.value="",Oe.value==="task"&&(La.value="",Pa.value=""))}async function cm(){var n;const t=qn.value,e=Na.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){w("Select a team session first","warning");return}await he({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:ti.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function dm(){var s;const t=qn.value,e=ei.value||((s=t==null?void 0:t.keepers[0])==null?void 0:s.name)||"",n=pn.value.trim();if(!e){w("Select a keeper first","warning");return}if(!n)return;await he({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(pn.value="")}async function uo(t){const e=Ja.value.trim()||"dashboard";try{await tm(e,t),w("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";w(a,"error")}}function um(){var v;const t=qn.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],a=(t==null?void 0:t.keepers)??[],s=(t==null?void 0:t.pending_confirms)??[],o=(t==null?void 0:t.recent_messages)??[],r=n.find(c=>c.session_id===Na.value)??n[0]??null,l=a.find(c=>c.name===ei.value)??a[0]??null,p=n.filter(c=>sm(c)!=="ok"),$=a.filter(c=>lo(c)!=="ok"),m=o.slice(0,5),d=[{key:"room",label:"Room Gate",value:e.paused?"Paused":"Open",detail:e.paused?`Resume gate armed${e.pause_reason?` · ${e.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:e.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:s.length,detail:s.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:s.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:p.length,detail:p.length>0?"Team sessions need steering, stop, or checkpoint attention":"Team sessions look healthy from the operator snapshot",tone:p.some(c=>Da(c.status)==="paused")?"bad":p.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:$.length,detail:$.length>0?"At least one keeper is stale, offline, or running hot":"Keepers are available for direct intervention",tone:$.some(c=>lo(c)==="bad")?"bad":$.length>0?"warn":"ok"}];return i`
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
            onInput=${c=>nm(c.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{He()}} disabled=${Aa.value||W.value}>
            ${Aa.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${ae.value?i`
        <section class="ops-banner error">${ae.value}</section>
      `:null}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Action Priority</h2>
          <p class="monitor-subheadline">Ops is the command surface. These four signals explain when to intervene before you drop into a specific control panel.</p>
        </div>
        <div class="ops-priority-grid">
          ${d.map(c=>i`
            <div key=${c.key} class="ops-priority-card ${c.tone}">
              <span class="ops-priority-label">${c.label}</span>
              <strong>${c.value}</strong>
              <div class="ops-priority-detail">${c.detail}</div>
            </div>
          `)}
        </div>
      </section>

      ${s.length>0?i`
        <section class="card ops-confirmations">
          <div class="card-title">Pending Confirmations</div>
          <p class="ops-context-note">Only previewed actions that still need an explicit operator confirmation stay here.</p>
          <div class="ops-confirmation-list">
            ${s.map(c=>i`
              <article key=${c.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${c.action_type??"unknown"}</strong>
                  <span>${c.target_type??"target"}${c.target_id?`:${c.target_id}`:""}</span>
                  <span>${c.delegated_tool??"delegated tool pending"}</span>
                </div>
                ${c.preview?i`<pre class="ops-code-block">${cs(c.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{uo(c.confirm_token)}} disabled=${W.value}>
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
            ${s.length>0?i`
              <div class="ops-confirmation-list">
                ${s.map(c=>i`
                  <article key=${c.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${c.action_type??"unknown"}</strong>
                      <span>${c.target_type??"target"}${c.target_id?`:${c.target_id}`:""}</span>
                      <span>${c.delegated_tool??"delegated tool pending"}</span>
                    </div>
                    ${c.preview?i`<pre class="ops-code-block compact">${cs(c.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{uo(c.confirm_token)}} disabled=${W.value}>
                        Confirm
                      </button>
                      <span class="ops-token">${c.confirm_token}</span>
                    </div>
                  </article>
                `)}
              </div>
            `:i`<div class="ops-empty">No pending confirmations.</div>`}
          </section>

          <section class="card ops-panel">
            <div class="card-title">Operator Log</div>
            <div class="ops-log-list">
              ${wa.value.length===0?i`
                <div class="ops-empty">No operator actions in this session yet.</div>
              `:wa.value.map(c=>i`
                <article key=${c.id} class="ops-log-entry ${c.outcome}">
                  <div class="ops-log-head">
                    <strong>${c.action_type}</strong>
                    <span>${c.target_label}</span>
                    <span>${c.at}</span>
                  </div>
                  <div class="ops-log-body">${c.message}</div>
                </article>
              `)}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title">Room Feed</div>
            <p class="ops-context-note">Recent chatter stays available for operator context, but it is secondary to the intervention queue.</p>
            ${m.length>0?i`
              <div class="ops-feed-list">
                ${m.map(c=>i`
                  <article key=${c.seq??c.id??c.timestamp} class="ops-feed-item">
                    <div class="ops-feed-meta">
                      <strong>${c.from}</strong>
                      <span>${c.timestamp}</span>
                    </div>
                    <div class="ops-feed-content">${c.content}</div>
                  </article>
                `)}
              </div>
            `:i`<div class="ops-empty">No recent room messages.</div>`}
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel">
            <div class="card-title">Session Queue</div>
            <p class="ops-context-note">Select the session that needs steering. This queue should answer which run is hot, paused, or drifting.</p>
            <div class="ops-entity-list">
              ${n.length===0?i`<div class="ops-empty">No team sessions available.</div>`:n.map(c=>{var y;return i`
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
              ${a.length===0?i`<div class="ops-empty">No keepers available.</div>`:a.map(c=>i`
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
                    <span>${am(c.last_turn_ago_s)}</span>
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
                  disabled=${W.value}
                />
                <button class="control-btn" onClick=${()=>{co()}} disabled=${W.value||dn.value.trim()===""}>
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
                  disabled=${W.value}
                />
                <button class="control-btn ghost" onClick=${()=>{im()}} disabled=${W.value}>
                  Pause
                </button>
                <button class="control-btn ghost" onClick=${()=>{om()}} disabled=${W.value}>
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
                disabled=${W.value}
              />
              <textarea
                class="control-textarea"
                rows=${3}
                placeholder="Task description"
                value=${Ta.value}
                onInput=${c=>{Ta.value=c.target.value}}
                disabled=${W.value}
              ></textarea>
              <div class="control-row ops-split-row">
                <select
                  class="control-input ops-select"
                  value=${Xs.value}
                  onChange=${c=>{Xs.value=c.target.value}}
                  disabled=${W.value}
                >
                  <option value="1">P1</option>
                  <option value="2">P2</option>
                  <option value="3">P3</option>
                  <option value="4">P4</option>
                  <option value="5">P5</option>
                </select>
                <button class="control-btn" onClick=${()=>{rm()}} disabled=${W.value||un.value.trim()===""}>
                  Inject
                </button>
              </div>
            </div>

            <div class="ops-studio-group">
              <div class="ops-section-head">Selected Session</div>
              ${r?i`
                <div class="ops-detail-card">
                  <div class="ops-detail-title">${r.session_id}</div>
                  <div class="ops-detail-meta">
                    <span>Status: ${r.status??"unknown"}</span>
                    <span>Elapsed: ${r.elapsed_sec??0}s</span>
                    <span>Remaining: ${r.remaining_sec??0}s</span>
                  </div>
                  ${r.recent_events&&r.recent_events.length>0?i`
                    <pre class="ops-code-block compact">${cs(r.recent_events.slice(-3))}</pre>
                  `:null}
                </div>
              `:i`<div class="ops-empty">Select a team session to edit notes, inject tasks, or stop the run.</div>`}

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
                <button class="control-btn" onClick=${()=>{lm()}} disabled=${W.value||!r}>
                  Apply
                </button>
              </div>
              <textarea
                class="control-textarea"
                rows=${3}
                placeholder="Session message"
                value=${Ra.value}
                onInput=${c=>{Ra.value=c.target.value}}
                disabled=${W.value||!r}
              ></textarea>
              ${Oe.value==="task"?i`
                <input
                  class="control-input"
                  type="text"
                  placeholder="Injected task title"
                  value=${La.value}
                  onInput=${c=>{La.value=c.target.value}}
                  disabled=${W.value||!r}
                />
                <textarea
                  class="control-textarea"
                  rows=${2}
                  placeholder="Injected task description"
                  value=${Pa.value}
                  onInput=${c=>{Pa.value=c.target.value}}
                  disabled=${W.value||!r}
                ></textarea>
                <select
                  class="control-input ops-select"
                  value=${Zs.value}
                  onChange=${c=>{Zs.value=c.target.value}}
                  disabled=${W.value||!r}
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
                  disabled=${W.value||!r}
                />
                <button class="control-btn ghost" onClick=${()=>{cm()}} disabled=${W.value||!r}>
                  Stop
                </button>
              </div>
            </div>

            <div class="ops-studio-group">
              <div class="ops-section-head">Selected Keeper</div>
              ${l?i`
                <div class="ops-detail-card">
                  <div class="ops-detail-title">${l.name}</div>
                  <div class="ops-detail-meta">
                    <span>Autonomy: ${l.autonomy_level??"n/a"}</span>
                    <span>Generation: ${l.generation??0}</span>
                    <span>Goals: ${((v=l.active_goal_ids)==null?void 0:v.length)??0}</span>
                  </div>
                </div>
              `:i`<div class="ops-empty">Select a keeper to send a direct intervention.</div>`}

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
                <button class="control-btn" onClick=${()=>{dm()}} disabled=${W.value||!l||pn.value.trim()===""}>
                  Send Keeper Message
                </button>
              </div>
            </div>
          </section>
        </div>
      </div>
    </section>
  `}function pm({text:t}){if(!t)return null;const e=mm(t);return i`<div class="markdown-content">${e}</div>`}function mm(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],l=s.slice(r.length).trim(),p=[];for(a++;a<e.length&&!e[a].startsWith(r);)p.push(e[a]),a++;a++,n.push(i`<pre><code class=${l?`language-${l}`:""}>${p.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],l=s.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const $=e[a].replace("</think>","").trim();$&&r.push($),a++}const p=r.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${ds(p)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(i`<blockquote>${ds(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const o=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;o.push(r),a++}o.length>0&&n.push(i`<p>${ds(o.join(`
`))}</p>`)}return n}function ds(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const o=s[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(s[2]){const o=s[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(s[3]){const o=s[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else s[4]&&s[5]&&e.push(i`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const sn=_("posts"),ni=_([]),ai=_([]),mn=_(""),Ea=_(!1),vn=_(!1),Dn=_(""),Ia=_(null),Tt=_(null),si=_(!1),Xt=_(null),aa=_(null);async function Va(){Ea.value=!0,Dn.value="";try{const[t,e]=await Promise.all([gc(),$c()]);ni.value=t,ai.value=e,Xt.value=!0,aa.value=Date.now()}catch(t){Dn.value=t instanceof Error?t.message:"Failed to load council data",Xt.value=!1}finally{Ea.value=!1}}id(Va);async function po(){const t=mn.value.trim();if(t){vn.value=!0;try{const e=await hc(t);mn.value="",w(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Va()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";w(n,"error")}finally{vn.value=!1}}}async function vm(t){Ia.value=t,si.value=!0,Tt.value=null;try{Tt.value=await yc(t)}catch(e){Dn.value=e instanceof Error?e.message:"Failed to load debate status",Tt.value=null}finally{si.value=!1}}const Rr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],sa=_(null),fn=_([]),$e=_(!1),fe=_(null),_n=_("");function fm(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const _m=_(fm()),gn=_(!1);async function Li(t){fe.value=t,sa.value=null,fn.value=[],$e.value=!0;try{const e=await Fl(t);if(fe.value!==t)return;sa.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},fn.value=e.comments??[]}catch{fe.value===t&&(sa.value=null,fn.value=[])}finally{fe.value===t&&($e.value=!1)}}async function mo(t){const e=_n.value.trim();if(e){gn.value=!0;try{await Kl(t,_m.value,e),_n.value="",w("Comment posted","success"),await Li(t),qt()}catch{w("Failed to post comment","error")}finally{gn.value=!1}}}function gm(){const t=An.value;return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Rr.map(e=>i`
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
        <button class="control-btn ghost" onClick=${qt} disabled=${Cn.value}>
          ${Cn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function ii(){var e;const t=(e=se.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:i`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?i`<span class="feed-health-meta">Last sync: <${F} timestamp=${t.last_sync_at} /></span>`:i`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Lr({flair:t}){return t?i`<span class="post-flair ${t}">${t}</span>`:null}function $m(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function vo(t){return t.updated_at!==t.created_at}function oi(){var n;const t=((n=Rr.find(a=>a.id===An.value))==null?void 0:n.label)??An.value,e=Be.value.length;return i`
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
        <strong>${Bs.value?i`<${F} timestamp=${Bs.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function hm({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await Oo(t.id,n),qt()}catch{w("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>el(t.id)}>
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
              ${vo(t)?i`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${F} timestamp=${t.created_at} /></span>
            ${vo(t)?i`<span>Updated <${F} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?i`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${$m(t.content)}</div>
      </div>
    </div>
  `}function ym({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${F} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function bm({postId:t}){return i`
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
  `}function km({post:t}){fe.value!==t.id&&!$e.value&&Li(t.id);const e=async n=>{try{await Oo(t.id,n),qt()}catch{w("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>Rt("board")}>← Back to Board</button>
      <${C} title=${i`${t.title} <${Lr} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${pm} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${F} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?i`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${C} title="Comments (${$e.value?"...":fn.value.length})">
        ${$e.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${ym} comments=${fn.value} />`}
        <${bm} postId=${t.id} />
      <//>
    </div>
  `}function xm({debate:t}){const e=Ia.value===t.id;return i`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>vm(t.id)}
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
  `}function Sm({session:t}){return i`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.state?i`<span>State: ${t.state}</span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function Pr(){return Xt.value===null||Xt.value&&!aa.value?null:i`
    <div class="feed-health-banner ${Xt.value===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${Xt.value===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${aa.value?i`<span class="feed-health-meta">Last sync: <${F} timestamp=${aa.value} /></span>`:i`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Am(){const t=Xt.value===!1;return i`
    <div>
      <${Pr} />
      <${C} title="Start Debate" class="section">
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
        ${Dn.value?i`<div class="council-error">${Dn.value}</div>`:null}
      <//>

      <${C} title="Debates" class="section">
        <div class="council-list">
          ${ni.value.length===0?i`<div class="empty-state">${t?"No debates loaded (council feed degraded).":"No debates yet"}</div>`:ni.value.map(e=>i`<${xm} key=${e.id} debate=${e} />`)}
        </div>
      <//>

      <${C} title=${Ia.value?`Debate Detail (${Ia.value})`:"Debate Detail"} class="section">
        ${si.value?i`<div class="loading-indicator">Loading debate detail...</div>`:Tt.value?i`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${Tt.value.status}</span>
                  <span>Total arguments: ${Tt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${Tt.value.support_count}</span>
                  <span>Oppose: ${Tt.value.oppose_count}</span>
                  <span>Neutral: ${Tt.value.neutral_count}</span>
                </div>
                ${Tt.value.summary_text?i`<pre class="council-detail">${Tt.value.summary_text}</pre>`:null}
              `:i`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function wm(){const t=Xt.value===!1;return i`
    <div>
      <${Pr} />
      <${C} title="Voting Sessions" class="section">
        <div class="council-list">
          ${ai.value.length===0?i`<div class="empty-state">${t?"No sessions loaded (council feed degraded).":"No active sessions"}</div>`:ai.value.map(e=>i`<${Sm} key=${e.id} session=${e} />`)}
        </div>
      <//>
    </div>
  `}function Cm(){const t=sn.value;return i`
    <div class="overview-sub-tabs" style="margin-bottom: 12px;">
      <button class="sub-tab-btn ${t==="posts"?"active":""}" onClick=${()=>{sn.value="posts"}}>Posts</button>
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{sn.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{sn.value="voting"}}>Voting</button>
    </div>
  `}function Tm(){var a,s;const t=Be.value,e=Cn.value,n=((s=(a=se.value)==null?void 0:a.data_quality)==null?void 0:s.board_contract_ok)===!1;return i`
    <div>
      <${ii} />
      <${oi} />
      <${gm} />
      ${e?i`<div class="loading-indicator">Loading board...</div>`:t.length===0?i`
              <div class="empty-state">
                ${n?"No posts loaded (board feed degraded). Check board contract sync.":ue.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
              </div>
            `:i`<div class="board-post-list">
              ${t.map(o=>i`<${hm} key=${o.id} post=${o} />`)}
            </div>`}
    </div>
  `}function Nm(){var s,o;const t=Be.value,e=nt.value.postId,n=((o=(s=se.value)==null?void 0:s.data_quality)==null?void 0:o.board_contract_ok)===!1,a=sn.value;if(rt(()=>{(a==="debates"||a==="voting")&&Va()},[a]),e){const r=t.find(l=>l.id===e)??(fe.value===e?sa.value:null);return!r&&fe.value!==e&&!$e.value&&Li(e),r?i`
          <${ii} />
          <${oi} />
          <${km} post=${r} />
        `:i`
          <div>
            <${ii} />
            <${oi} />
            <button class="back-btn" onClick=${()=>Rt("board")}>← Back to Board</button>
            ${$e.value?i`<div class="loading-indicator">Loading post...</div>`:i`
                  <div class="empty-state">
                    ${n?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return i`
    <${Cm} />
    ${a==="debates"?i`<${Am} />`:a==="voting"?i`<${wm} />`:i`<${Tm} />`}
  `}const Rm=40;function Lm({items:t,itemHeight:e,overscan:n=5,renderItem:a,getKey:s,className:o=""}){const r=wo(null),[l,p]=Ua({start:0,end:30}),$=t.length>Rm;if(rt(()=>{if(!$)return;const c=r.current;if(!c)return;let y=!1;const S=()=>{const{scrollTop:E,clientHeight:N}=c,R=Math.max(0,Math.floor(E/e)-n),X=Math.min(t.length,Math.ceil((E+N)/e)+n);p(H=>H.start===R&&H.end===X?H:{start:R,end:X})};let T=!1;const P=()=>{T||y||(T=!0,requestAnimationFrame(()=>{y||S(),T=!1}))},K=new ResizeObserver(()=>{y||S()});return S(),c.addEventListener("scroll",P,{passive:!0}),K.observe(c),()=>{y=!0,c.removeEventListener("scroll",P),K.disconnect()}},[$,t.length,e,n]),!$)return i`
      <div class=${o}>
        ${t.map((c,y)=>a(c,y))}
      </div>
    `;const m=t.length*e,d=l.start*e,v=t.slice(l.start,l.end);return i`
    <div ref=${r} class=${o}>
      <div class="virtual-list-spacer" style=${{height:`${m}px`,position:"relative"}}>
        <div
          class="virtual-list-viewport"
          style=${{position:"absolute",top:0,left:0,right:0,willChange:"transform",transform:`translateY(${d}px)`}}
        >
          ${v.map((c,y)=>{const S=l.start+y;return i`<div key=${s(c)}>${a(c,S)}</div>`})}
        </div>
      </div>
    </div>
  `}function Pm(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function Dm(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function Em(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const Dr=120,Im=12,Mm=16,Om=12,ri=_("all"),zm={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},qm={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function jm(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Fm(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:Pm(t),actor:Dm(t),content:Em(t),timestamp:new Date(t.timestamp).toISOString()}}function Km(t,e){var s;const n=(s=t.assignee)==null?void 0:s.trim(),a=t.updated_at??t.created_at;return!n||!a?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:a}}function Hm(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function Hn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function li(t){return t.last_heartbeat??Hn(t.last_turn_ago_s)??Hn(t.last_proactive_ago_s)??Hn(t.last_handoff_ago_s)??Hn(t.last_compaction_ago_s)}function Um(t,e){const n=li(t);if(!n)return null;const a=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${a}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${a}`,timestamp:n}}function It(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const ci=wt(()=>{const t=Sn.value.map(jm),e=ca.value.map(Fm),n=[...yt.value].sort((o,r)=>It(r.updated_at??r.created_at??0)-It(o.updated_at??o.created_at??0)).slice(0,Im).map(Km).filter(o=>o!==null),a=[...Be.value].sort((o,r)=>It(r.updated_at||r.created_at)-It(o.updated_at||o.created_at)).slice(0,Mm).map(Hm),s=[...Jt.value].sort((o,r)=>It(li(r)??0)-It(li(o)??0)).slice(0,Om).map(Um).filter(o=>o!==null);return[...t,...e,...n,...a,...s].sort((o,r)=>It(r.timestamp)-It(o.timestamp))}),Bm=wt(()=>{const t=ci.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),Wm=wt(()=>{const t=ri.value;return(t==="all"?ci.value:ci.value.filter(n=>n.kind===t)).slice(0,Dr)}),Gm=wt(()=>{const t=Wa.value,e={activeAssignedCount:0,lastActivityAt:null,lastActivityText:null};return At.value.map(n=>({agent:n,motion:t.get(n.name.trim().toLowerCase())??e})).sort((n,a)=>{const s=a.motion.activeAssignedCount-n.motion.activeAssignedCount;return s!==0?s:It(a.motion.lastActivityAt??0)-It(n.motion.lastActivityAt??0)})});function Jm(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function tn({label:t,value:e,color:n}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function Vm({row:t}){return i`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${Jm(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${qm[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function Qm(){const t=Bm.value,e=Wm.value,n=e[0],a=Gm.value;return i`
    <div class="stats-grid">
      <${tn} label="Visible rows" value=${e.length} />
      <${tn} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${tn} label="Keeper signals" value=${t.keepers} color="#4ade80" />
      <${tn} label="Board signals" value=${t.board} color="#fbbf24" />
      <${tn} label="SSE events" value=${In.value} color="#c084fc" />
    </div>

    <${C} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(s=>i`
            <button
              class="goal-filter-btn ${ri.value===s?"active":""}"
              onClick=${()=>{ri.value=s}}
            >
              ${zm[s]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${Ft.value?"":"pill-stale"}">
            ${Ft.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?i`Latest: <${F} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${Dr} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      ${e.length===0?i`<div class="terminal-feed"><div class="empty-state">Waiting for live or snapshot signals...</div></div>`:i`<${Lm}
            items=${e}
            itemHeight=${28}
            overscan=${8}
            getKey=${s=>s.id}
            renderItem=${s=>i`<${Vm} row=${s} />`}
            className="terminal-feed"
          />`}
    <//>

    <${C} title="Agent Motion" class="section">
      <div class="activity-motion-list">
        ${a.length===0?i`<div class="empty-state">No active agents</div>`:a.map(({agent:s,motion:o})=>i`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${s.name}</div>
                  <div class="activity-motion-meta">
                    ${o.activeAssignedCount>0?`${o.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${o.lastActivityAt?i` · <${F} timestamp=${o.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${o.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function Er({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,s=e/2,o=2*Math.PI*a,r=o*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),i`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${s}" cy="${s}" r="${a}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${l}" 
          cx="${s}" cy="${s}" r="${a}" 
          stroke-width="${n}" 
          stroke-dasharray="${o}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${l}">${Math.round(t*100)}%</span>
    </div>
  `}const us=600*1e3,Ym=1200*1e3,fo=.8;function Qt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Ae(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Xm(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function Zm(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function tv(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function ev(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function nv(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function av(t){var p,$;const e=Wa.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-Qt(n)):Number.POSITIVE_INFINITY,s=!!((p=t.current_task)!=null&&p.trim())||e.activeAssignedCount>0;let o="watching",r="ok",l="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",r="bad",l=n?"Offline or inactive":"No recent presence"):a>Ym?(o="quiet",r="bad",l=s?"Working without a fresh signal":"No fresh agent signal"):s?(o="working",r=a>us?"warn":"ok",l=a>us?"Execution looks quiet for too long":"Task and live signal aligned"):a>us?(o="quiet",r="warn",l="Quiet but still reachable"):t.status==="idle"&&(o="watching",r="ok",l="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:r,focus:(($=t.current_task)==null?void 0:$.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:l}}function sv(t){const e=Jo.value.get(t.name)??"idle",n=Vo.value.has(t.name),a=t.context_ratio??0;let s="healthy",o="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(s="critical",o="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=fo)&&(s="warning",o="warn",r=a>=fo?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:s,tone:o,focus:ev(t),note:r}}function en({label:t,value:e,color:n,caption:a}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?i`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function iv({item:t}){const e=t.kind==="agent"?()=>Ie(t.agent.name):()=>fa(t.keeper);return i`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?i`<span><${F} timestamp=${t.timestamp} /></span>`:i`<span>No signal</span>`}
      </div>
    </button>
  `}function _o({row:t}){const{agent:e,motion:n}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Ie(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Er} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Lt} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${Xm(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?i`<span>Signal <${F} timestamp=${t.lastSignalAt} /></span>`:i`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
        ${e.last_seen?i`<span>Seen <${F} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?i`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function ov({row:t}){const{keeper:e}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>fa(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Er} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Lt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Zm(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?i`<span>Heartbeat <${F} timestamp=${e.last_heartbeat} /></span>`:i`<span>No heartbeat</span>`}
        <span>${nv(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${tv(e.context_ratio)}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?i`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function rv(){const t=[...At.value].map(av).sort((m,d)=>{const v=Ae(d.tone)-Ae(m.tone);if(v!==0)return v;const c=d.activeTaskCount-m.activeTaskCount;return c!==0?c:Qt(d.lastSignalAt)-Qt(m.lastSignalAt)}),e=[...Jt.value].map(sv).sort((m,d)=>{const v=Ae(d.tone)-Ae(m.tone);if(v!==0)return v;const c=(d.keeper.context_ratio??0)-(m.keeper.context_ratio??0);return c!==0?c:Qt(d.keeper.last_heartbeat)-Qt(m.keeper.last_heartbeat)}),n=t.filter(m=>m.state!=="offline"),a=t.filter(m=>m.state==="offline"),s=n.length,o=t.filter(m=>m.state==="working").length,r=t.filter(m=>m.lastSignalAt&&Date.now()-Qt(m.lastSignalAt)<=12e4).length,l=t.filter(m=>m.tone!=="ok"),p=e.filter(m=>m.tone!=="ok"),$=[...p.map(m=>({kind:"keeper",key:`keeper-${m.keeper.name}`,tone:m.tone,title:m.keeper.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.keeper.last_heartbeat??null,keeper:m.keeper})),...l.map(m=>({kind:"agent",key:`agent-${m.agent.name}`,tone:m.tone,title:m.agent.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.lastSignalAt,agent:m.agent}))].sort((m,d)=>{const v=Ae(d.tone)-Ae(m.tone);return v!==0?v:Qt(d.timestamp)-Qt(m.timestamp)}).slice(0,8);return i`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${en} label="Agents online" value=${s} color="#4ade80" caption="active + idle" />
        <${en} label="Working now" value=${o} color="#fbbf24" caption="task or claimed load" />
        <${en} label="Fresh signals" value=${r} color="#22d3ee" caption="within last 2 minutes" />
        <${en} label="Agent alerts" value=${l.length} color=${l.length>0?"#fb7185":"#4ade80"} caption="quiet or offline" />
        <${en} label="Keeper alerts" value=${p.length} color=${p.length>0?"#fb7185":"#4ade80"} caption="stale or high pressure" />
      </div>

      <${C} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${$.length===0?i`<div class="empty-state">No agent or keeper alerts right now</div>`:$.map(m=>i`<${iv} key=${m.key} item=${m} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${C} title="Active Agents" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Live agents stay grouped here first so execution drift is visible before you scan offline history.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?i`<div class="empty-state">No active agents visible</div>`:n.map(m=>i`<${_o} key=${m.agent.name} row=${m} />`)}
          </div>
        <//>

        <${C} title="Keeper Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?i`<div class="empty-state">No keepers active</div>`:e.map(m=>i`<${ov} key=${m.keeper.name} row=${m} />`)}
          </div>
        <//>

        <${C} title="Offline Agents" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who dropped out of the live loop</h2>
            <p class="monitor-subheadline">Offline rows are separated so they do not drown the active execution monitor.</p>
          </div>
          <div class="monitor-list">
            ${a.length===0?i`<div class="empty-state">No offline agents right now</div>`:a.map(m=>i`<${_o} key=${m.agent.name} row=${m} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Ma=_("all"),Oa=_("all"),di=wt(()=>{let t=wn.value;return Ma.value!=="all"&&(t=t.filter(e=>e.horizon===Ma.value)),Oa.value!=="all"&&(t=t.filter(e=>e.status===Oa.value)),t}),lv=wt(()=>{const t={short:[],mid:[],long:[]};for(const e of di.value){const n=t[e.horizon];n&&n.push(e)}return t}),cv=wt(()=>{const t=Array.from(Uo.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function dv(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Pi(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function ia(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function uv(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function go(t){return t.toFixed(4)}function $o(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function pv({goal:t}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ia(t.horizon)}">
            ${Pi(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${dv(t.priority)}</span>
          ${t.metric?i`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?i`<span class="goal-due">Due: <${F} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?i`
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
  `}function ho({label:t,timestamp:e,source:n,note:a}){return i`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${a?i`<div class="planning-freshness-source">${a}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?i`<${F} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function ps({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,s)=>s.priority-a.priority);return i`
    <${C} title="${Pi(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(a=>i`<${pv} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function mv(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>i`
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
        ${["all","active","completed","paused"].map(t=>i`
          <button
            class="goal-filter-btn ${Oa.value===t?"active":""}"
            onClick=${()=>{Oa.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function vv(){const t=wn.value,e=t.filter(s=>s.status==="active").length,n=t.filter(s=>s.status==="completed").length,a={short:0,mid:0,long:0};for(const s of t)s.horizon in a&&a[s.horizon]++;return i`
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
  `}function fv({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return i`
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
          <span>Elapsed ${uv(t.elapsed_seconds)}</span>
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
  `}function ms({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return i`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?i`<${F} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function _v(){const{todo:t,inProgress:e,done:n}=Go.value;return i`
    <${C} title="Task Backlog" class="section">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?i`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>i`<${ms} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?i`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>i`<${ms} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?i`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>i`<${ms} key=${a.id} task=${a} />`)}
          ${n.length>20?i`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function gv(){const t=lv.value,e=cv.value,n=e.filter(l=>l.status==="running").length,a=e.filter(l=>l.recoverable).length,s=wn.value.filter(l=>l.status==="active").length,o=Fs.value,r=o==="idle"?"No loop running":o==="error"?Ks.value??"MDAL snapshot unavailable":"Current loop snapshot";return i`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${s}</div>
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

      <${C} title="Planning Surface" class="section">
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

      <${C} title="Goal Pipeline" class="section">
        <${vv} />
        <${mv} />
      <//>

      ${Re.value&&wn.value.length===0?i`<div class="loading-indicator">Loading goals...</div>`:di.value.length===0?i`<div class="empty-state">No goals match the current filters</div>`:i`
              <${ps} horizon="short" items=${t.short??[]} />
              <${ps} horizon="mid" items=${t.mid??[]} />
              <${ps} horizon="long" items=${t.long??[]} />
            `}

      <${C} title="MDAL Loops" class="section">
        ${Le.value&&e.length===0?i`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&o==="error"?i`
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
                  ${e.map(l=>i`<${fv} key=${l.loop_id} loop=${l} />`)}
                </div>
              `}
      <//>

      <${_v} />
    </div>
  `}const Te=_(""),vs=_("ability_check"),fs=_("10"),_s=_("12"),Un=_(""),Bn=_("idle"),Yt=_(""),Wn=_("keeper-late"),gs=_("player"),$s=_(""),St=_("idle"),hs=_(null),Gn=_(""),ys=_(""),bs=_("player"),ks=_(""),xs=_(""),Ss=_(""),$n=_("20"),As=_("20"),ws=_(""),Jn=_("idle"),ui=_(null),Ir=_("overview"),Cs=_("all"),Ts=_("all"),Ns=_("all"),$v=12e4,Qa=_(null),yo=_(Date.now());function hv(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function yv(t,e){return e>0?Math.round(t/e*100):0}const bv={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},kv={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Vn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function xv(t){const e=t.trim().toLowerCase();return bv[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Sv(t){const e=t.trim().toLowerCase();return kv[e]??"상황에 따라 선택되는 전술 액션입니다."}function ee(t){return typeof t=="object"&&t!==null}function gt(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function Mt(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function En(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const Av=new Set(["str","dex","con","int","wis","cha"]);function wv(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(s){throw new Error(`능력치 JSON 파싱 실패: ${s instanceof Error?s.message:"invalid json"}`)}if(!ee(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([s,o])=>{const r=s.trim();if(r){if(typeof o=="number"&&Number.isFinite(o)){a[r]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const l=Number.parseFloat(o.trim());if(Number.isFinite(l)){a[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function Cv(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt($n.value.trim(),10);Number.isFinite(a)&&a>n&&($n.value=String(n))}function pi(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Tv(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Nv(t){Ir.value=t}function Mr(t){const e=Qa.value;return e==null||e<=t}function Rv(t){const e=Qa.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function za(){Qa.value=null}function Or(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Lv(t,e){Or(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Qa.value=Date.now()+$v,w("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function oa(t){return Mr(t)?(w("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function mi(t,e,n){return Or([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Pv({hp:t,max:e}){const n=yv(t,e),a=hv(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function Dv({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Ev({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function zr({actor:t}){var p,$,m,d;const e=(p=t.archetype)==null?void 0:p.trim(),n=($=t.persona)==null?void 0:$.trim(),a=(m=t.portrait)==null?void 0:m.trim(),s=(d=t.background)==null?void 0:d.trim(),o=t.traits??[],r=t.skills??[],l=Object.entries(t.stats_raw??{}).filter(([v,c])=>Number.isFinite(c)).filter(([v])=>!Av.has(v.toLowerCase()));return i`
    <div class="trpg-actor">
      ${a?i`
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
        <${Ev} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Pv} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Dv} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${Vn(e)}</div>`:null}
      ${s?i`<div class="trpg-actor-meta">Background: ${s}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${l.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${l.map(([v,c])=>i`
                <span class="trpg-custom-stat-chip">${Vn(v)} ${c}</span>
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
                  <span class="trpg-annot-name">${Vn(v)}</span>
                  <span class="trpg-annot-desc">${xv(v)}</span>
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
                  <span class="trpg-annot-name">${Vn(v)}</span>
                  <span class="trpg-annot-desc">${Sv(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Iv({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function qr({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?i`<div class="empty-state" style="font-size:13px">${e}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var s;return i`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Tv(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${pi(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(s=n.dice_roll.rolls)==null?void 0:s.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${F} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Mv({events:t}){const e="__none__",n=Cs.value,a=Ts.value,s=Ns.value,o=Array.from(new Set(t.map(pi).map(d=>d.trim()).filter(d=>d!==""))).sort((d,v)=>d.localeCompare(v)),r=Array.from(new Set(t.map(d=>(d.type??"").trim()).filter(d=>d!==""))).sort((d,v)=>d.localeCompare(v)),l=t.some(d=>(d.type??"").trim()===""),p=Array.from(new Set(t.map(d=>(d.phase??"").trim()).filter(d=>d!==""))).sort((d,v)=>d.localeCompare(v)),$=t.some(d=>(d.phase??"").trim()===""),m=t.filter(d=>{if(n!=="all"&&pi(d)!==n)return!1;const v=(d.type??"").trim(),c=(d.phase??"").trim();if(a===e){if(v!=="")return!1}else if(a!=="all"&&v!==a)return!1;if(s===e){if(c!=="")return!1}else if(s!=="all"&&c!==s)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${d=>{Cs.value=d.target.value}}>
          <option value="all">all</option>
          ${o.map(d=>i`<option value=${d}>${d}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${d=>{Ts.value=d.target.value}}>
          <option value="all">all</option>
          ${l?i`<option value=${e}>(none)</option>`:null}
          ${r.map(d=>i`<option value=${d}>${d}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${s} onChange=${d=>{Ns.value=d.target.value}}>
          <option value="all">all</option>
          ${$?i`<option value=${e}>(none)</option>`:null}
          ${p.map(d=>i`<option value=${d}>${d}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Cs.value="all",Ts.value="all",Ns.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${m.length} / 전체 ${t.length}
      </span>
    </div>
    <${qr} events=${m.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Ov({outcome:t}){if(!t)return null;const e=o=>{const r=o.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",s=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${s?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${s}</div>`:null}
    </div>
  `}function jr({state:t}){const e=t.history??[];return e.length===0?null:i`
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
  `}function zv({state:t,nowMs:e}){var $;const n=Ut.value||(($=t.session)==null?void 0:$.room)||"",a=Bn.value,s=t.party??[];if(!s.find(m=>m.id===Te.value)&&s.length>0){const m=s[0];m&&(Te.value=m.id)}const r=async()=>{var d,v;if(!n){w("Room ID가 비어 있습니다.","error");return}if(!oa(e))return;const m=((d=t.current_round)==null?void 0:d.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(mi("라운드 실행",n,m)){Bn.value="running";try{const c=await sc(n);ui.value=c,Bn.value="ok";const y=ee(c.summary)?c.summary:null,S=y?En(y,"advanced",!1):!1,T=y?gt(y,"progress_reason",""):"";w(S?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${T?`: ${T}`:""}`,S?"success":"warning"),jt()}catch(c){ui.value=null,Bn.value="error";const y=c instanceof Error?c.message:"라운드 실행에 실패했습니다.";w(y,"error")}finally{za()}}},l=async()=>{var d,v;if(!n||!oa(e))return;const m=((d=t.current_round)==null?void 0:d.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(mi("턴 강제 진행",n,m))try{await rc(n),w("턴을 다음 단계로 이동했습니다.","success"),jt()}catch{w("턴 이동에 실패했습니다.","error")}finally{za()}},p=async()=>{if(!n||!oa(e))return;const m=Te.value.trim();if(!m){w("먼저 Actor를 선택하세요.","warning");return}const d=Number.parseInt(fs.value,10),v=Number.parseInt(_s.value,10);if(Number.isNaN(d)||Number.isNaN(v)){w("stat/dc는 숫자여야 합니다.","warning");return}const c=Number.parseInt(Un.value,10),y=Un.value.trim()===""||Number.isNaN(c)?void 0:c;try{await oc({roomId:n,actorId:m,action:vs.value.trim()||"ability_check",statValue:d,dc:v,rawD20:y}),w("주사위 판정을 기록했습니다.","success"),jt()}catch{w("주사위 판정 기록에 실패했습니다.","error")}};return i`
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
            ${s.map(m=>i`<option value=${m.id}>${m.name} (${m.id})</option>`)}
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

      ${a!=="idle"?i`<div class="trpg-run-status ${a}">${a==="running"?"처리 중...":a==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function qv({state:t}){var s;const e=Ut.value||((s=t.session)==null?void 0:s.room)||"",n=Jn.value,a=async()=>{if(!e){w("Room ID가 비어 있습니다.","warning");return}const o=Gn.value.trim(),r=ys.value.trim();if(!r&&!o){w("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt($n.value.trim(),10),p=Number.parseInt(As.value.trim(),10),$=Number.isFinite(p)?Math.max(1,p):20,m=Number.isFinite(l)?Math.max(0,Math.min($,l)):$;let d={};try{d=wv(ws.value)}catch(v){w(v instanceof Error?v.message:"능력치 JSON 오류","error");return}Jn.value="spawning";try{const v=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,c=await lc(e,{actor_id:o||void 0,name:r||void 0,role:bs.value,idempotencyKey:v,portrait:xs.value.trim()||void 0,background:Ss.value.trim()||void 0,hp:m,max_hp:$,alive:m>0,stats:Object.keys(d).length>0?d:void 0}),y=typeof c.actor_id=="string"?c.actor_id.trim():"";if(!y)throw new Error("생성 응답에 actor_id가 없습니다.");const S=ks.value.trim();S&&await cc(e,y,S),Te.value=y,Yt.value=y,o||(Gn.value=""),Jn.value="ok",w(`Actor 생성 완료: ${y}`,"success"),await jt()}catch(v){Jn.value="error",w(v instanceof Error?v.message:"Actor 생성에 실패했습니다.","error")}};return i`
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
              onInput=${o=>{const r=o.target.value;As.value=r,Cv(r)}}
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

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function jv({state:t,nowMs:e}){var v;const n=Ut.value||((v=t.session)==null?void 0:v.room)||"",a=t.join_gate,s=hs.value,o=ee(s)?s:null,r=(t.party??[]).filter(c=>c.role!=="dm"),l=Yt.value.trim(),p=r.some(c=>c.id===l),$=p?l:l?"__manual__":"",m=async()=>{const c=Yt.value.trim(),y=Wn.value.trim();if(!n||!c){w("Room/Actor가 필요합니다.","warning");return}St.value="checking";try{const S=await dc(n,c,y||void 0);hs.value=S,St.value="ok",w("참가 가능 여부를 갱신했습니다.","success")}catch(S){St.value="error";const T=S instanceof Error?S.message:"참가 가능 여부 확인에 실패했습니다.";w(T,"error")}},d=async()=>{var P,K;const c=Yt.value.trim(),y=Wn.value.trim(),S=$s.value.trim();if(!n||!c||!y){w("Room/Actor/Keeper가 필요합니다.","warning");return}if(!oa(e))return;const T=((P=t.current_round)==null?void 0:P.phase)??((K=t.session)==null?void 0:K.status)??"unknown";if(mi("Mid-Join 승인 요청",n,T)){St.value="requesting";try{const E=await uc({room_id:n,actor_id:c,keeper_name:y,role:gs.value,...S?{name:S}:{}});hs.value=E;const N=ee(E)?En(E,"granted",!1):!1,R=ee(E)?gt(E,"reason_code",""):"";N?w("Mid-Join이 승인되었습니다.","success"):w(`Mid-Join이 거절되었습니다${R?`: ${R}`:""}`,"warning"),St.value=N?"ok":"error",jt()}catch(E){St.value="error";const N=E instanceof Error?E.message:"Mid-Join 요청에 실패했습니다.";w(N,"error")}finally{za()}}};return i`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${a!=null&&a.phase_open?"OPEN":"CLOSED"}</strong>
        ${a!=null&&a.window?i`<span style="margin-left:8px;">(${a.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(a==null?void 0:a.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <select
            value=${$}
            onChange=${c=>{const y=c.target.value;if(y==="__manual__"){(p||!l)&&(Yt.value="");return}Yt.value=y}}
          >
            <option value="">Actor 선택</option>
            ${r.map(c=>i`
              <option value=${c.id}>${c.name} (${c.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${$==="__manual__"?i`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${Yt.value}
                onInput=${c=>{Yt.value=c.target.value}}
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
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${En(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Mt(o,"effective_score",0)}/${Mt(o,"required_points",0)}</span>
            ${gt(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${gt(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Fr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Kr({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Hr(){const t=ui.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=ee(e)?e:null,s=(Array.isArray(t.statuses)?t.statuses:[]).filter(ee).slice(-8),o=t.canon_check,r=ee(o)?o:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(R=>typeof R=="string").slice(0,3):[],p=r&&Array.isArray(r.violations)?r.violations.filter(R=>typeof R=="string").slice(0,3):[],$=n?En(n,"advanced",!1):!1,m=n?gt(n,"progress_reason",""):"",d=n?gt(n,"progress_detail",""):"",v=n?Mt(n,"player_successes",0):0,c=n?Mt(n,"player_required_successes",0):0,y=n?En(n,"dm_success",!1):!1,S=n?Mt(n,"timeouts",0):0,T=n?Mt(n,"unavailable",0):0,P=n?Mt(n,"reprompts",0):0,K=n?Mt(n,"npc_attacks",0):0,E=n?Mt(n,"keeper_timeout_sec",0):0,N=n?Mt(n,"roll_audit_count",0):0;return i`
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
        ${m?i`<div style="margin-top:4px; font-size:12px;">${m}</div>`:null}
        ${d?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${d}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${P}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${K}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${E||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${N}</div></div>
      </div>

      ${s.length>0?i`
          <div class="trpg-round-list">
            ${s.map(R=>{const X=gt(R,"status","unknown"),H=gt(R,"actor_id","-"),Pt=gt(R,"role","-"),mt=gt(R,"reason",""),vt=gt(R,"action_type",""),B=gt(R,"reply","");return i`
                <div class="trpg-round-item ${X.includes("fallback")||X.includes("timeout")?"failed":"active"}">
                  <span>${H} (${Pt})</span>
                  <span style="margin-left:auto; font-size:11px;">${X}</span>
                  ${vt?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${vt}</div>`:null}
                  ${mt?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${mt}</div>`:null}
                  ${B?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${B.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${gt(r,"status","unknown")}</strong>
            </div>
            ${p.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${p.map(R=>i`<div>violation: ${R}</div>`)}
                </div>`:null}
            ${l.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${l.map(R=>i`<div>warning: ${R}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Fv({state:t,nowMs:e}){var r,l,p;const n=Ut.value||((r=t.session)==null?void 0:r.room)||"",a=((l=t.current_round)==null?void 0:l.phase)??((p=t.session)==null?void 0:p.status)??"unknown",s=Mr(e),o=Rv(e);return i`
    <${C} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${s?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${s?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${s?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${o}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${a||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${s?i`<button class="trpg-run-btn recommend" onClick=${()=>Lv(n,a)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{za(),w("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Kv({active:t}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Nv(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Hv({state:t}){const e=t.party??[],n=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${C} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${C} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${qr} events=${n.slice(-20)} />
        <//>

        ${t.map?i`
            <${C} title="맵" style="margin-top:16px;">
              <${Iv} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${C} title="현재 라운드">
          <${Kr} state=${t} />
        <//>

        <${C} title="기여도" style="margin-top:16px;">
          <${Fr} state=${t} />
        <//>

        <${C} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>i`<${zr} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?i`
            <${C} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${jr} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Uv({state:t}){const e=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${C} title=${`이벤트 타임라인 (${e.length})`}>
          <${Mv} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${C} title="최근 라운드 결과">
          <${Hr} />
        <//>

        <${C} title="현재 라운드" style="margin-top:16px;">
          <${Kr} state=${t} />
        <//>
      </div>
    </div>
  `}function Bv({state:t,nowMs:e}){const n=t.party??[];return i`
    <div>
      <${Fv} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${C} title="조작 패널">
            <${zv} state=${t} nowMs=${e} />
          <//>

          <${C} title="Actor Spawn" style="margin-top:16px;">
            <${qv} state=${t} />
          <//>

          <${C} title="Mid-Join Gate" style="margin-top:16px;">
            <${jv} state=${t} nowMs=${e} />
          <//>

          <${C} title="최근 라운드 결과" style="margin-top:16px;">
            <${Hr} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${C} title="기여도" style="margin-top:0;">
            <${Fr} state=${t} />
          <//>

          <${C} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>i`<${zr} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?i`
              <${C} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${jr} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Wv(){var l,p,$,m,d;const t=Ho.value,e=Us.value;if(rt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const v=window.setInterval(()=>{yo.value=Date.now()},1e3);return()=>{window.clearInterval(v)}},[]),e&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>jt()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],s=t.outcome,o=Ir.value,r=yo.value;return i`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Ut.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((p=t.current_round)==null?void 0:p.phase)??(($=t.session)==null?void 0:$.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>jt()}>새로고침</button>
      </div>

      <${Ov} outcome=${s} />

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

      <${Kv} active=${o} />

      ${o==="overview"?i`<${Hv} state=${t} />`:o==="timeline"?i`<${Uv} state=${t} />`:i`<${Bv} state=${t} nowMs=${r} />`}
    </div>
  `}const Di="masc_dashboard_agent_name";function Gv(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Di);return e??n??"dashboard"}const ht=_(Gv()),hn=_(""),yn=_(""),qa=_(""),Ur=_(null),ja=_(null),bn=_(!1),Pe=_(!1),kn=_(!1),xn=_(!1),Fa=_(!1),Ka=_(!1),Ya=_(!1);function Ha(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function ra(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function Br(t){return!t||t.length===0?"none":t.join(", ")}function Jv(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Ha(t.quiet_start)}-${Ha(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${ra(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${ra(t.interval_s)}.`:`Lodge ticks every ${ra(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function Ge(){qe();try{await ne()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function Ei(t){const e=t.trim();ht.value=e,e&&localStorage.setItem(Di,e)}function Vv(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function vi(){const t=ht.value.trim();if(t){kn.value=!0;try{const e=await mc(t),n=Vv(e);n&&Ei(n),Ya.value=!0,await Ge(),w(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";w(n,"error")}finally{kn.value=!1}}}async function Qv(){const t=ht.value.trim();if(t){xn.value=!0;try{await qo(t),Ya.value=!1,await Ge(),w(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";w(n,"error")}finally{xn.value=!1}}}async function Yv(){const t=ht.value.trim();if(t)try{await qo(t)}catch{}localStorage.removeItem(Di),Ei("dashboard"),Ya.value=!1,await vi()}async function Xv(){const t=ht.value.trim();if(t){Fa.value=!0;try{await vc(t),await Ge(),w("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";w(n,"error")}finally{Fa.value=!1}}}async function bo(){const t=ht.value.trim(),e=hn.value.trim();if(!(!t||!e)){bn.value=!0;try{await zo(t,e),hn.value="",await Ge(),w("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";w(a,"error")}finally{bn.value=!1}}}async function Zv(){const t=yn.value.trim(),e=qa.value.trim()||"Created from dashboard";if(t){Pe.value=!0;try{await pc(t,e,1),yn.value="",qa.value="",await Ge(),w("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";w(a,"error")}finally{Pe.value=!1}}}async function ko(){const t=ht.value.trim()||"dashboard";Ka.value=!0,ja.value=null;try{const e=await On({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=$i(e.result);Ur.value=n,await Ge(),n!=null&&n.skipped_reason?w(n.skipped_reason,"warning"):w(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";ja.value=n,w(n,"error")}finally{Ka.value=!1}}function tf({runtime:t}){var s,o;const e=Ur.value??(t==null?void 0:t.last_tick_result)??null;if(ja.value)return i`<div class="control-result-box is-error">${ja.value}</div>`;if(!e)return i`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((s=e.skipped_rows)==null?void 0:s.slice(0,3))??[],a=((o=e.passed_rows)==null?void 0:o.slice(0,3))??[];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?i`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">Last acted: ${Br(e.acted_names)}</div>
      ${e.skipped_reason?i`<div class="control-status-copy">${e.skipped_reason}</div>`:null}
      ${e.activity_report?i`<pre class="control-transcript-text">${e.activity_report}</pre>`:null}
      ${n.length>0?i`
            <div class="control-result-list">
              ${n.map(r=>i`<div>${r.name}: ${r.reason??"skipped"}</div>`)}
            </div>
          `:null}
      ${a.length>0?i`
            <div class="control-result-list">
              ${a.map(r=>i`<div>${r.name}: ${r.reason??"passed"}</div>`)}
            </div>
          `:null}
    </div>
  `}function ef(t){return t.find(n=>n.name===on.value)??t[0]??null}function nf(){var a,s;const t=Jt.value,e=((a=se.value)==null?void 0:a.lodge)??null,n=ef(t);return rt(()=>{vi()},[]),rt(()=>{var r;const o=((r=t[0])==null?void 0:r.name)??"";if(!on.value&&o){Yn(o);return}on.value&&!t.some(l=>l.name===on.value)&&Yn(o)},[t.map(o=>o.name).join("|")]),i`
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
          value=${ht.value}
          onInput=${o=>Ei(o.target.value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{vi()}}
            disabled=${kn.value||ht.value.trim()===""}
          >
            ${kn.value?"Joining...":Ya.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Qv()}}
            disabled=${xn.value||ht.value.trim()===""}
          >
            ${xn.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Yv()}}
            disabled=${kn.value||xn.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Xv()}}
            disabled=${Fa.value||ht.value.trim()===""}
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
            onClick=${()=>{bo()}}
            disabled=${bn.value||hn.value.trim()===""||ht.value.trim()===""}
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
          ${t.length===0?i`<option value="">No keepers available</option>`:t.map(o=>i`<option value=${o.name}>${o.name}</option>`)}
        </select>

        <${ir} keeper=${n} />
        <${rr}
          actor=${ht.value.trim()||"dashboard"}
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
          <p class="control-help">${Jv(e)}</p>
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
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${Br((s=e==null?void 0:e.last_tick_result)==null?void 0:s.acted_names)}
        </div>
        ${e!=null&&e.last_skip_reason?i`<div class="control-status-copy">Last skip reason: ${e.last_skip_reason}</div>`:null}

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{ko()}}
            disabled=${Ka.value}
          >
            ${Ka.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${tf} runtime=${e} />
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
          onClick=${()=>{Zv()}}
          disabled=${Pe.value||yn.value.trim()===""}
        >
          ${Pe.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
  `}const xo=[{id:"observe",label:"Observe",description:"Live health, execution state, and room-wide telemetry"},{id:"coordinate",label:"Coordinate",description:"Conversation, decisions, planning, and backlog context"},{id:"command",label:"Command",description:"Direct control surfaces and intervention workflows"}],fi=[{id:"command",label:"Command",icon:"🧭",group:"command",description:"Company, platoon, squad, and agent command plane with operation and trace visibility"},{id:"overview",label:"Overview",icon:"🏠",group:"observe",description:"Room health, keeper pressure, and top-line execution status"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals, MDAL loops, and task backlog in one planning surface"},{id:"ops",label:"Ops",icon:"🎮",group:"command",description:"Guided operator controls for room, sessions, and keepers"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}],So="masc_dashboard_quick_actions_open";function af(){const t=Ft.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${In.value} events</span>
    </div>
  `}function sf(){const t=nt.value.tab,e=Ft.value,n=fi.find(r=>r.id===t),a=xo.find(r=>r.id===(n==null?void 0:n.group)),[s,o]=Ua(()=>{const r=localStorage.getItem(So);return r!=="0"});return rt(()=>{localStorage.setItem(So,s?"1":"0")},[s]),i`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${a?i`<span class="rail-section-chip">${a.label}</span>`:null}
        </div>
        ${xo.map(r=>i`
          <div class="rail-nav-group" key=${r.id}>
            <div class="rail-group-label">${r.label}</div>
            <div class="rail-group-copy">${r.description}</div>
            <div class="rail-tab-list">
              ${fi.filter(l=>l.group===r.id).map(l=>i`
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
            onClick=${()=>{ne(),t==="command"&&(Me(),ge()),t==="ops"&&He(),t==="board"&&qt(),t==="trpg"&&jt(),t==="goals"&&(Tn(),je())}}
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
          <span class="rail-section-chip">${s?"Open":"Closed"}</span>
        </div>
        <button class="fold-toggle" onClick=${()=>o(r=>!r)}>
          <span>${s?"Hide inline actions":"Show inline actions"}</span>
          <span class="fold-toggle-meta">Join, broadcast, keeper DM, lodge poke</span>
        </button>
        ${s?i`<div class="rail-fold-body"><${nf} /></div>`:i`<div class="rail-fold-hint">Use inline actions for quick room nudges. Open the Ops tab for structured intervention work.</div>`}
      </section>
    </aside>
  `}function of(){switch(nt.value.tab){case"command":return i`<${Up} />`;case"overview":return i`<${ao} />`;case"ops":return i`<${um} />`;case"board":return i`<${Nm} />`;case"agents":return i`<${rv} />`;case"goals":return i`<${gv} />`;case"trpg":return i`<${Wv} />`;default:return i`<${ao} />`}}function rf(){rt(()=>{nl(),Po(),ne();const n=rd();return ld(),()=>{dl(),n(),cd()}},[]),rt(()=>{const n=setInterval(()=>{const a=nt.value.tab;a==="command"?(Me(),ge()):a==="ops"?He():a==="board"?qt():a==="trpg"?jt():a==="goals"&&(Tn(),je())},15e3);return()=>{clearInterval(n)}},[]),rt(()=>{const n=nt.value.tab;n==="command"&&(Me(),ge()),n==="ops"&&He(),n==="board"&&qt(),n==="trpg"&&jt(),n==="goals"&&(Tn(),je())},[nt.value.tab]);const t=nt.value.tab,e=fi.find(n=>n.id===t);return i`
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
          <${af} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${sf} />
        <main class="dashboard-main">
          ${Hs.value&&!Ft.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${of} />`}
        </main>
      </div>

      ${Fe.value?i`
        <div class="activity-panel-backdrop" onClick=${Xi} />
        <aside class="activity-panel">
          <div class="activity-panel-header">
            <h3>Activity Feed</h3>
            <button class="activity-panel-close" onClick=${Xi}>Close</button>
          </div>
          <div class="activity-panel-body">
            <${Qm} />
          </div>
        </aside>
      `:null}

      <${qd} />
      <${$d} />
      <${md} />
    </div>
  `}const Ao=document.getElementById("app");Ao&&Qr(i`<${rf} />`,Ao);export{Qd as _};
