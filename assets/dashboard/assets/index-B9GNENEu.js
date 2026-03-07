var er=Object.defineProperty;var nr=(t,e,n)=>e in t?er(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var ge=(t,e,n)=>nr(t,typeof e!="symbol"?e+"":e,n);import{e as ar,_ as sr,c as f,b as ft,y as Pt,d as Yi,G as ir}from"./vendor-Bda-OZ-N.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const i of document.querySelectorAll('link[rel="modulepreload"]'))a(i);new MutationObserver(i=>{for(const o of i)if(o.type==="childList")for(const r of o.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(i){const o={};return i.integrity&&(o.integrity=i.integrity),i.referrerPolicy&&(o.referrerPolicy=i.referrerPolicy),i.crossOrigin==="use-credentials"?o.credentials="include":i.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function a(i){if(i.ep)return;i.ep=!0;const o=n(i);fetch(i.href,o)}})();var s=ar.bind(sr);const or=["command","overview","board","goals","agents","ops","trpg"],Xi={tab:"overview",params:{},postId:null},rr={journal:"overview",mdal:"goals",tasks:"goals",execution:"overview",council:"board",activity:"overview"};function di(t){return!!t&&or.includes(t)}function ui(t){if(t)return rr[t]??t}function ds(t){try{return decodeURIComponent(t)}catch{return t}}function us(t){const e={};return t&&new URLSearchParams(t).forEach((a,i)=>{e[i]=a}),e}function lr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Zi(t,e){const n=ui(t[0]),a=ui(e.tab),i=di(n)?n:di(a)?a:"overview";let o=null;return i==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?o=ds(t[2]):t[0]==="post"&&t[1]&&(o=ds(t[1]))),{tab:i,params:e,postId:o}}function Jn(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Xi;const n=ds(e);let a=n,i;if(n.startsWith("?"))a="",i=n.slice(1);else{const d=n.indexOf("?");d>=0&&(a=n.slice(0,d),i=n.slice(d+1))}!i&&a.includes("=")&&!a.includes("/")&&(i=a,a="");const o=us(i),r=lr(a);return Zi(r,o)}function cr(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...Xi,params:us(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const i=us(e.replace(/^\?/,""));return Zi(a,i)}function to(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([i])=>i!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const Lt=f(Jn(window.location.hash));window.addEventListener("hashchange",()=>{Lt.value=Jn(window.location.hash)});function Rt(t,e){const n={tab:t,params:{},postId:null};window.location.hash=to(n)}function dr(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function ur(){if(window.location.hash&&window.location.hash!=="#"){Lt.value=Jn(window.location.hash);return}const t=cr(window.location.pathname,window.location.search);if(t){Lt.value=t;const e=to(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",Lt.value=Jn(window.location.hash)}const pi="masc_dashboard_sse_session_id",pr=1e3,mr=15e3,It=f(!1),yn=f(0),eo=f(null),Vn=f([]);function vr(){let t=sessionStorage.getItem(pi);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(pi,t)),t}const fr=200;function gr(t,e,n="system",a={}){const i={agent:t,text:e,timestamp:Date.now(),kind:n,...a};Vn.value=[i,...Vn.value].slice(0,fr)}function ps(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function mi(t,e){const n=ps(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function yt(t,e,n,a,i={}){gr(t,e,n,{eventType:a,...i})}let Nt=null,Te=null,ms=0;function no(){Te&&(clearTimeout(Te),Te=null)}function _r(){if(Te)return;ms++;const t=Math.min(ms,5),e=Math.min(mr,pr*Math.pow(2,t));Te=setTimeout(()=>{Te=null,ao()},e)}function ao(){no(),Nt&&(Nt.close(),Nt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",vr());const i=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(i);Nt=o,o.onopen=()=>{Nt===o&&(ms=0,It.value=!0)},o.onerror=()=>{Nt===o&&(It.value=!1,o.close(),Nt=null,_r())},o.onmessage=r=>{try{const d=JSON.parse(r.data);yn.value++,eo.value=d,$r(d)}catch{}}}function $r(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":yt(n,"Joined","system","agent_joined");break;case"agent_left":yt(n,"Left","system","agent_left");break;case"broadcast":yt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":yt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":yt(n,mi("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:ps(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":yt(n,mi("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:ps(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":yt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":yt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":yt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":yt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:yt(n,e,"system","unknown")}}function hr(){no(),Nt&&(Nt.close(),Nt=null),It.value=!1}function so(){return new URLSearchParams(window.location.search)}function io(){const t=so(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function oo(){return{...io(),"Content-Type":"application/json"}}const yr=15e3,Qs=3e4,br=6e4,vi=new Set([408,425,429,500,502,503,504]);class bn extends Error{constructor(n){const a=n.method.toUpperCase(),i=n.timeout===!0,o=i?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);ge(this,"method");ge(this,"path");ge(this,"status");ge(this,"statusText");ge(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=i}}async function Ys(t,e,n){const a=new AbortController,i=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new bn({method:r,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(i)}}function kr(){var e,n;const t=so();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function gt(t){const e=await Ys(t,{headers:io()},yr);if(!e.ok)throw new bn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function xr(t){return new Promise(e=>setTimeout(e,t))}function Ar(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function Sr(t){if(t instanceof bn)return t.timeout||typeof t.status=="number"&&vi.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=Ar(t.message);return e!==null&&vi.has(e)}async function Ee(t,e,n=2){let a=0;for(;;)try{return await e()}catch(i){if(!Sr(i)||a>=n)throw i;const o=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${o}ms`,i),await xr(o),a+=1}}async function Ot(t,e,n,a=Qs){const i=await Ys(t,{method:"POST",headers:{...oo(),...n??{}},body:JSON.stringify(e)},a);if(!i.ok)throw new bn({method:"POST",path:t,status:i.status,statusText:i.statusText});return i.json()}async function wr(t,e,n,a=Qs){const i=await Ys(t,{method:"POST",headers:{...oo(),...n??{}},body:JSON.stringify(e)},a);if(!i.ok)throw new bn({method:"POST",path:t,status:i.status,statusText:i.statusText});return i.text()}function Tr(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Cr(t){var e,n,a,i,o,r,d;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const p=((i=(a=t.result.content)==null?void 0:a[0])==null?void 0:i.text)??"MCP tool call failed";throw new Error(p)}return((d=(r=(o=t.result)==null?void 0:o.content)==null?void 0:r[0])==null?void 0:d.text)??""}async function ut(t,e){const n=await wr("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},br),a=Tr(n);return Cr(a)}function Nr(t="compact"){return gt(`/api/v1/dashboard?mode=${t}`)}function Rr(t={}){return Ee("fetchMdalLoops",async()=>{const e=new URLSearchParams;t.limit!=null&&e.set("limit",String(t.limit)),t.historyLimit!=null&&e.set("history_limit",String(t.historyLimit)),t.status&&e.set("status",t.status);const n=e.toString();return gt(`/api/v1/mdal/loops${n?`?${n}`:""}`)})}function Dr(){return gt("/api/v1/operator")}function Lr(){return gt("/api/v1/command-plane")}function Pr(){return gt("/api/v1/command-plane/help")}function Ir(t,e){return Ot(t,e)}function Er(t){switch(t.action_type){case"keeper_msg":case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return Qs}}function kn(t){return Ot("/api/v1/operator/action",t,void 0,Er(t))}function Or(t,e){return Ot("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const Mr=new Set(["lodge-system","team-session"]);function Pe(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function zr(t){return Mr.has(t.trim().toLowerCase())}function jr(t){return t.filter(e=>!zr(e.author))}function qr(t){var i;const e=t.trim(),a=((i=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:i.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function ro(t){if(!I(t))return null;const e=$(t.id,"").trim(),n=$(t.author,"").trim(),a=$(t.content,"").trim();if(!e||!n)return null;const i=O(t.score,0),o=O(t.votes_up,0),r=O(t.votes_down,0),d=O(t.votes,i||o-r),p=O(t.comment_count,O(t.reply_count,0)),_=(()=>{const b=t.flair;if(typeof b=="string"&&b.trim())return b.trim();if(I(b)){const T=$(b.name,"").trim();if(T)return T}return $(t.flair_name,"").trim()||void 0})(),m=$(t.created_at_iso,"").trim()||Pe(t.created_at),c=$(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Pe(t.updated_at):m),g=$(t.title,"").trim()||qr(a);return{id:e,author:n,title:g,content:a,tags:[],votes:d,vote_balance:i,comment_count:p,created_at:m,updated_at:c,flair:_,hearth_count:O(t.hearth_count,0)}}function Fr(t){if(!I(t))return null;const e=$(t.id,"").trim(),n=$(t.post_id,"").trim(),a=$(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:$(t.content,""),created_at:Pe(t.created_at)}}async function Kr(t,e){return Ee("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const a=n.toString(),i=await gt(`/api/v1/board${a?`?${a}`:""}`),o=Array.isArray(i.posts)?i.posts.map(ro).filter(d=>d!==null):[];return{posts:e!=null&&e.excludeSystem?jr(o):o}})}async function Hr(t){return Ee("fetchBoardPost",async()=>{const e=await gt(`/api/v1/board/${t}?format=flat`),n=I(e.post)?e.post:e,a=ro(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},o=(Array.isArray(e.comments)?e.comments:[]).map(Fr).filter(r=>r!==null);return{...a,comments:o}})}function lo(t,e){return Ot("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:kr()})}function Br(t,e,n){return Ot("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Ur(t){const e=$(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function et(...t){for(const e of t){const n=$(e,"");if(n.trim())return n.trim()}return""}function fi(t){const e=Ur(et(t.outcome,t.result,t.result_code));if(!e)return;const n=et(t.reason,t.reason_code,t.description,t.detail),a=et(t.summary,t.summary_ko,t.summary_en,t.note),i=et(t.details,t.details_text,t.text,t.note),o=et(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=et(t.winner_actor_id,t.winner_actor,t.actor_winner_id),d=et(t.raw_reason,t.raw_reason_code,t.error_message),p=(()=>{const c=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof c=="string"?[c]:Array.isArray(c)?c.map(l=>{if(typeof l=="string")return l.trim();if(I(l)){const g=$(l.summary,"").trim();if(g)return g;const b=$(l.text,"").trim();if(b)return b;const A=$(l.type,"").trim();return A||$(l.event_id,"").trim()}return""}).filter(l=>l.length>0):[]})(),_=(()=>{const c=O(t.turn,Number.NaN);if(Number.isFinite(c))return c;const l=O(t.turn_number,Number.NaN);if(Number.isFinite(l))return l;const g=O(t.current_turn,Number.NaN);if(Number.isFinite(g))return g;const b=O(t.round,Number.NaN);return Number.isFinite(b)?b:void 0})(),m=et(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:i||void 0,winner:o||void 0,winner_actor_id:r||void 0,evidence:p.length>0?p:void 0,raw_reason:d||void 0,turn:_,phase:m||void 0}}function Gr(t,e){const n=I(t.state)?t.state:{};if($(n.status,"active").toLowerCase()!=="ended")return;const i=[...e].reverse().find(r=>I(r)?$(r.type,"")==="session.outcome":!1),o=I(n.session_outcome)?n.session_outcome:{};if(I(o)&&Object.keys(o).length>0){const r=fi(o);if(r)return r}if(I(i))return fi(I(i.payload)?i.payload:{})}function I(t){return typeof t=="object"&&t!==null}function $(t,e=""){return typeof t=="string"?t:e}function O(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Wr(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function vs(t,e=!1){return typeof t=="boolean"?t:e}function Fe(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(I(e)){const n=$(e.name,"").trim(),a=$(e.id,"").trim(),i=$(e.skill,"").trim();return n||a||i}return""}).filter(e=>e.length>0):[]}function Jr(t){const e={};if(!I(t)&&!Array.isArray(t))return e;if(I(t))return Object.entries(t).forEach(([n,a])=>{const i=n.trim(),o=$(a,"").trim();!i||!o||(e[i]=o)}),e;for(const n of t){if(!I(n))continue;const a=et(n.to,n.target,n.actor_id,n.name,n.id),i=et(n.relationship,n.relation,n.type,n.kind);!a||!i||(e[a]=i)}return e}function Vr(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function mt(t,e,n,a=0){const i=t[e];if(typeof i=="number"&&Number.isFinite(i))return i;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return a}const Qr=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Yr(t){const e=I(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,i])=>{const o=a.trim();o&&(Qr.has(o.toLowerCase())||typeof i=="number"&&Number.isFinite(i)&&(n[o]=i))}),n}function Xr(t,e){if(t!=="dice.rolled")return;const n=O(e.raw_d20,0),a=O(e.total,0),i=O(e.bonus,0),o=$(e.action,"roll"),r=O(e.dc,0);return{notation:r>0?`${o} (DC ${r})`:o,rolls:n>0?[n]:[],total:a,modifier:i}}function Zr(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function tl(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function el(t,e,n,a){const i=n||e||$(a.actor_id,"")||$(a.actor_name,"");switch(t){case"turn.action.proposed":{const o=$(a.proposed_action,$(a.reply,""));return o?`${i||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=$(a.reply,$(a.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return $(a.reply,$(a.content,$(a.text,"Narration")));case"dice.rolled":{const o=$(a.action,"roll"),r=O(a.total,0),d=O(a.dc,0),p=$(a.label,""),_=i||"actor",m=d>0?` vs DC ${d}`:"",c=p?` (${p})`:"";return`${_} ${o}: ${r}${m}${c}`}case"turn.started":return`Turn ${O(a.turn,1)} started`;case"phase.changed":return`Phase: ${$(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${$(a.name,I(a.actor)?$(a.actor.name,i||"unknown"):i||"unknown")}`;case"actor.claimed":return`${$(a.keeper_name,$(a.keeper,"keeper"))} claimed ${i||"actor"}`;case"actor.released":return`${$(a.keeper_name,$(a.keeper,"keeper"))} released ${i||"actor"}`;case"join.window.opened":return`Join window opened (turn ${O(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${O(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${i||$(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${i||$(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${$(a.reason_code,"unknown")}`;case"memory.signal":{const o=I(a.entity_refs)?a.entity_refs:{},r=$(o.requested_tier,""),d=$(o.effective_tier,""),p=vs(o.guardrail_applied,!1),_=$(a.summary_en,$(a.summary_ko,"Memory signal"));if(!r&&!d)return _;const m=r&&d?`${r}->${d}`:d||r;return`${_} [${m}${p?" (guardrail)":""}]`}case"world.event":{if($(a.event_type,"")==="canon.check"){const r=$(a.status,"unknown"),d=$(a.contract_id,"n/a");return`Canon ${r}: ${d}`}return $(a.description,$(a.summary,"World event"))}case"combat.attack":return $(a.summary,$(a.result,"Attack resolved"));case"combat.defense":return $(a.summary,$(a.result,"Defense resolved"));case"session.outcome":return $(a.summary,$(a.outcome,"Session ended"));default:{const o=Zr(a);return o?`${t}: ${o}`:t}}}function nl(t,e){const n=I(t)?t:{},a=$(n.type,"event"),i=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=$(n.actor_name,"").trim()||e[i]||$(I(n.payload)?n.payload.actor_name:"",""),r=I(n.payload)?n.payload:{},d=$(n.ts,$(n.timestamp,new Date().toISOString())),p=$(n.phase,$(r.phase,"")),_=$(n.category,"");return{type:a,actor:o||i||$(r.actor_name,""),actor_id:i||$(r.actor_id,""),actor_name:o,seq:n.seq,room_id:$(n.room_id,""),phase:p||void 0,category:_||tl(a),visibility:$(n.visibility,$(r.visibility,"public")),event_id:$(n.event_id,""),content:el(a,i,o,r),dice_roll:Xr(a,r),timestamp:d}}function al(t,e,n){var $t,ht;const a=$(t.room_id,"")||n||"default",i=I(t.state)?t.state:{},o=I(i.party)?i.party:{},r=I(i.actor_control)?i.actor_control:{},d=I(i.join_gate)?i.join_gate:{},p=I(i.contribution_ledger)?i.contribution_ledger:{},_=Object.entries(o).map(([H,V])=>{const y=I(V)?V:{},St=mt(y,"max_hp",void 0,10),Jt=mt(y,"hp",void 0,St),ae=mt(y,"max_mp",void 0,0),L=mt(y,"mp",void 0,0),wt=mt(y,"level",void 0,1),se=mt(y,"xp",void 0,0),Tn=vs(y.alive,Jt>0),je=r[H],qe=typeof je=="string"?je:void 0,u=Vr(y.role,H,qe),C=Wr(y.generation),M=et(y.joined_at,y.joinedAt,y.started_at,y.startedAt),Q=et(y.claimed_at,y.claimedAt,y.assigned_at,y.assignedAt,y.assigned_time),E=et(y.last_seen,y.lastSeen,y.last_seen_at,y.lastSeenAt,y.last_active,y.lastActive),it=et(y.scene,y.current_scene,y.currentScene,y.world_scene,y.scene_name,y.sceneName),G=et(y.location,y.current_location,y.currentLocation,y.position,y.zone,y.area);return{id:H,name:$(y.name,H),role:u,keeper:qe,archetype:$(y.archetype,""),persona:$(y.persona,""),portrait:$(y.portrait,"")||void 0,background:$(y.background,"")||void 0,traits:Fe(y.traits),skills:Fe(y.skills),stats_raw:Yr(y),status:Tn?"active":"dead",generation:C,joined_at:M||void 0,claimed_at:Q||void 0,last_seen:E||void 0,scene:it||void 0,location:G||void 0,inventory:Fe(y.inventory),notes:Fe(y.notes),relationships:Jr(y.relationships),stats:{hp:Jt,max_hp:St,mp:L,max_mp:ae,level:wt,xp:se,strength:mt(y,"strength","str",10),dexterity:mt(y,"dexterity","dex",10),constitution:mt(y,"constitution","con",10),intelligence:mt(y,"intelligence","int",10),wisdom:mt(y,"wisdom","wis",10),charisma:mt(y,"charisma","cha",10)}}}),m=_.filter(H=>H.status!=="dead"),c=Gr(t,e),l={phase_open:vs(d.phase_open,!0),min_points:O(d.min_points,3),window:$(d.window,"round_boundary_only"),last_opened_turn:typeof d.last_opened_turn=="number"?d.last_opened_turn:null,last_closed_turn:typeof d.last_closed_turn=="number"?d.last_closed_turn:null},g=Object.entries(p).map(([H,V])=>{const y=I(V)?V:{};return{actor_id:H,score:O(y.score,0),last_reason:$(y.last_reason,"")||null,reasons:Fe(y.reasons)}}),b=_.reduce((H,V)=>(H[V.id]=V.name,H),{}),A=e.map(H=>nl(H,b)),T=O(i.turn,1),B=$(i.phase,"round"),U=$(i.map,""),z=I(i.world)?i.world:{},R=U||$(z.ascii_map,$(z.map,"")),P=A.filter((H,V)=>{const y=e[V];if(!I(y))return!1;const St=I(y.payload)?y.payload:{};return O(St.turn,-1)===T}),_t=(P.length>0?P:A).slice(-12),zt=$(i.status,"active");return{session:{id:a,room:a,status:zt==="ended"?"ended":zt==="paused"?"paused":"active",round:T,actors:m,created_at:(($t=A[0])==null?void 0:$t.timestamp)??new Date().toISOString()},current_round:{round_number:T,phase:B,events:_t,timestamp:((ht=A[A.length-1])==null?void 0:ht.timestamp)??new Date().toISOString()},map:R||void 0,join_gate:l,contribution_ledger:g,outcome:c,party:m,story_log:A,history:[]}}async function sl(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await gt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function il(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([gt(`/api/v1/trpg/state${e}`),sl(t)]);return al(n,a,t)}function ol(t){return Ot("/api/v1/trpg/rounds/run",{room_id:t})}function rl(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function ll(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Ot("/api/v1/trpg/dice/roll",e)}function cl(t,e){const n=rl();return Ot("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function dl(t,e){var i;const n=(i=e.idempotencyKey)==null?void 0:i.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),Ot("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function ul(t,e,n){return Ot("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function pl(t,e,n){const a=await ut("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function ml(t){const e=await ut("trpg.mid_join.request",t);return JSON.parse(e)}async function co(t,e){await ut("masc_broadcast",{agent_name:t,message:e})}async function vl(t,e,n=1){await ut("masc_add_task",{title:t,description:e,priority:n})}async function fl(t){return ut("masc_join",{agent_name:t})}async function uo(t){await ut("masc_leave",{agent_name:t})}async function gl(t){await ut("masc_heartbeat",{agent_name:t})}async function _l(t=40){return(await ut("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function $l(t,e=20){return ut("masc_task_history",{task_id:t,limit:e})}async function hl(){return Ee("fetchDebates",async()=>{const t=await gt("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!I(e))return null;const n=$(e.id,"").trim(),a=$(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:$(e.status,"open"),argument_count:O(e.argument_count,0),created_at:Pe(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function yl(){return Ee("fetchCouncilSessions",async()=>{const t=await gt("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!I(e))return null;const n=$(e.id,"").trim(),a=$(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:$(e.initiator,"system"),votes:O(e.votes,0),quorum:O(e.quorum,0),state:$(e.state,"open"),created_at:Pe(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function bl(t){const e=await ut("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function kl(t){return Ee("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await gt(`/api/v1/council/debates/${e}/summary`);if(!I(n))return null;const a=$(n.id,"").trim();return a?{id:a,topic:$(n.topic,""),status:$(n.status,"open"),support_count:O(n.support_count,0),oppose_count:O(n.oppose_count,0),neutral_count:O(n.neutral_count,0),total_arguments:O(n.total_arguments,0),created_at:Pe(n.created_at_iso??n.created_at),summary_text:$(n.summary_text,"")}:null})}function xl(t,e,n){return ut("masc_keeper_msg",{name:t,message:e})}async function Al(){try{const t=await ut("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const Je=f(""),Kt=f({}),at=f({}),fs=f({}),gs=f({}),_s=f({}),$s=f({}),Ht=f({});function Z(t,e,n){t.value={...t.value,[e]:n}}function Bt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function q(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function kt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function xe(t){return typeof t=="boolean"?t:void 0}function hs(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function ys(t){return Array.isArray(t)?t.map(e=>q(e)).filter(e=>!!e):[]}function Sl(t){var n;const e=(n=q(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function wl(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Pa(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!Bt(a))continue;const i=q(a.name);if(!i)continue;const o=q(a[e]);e==="summary"?n.push({name:i,summary:o}):n.push({name:i,reason:o})}return n}function Tl(t){if(!Bt(t))return null;const e=q(t.name);return e?{name:e,trigger:q(t.trigger),outcome:q(t.outcome),summary:q(t.summary),reason:q(t.reason)}:null}function Cl(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Nl(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function po(t,e,n){return q(t)??Nl(e,n)}function mo(t,e){return typeof t=="boolean"?t:e==="recover"}function Qn(t){if(!Bt(t))return null;const e=q(t.health_state),n=q(t.next_action_path),a=q(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:q(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:hs(t.last_reply_at),last_reply_preview:q(t.last_reply_preview)??null,last_error:q(t.last_error)??null,next_eligible_at_s:kt(t.next_eligible_at_s)??null,recoverable:mo(t.recoverable,n),summary:po(t.summary,e,q(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Xs(t){return Bt(t)?{hour:kt(t.hour),checked:kt(t.checked)??0,acted:kt(t.acted)??0,acted_names:ys(t.acted_names),activity_report:q(t.activity_report),quiet_hours_overridden:xe(t.quiet_hours_overridden),skipped_reason:q(t.skipped_reason),acted_rows:Pa(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:Pa(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:Pa(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Tl).filter(e=>e!==null):[]}:null}function Rl(t){return Bt(t)?{enabled:xe(t.enabled)??!1,interval_s:kt(t.interval_s)??0,quiet_start:kt(t.quiet_start),quiet_end:kt(t.quiet_end),quiet_active:xe(t.quiet_active),use_planner:xe(t.use_planner),delegate_llm:xe(t.delegate_llm),agent_count:kt(t.agent_count),agents:ys(t.agents),last_tick_ago_s:kt(t.last_tick_ago_s)??null,last_tick_ago:q(t.last_tick_ago),total_ticks:kt(t.total_ticks),total_checkins:kt(t.total_checkins),last_skip_reason:q(t.last_skip_reason)??null,last_tick_result:Xs(t.last_tick_result),active_self_heartbeats:ys(t.active_self_heartbeats)}:null}function Dl(t){return Bt(t)?{status:t.status,diagnostic:Qn(t.diagnostic)}:null}function Ll(t){return Bt(t)?{recovered:xe(t.recovered)??!1,skipped_reason:q(t.skipped_reason)??null,before:Qn(t.before),after:Qn(t.after),down:t.down,up:t.up}:null}function Pl(t,e){var U,z;if(!(t!=null&&t.name))return null;const n=q((U=t.agent)==null?void 0:U.status)??q(t.status)??"unknown",a=q((z=t.agent)==null?void 0:z.error)??null,i=t.presence_keepalive??!0,o=t.keepalive_running??!1,r=t.turn_count??0,d=t.last_turn_ago_s??null,p=t.proactive_enabled??!1,_=t.proactive_cooldown_sec??0,m=t.last_proactive_ago_s??null,c=p&&m!=null?Math.max(0,_-m):null,l=r<=0||d==null?"never":d>900?"stale":"fresh",g=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,b=a??(i&&!o?"keeper keepalive is not running":null),A=n==="offline"||n==="inactive"?"offline":b?"degraded":l==="stale"?"stale":l==="never"?"idle":"healthy",T=b?Cl(b):e!=null&&e.quiet_active&&l!=="fresh"?"quiet_hours":i&&!o?"disabled":r<=0?"never_started":c!=null&&c>0?"min_gap":l==="fresh"||l==="stale"?"no_recent_activity":"unknown",B=A==="offline"||A==="degraded"||A==="stale"?"recover":T==="quiet_hours"?"manual_lodge_poke":T==="unknown"?"probe":"direct_message";return{health_state:A,quiet_reason:T,next_action_path:B,last_reply_status:l,last_reply_at:g,last_reply_preview:null,last_error:b,next_eligible_at_s:c!=null&&c>0?c:null,recoverable:mo(void 0,B),summary:po(void 0,A,T),keepalive_running:o}}function Il(t,e){if(!Bt(t))return null;const n=Sl(t.role),a=q(t.content)??q(t.preview);if(!a)return null;const i=hs(t.ts_unix)??hs(t.timestamp);return{id:`${n}-${i??"entry"}-${e}`,role:n,label:wl(n),text:a,timestamp:i,delivery:"history"}}function El(t,e,n){const a=Bt(n)?n:null,i=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((o,r)=>Il(o,r)).filter(o=>o!==null):[];return{name:t,diagnostic:Qn(a==null?void 0:a.diagnostic),history:i,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function gi(t,e){const n=at.value[t]??[];at.value={...at.value,[t]:[...n,e].slice(-50)}}function Ol(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Ml(t,e){const a=(at.value[t]??[]).filter(i=>i.delivery!=="history"&&!e.some(o=>Ol(i,o)));at.value={...at.value,[t]:[...e,...a].slice(-50)}}function wa(t,e){Kt.value={...Kt.value,[t]:e},Ml(t,e.history)}function _i(t,e){const n=Kt.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};wa(t,{...n,diagnostic:{...a,...e}})}async function Zs(){xn();try{await pe()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function zn(t){Je.value=t.trim()}async function vo(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Kt.value[n])return Kt.value[n];Z(fs,n,!0),Z(Ht,n,null);try{const a=await ut("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let i=null;try{i=JSON.parse(a)}catch{i=null}const o=El(n,a,i);return wa(n,o),o}catch(a){const i=a instanceof Error?a.message:`Failed to inspect ${n}`;return Z(Ht,n,i),null}finally{Z(fs,n,!1)}}async function zl(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const i=`local-${Date.now()}`;gi(n,{id:i,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),Z(gs,n,!0),Z(Ht,n,null);try{const o=await xl(n,a);at.value={...at.value,[n]:(at.value[n]??[]).map(r=>r.id===i?{...r,delivery:"delivered"}:r)},gi(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),_i(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await Zs()}catch(o){const r=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw at.value={...at.value,[n]:(at.value[n]??[]).map(d=>d.id===i?{...d,delivery:"error",error:r}:d)},_i(n,{last_reply_status:"error",last_error:r}),Z(Ht,n,r),o}finally{Z(gs,n,!1)}}async function jl(t,e){const n=t.trim();if(!n)return null;Z(_s,n,!0),Z(Ht,n,null);try{const a=await kn({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),i=Dl(a.result),o=(i==null?void 0:i.diagnostic)??null;if(o){const r=Kt.value[n];wa(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??at.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await Zs(),o}catch(a){const i=a instanceof Error?a.message:`Failed to probe ${n}`;throw Z(Ht,n,i),a}finally{Z(_s,n,!1)}}async function ql(t,e){const n=t.trim();if(!n)return null;Z($s,n,!0),Z(Ht,n,null);try{const a=await kn({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),i=Ll(a.result),o=(i==null?void 0:i.after)??null;if(o){const r=Kt.value[n];wa(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??at.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await Zs(),o}catch(a){const i=a instanceof Error?a.message:`Failed to recover ${n}`;throw Z(Ht,n,i),a}finally{Z($s,n,!1)}}function ie(t){return(t??"").trim().toLowerCase()}function rt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function jn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Cn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ke(t){return t.last_heartbeat??Cn(t.last_turn_ago_s)??Cn(t.last_proactive_ago_s)??Cn(t.last_handoff_ago_s)??Cn(t.last_compaction_ago_s)}function Fl(t){const e=t.title.trim();return e||jn(t.content)}function Kl(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Hl(t,e,n,a,i={}){var z;const o=ie(t),r=e.filter(R=>ie(R.assignee)===o&&(R.status==="claimed"||R.status==="in_progress")).length,d=n.filter(R=>ie(R.from)===o).sort((R,P)=>rt(P.timestamp)-rt(R.timestamp))[0],p=a.filter(R=>ie(R.agent)===o||ie(R.author)===o).sort((R,P)=>rt(P.timestamp)-rt(R.timestamp))[0],_=(i.boardPosts??[]).filter(R=>ie(R.author)===o).sort((R,P)=>rt(P.updated_at||P.created_at)-rt(R.updated_at||R.created_at))[0],m=(i.keepers??[]).filter(R=>ie(R.name)===o&&Ke(R)!==null).sort((R,P)=>rt(Ke(P)??0)-rt(Ke(R)??0))[0],c=d?rt(d.timestamp):0,l=p?rt(p.timestamp):0,g=_?rt(_.updated_at||_.created_at):0,b=m?rt(Ke(m)??0):0,A=i.lastSeen?rt(i.lastSeen):0,T=((z=i.currentTask)==null?void 0:z.trim())||(r>0?`${r} claimed tasks`:null);if(c===0&&l===0&&g===0&&b===0&&A===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:T};const U=[d?{timestamp:d.timestamp,ts:c,text:jn(d.content)}:null,_?{timestamp:_.updated_at||_.created_at,ts:g,text:`Post: ${jn(Fl(_))}`}:null,m?{timestamp:Ke(m),ts:b,text:Kl(m)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:l,text:jn(p.text)}:null].filter(R=>R!==null).sort((R,P)=>P.ts-R.ts)[0];return U&&U.ts>=A?{activeAssignedCount:r,lastActivityAt:U.timestamp,lastActivityText:U.text}:{activeAssignedCount:r,lastActivityAt:i.lastSeen??null,lastActivityText:T??"Presence heartbeat"}}const Mt=f([]),xt=f([]),ti=f([]),Ut=f([]),ee=f(null),Ge=f(null),bs=f(new Map),Oe=f([]),pn=f("hot"),oe=f(!0),fo=f(null),jt=f(""),mn=f([]),Ae=f(!1),go=f(new Map),ks=f("unknown"),xs=f(null),As=f(!1),vn=f(!1),Ss=f(!1),Se=f(!1),Bl=f(null),ws=f(null),_o=f(null),$o=f(null),Ul=ft(()=>Mt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle")),ho=ft(()=>{const t=xt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Ta=ft(()=>{const t=new Map,e=xt.value,n=ti.value,a=Vn.value,i=Oe.value,o=Ut.value;for(const r of Mt.value)t.set(r.name.trim().toLowerCase(),Hl(r.name,e,n,a,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:i,keepers:o}));return t});function Gl(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const i=a.context_ratio;return i>.85?"handoff-imminent":i>.7?"preparing":i>.5?"compacting":"active"}const yo=ft(()=>{const t=new Map;for(const e of Ut.value)t.set(e.name,Gl(e));return t}),Wl=12e4;function Jl(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const i=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof i=="number"?Date.now()-i*1e3:null}const bo=ft(()=>{const t=Date.now(),e=new Set,n=bs.value;for(const a of Ut.value){const i=Jl(a,n);i!=null&&t-i>Wl&&e.add(a.name)}return e}),Yn={},Vl=5e3;function xn(){delete Yn.compact,delete Yn.full}function st(t){return typeof t=="object"&&t!==null}function h(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function k(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function de(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Ts(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function ko(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Ql(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Yl(t){if(!st(t))return null;const e=h(t.name);return e?{name:e,status:ko(t.status),current_task:h(t.current_task)??null,last_seen:h(t.last_seen),emoji:h(t.emoji),koreanName:h(t.koreanName)??h(t.korean_name),model:h(t.model),traits:de(t.traits),interests:de(t.interests),activityLevel:k(t.activityLevel)??k(t.activity_level),primaryValue:h(t.primaryValue)??h(t.primary_value)}:null}function Xl(t){if(!st(t))return null;const e=h(t.id),n=h(t.title);return!e||!n?null:{id:e,title:n,status:Ql(t.status),priority:k(t.priority),assignee:h(t.assignee),description:h(t.description),created_at:h(t.created_at),updated_at:h(t.updated_at)}}function Zl(t){if(!st(t))return null;const e=h(t.from)??h(t.from_agent)??"system",n=h(t.content)??"",a=h(t.timestamp)??new Date().toISOString();return{id:h(t.id),seq:k(t.seq),from:e,content:n,timestamp:a,type:h(t.type)}}function tc(t){return Array.isArray(t)?t.map(e=>{if(!st(e))return null;const n=k(e.ts_unix);if(n==null)return null;const a=st(e.handoff)?e.handoff:null;return{ts:n,context_ratio:k(e.context_ratio)??0,context_tokens:k(e.context_tokens)??0,context_max:k(e.context_max)??0,latency_ms:k(e.latency_ms)??0,generation:k(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:k(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:k(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?k(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function $i(t){if(!st(t))return null;const e=h(t.health_state),n=h(t.next_action_path),a=h(t.last_reply_status);if(!e||!n||!a)return null;const i=h(t.quiet_reason)??null,o=h(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":i==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":i==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":i==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:i,next_action_path:n,last_reply_status:a,last_reply_at:Ts(t.last_reply_at)??h(t.last_reply_at)??null,last_reply_preview:h(t.last_reply_preview)??null,last_error:h(t.last_error)??null,next_eligible_at_s:k(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function ec(t,e){return(Array.isArray(t)?t:st(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!st(a))return null;const i=st(a.agent)?a.agent:null,o=st(a.context)?a.context:null,r=st(a.metrics_window)?a.metrics_window:void 0,d=h(a.name);if(!d)return null;const p=k(a.context_ratio)??k(o==null?void 0:o.context_ratio),_=h(a.status)??h(i==null?void 0:i.status)??"offline",m=ko(_),c=h(a.model)??h(a.active_model)??h(a.primary_model),l=de(a.skill_secondary),g=o?{source:h(o.source),context_ratio:k(o.context_ratio),context_tokens:k(o.context_tokens),context_max:k(o.context_max),message_count:k(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,b=i?{name:h(i.name),exists:typeof i.exists=="boolean"?i.exists:void 0,error:h(i.error),status:h(i.status),current_task:h(i.current_task)??null,last_seen:h(i.last_seen),last_seen_ago_s:k(i.last_seen_ago_s),is_zombie:typeof i.is_zombie=="boolean"?i.is_zombie:void 0}:void 0,A=tc(a.metrics_series),T={name:d,emoji:h(a.emoji),koreanName:h(a.koreanName)??h(a.korean_name),agent_name:h(a.agent_name),trace_id:h(a.trace_id),model:c,primary_model:h(a.primary_model),active_model:h(a.active_model),next_model_hint:h(a.next_model_hint)??null,status:m,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:k(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:k(a.proactive_idle_sec),proactive_cooldown_sec:k(a.proactive_cooldown_sec),last_heartbeat:h(a.last_heartbeat)??h(i==null?void 0:i.last_seen),generation:k(a.generation),turn_count:k(a.turn_count)??k(a.total_turns),keeper_age_s:k(a.keeper_age_s),last_turn_ago_s:k(a.last_turn_ago_s),last_handoff_ago_s:k(a.last_handoff_ago_s),last_compaction_ago_s:k(a.last_compaction_ago_s),last_proactive_ago_s:k(a.last_proactive_ago_s),context_ratio:p,context_tokens:k(a.context_tokens)??k(o==null?void 0:o.context_tokens),context_max:k(a.context_max)??k(o==null?void 0:o.context_max),context_source:h(a.context_source)??h(o==null?void 0:o.source),context:g,traits:de(a.traits),interests:de(a.interests),primaryValue:h(a.primaryValue)??h(a.primary_value),activityLevel:k(a.activityLevel)??k(a.activity_level),memory_recent_note:h(a.memory_recent_note)??null,conversation_tail_count:k(a.conversation_tail_count),k2k_count:k(a.k2k_count),handoff_count_total:k(a.handoff_count_total)??k(a.trace_history_count),compaction_count:k(a.compaction_count),last_compaction_saved_tokens:k(a.last_compaction_saved_tokens),diagnostic:$i(a.diagnostic),skill_primary:h(a.skill_primary)??null,skill_secondary:l,skill_reason:h(a.skill_reason)??null,metrics_series:A.length>0?A:void 0,metrics_window:r,agent:b};return T.diagnostic=$i(a.diagnostic)??Pl(T,(e==null?void 0:e.lodge)??null),T}).filter(a=>a!==null)}function nc(t){return st(t)?{...t,lodge:Rl(t.lodge)??void 0}:null}function ac(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function sc(t){if(!st(t))return null;const e=k(t.iteration);if(e==null)return null;const n=k(t.metric_before)??0,a=k(t.metric_after)??n,i=st(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:a,delta:k(t.delta)??a-n,changes:h(t.changes)??"",failed_attempts:h(t.failed_attempts)??"",next_suggestion:h(t.next_suggestion)??"",elapsed_ms:k(t.elapsed_ms)??0,cost_usd:k(t.cost_usd)??null,evidence:i?{worker_engine:(i.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:h(i.worker_model)??"",tool_call_count:k(i.tool_call_count)??0,tool_names:de(i.tool_names)??[],session_id:h(i.session_id)??"",evidence_status:i.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function ic(t){var o,r;if(!st(t))return null;const e=h(t.loop_id);if(!e)return null;const n=k(t.baseline_metric)??0,a=Array.isArray(t.history)?t.history.map(sc).filter(d=>d!==null):[],i=k(t.current_metric)??((o=a[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:h(t.profile)??"unknown",status:ac(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:h(t.error_message)??h(t.error_reason)??null,stop_reason:h(t.stop_reason)??h(t.reason)??null,current_iteration:k(t.current_iteration)??((r=a[0])==null?void 0:r.iteration)??0,max_iterations:k(t.max_iterations)??0,baseline_metric:n,current_metric:i,target:h(t.target)??"",stagnation_streak:k(t.stagnation_streak)??0,stagnation_limit:k(t.stagnation_limit)??0,elapsed_seconds:k(t.elapsed_seconds)??0,updated_at:Ts(t.updated_at)??null,stopped_at:Ts(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:h(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:k(t.latest_tool_call_count)??0,latest_tool_names:de(t.latest_tool_names)??[],session_id:h(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:a}}async function pe(t="full"){var a,i,o;const e=Date.now(),n=Yn[t];if(!(n&&e-n.time<Vl)){As.value=!0;try{const r=await Nr(t);Yn[t]={data:r,time:e},Mt.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(Yl).filter(p=>p!==null),xt.value=(Array.isArray((i=r.tasks)==null?void 0:i.tasks)?r.tasks.tasks:[]).map(Xl).filter(p=>p!==null),ti.value=(Array.isArray((o=r.messages)==null?void 0:o.messages)?r.messages.messages:[]).map(Zl).filter(p=>p!==null);const d=nc(r.status);ee.value=d,Ut.value=ec(r.keepers,d),Ge.value=r.perpetual??null,Bl.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{As.value=!1}}}async function qt(){vn.value=!0;try{const t=await Kr(pn.value,{excludeSystem:oe.value});Oe.value=t.posts??[],ws.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{vn.value=!1}}async function Ft(){var t;Ss.value=!0;try{const e=jt.value||((t=ee.value)==null?void 0:t.room)||"default";jt.value||(jt.value=e);const n=await il(e);fo.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Ss.value=!1}}async function Xn(){Ae.value=!0;try{const t=await Al();mn.value=Array.isArray(t)?t:[],_o.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Ae.value=!1}}async function fn(){Se.value=!0;try{const t=await Rr(),e=Array.isArray(t.loops)?t.loops:[],n=new Map;for(const a of e){const i=ic(a);i&&n.set(i.loop_id,i)}go.value=n,$o.value=new Date().toISOString(),xs.value=null,ks.value=n.size===0?"idle":"ready"}catch(t){console.error("MDAL fetch error:",t),ks.value="error",xs.value=t instanceof Error?t.message:String(t)}finally{Se.value=!1}}let qn=null;function oc(t){qn=t}let Ia=null,Ea=null,Ce=null,Ne=null;function rc(){Ce||(Ce=setTimeout(()=>{qn==null||qn(),Ce=null},500))}function lc(){Ne||(Ne=setTimeout(()=>{fn(),Ne=null},350))}const cc=new Set(["task_update","task_claimed","task_done","agent_joined","agent_left","broadcast","keeper_handoff","keeper_compaction","keeper_guardrail"]);function dc(){const t=eo.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(bs.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),bs.value=n;return}cc.has(e.type)&&(xn(),Ia||(Ia=setTimeout(()=>{pe(),Ia=null},500))),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&(Ea||(Ea=setTimeout(()=>{qt(),Ea=null},500))),e.type.startsWith("decision_")&&rc(),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&lc()}});return()=>{t(),Ce&&(clearTimeout(Ce),Ce=null),Ne&&(clearTimeout(Ne),Ne=null)}}let Ve=null;function uc(){Ve||(Ve=setInterval(()=>{It.value||(xn(),pe())},1e4))}function pc(){Ve&&(clearInterval(Ve),Ve=null)}function S({title:t,class:e,children:n}){return s`
    <div class="card ${e??""}">
      ${t?s`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function At({status:t,label:e}){return s`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function mc(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const i=Math.floor(a/60);if(i<60)return`${i}m ago`;const o=Math.floor(i/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function j({timestamp:t}){const e=mc(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return s`<span class="time-ago" title=${n}>${e}</span>`}function W(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Y(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function re(t){return(t??"").trim().toLowerCase()}function nt(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function Dt(t){return typeof t!="number"||Number.isNaN(t)?3:t}function ei(t){const e=Dt(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}let vc=0;const le=f([]);function x(t,e="success",n=4e3){const a=++vc;le.value=[...le.value,{id:a,message:t,type:e}],setTimeout(()=>{le.value=le.value.filter(i=>i.id!==a)},n)}function fc(t){le.value=le.value.filter(e=>e.id!==t)}function gc(){const t=le.value;return t.length===0?null:s`
    <div class="toast-container">
      ${t.map(e=>s`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>fc(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const _c="masc_dashboard_agent_name",Me=f(null),Zn=f(!1),gn=f(""),ta=f([]),_n=f([]),Re=f(""),Qe=f(!1);function De(t){Me.value=t,ni()}function hi(){Me.value=null,gn.value="",ta.value=[],_n.value=[],Re.value=""}function $c(){const t=Me.value;return t?Mt.value.find(e=>e.name===t)??null:null}function xo(t){return t?xt.value.filter(e=>e.assignee===t):[]}async function ni(){const t=Me.value;if(t){Zn.value=!0,gn.value="",ta.value=[],_n.value=[];try{const e=await _l(80);ta.value=e.filter(i=>i.includes(t)).slice(0,20);const n=xo(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async i=>{try{const o=await $l(i.id,25);return{taskId:i.id,text:o.trim()}}catch(o){const r=o instanceof Error?o.message:"history load failed";return{taskId:i.id,text:`Failed to load history: ${r}`}}}));_n.value=a}catch(e){gn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Zn.value=!1}}}async function yi(){var a;const t=Me.value,e=Re.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(_c))==null?void 0:a.trim())||"dashboard";Qe.value=!0;try{await co(n,`@${t} ${e}`),Re.value="",x(`Mention sent to ${t}`,"success"),ni()}catch(i){const o=i instanceof Error?i.message:"Failed to send mention";x(o,"error")}finally{Qe.value=!1}}function hc({task:t}){return s`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${At} status=${t.status} />
    </div>
  `}function yc({row:t}){return s`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function bc(){var i,o,r,d;const t=Me.value;if(!t)return null;const e=$c(),n=xo(t),a=ta.value;return s`
    <div
      class="agent-detail-overlay"
      onClick=${p=>{p.target.classList.contains("agent-detail-overlay")&&hi()}}
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
                        <${At} status=${e.status} />
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
                ${(d=e==null?void 0:e.interests)==null?void 0:d.map(p=>s`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${p}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?s`
                    ${e.current_task?s`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?s`<span>Last seen: <${j} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{ni()}} disabled=${Zn.value}>
              ${Zn.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${hi}>Close</button>
          </div>
        </div>

        ${gn.value?s`<div class="council-error">${gn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${S} title="Assigned Tasks">
            ${n.length===0?s`<div class="empty-state">No assigned tasks</div>`:s`<div class="agent-detail-task-list">${n.map(p=>s`<${hc} key=${p.id} task=${p} />`)}</div>`}
          <//>

          <${S} title="Recent Activity">
            ${a.length===0?s`<div class="empty-state">No recent room activity match</div>`:s`<div class="agent-activity-list">${a.map((p,_)=>s`<div key=${_} class="agent-activity-line">${p}</div>`)}</div>`}
          <//>
        </div>

        <${S} title="Task History">
          ${_n.value.length===0?s`<div class="empty-state">No task history loaded</div>`:s`<div class="agent-history-list">${_n.value.map(p=>s`<${yc} key=${p.taskId} row=${p} />`)}</div>`}
        <//>

        <${S} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Re.value}
              onInput=${p=>{Re.value=p.target.value}}
              onKeyDown=${p=>{p.key==="Enter"&&yi()}}
              disabled=${Qe.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{yi()}}
              disabled=${Qe.value||Re.value.trim()===""}
            >
              ${Qe.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const ea=600*1e3,Fn=1200*1e3;function Ao(t){switch(t){case"in_progress":return"In Progress";case"claimed":return"Claimed";case"done":return"Done";case"cancelled":return"Cancelled";default:return"Todo"}}function So(t){switch(t){case"dispatchable":return"Dispatch";case"drift":return"Drift";case"quiet":return"Quiet";case"offline":return"Offline";default:return"Loaded"}}function kc(t){return t.updated_at??t.created_at??null}function bi(t,e,n){var T,B;const a=re(t.assignee),i=a?e.get(a)??null:null,o=i?n.get(a)??null:null,r=(o==null?void 0:o.lastActivityAt)??(i==null?void 0:i.last_seen)??null,d=r?Math.max(0,Date.now()-W(r)):Number.POSITIVE_INFINITY,p=nt(t.description),_=nt(i==null?void 0:i.current_task)??(o==null?void 0:o.lastActivityText)??null,m=t.status==="claimed"||t.status==="in_progress";let c="ok",l="Fresh owner coverage",g=_??p??t.id,b=!1,A=!1;return t.status==="todo"?t.assignee?i?i.status==="offline"||i.status==="inactive"?(b=!0,c="bad",l="Assigned owner is offline",g="Queue item is blocked until ownership changes."):d>ea?(c="warn",l="Owner exists but live signal is quiet",g=_??"Owner may need a nudge before pickup."):((o==null?void 0:o.activeAssignedCount)??0)>0||(T=i.current_task)!=null&&T.trim()?(c="warn",l="Owner is already carrying active work",g=_??`${(o==null?void 0:o.activeAssignedCount)??0} active tasks already assigned.`):(l="Ready and covered by a fresh operator",g=_??p??"This can be picked up immediately."):(b=!0,c="bad",l="Assigned owner is not present in the room",g="Reassign or bring the owner back online."):(b=!0,c=Dt(t.priority)<=2?"bad":"warn",l=Dt(t.priority)<=2?"Urgent ready work has no owner":"Ready work has no owner",g="Assign an agent before this queue item slips."):m&&(t.assignee?i?i.status==="offline"||i.status==="inactive"?(b=!0,c="bad",l="Assigned owner is offline",g=_??"Execution has no live operator right now."):d>Fn?(A=!0,c="bad",l="Assigned owner has gone quiet",g=_??"Fresh operator signal is missing."):d>ea?(A=!0,c="warn",l="Execution has been quiet for too long",g=_??"Check whether this work is blocked."):(B=i.current_task)!=null&&B.trim()?(l="Execution has fresh owner coverage",g=_??p??t.id):(c="warn",l=t.status==="claimed"?"Claimed work is waiting for explicit focus":"Owner is live but current_task is empty",g=_??"Task state and agent focus are drifting apart."):(b=!0,c="bad",l="Assigned owner is not active in the room",g="Execution is orphaned until ownership is restored."):(b=!0,c="bad",l="Active work has no assignee",g="Claim or reassign this task immediately.")),{task:t,assigneeAgent:i,motion:o,tone:c,note:l,focus:g,lastSignalAt:r,lastTouchedAt:kc(t),ownerGap:b,quiet:A}}function xc(t,e){var l;const n=e.get(re(t.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},a=n.lastActivityAt??t.last_seen??null,i=a?Math.max(0,Date.now()-W(a)):Number.POSITIVE_INFINITY,o=!!((l=t.current_task)!=null&&l.trim()),r=n.activeAssignedCount,d=o||r>0;let p="loaded",_="ok",m="Healthy active load",c=nt(t.current_task)??n.lastActivityText??"Ready for assignment";return t.status==="offline"||t.status==="inactive"?(p="offline",_="bad",m="Agent is unavailable"):d&&i>Fn?(p="quiet",_="bad",m="Working without a fresh signal"):r>0&&!o?(p="drift",_="warn",m="Claimed work exists but current_task is empty",c=`${r} active tasks need explicit focus.`):o&&r===0?(p="drift",_="warn",m="current_task has no matching claimed work",c=nt(t.current_task)??"Task metadata and operator state drifted."):!d&&i<=ea?(p="dispatchable",_="ok",m="Fresh signal and no active load",c=n.lastActivityText??"Ready for assignment."):d?i>ea&&(p="loaded",_="warn",m="Execution load is healthy but slightly quiet",c=nt(t.current_task)??`${r} active tasks in flight.`):(p="quiet",_=i>Fn?"bad":"warn",m=i>Fn?"No fresh signal while idle":"Reachable, but not freshly active",c=n.lastActivityText??"Likely available after a quick check-in."),{agent:t,motion:n,tone:_,state:p,note:m,focus:c,lastSignalAt:a,activeTaskCount:r}}function He({label:t,value:e,color:n,caption:a}){return s`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?s`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Ac({item:t}){return s`
    <div class="execution-alert ${t.tone}">
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="task"?ei(t.taskRow.task.priority):So(t.agentRow.state)}
        </span>
        ${t.kind==="task"?s`<span>${Ao(t.taskRow.task.status)}</span>`:s`<span>${t.agentRow.agent.name}</span>`}
        ${t.timestamp?s`<span><${j} timestamp=${t.timestamp} /></span>`:s`<span>No signal</span>`}
      </div>
    </div>
  `}function ki({row:t}){var e;return s`
    <div class="execution-task-row ${t.tone}">
      <div class="monitor-row-header">
        <span class="monitor-pill ${t.tone}">${ei(t.task.priority)}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.task.title}</span>
            <span class="monitor-sub">${t.task.id}</span>
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        ${t.assigneeAgent?s`<${At} status=${t.assigneeAgent.status} />`:s`<span class="monitor-sub">No owner</span>`}
        <span class="monitor-pill ${t.tone}">${Ao(t.task.status)}</span>
      </div>

      <div class="monitor-meta">
        ${t.task.assignee?s`<span>Owner ${t.task.assignee}</span>`:s`<span>Unassigned</span>`}
        ${t.lastTouchedAt?s`<span>Touched <${j} timestamp=${t.lastTouchedAt} /></span>`:null}
        ${t.lastSignalAt?s`<span>Signal <${j} timestamp=${t.lastSignalAt} /></span>`:s`<span>No live signal</span>`}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${(e=t.assigneeAgent)!=null&&e.current_task&&nt(t.assigneeAgent.current_task)!==t.focus?s`<div class="monitor-footnote">Owner focus: ${nt(t.assigneeAgent.current_task)}</div>`:null}
    </div>
  `}function Sc({row:t}){const{agent:e}=t;return s`
    <button class="monitor-row ${t.tone}" onClick=${()=>De(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?s`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${At} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${So(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?s`<span>Signal <${j} timestamp=${t.lastSignalAt} /></span>`:s`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?s`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
    </button>
  `}function wc(){const t=Mt.value,e=xt.value,n=new Map(t.map(c=>[re(c.name),c])),a=Ta.value,i=e.filter(c=>c.status==="claimed"||c.status==="in_progress").map(c=>bi(c,n,a)).sort((c,l)=>{const g=Y(l.tone)-Y(c.tone);return g!==0?g:W(l.lastSignalAt??l.lastTouchedAt)-W(c.lastSignalAt??c.lastTouchedAt)}),o=e.filter(c=>c.status==="todo").map(c=>bi(c,n,a)).sort((c,l)=>{const g=Y(l.tone)-Y(c.tone);if(g!==0)return g;const b=Dt(c.task.priority)-Dt(l.task.priority);return b!==0?b:W(c.lastTouchedAt)-W(l.lastTouchedAt)}),r=t.map(c=>xc(c,a)).filter(c=>c.state==="dispatchable"||c.state==="drift"||c.state==="quiet").sort((c,l)=>{if(c.state==="dispatchable"&&l.state!=="dispatchable")return-1;if(l.state==="dispatchable"&&c.state!=="dispatchable")return 1;const g=Y(l.tone)-Y(c.tone);return g!==0?g:W(l.lastSignalAt)-W(c.lastSignalAt)}),d=[...i.filter(c=>c.tone!=="ok").map(c=>({kind:"task",key:`active-${c.task.id}`,tone:c.tone,title:c.task.title,subtitle:`${c.note} · ${c.focus}`,timestamp:c.lastSignalAt??c.lastTouchedAt,taskRow:c})),...o.filter(c=>c.tone==="bad").map(c=>({kind:"task",key:`ready-${c.task.id}`,tone:c.tone,title:c.task.title,subtitle:`${c.note} · ${c.focus}`,timestamp:c.lastTouchedAt,taskRow:c})),...r.filter(c=>c.state==="drift"||c.tone==="bad").map(c=>({kind:"agent",key:`agent-${c.agent.name}`,tone:c.tone,title:c.agent.name,subtitle:`${c.note} · ${c.focus}`,timestamp:c.lastSignalAt,agentRow:c}))].sort((c,l)=>{const g=Y(l.tone)-Y(c.tone);return g!==0?g:W(l.timestamp)-W(c.timestamp)}).slice(0,8),p=r.filter(c=>c.state==="dispatchable"),_=[...i,...o].filter(c=>c.ownerGap),m=i.filter(c=>c.quiet);return s`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${He} label="Active work" value=${i.length} color="#fbbf24" caption="claimed + in progress" />
        <${He} label="Needs intervention" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="stalled or drifting now" />
        <${He} label="Ownership gaps" value=${_.length} color=${_.length>0?"#fb7185":"#4ade80"} caption="missing or unavailable owners" />
        <${He} label="Dispatchable agents" value=${p.length} color="#22d3ee" caption="fresh signal, no active load" />
        <${He} label="Quiet execution" value=${m.length} color=${m.length>0?"#fbbf24":"#4ade80"} caption="active tasks with aging signals" />
      </div>

      <${S} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs a nudge right now</h2>
          <p class="monitor-subheadline">Severity comes first, then the freshest evidence we have about the stall or drift.</p>
        </div>
        <div class="monitor-alert-list">
          ${d.length===0?s`<div class="empty-state">No active execution risks right now</div>`:d.map(c=>s`<${Ac} key=${c.key} item=${c} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${S} title="Ready Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Ready work, sorted by dispatch risk</h2>
            <p class="monitor-subheadline">Ownerless or owner-unavailable items float to the top before healthy assigned queue items.</p>
          </div>
          <div class="monitor-list">
            ${o.length===0?s`<div class="empty-state">No ready tasks in the queue</div>`:o.slice(0,10).map(c=>s`<${ki} key=${c.task.id} row=${c} />`)}
          </div>
        <//>

        <${S} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity appears first. Task-state drift stays visible so owners can clean up metadata fast.</p>
          </div>
          <div class="monitor-list">
            ${r.length===0?s`<div class="empty-state">No agent capacity or drift signals right now</div>`:r.map(c=>s`<${Sc} key=${c.agent.name} row=${c} />`)}
          </div>
        <//>
      </div>

      <${S} title="Active Execution Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Claimed and in-progress work</h2>
          <p class="monitor-subheadline">Rows are sorted by risk first, then by the freshest operator signal tied to each task.</p>
        </div>
        <div class="monitor-list">
          ${i.length===0?s`<div class="empty-state">No active execution tasks</div>`:i.map(c=>s`<${ki} key=${c.task.id} row=${c} />`)}
        </div>
      <//>
    </div>
  `}function Tc(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Cc(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Nc(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function xi(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function wo(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Rc(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function To(t){if(!t)return null;const e=Kt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function Co({keeper:t,showRawStatus:e=!1}){if(Pt(()=>{t!=null&&t.name&&vo(t.name)},[t==null?void 0:t.name]),!t)return s`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Kt.value[t.name],a=To(t),i=fs.value[t.name];return s`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(a==null?void 0:a.health_state)??"unknown"}</span>
        <span class="pill">${Tc(a==null?void 0:a.quiet_reason)}</span>
        <span class="pill">next ${Cc((a==null?void 0:a.next_action_path)??"direct_message")}</span>
        ${i?s`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(a==null?void 0:a.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(a==null?void 0:a.last_reply_status)??"unknown"}
        ${a!=null&&a.last_reply_at?s` · ${wo(a.last_reply_at)}`:null}
        ${a!=null&&a.next_eligible_at_s?s` · next eligible ${Rc(a.next_eligible_at_s)}`:null}
      </div>
      ${a!=null&&a.last_error?s`<div class="control-status-copy control-error-copy">${a.last_error}</div>`:null}
      ${e?s`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function No({keeperName:t,placeholder:e}){const[n,a]=Yi("");Pt(()=>{t&&vo(t)},[t]);const i=at.value[t]??[],o=gs.value[t]??!1,r=Ht.value[t],d=async()=>{const p=n.trim();if(!(!t||!p)){a("");try{await zl(t,p)}catch(_){const m=_ instanceof Error?_.message:`Failed to message ${t}`;x(m,"error")}}};return s`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${i.length===0?s`<div class="control-status-copy">No direct keeper conversation yet.</div>`:i.map(p=>s`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${xi(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${xi(p)}`}>${Nc(p)}</span>
                  ${p.timestamp?s`<span class="keeper-conversation-time">${wo(p.timestamp)}</span>`:null}
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
            onClick=${()=>{d()}}
            disabled=${o||n.trim()===""||!t}
          >
            ${o?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${r?s`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function Ro({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const a=To(e),i=_s.value[e.name]??!1,o=$s.value[e.name]??!1,r=(a==null?void 0:a.next_action_path)??"direct_message",d=(a==null?void 0:a.recoverable)??r==="recover";return s`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{jl(e.name,t).catch(p=>{const _=p instanceof Error?p.message:`Failed to probe ${e.name}`;x(_,"error")})}}
        disabled=${i||!t.trim()}
      >
        ${i?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{ql(e.name,t).catch(p=>{const _=p instanceof Error?p.message:`Failed to recover ${e.name}`;x(_,"error")})}}
        disabled=${o||!d||!t.trim()}
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
  `}const ai=f(null);function na(t){ai.value=t,zn(t.name)}function Ai(){ai.value=null}const ye=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Dc(t){if(!t)return 0;const e=ye.findIndex(n=>n.level===t);return e>=0?e:0}function Lc({keeper:t}){const e=Dc(t.autonomy_level),n=ye[e]??ye[0];if(!n)return null;const a=(e+1)/ye.length*100;return s`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${ye.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${ye.map((i,o)=>s`
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
            <strong><${j} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?s`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Kn(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Pc({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",i=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return s`
    <div class="keeper-kpis">
      ${i.map(o=>s`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?s`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Kn(t.context_tokens)}</div>
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
  `}function Ic({keeper:t}){var m,c;const e=t.metrics_series??[];if(e.length<2){const l=(((m=t.context)==null?void 0:m.context_ratio)??0)*100,g=l>85?"#ef4444":l>70?"#f59e0b":"#22c55e";return s`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${l.toFixed(1)}%;background:${g}"></div>
        </div>
        <span class="chart-pct">${l.toFixed(1)}%</span>
      </div>`}const n=200,a=60,i=2,o=e.length,r=e.map((l,g)=>{const b=i+g/(o-1)*(n-2*i),A=a-i-(l.context_ratio??0)*(a-2*i);return{x:b,y:A,p:l}}),d=r.map(({x:l,y:g})=>`${l.toFixed(1)},${g.toFixed(1)}`).join(" "),p=(((c=e[e.length-1])==null?void 0:c.context_ratio)??0)*100,_=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return s`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${i}" y1="${(a-i-.5*(a-2*i)).toFixed(1)}" x2="${n-i}" y2="${(a-i-.5*(a-2*i)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${i}" y1="${(a-i-.7*(a-2*i)).toFixed(1)}" x2="${n-i}" y2="${(a-i-.7*(a-2*i)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${i}" y1="${(a-i-.85*(a-2*i)).toFixed(1)}" x2="${n-i}" y2="${(a-i-.85*(a-2*i)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:l})=>l.is_handoff).map(({x:l})=>s`
          <line x1="${l.toFixed(1)}" y1="${i}" x2="${l.toFixed(1)}" y2="${a-i}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${d}" fill="none" stroke="${_}" stroke-width="1.5"/>
        ${r.filter(({p:l})=>l.is_compaction).map(({x:l,y:g})=>s`
          <circle cx="${l.toFixed(1)}" cy="${g.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}const Oa=f("");function Ec({keeper:t}){var i,o,r,d;const e=Oa.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((i=t.traits)==null?void 0:i.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],a=e?n.filter(p=>p.title.toLowerCase().includes(e)||p.key.includes(e)||p.value.toLowerCase().includes(e)):n;return s`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Oa.value}
        onInput=${p=>{Oa.value=p.target.value}}
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
      ${t.context_tokens!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Kn(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Kn(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?s`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Kn(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((d=t.context)==null?void 0:d.has_checkpoint)!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Oc({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return s`
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
  `}function Mc({items:t}){return t.length===0?s`<div class="empty-state" style="font-size:13px">No equipment</div>`:s`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>s`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function zc({rels:t}){const e=Object.entries(t);return e.length===0?s`<div class="empty-state" style="font-size:13px">No relationships</div>`:s`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>s`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function Si({traits:t,label:e}){return t.length===0?null:s`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>s`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Ma(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function jc({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Ma(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Ma(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Ma(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return s`
    <div class="keeper-signal-list">
      ${n.map(a=>s`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function Do(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function qc(){try{const t=await kn({actor:Do(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Xs(t.result);xn(),await pe(),e!=null&&e.skipped_reason?x(e.skipped_reason,"warning"):x(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";x(e,"error")}}function Fc({keeper:t}){return s`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Co} keeper=${t} />
          <${Ro}
            actor=${Do()}
            keeper=${t}
            onPokeLodge=${()=>{qc()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${No}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function Kc(){var e,n,a;const t=ai.value;return t?s`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${i=>{i.target.classList.contains("keeper-detail-overlay")&&Ai()}}
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
            <${At} status=${t.status} />
            ${t.model?s`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Ai()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Pc} keeper=${t} />

        ${""}
        <${Ic} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${S} title="Field Dictionary">
            <${Ec} keeper=${t} />
          <//>

          ${""}
          <${S} title="Profile">
            <${Si} traits=${t.traits??[]} label="Traits" />
            <${Si} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?s`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?s`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?s`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?s`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${j} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?s`
              <${S} title="Autonomy">
                <${Lc} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?s`
              <${S} title="TRPG Stats">
                <${Oc} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?s`
              <${S} title="Equipment (${t.inventory.length})">
                <${Mc} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?s`
              <${S} title="Relationships (${Object.keys(t.relationships).length})">
                <${zc} rels=${t.relationships} />
              <//>
            `:null}

          <${S} title="Runtime Signals">
            <${jc} keeper=${t} />
          <//>

          <${S} title="Memory & Context">
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
        <${Fc} keeper=${t} />
      </div>
    </div>
  `:null}const Ie=f(!1);function Hc(){Ie.value=!0}function wi(){Ie.value=!1}function Bc(){Ie.value=!Ie.value}const za=600*1e3,ja=1200*1e3,Ti=.8,qa=f("triage");function _e(t){const e=(t??"").toLowerCase();return e==="bad"?"bad":e==="warn"?"warn":"ok"}function Nn(t){switch(t){case"bad":return"#fb7185";case"warn":return"#fbbf24";default:return"#4ade80"}}function Ci(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function Ni(t){if(t==null||!Number.isFinite(t))return"unknown";if(t<60)return`${Math.round(t)}s`;const e=Math.round(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Uc(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function Fa(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Gc(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Wc(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Jc(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Vc(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Ci(t.quiet_start)}-${Ci(t.quiet_end)} KST are active.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${Ni(t.interval_s)}, but no tick has run yet.`:`Lodge ticks every ${Ni(t.interval_s)} with planner ${t.use_planner?"on":"off"} and delegated LLM ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled.":"Lodge runtime status is unavailable in the current dashboard payload."}function Ri(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function $e({label:t,value:e,color:n,caption:a}){return s`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
      ${a?s`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Qc({item:t}){return s`
    <button class="monitor-alert ${t.tone}" onClick=${t.action}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.detail}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">${t.tone==="bad"?"Act now":t.tone==="warn"?"Watch":"Stable"}</span>
        ${t.timestamp?s`<span><${j} timestamp=${t.timestamp} /></span>`:null}
      </div>
    </button>
  `}function Ka({tone:t,title:e,subtitle:n,meta:a,focus:i,onClick:o}){return s`
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
  `}function Di(){var _t,zt,Wt,$t,ht,H,V,y,St,Jt,ae,L,wt,se,Tn,je,qe;const t=ee.value,e=Mt.value,n=xt.value,a=Ut.value,i=ho.value,o=(_t=t==null?void 0:t.monitoring)==null?void 0:_t.board,r=(zt=t==null?void 0:t.monitoring)==null?void 0:zt.council,d=It.value,p=new Map(e.map(u=>[re(u.name),u])),_=Ta.value,m=e.map(u=>{var ci;const C=_.get(re(u.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},M=C.lastActivityAt??u.last_seen??null,Q=M?Math.max(0,Date.now()-W(M)):Number.POSITIVE_INFINITY,E=C.activeAssignedCount,it=!!((ci=u.current_task)!=null&&ci.trim()),G=it||E>0;let J="ok",pt="Fresh and ready",ve=!1,fe=!1;return u.status==="offline"||u.status==="inactive"?(J=G?"bad":"warn",pt=G?"Load without an available owner":"Offline"):G&&Q>ja?(J="bad",pt="Execution is stale"):E>0&&!it?(J="warn",pt="Claimed work has no current_task",fe=!0):it&&E===0?(J="warn",pt="current_task has no claimed work",fe=!0):!G&&Q<=za?(J="ok",pt="Dispatchable now",ve=!0):!G&&Q>ja?(J="warn",pt="Idle but not freshly active"):G&&Q>za&&(J="warn",pt="Execution is getting quiet"),{agent:u,lastSignalAt:M,activeTaskCount:E,tone:J,note:pt,focus:nt(u.current_task)??C.lastActivityText??(ve?"Ready for assignment.":"Waiting for a clearer signal."),dispatchable:ve,drift:fe}}).sort((u,C)=>{const M=Y(C.tone)-Y(u.tone);return M!==0?M:W(C.lastSignalAt)-W(u.lastSignalAt)}),c=a.map(u=>{var J;const C=yo.value.get(u.name)??"idle",M=bo.value.has(u.name),Q=u.context_ratio??0,E=u.diagnostic??null;let it="ok",G="Healthy keeper";return M||u.status==="offline"||C==="handoff-imminent"||(E==null?void 0:E.health_state)==="offline"||(E==null?void 0:E.health_state)==="degraded"?(it="bad",G=nt(E==null?void 0:E.summary,56)??(M?"Heartbeat stale":C==="handoff-imminent"?"Handoff imminent":(E==null?void 0:E.health_state)==="degraded"?"Keeper degraded":"Keeper offline")):((E==null?void 0:E.health_state)==="stale"||Q>=Ti||C==="preparing"||C==="compacting")&&(it="warn",G=nt(E==null?void 0:E.summary,56)??(Q>=Ti?"High context pressure":`Lifecycle ${C}`)),{keeper:u,tone:it,note:G,focus:nt(E==null?void 0:E.summary,120)??nt((J=u.agent)==null?void 0:J.current_task)??u.skill_primary??u.last_proactive_reason??u.memory_recent_note??"No active focus",timestamp:u.last_heartbeat??null}}).sort((u,C)=>{const M=Y(C.tone)-Y(u.tone);return M!==0?M:W(C.timestamp)-W(u.timestamp)}),l=n.filter(u=>u.status==="todo"||u.status==="claimed"||u.status==="in_progress").map(u=>{var ve,fe;const C=u.assignee?p.get(re(u.assignee))??null:null,M=C?_.get(re(C.name))??null:null,Q=(M==null?void 0:M.lastActivityAt)??(C==null?void 0:C.last_seen)??null,E=Q?Math.max(0,Date.now()-W(Q)):Number.POSITIVE_INFINITY,it=u.status==="claimed"||u.status==="in_progress";let G="ok",J="Covered",pt=!1;return u.assignee?!C||C.status==="offline"||C.status==="inactive"?(G="bad",J="Assigned owner is unavailable",pt=!0):it&&E>ja?(G="bad",J="Execution has lost a fresh signal"):it&&E>za?(G="warn",J="Execution is drifting quiet"):u.status==="todo"&&Dt(u.priority)<=2&&!((ve=C.current_task)!=null&&ve.trim())&&((M==null?void 0:M.activeAssignedCount)??0)===0?(G="ok",J="Ready for dispatch"):it&&!((fe=C.current_task)!=null&&fe.trim())&&(G="warn",J="Owner focus is not explicit"):(G=Dt(u.priority)<=2?"bad":"warn",J=it?"Active work has no owner":"Ready work has no owner",pt=!0),{task:u,owner:C,lastSignalAt:Q,tone:G,note:J,focus:nt(C==null?void 0:C.current_task)??(M==null?void 0:M.lastActivityText)??nt(u.description)??"Needs operator attention.",ownerGap:pt}}).sort((u,C)=>{const M=Y(C.tone)-Y(u.tone);if(M!==0)return M;const Q=Dt(u.task.priority)-Dt(C.task.priority);return Q!==0?Q:W(C.lastSignalAt??C.task.updated_at??C.task.created_at)-W(u.lastSignalAt??u.task.updated_at??u.task.created_at)}),g=l.filter(u=>u.task.status==="todo"&&Dt(u.task.priority)<=2),b=l.filter(u=>u.ownerGap).length,A=m.filter(u=>u.dispatchable),T=m.filter(u=>u.drift||u.tone!=="ok"),B=c.filter(u=>u.tone!=="ok"),U=t!=null&&t.paused?"bad":((Wt=t==null?void 0:t.data_quality)==null?void 0:Wt.board_contract_ok)===!1||(($t=t==null?void 0:t.data_quality)==null?void 0:$t.council_feed_ok)===!1?"warn":d?"ok":"warn",z=[];t!=null&&t.paused&&z.push({key:"paused",tone:"bad",title:"Room is paused",detail:t.tempo?`Tempo is ${t.tempo}. Resume from Ops when ready.`:"Resume from Ops when ready.",timestamp:((ht=t.data_quality)==null?void 0:ht.last_sync_at)??null,action:()=>Rt("ops")}),d||z.push({key:"live-connection",tone:"warn",title:"Live feed is reconnecting",detail:"Dashboard telemetry is stale until the SSE stream recovers.",timestamp:null,action:Hc}),_e(o==null?void 0:o.alert_level)!=="ok"&&z.push({key:"board-monitor",tone:_e(o==null?void 0:o.alert_level),title:"Board feed needs attention",detail:`Freshness ${Fa(o==null?void 0:o.last_activity_age_s)} · ${(o==null?void 0:o.unanswered_posts)??0} unanswered posts.`,timestamp:null,action:()=>Rt("board")}),_e(r==null?void 0:r.alert_level)!=="ok"&&z.push({key:"council-monitor",tone:_e(r==null?void 0:r.alert_level),title:"Council quorum risk is elevated",detail:`${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum · freshness ${Fa(r==null?void 0:r.last_activity_age_s)}.`,timestamp:null,action:()=>Rt("board")}),(((H=t==null?void 0:t.data_quality)==null?void 0:H.board_contract_ok)===!1||((V=t==null?void 0:t.data_quality)==null?void 0:V.council_feed_ok)===!1)&&z.push({key:"data-quality",tone:"warn",title:"Dashboard data quality is degraded",detail:`${((y=t.data_quality)==null?void 0:y.board_contract_ok)===!1?"Board contract":"Board contract ok"} · ${((St=t.data_quality)==null?void 0:St.council_feed_ok)===!1?"Council feed degraded":"Council feed ok"}.`,timestamp:((Jt=t.data_quality)==null?void 0:Jt.last_sync_at)??null,action:()=>Rt("ops")});const R=[...z,...l.filter(u=>u.tone!=="ok").slice(0,3).map(u=>({key:`task-${u.task.id}`,tone:u.tone,title:u.task.title,detail:`${u.note} · ${u.focus}`,timestamp:u.lastSignalAt??u.task.updated_at??u.task.created_at??null,action:()=>Rt("overview")})),...B.slice(0,2).map(u=>({key:`keeper-${u.keeper.name}`,tone:u.tone,title:u.keeper.name,detail:`${u.note} · ${u.focus}`,timestamp:u.timestamp,action:()=>na(u.keeper)})),...T.slice(0,2).map(u=>({key:`agent-${u.agent.name}`,tone:u.tone,title:u.agent.name,detail:`${u.note} · ${u.focus}`,timestamp:u.lastSignalAt,action:()=>De(u.agent.name)}))].sort((u,C)=>{const M=Y(C.tone)-Y(u.tone);return M!==0?M:W(C.timestamp)-W(u.timestamp)}).slice(0,8),P=qa.value;return s`
    <div class="overview-sub-tabs">
      <button
        class="sub-tab-btn ${P==="triage"?"active":""}"
        onClick=${()=>{qa.value="triage"}}
      >Triage</button>
      <button
        class="sub-tab-btn ${P==="dispatch"?"active":""}"
        onClick=${()=>{qa.value="dispatch"}}
      >Dispatch</button>
    </div>

    ${P==="dispatch"?s`<${wc} />`:s`<div class="stats-grid">
      <${$e}
        label="Room State"
        value=${t!=null&&t.paused?"Paused":"Running"}
        color=${Nn(U)}
        caption=${(t==null?void 0:t.room)??(t==null?void 0:t.project)??"default room"}
      />
      <${$e}
        label="Urgent Queue"
        value=${g.length}
        color=${g.length>0?"#fb7185":"#4ade80"}
        caption="todo tasks at P1/P2"
      />
      <${$e}
        label="Active Work"
        value=${i.inProgress.length}
        color="#fbbf24"
        caption="claimed + in progress"
      />
      <${$e}
        label="Dispatchable"
        value=${A.length}
        color="#22d3ee"
        caption="fresh agents with no load"
      />
      <${$e}
        label="Keeper Pressure"
        value=${B.length}
        color=${B.length>0?"#fbbf24":"#4ade80"}
        caption="stale or high-context keepers"
      />
      <${$e}
        label="Owner Gaps"
        value=${b}
        color=${b>0?"#fb7185":"#4ade80"}
        caption="tasks missing a live owner"
      />
    </div>

    <${S} title="Room Health" class="section">
      <div class="monitor-section-head">
        <h2 class="monitor-headline">Operational health at a glance</h2>
        <p class="monitor-subheadline">The Overview now prioritizes room state, feed freshness, and immediate intervention signals over full entity dumps.</p>
      </div>
      <div class="overview-health-grid">
        <div class="stat-card">
          <div class="stat-label">Live Feed</div>
          <div class="stat-value" style=${`color:${d?"#4ade80":"#fbbf24"}`}>${d?"Online":"Retrying"}</div>
          <div class="monitor-stat-caption">${yn.value} events seen in this session</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Board Feed</div>
          <div class="stat-value" style=${`color:${Nn(_e(o==null?void 0:o.alert_level))}`}>${Ri(o==null?void 0:o.alert_level)}</div>
          <div class="monitor-stat-caption">Freshness ${Fa(o==null?void 0:o.last_activity_age_s)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Council Feed</div>
          <div class="stat-value" style=${`color:${Nn(_e(r==null?void 0:r.alert_level))}`}>${Ri(r==null?void 0:r.alert_level)}</div>
          <div class="monitor-stat-caption">${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Runtime</div>
          <div class="stat-value" style=${`color:${Nn(U)}`}>${t!=null&&t.paused?"Paused":"Stable"}</div>
          <div class="monitor-stat-caption">Uptime ${Uc((t==null?void 0:t.uptime_seconds)??0)}</div>
        </div>
      </div>
      <div class="overview-note-stack">
        <div class="overview-inline-note">
          ${(ae=t==null?void 0:t.data_quality)!=null&&ae.last_sync_at?s`Last sync <${j} timestamp=${t.data_quality.last_sync_at} />`:s`No sync metadata yet`}
        </div>
        <div class="overview-inline-note">
          ${t!=null&&t.tempo?`Tempo ${t.tempo}`:"Tempo unavailable"}${(t==null?void 0:t.tempo_interval_s)!=null?` · ${t.tempo_interval_s}s interval`:""}
        </div>
        <div class="overview-inline-note">${Vc(t==null?void 0:t.lodge)}</div>
        ${(L=t==null?void 0:t.lodge)!=null&&L.last_skip_reason?s`<div class="overview-inline-note">Last Lodge skip: ${t.lodge.last_skip_reason}</div>`:null}
      </div>
    <//>

    <div class="grid-2col">
      <${S} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs intervention right now</h2>
          <p class="monitor-subheadline">Room-level risks, stalled work, and keeper/agent drift are sorted into one operator-facing queue.</p>
        </div>
        <div class="monitor-alert-list">
          ${R.length===0?s`<div class="empty-state">No immediate intervention required</div>`:R.map(u=>s`<${Qc} key=${u.key} item=${u} />`)}
        </div>
      <//>

      <${S} title="Dispatch Window" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who can pick up work next</h2>
          <p class="monitor-subheadline">Fresh capacity stays visible here so dispatch does not require opening the full Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${A.length===0?s`<div class="empty-state">No fully dispatchable agents right now</div>`:A.slice(0,5).map(u=>s`
                <${Ka}
                  key=${u.agent.name}
                  tone=${u.tone}
                  title=${u.agent.name}
                  subtitle=${u.note}
                  meta=${[u.lastSignalAt?`Signal ${new Date(u.lastSignalAt).toLocaleTimeString()}`:"No recent signal",u.agent.model??"model n/a",u.agent.koreanName??"room agent"]}
                  focus=${u.focus}
                  onClick=${()=>De(u.agent.name)}
                />
              `)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${S} title="Execution Pulse" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Priority work and ownership drift</h2>
          <p class="monitor-subheadline">Urgent ready tasks and active execution issues stay visible without duplicating the full Execution surface.</p>
        </div>
        <div class="monitor-list">
          ${l.length===0?s`<div class="empty-state">No active or ready tasks</div>`:l.slice(0,6).map(u=>s`
                <${Ka}
                  key=${u.task.id}
                  tone=${u.tone}
                  title=${u.task.title}
                  subtitle=${`${ei(u.task.priority)} · ${u.note}`}
                  meta=${[u.task.assignee?`Owner ${u.task.assignee}`:"Unassigned",u.lastSignalAt?`Signal ${new Date(u.lastSignalAt).toLocaleTimeString()}`:"No live signal",u.task.updated_at?`Touched ${new Date(u.task.updated_at).toLocaleTimeString()}`:"No task timestamp"]}
                  focus=${u.focus}
                  onClick=${()=>Rt("overview")}
                />
              `)}
        </div>
      <//>

      <${S} title="Keeper Pressure" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Long-running keepers under pressure</h2>
          <p class="monitor-subheadline">Only keepers with real pressure stay in the Overview. The full keeper census still lives in the Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${B.length===0?s`<div class="empty-state">No keeper pressure signals right now</div>`:B.slice(0,5).map(u=>{var C;return s`
                <${Ka}
                  key=${u.keeper.name}
                  tone=${u.tone}
                  title=${u.keeper.name}
                  subtitle=${(C=u.keeper.diagnostic)!=null&&C.health_state?`${u.note} · ${u.keeper.diagnostic.health_state}`:u.note}
                  meta=${[u.timestamp?`Heartbeat ${new Date(u.timestamp).toLocaleTimeString()}`:"No heartbeat",`Context ${typeof u.keeper.context_ratio=="number"?Math.round(u.keeper.context_ratio*100):0}%`,u.keeper.model?`Model ${u.keeper.model}`:"model n/a",u.keeper.diagnostic?`${Wc(u.keeper.diagnostic.quiet_reason)} · next ${Jc(u.keeper.diagnostic.next_action_path)} · reply ${u.keeper.diagnostic.last_reply_status}`:"Diagnostic unavailable"]}
                  focus=${u.focus}
                  onClick=${()=>na(u.keeper)}
                />
              `})}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${S} title="Agent Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Agents with drift or aging load</h2>
          <p class="monitor-subheadline">This is the short list. Use the Agents tab when you need the full live monitor.</p>
        </div>
        <div class="monitor-list">
          ${T.length===0?s`<div class="empty-state">No agent drift or stale load right now</div>`:T.slice(0,5).map(u=>s`
                <button class="monitor-row ${u.tone}" onClick=${()=>De(u.agent.name)}>
                  <div class="monitor-row-header">
                    <div class="monitor-row-title">
                      <div class="monitor-name-line">
                        <span class="monitor-title">${u.agent.name}</span>
                        ${u.agent.koreanName?s`<span class="monitor-sub">${u.agent.koreanName}</span>`:null}
                      </div>
                      <div class="monitor-note">${u.note}</div>
                    </div>
                    <${At} status=${u.agent.status} />
                    <span class="monitor-pill ${u.tone}">${u.dispatchable?"Ready":u.drift?"Drift":"Watch"}</span>
                  </div>
                  <div class="monitor-meta">
                    ${u.lastSignalAt?s`<span>Signal <${j} timestamp=${u.lastSignalAt} /></span>`:s`<span>No recent signal</span>`}
                    <span>${u.activeTaskCount>0?`${u.activeTaskCount} active tasks`:"No active tasks"}</span>
                    ${u.agent.model?s`<span>${u.agent.model}</span>`:null}
                  </div>
                  <div class="monitor-focus">${u.focus}</div>
                </button>
              `)}
        </div>
      <//>

      <${S} title="Runtime Notes" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Secondary runtime context</h2>
          <p class="monitor-subheadline">This stays below the triage queue so operators can scan first and drill later.</p>
        </div>
        <div class="overview-note-stack">
          <div class="overview-inline-note">
            Room ${(t==null?void 0:t.room)??"default"}${t!=null&&t.cluster?` · Cluster ${t.cluster}`:""}${t!=null&&t.project?` · Project ${t.project}`:""}
          </div>
          <div class="overview-inline-note">
            ${t!=null&&t.version?`Version ${t.version}`:"Version unavailable"} · Active agents ${Ul.value.length} · Total tasks ${n.length}
          </div>
          <div class="overview-inline-note">
            ${Ge.value?`Perpetual runtime ${Ge.value.running?"running":"stopped"}${Ge.value.goal?` · ${nt(Ge.value.goal,120)}`:""}`:"Perpetual runtime unavailable"}
          </div>
          <div class="overview-inline-note">
            Lodge ${(wt=t==null?void 0:t.lodge)!=null&&wt.enabled?"enabled":"disabled"} · Last tick ${((se=t==null?void 0:t.lodge)==null?void 0:se.last_tick_ago)??"never"} · Self heartbeats ${((je=(Tn=t==null?void 0:t.lodge)==null?void 0:Tn.active_self_heartbeats)==null?void 0:je.length)??0}${(qe=t==null?void 0:t.lodge)!=null&&qe.last_skip_reason?` · Skip ${t.lodge.last_skip_reason}`:""}
          </div>
          <div class="overview-inline-note">
            ${a.length>0?`Hot keepers: ${B.length} · Highest context ${Gc(Math.max(...a.map(u=>u.context_tokens??0)))}`:"No keepers registered"}
          </div>
        </div>
      <//>
    </div>`}
  `}const Gt=f(null),aa=f(!1),sa=f(null),Cs=f(null),ia=f(null),si=f("operations"),An=f(null),Ns=f(!1),oa=f(null);function N(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function v(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function w(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Rs(t){return typeof t=="boolean"?t:void 0}function ot(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Yc(t){if(N(t))return{policy_class:v(t.policy_class),approval_class:v(t.approval_class),tool_allowlist:ot(t.tool_allowlist),model_allowlist:ot(t.model_allowlist),requires_human_for:ot(t.requires_human_for),autonomy_level:v(t.autonomy_level),escalation_timeout_sec:w(t.escalation_timeout_sec),kill_switch:Rs(t.kill_switch),frozen:Rs(t.frozen)}}function Xc(t){if(N(t))return{headcount_cap:w(t.headcount_cap),active_operation_cap:w(t.active_operation_cap),max_cost_usd:w(t.max_cost_usd),max_tokens:w(t.max_tokens)}}function Lo(t){if(!N(t))return null;const e=v(t.unit_id),n=v(t.label),a=v(t.kind);return!e||!n||!a?null:{unit_id:e,label:n,kind:a,parent_unit_id:v(t.parent_unit_id)??null,leader_id:v(t.leader_id)??null,roster:ot(t.roster),capability_profile:ot(t.capability_profile),source:v(t.source),created_at:v(t.created_at),updated_at:v(t.updated_at),policy:Yc(t.policy),budget:Xc(t.budget)}}function Po(t){if(!N(t))return null;const e=Lo(t.unit);return e?{unit:e,leader_status:v(t.leader_status),roster_total:w(t.roster_total),roster_live:w(t.roster_live),active_operation_count:w(t.active_operation_count),health:v(t.health),reasons:ot(t.reasons),children:Array.isArray(t.children)?t.children.map(Po).filter(n=>n!==null):[]}:null}function Zc(t){if(N(t))return{total_units:w(t.total_units),company_count:w(t.company_count),platoon_count:w(t.platoon_count),squad_count:w(t.squad_count),leaf_agent_unit_count:w(t.leaf_agent_unit_count),live_agent_count:w(t.live_agent_count),managed_unit_count:w(t.managed_unit_count),active_operation_count:w(t.active_operation_count)}}function td(t){const e=N(t)?t:{};return{version:v(e.version),generated_at:v(e.generated_at),source:v(e.source),summary:Zc(e.summary),units:Array.isArray(e.units)?e.units.map(Po).filter(n=>n!==null):[]}}function Io(t){if(!N(t))return null;const e=v(t.operation_id),n=v(t.objective),a=v(t.assigned_unit_id),i=v(t.trace_id),o=v(t.status);return!e||!n||!a||!i||!o?null:{operation_id:e,objective:n,assigned_unit_id:a,autonomy_level:v(t.autonomy_level),policy_class:v(t.policy_class),budget_class:v(t.budget_class),detachment_session_id:v(t.detachment_session_id)??null,trace_id:i,checkpoint_ref:v(t.checkpoint_ref)??null,active_goal_ids:ot(t.active_goal_ids),note:v(t.note)??null,created_by:v(t.created_by),source:v(t.source),status:o,created_at:v(t.created_at),updated_at:v(t.updated_at)}}function ed(t){if(!N(t))return null;const e=Io(t.operation);return e?{operation:e,assigned_unit_label:v(t.assigned_unit_label)}:null}function nd(t){const e=N(t)?t:{},n=N(e.summary)?e.summary:void 0;return{version:v(e.version),generated_at:v(e.generated_at),summary:n?{total:w(n.total),active:w(n.active),paused:w(n.paused),managed:w(n.managed),projected:w(n.projected)}:void 0,operations:Array.isArray(e.operations)?e.operations.map(ed).filter(a=>a!==null):[]}}function ad(t){if(!N(t))return null;const e=v(t.detachment_id),n=v(t.operation_id),a=v(t.assigned_unit_id);return!e||!n||!a?null:{detachment_id:e,operation_id:n,assigned_unit_id:a,leader_id:v(t.leader_id)??null,roster:ot(t.roster),session_id:v(t.session_id)??null,checkpoint_ref:v(t.checkpoint_ref)??null,runtime_kind:v(t.runtime_kind)??null,runtime_ref:v(t.runtime_ref)??null,source:v(t.source),status:v(t.status),last_event_at:v(t.last_event_at)??null,last_progress_at:v(t.last_progress_at)??null,heartbeat_deadline:v(t.heartbeat_deadline)??null,created_at:v(t.created_at),updated_at:v(t.updated_at)}}function sd(t){if(!N(t))return null;const e=ad(t.detachment);return e?{detachment:e,assigned_unit_label:v(t.assigned_unit_label),operation:Io(t.operation)}:null}function id(t){const e=N(t)?t:{},n=N(e.summary)?e.summary:void 0;return{version:v(e.version),generated_at:v(e.generated_at),summary:n?{total:w(n.total),active:w(n.active),projected:w(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(sd).filter(a=>a!==null):[]}}function od(t){if(!N(t))return null;const e=v(t.decision_id),n=v(t.trace_id),a=v(t.requested_action),i=v(t.scope_type),o=v(t.scope_id);return!e||!n||!a||!i||!o?null:{decision_id:e,trace_id:n,requested_action:a,scope_type:i,scope_id:o,operation_id:v(t.operation_id)??null,target_unit_id:v(t.target_unit_id)??null,requested_by:v(t.requested_by),status:v(t.status),reason:v(t.reason)??null,source:v(t.source),detail:t.detail,created_at:v(t.created_at),decided_at:v(t.decided_at)??null,expires_at:v(t.expires_at)??null}}function rd(t){const e=N(t)?t:{},n=N(e.summary)?e.summary:void 0;return{version:v(e.version),generated_at:v(e.generated_at),summary:n?{total:w(n.total),pending:w(n.pending),approved:w(n.approved),denied:w(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(od).filter(a=>a!==null):[]}}function ld(t){if(!N(t))return null;const e=Lo(t.unit);return e?{unit:e,roster_total:w(t.roster_total),roster_live:w(t.roster_live),headcount_cap:w(t.headcount_cap),active_operations:w(t.active_operations),active_operation_cap:w(t.active_operation_cap),utilization:w(t.utilization)}:null}function cd(t){const e=N(t)?t:{};return{version:v(e.version),generated_at:v(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(ld).filter(n=>n!==null):[]}}function dd(t){if(!N(t))return null;const e=v(t.alert_id);return e?{alert_id:e,severity:v(t.severity),kind:v(t.kind),scope_type:v(t.scope_type),scope_id:v(t.scope_id),title:v(t.title),detail:v(t.detail),timestamp:v(t.timestamp)}:null}function ud(t){const e=N(t)?t:{},n=N(e.summary)?e.summary:void 0;return{version:v(e.version),generated_at:v(e.generated_at),summary:n?{total:w(n.total),bad:w(n.bad),warn:w(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(dd).filter(a=>a!==null):[]}}function pd(t){if(!N(t))return null;const e=v(t.event_id),n=v(t.trace_id),a=v(t.event_type);return!e||!n||!a?null:{event_id:e,trace_id:n,event_type:a,operation_id:v(t.operation_id)??null,unit_id:v(t.unit_id)??null,actor:v(t.actor)??null,source:v(t.source),timestamp:v(t.timestamp),detail:t.detail}}function md(t){const e=N(t)?t:{};return{version:v(e.version),generated_at:v(e.generated_at),events:Array.isArray(e.events)?e.events.map(pd).filter(n=>n!==null):[]}}function vd(t){if(!N(t))return null;const e=v(t.code),n=v(t.severity),a=v(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a}}function fd(t){if(!N(t))return null;const e=v(t.lane_id),n=v(t.label),a=v(t.kind),i=v(t.phase),o=v(t.motion_state),r=v(t.source_of_truth),d=v(t.movement_reason),p=v(t.current_step);if(!e||!n||!a||!i||!o||!r||!d||!p)return null;const _=N(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:a,present:Rs(t.present)??!1,phase:i,motion_state:o,source_of_truth:r,last_movement_at:v(t.last_movement_at)??null,movement_reason:d,current_step:p,blockers:ot(t.blockers),counts:{operations:w(_.operations),detachments:w(_.detachments),workers:w(_.workers),approvals:w(_.approvals),alerts:w(_.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(vd).filter(m=>m!==null):[]}}function gd(t){if(!N(t))return null;const e=v(t.event_id),n=v(t.lane_id),a=v(t.kind),i=v(t.timestamp),o=v(t.title),r=v(t.detail),d=v(t.tone),p=v(t.source);return!e||!n||!a||!i||!o||!r||!d||!p?null:{event_id:e,lane_id:n,kind:a,timestamp:i,title:o,detail:r,tone:d,source:p}}function _d(t){if(!N(t))return null;const e=v(t.code),n=v(t.severity),a=v(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a,lane_ids:ot(t.lane_ids),count:w(t.count)??0}}function $d(t){if(!N(t))return;const e=N(t.overview)?t.overview:{},n=N(t.gaps)?t.gaps:{},a=N(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:v(t.generated_at),overview:{active_lanes:w(e.active_lanes),moving_lanes:w(e.moving_lanes),stalled_lanes:w(e.stalled_lanes),projected_lanes:w(e.projected_lanes),last_movement_at:v(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(fd).filter(i=>i!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(gd).filter(i=>i!==null):[],gaps:{count:w(n.count),items:Array.isArray(n.items)?n.items.map(_d).filter(i=>i!==null):[]},recommended_next_action:a?{tool:v(a.tool)??"masc_operator_snapshot",label:v(a.label)??"Observe operator state",reason:v(a.reason)??"",lane_id:v(a.lane_id)??null}:void 0}}function hd(t){const e=N(t)?t:{};return{version:v(e.version),generated_at:v(e.generated_at),topology:td(e.topology),operations:nd(e.operations),detachments:id(e.detachments),alerts:ud(e.alerts),decisions:rd(e.decisions),capacity:cd(e.capacity),traces:md(e.traces),swarm_status:$d(e.swarm_status)}}function yd(t){if(!N(t))return null;const e=v(t.title),n=v(t.path);return!e||!n?null:{title:e,path:n}}function bd(t){if(!N(t))return null;const e=v(t.id),n=v(t.title),a=v(t.summary);return!e||!n||!a?null:{id:e,title:n,summary:a}}function kd(t){if(!N(t))return null;const e=v(t.id),n=v(t.title),a=v(t.tool),i=v(t.summary);return!e||!n||!a||!i?null:{id:e,title:n,tool:a,summary:i,success_signals:ot(t.success_signals),pitfalls:ot(t.pitfalls)}}function xd(t){if(!N(t))return null;const e=v(t.id),n=v(t.title),a=v(t.summary),i=v(t.when_to_use);return!e||!n||!a||!i?null:{id:e,title:n,summary:a,when_to_use:i,steps:Array.isArray(t.steps)?t.steps.map(kd).filter(o=>o!==null):[]}}function Ad(t){if(!N(t))return null;const e=v(t.id),n=v(t.title),a=v(t.description);return!e||!n||!a?null:{id:e,title:n,description:a,tools:ot(t.tools)}}function Sd(t){if(!N(t))return null;const e=v(t.id),n=v(t.title),a=v(t.symptom),i=v(t.why),o=v(t.fix_tool),r=v(t.fix_summary);return!e||!n||!a||!i||!o||!r?null:{id:e,title:n,symptom:a,why:i,fix_tool:o,fix_summary:r}}function wd(t){if(!N(t))return null;const e=v(t.id),n=v(t.title),a=v(t.path_id),i=v(t.transport);return!e||!n||!a||!i?null:{id:e,title:n,path_id:a,transport:i,request:t.request,response:t.response,notes:ot(t.notes)}}function Td(t){const e=N(t)?t:{};return{version:v(e.version),generated_at:v(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(yd).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(bd).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(xd).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Ad).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Sd).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(wd).filter(n=>n!==null):[]}}function Cd(t){si.value=t}async function Ca(){aa.value=!0,sa.value=null;try{const t=await Lr();Gt.value=hd(t)}catch(t){sa.value=t instanceof Error?t.message:"Failed to load command plane snapshot"}finally{aa.value=!1}}async function Nd(){Ns.value=!0,oa.value=null;try{const t=await Pr();An.value=Td(t)}catch(t){oa.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Ns.value=!1}}async function ne(t,e,n){Cs.value=t,ia.value=null;try{await Ir(e,n),await Ca()}catch(a){throw ia.value=a instanceof Error?a.message:"Failed to execute command-plane action",a}finally{Cs.value=null}}function Rd(t){return ne(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Dd(t){return ne(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function Ld(t){return ne(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Pd(t={}){return ne("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function Id(t){return ne(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Ed(t){return ne(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Od(t,e){return ne(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Md(t,e){return ne(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}function zd(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Et(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function jd(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function qd(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function tt(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}function Fd(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function X(t){return Cs.value===t}function Kd(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Hd(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function Bd(t){return t.status==="claimed"||t.status==="in_progress"}function Ud(t){const e=An.value;if(!e)return null;for(const n of e.golden_paths){const a=n.steps.find(i=>i.tool===t);if(a)return a}return null}function Ha(t){var e;return((e=An.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function Gd(t){const e=An.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(a=>n.has(a.id))}async function Xt(t){try{await t()}catch{}}function Wd(){var o;const t=Gt.value,e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,a=t==null?void 0:t.decisions.summary,i=t==null?void 0:t.alerts.summary;return s`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>Units</span><strong>${(e==null?void 0:e.total_units)??0}</strong><small>${(e==null?void 0:e.managed_unit_count)??0} managed</small></div>
      <div class="monitor-stat-card"><span>Ops</span><strong>${(n==null?void 0:n.active)??0}</strong><small>${((o=t==null?void 0:t.detachments.summary)==null?void 0:o.active)??0} detachments</small></div>
      <div class="monitor-stat-card"><span>Approvals</span><strong>${(a==null?void 0:a.pending)??0}</strong><small>${(a==null?void 0:a.total)??0} tracked</small></div>
      <div class="monitor-stat-card"><span>Alerts</span><strong>${(i==null?void 0:i.bad)??0}</strong><small>${(i==null?void 0:i.warn)??0} warn</small></div>
    </div>
  `}function Jd(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function Vd({lane:t}){const e=t.counts??{},n=Jd(t);return s`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.label}</strong>
          <div class="command-card-sub">${t.source_of_truth}</div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${tt(n)}">${t.phase}</span>
          <span class="command-chip ${tt(n)}">${t.motion_state}</span>
          <span class="command-chip">${Et(t.last_movement_at)}</span>
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
              ${t.hard_flags.map(a=>s`<span class="command-tag ${tt(a.severity)}">${a.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Qd({event:t}){return s`
    <div class="command-trace-row">
      <div class="command-trace-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${tt(t.tone)}">${t.lane_id}</span>
        <span class="command-chip">${t.kind}</span>
        <span class="command-chip">${Et(t.timestamp)}</span>
      </div>
      <div class="command-card-sub">${t.source}</div>
      <div class="command-card-foot">${t.detail}</div>
    </div>
  `}function Yd({gap:t}){return s`
    <div class="command-guide-inline">
      <div class="command-guide-head">
        <strong>${t.code}</strong>
        <span class="command-chip ${tt(t.severity)}">${t.count}</span>
      </div>
      <p>${t.summary}</p>
      ${t.lane_ids.length>0?s`<div class="command-tag-row">${t.lane_ids.map(e=>s`<span class="command-tag">${e}</span>`)}</div>`:null}
    </div>
  `}function Xd(){var r;const t=(r=Gt.value)==null?void 0:r.swarm_status,e=(t==null?void 0:t.lanes.filter(d=>d.present))??[],n=(t==null?void 0:t.gaps.items)??[],a=(t==null?void 0:t.timeline.slice(0,6))??[],i=t==null?void 0:t.overview,o=t==null?void 0:t.recommended_next_action;return s`
    <section class="card command-section">
      <div class="card-title">Swarm</div>
      ${t?s`
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>Active Lanes</span><strong>${(i==null?void 0:i.active_lanes)??0}</strong><small>${(i==null?void 0:i.moving_lanes)??0} moving</small></div>
              <div class="monitor-stat-card"><span>Stalled</span><strong>${(i==null?void 0:i.stalled_lanes)??0}</strong><small>${(i==null?void 0:i.projected_lanes)??0} projected</small></div>
              <div class="monitor-stat-card"><span>Last Movement</span><strong>${Et(i==null?void 0:i.last_movement_at)}</strong><small>${t.generated_at?`snapshot ${Et(t.generated_at)}`:"snapshot now"}</small></div>
              <div class="monitor-stat-card"><span>Next Action</span><strong>${(o==null?void 0:o.label)??"Observe operator state"}</strong><small>${(o==null?void 0:o.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            <div class="command-swarm-layout">
              <div class="command-card-stack">
                ${e.length>0?e.map(d=>s`<${Vd} lane=${d} />`):s`<div class="empty-state">No active swarm lanes.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight">
                  <div class="command-guide-head">
                    <strong>${(o==null?void 0:o.label)??"Observe operator state"}</strong>
                    <span class="command-chip">${(o==null?void 0:o.lane_id)??"global"}</span>
                  </div>
                  <p>${(o==null?void 0:o.reason)??"No active swarm lane is visible yet."}</p>
                  <div class="command-card-foot">${(o==null?void 0:o.tool)??"masc_operator_snapshot"}</div>
                </div>

                <div class="command-guide-card ${n.length>0?"warn":"ok"}">
                  <div class="command-guide-head">
                    <strong>Hard Gaps</strong>
                    <span class="command-chip ${tt(n.some(d=>d.severity==="bad")?"bad":n.length>0?"warn":"ok")}">${n.length}</span>
                  </div>
                  ${n.length>0?s`<div class="command-card-stack">${n.slice(0,4).map(d=>s`<${Yd} gap=${d} />`)}</div>`:s`<p>No hard gaps are currently visible.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>Movement Timeline</strong>
                    <span class="command-chip">${a.length}</span>
                  </div>
                  ${a.length>0?s`<div class="command-card-stack">${a.map(d=>s`<${Qd} event=${d} />`)}</div>`:s`<p>No recent movement events are attached yet.</p>`}
                </div>
              </div>
            </div>
          `:s`<div class="empty-state">Swarm status is unavailable.</div>`}
    </section>
  `}function Zd(){return s`
    <div class="command-surface-tabs">
      ${["operations","topology","alerts","trace","control"].map(e=>s`
        <button
          class="command-surface-tab ${si.value===e?"active":""}"
          onClick=${()=>Cd(e)}
        >
          ${e}
        </button>
      `)}
    </div>
  `}function tu(){var Wt,$t,ht,H,V,y,St,Jt,ae;const t=Gt.value,e=ee.value,n=Kd(),a=n?Mt.value.find(L=>L.name===n)??null:null,i=n?xt.value.filter(L=>L.assignee===n&&Bd(L)):[],o=((Wt=t==null?void 0:t.operations.summary)==null?void 0:Wt.active)??0,r=(($t=t==null?void 0:t.detachments.summary)==null?void 0:$t.total)??0,d=((ht=t==null?void 0:t.decisions.summary)==null?void 0:ht.pending)??0,p=t==null?void 0:t.detachments.detachments.find(L=>{const wt=L.detachment.heartbeat_deadline,se=wt?Date.parse(wt):Number.NaN;return L.detachment.status==="stalled"||!Number.isNaN(se)&&se<=Date.now()}),_=t==null?void 0:t.alerts.alerts.find(L=>L.severity==="bad"),m=!!(e!=null&&e.room||e!=null&&e.project),c=(a==null?void 0:a.current_task)??null,l=Hd(a==null?void 0:a.last_seen),g=l!=null?l<=120:null,b=[m?{title:"Room readiness",tone:"ok",detail:`${(e==null?void 0:e.room)??(e==null?void 0:e.project)??"unknown"} · base ${(e==null?void 0:e.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room readiness",tone:"bad",detail:"No room snapshot yet. Set room to repo root before joining.",tool:"masc_set_room"},n?a?i.length===0?{title:"Task readiness",tone:"warn",detail:`${n} has no claimed task. Claim one or create one first.`,tool:xt.value.length>0?"masc_claim":"masc_add_task"}:c?g===!1?{title:"Task readiness",tone:"warn",detail:`${n} current_task=${c}, but heartbeat is stale (${l}s).`,tool:"masc_heartbeat"}:{title:"Task readiness",tone:"ok",detail:`${n} current_task=${c}${l!=null?` · last seen ${l}s ago`:""}`,tool:"masc_plan_get_task"}:{title:"Task readiness",tone:"bad",detail:`${n} has a claimed task but no session current_task binding.`,tool:"masc_plan_set_task"}:{title:"Task readiness",tone:"bad",detail:`${n} is not visible in the room roster.`,tool:"masc_join"}:{title:"Task readiness",tone:"warn",detail:"No ?agent= query param. Dashboard can show room health but not agent-specific next steps.",tool:"masc_join"},!t||(((H=t.topology.summary)==null?void 0:H.managed_unit_count)??0)===0?{title:"Operation readiness",tone:"warn",detail:"No managed units defined yet. CPv2 benchmark cannot start before hierarchy exists.",tool:"masc_unit_define"}:o===0?{title:"Operation readiness",tone:"warn",detail:`${((V=t.topology.summary)==null?void 0:V.managed_unit_count)??0} managed units are ready, but there is no active operation.`,tool:"masc_operation_start"}:{title:"Operation readiness",tone:"ok",detail:`${o} active operation(s) across ${((y=t.topology.summary)==null?void 0:y.managed_unit_count)??0} managed unit(s).`,tool:"masc_observe_operations"},d>0?{title:"Dispatch readiness",tone:"warn",detail:`${d} pending approval(s) are blocking strict actions.`,tool:"masc_policy_approve"}:o>0&&r===0?{title:"Dispatch readiness",tone:"bad",detail:"Active operation exists but no detachment has been materialized yet.",tool:"masc_dispatch_tick"}:p||_?{title:"Dispatch readiness",tone:"warn",detail:`Dispatch needs reconciliation${p?` · detachment ${p.detachment.detachment_id} is stalled`:""}${_?` · alert ${_.title??_.alert_id}`:""}.`,tool:d>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"Dispatch readiness",tone:"ok",detail:`${r} detachment(s) visible and no strict approval backlog.`,tool:"masc_detachment_list"}],A=m?!n||!a?"masc_join":i.length===0?xt.value.length>0?"masc_claim":"masc_add_task":c?g===!1?"masc_heartbeat":!t||(((St=t.topology.summary)==null?void 0:St.managed_unit_count)??0)===0?"masc_unit_define":o===0?"masc_operation_start":d>0?"masc_policy_approve":o>0&&r===0||p||_?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",T=Ud(A),U=Gd(A==="masc_set_room"?["repo-root-room"]:A==="masc_plan_set_task"?["claimed-not-current"]:A==="masc_heartbeat"?["heartbeat-stale"]:A==="masc_dispatch_tick"?["no-detachments"]:A==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),z=Ha("room_task_hygiene"),R=Ha("cpv2_benchmark"),P=Ha("supervisor_session"),_t=((Jt=An.value)==null?void 0:Jt.docs)??[],zt=[z,R,P].filter(L=>L!==null);return s`
    <div class="command-guide-grid">
      <section class="card command-section">
        <div class="card-title">Readiness</div>
        <div class="command-guide-readiness">
          ${b.map(L=>s`
            <article class="command-guide-card ${tt(L.tone)}">
              <div class="command-guide-head">
                <strong>${L.title}</strong>
                <span class="command-chip ${tt(L.tone)}">${L.tone}</span>
              </div>
              <p>${L.detail}</p>
              <div class="command-card-foot">Next tool: ${L.tool}</div>
            </article>
          `)}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title">Next Step</div>
        <article class="command-guide-card highlight">
          <div class="command-guide-head">
            <strong>${(T==null?void 0:T.title)??A}</strong>
            <span class="command-chip ok">${A}</span>
          </div>
          <p>${(T==null?void 0:T.summary)??"Use the next tool in the canonical flow to remove the current blocker."}</p>
          ${(ae=T==null?void 0:T.success_signals)!=null&&ae.length?s`<div class="command-tag-row">
                ${T.success_signals.map(L=>s`<span class="command-tag ok">${L}</span>`)}
              </div>`:null}
          ${U.length>0?s`<div class="command-guide-list">
                ${U.map(L=>s`
                  <article class="command-guide-inline">
                    <strong>${L.title}</strong>
                    <div>${L.symptom}</div>
                    <div class="command-card-sub">Fix with ${L.fix_tool}: ${L.fix_summary}</div>
                  </article>
                `)}
              </div>`:null}
        </article>
      </section>

      <section class="card command-section">
        <div class="card-title">How It Works</div>
        ${Ns.value?s`<div class="empty-state">Loading CPv2 runbook…</div>`:oa.value?s`<div class="empty-state error">${oa.value}</div>`:s`
                <div class="command-guide-paths">
                  ${zt.map(L=>s`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${L.title}</strong>
                        <span class="command-chip">${L.id}</span>
                      </div>
                      <p>${L.summary}</p>
                      <div class="command-card-sub">${L.when_to_use}</div>
                      <div class="command-step-list">
                        ${L.steps.map(wt=>s`
                          <div class="command-step-row">
                            <span class="command-step-tool">${wt.tool}</span>
                            <span>${wt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${_t.length>0?s`<div class="command-doc-links">
                      ${_t.map(L=>s`<span class="command-tag">${L.title}: ${L.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Eo({node:t,depth:e=0}){const n=t.roster_live??0,a=t.roster_total??t.unit.roster.length,i=t.active_operation_count??0,o=t.unit.policy;return s`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${Fd(t.unit.kind)}</span>
            <span class="command-chip ${tt(t.health)}">${t.health??"ok"}</span>
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
            ${t.children.map(r=>s`<${Eo} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function eu({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,a=`resume:${e.operation_id}`,i=`recall:${e.operation_id}`;return s`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${tt(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Autonomy</span><span>${e.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${e.budget_class??"standard"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Updated</span><span>${Et(e.updated_at)}</span>
      </div>
      ${e.checkpoint_ref?s`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        ${e.source==="managed"&&e.status==="active"?s`
              <button class="control-btn ghost" disabled=${X(n)} onClick=${()=>Xt(()=>Rd(e.operation_id))}>
                ${X(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${X(i)} onClick=${()=>Xt(()=>Ld(e.operation_id))}>
                ${X(i)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?s`
              <button class="control-btn ghost" disabled=${X(a)} onClick=${()=>Xt(()=>Dd(e.operation_id))}>
                ${X(a)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function nu({card:t}){var n;const e=t.detachment;return s`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${tt(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${Et(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${qd(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${Et(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?s`<span class="command-tag ${jd(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function au({alert:t}){return s`
    <article class="command-alert ${tt(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${tt(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${Et(t.timestamp)}</span>
      </div>
      ${t.detail?s`<p>${t.detail}</p>`:null}
    </article>
  `}function su({event:t}){return s`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${Et(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${zd(t.detail)}</pre>
    </article>
  `}function iu({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,a=t.source==="projected_operator";return s`
    <article class="command-card ${tt(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${tt(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${Et(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!a?s`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${X(e)} onClick=${()=>Xt(()=>Id(t.decision_id))}>
                ${X(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${X(n)} onClick=${()=>Xt(()=>Ed(t.decision_id))}>
                ${X(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${a?s`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function ou({row:t}){var d,p,_;const e=t.unit,n=`freeze:${e.unit_id}`,a=`kill:${e.unit_id}`,i=!!((d=e.policy)!=null&&d.frozen),o=!!((p=e.policy)!=null&&p.kill_switch),r=Math.round((t.utilization??0)*100);return s`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${tt(r>100?"bad":r>70?"warn":"ok")}">${r}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>Headcount Cap</span><span>${t.headcount_cap??0}</span>
        <span>Ops</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${((_=e.policy)==null?void 0:_.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${i?"yes":"no"}</span>
        <span>Kill Switch</span><span>${o?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${X(n)} onClick=${()=>Xt(()=>Od(e.unit_id,!i))}>
          ${X(n)?"Applying…":i?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${X(a)} onClick=${()=>Xt(()=>Md(e.unit_id,!o))}>
          ${X(a)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function ru(){const t=Gt.value;return s`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Operations</div>
        ${t&&t.operations.operations.length>0?s`<div class="command-card-stack">
              ${t.operations.operations.map(e=>s`<${eu} card=${e} />`)}
            </div>`:s`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title">Detachments</div>
        ${t&&t.detachments.detachments.length>0?s`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>s`<${nu} card=${e} />`)}
            </div>`:s`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function lu(){const t=Gt.value;return s`
    <section class="card command-section">
      <div class="card-title">Topology</div>
      ${t&&t.topology.units.length>0?s`${t.topology.units.map(e=>s`<${Eo} node=${e} />`)}`:s`<div class="empty-state">No command topology projected yet.</div>`}
    </section>
  `}function cu(){const t=Gt.value;return s`
    <section class="card command-section">
      <div class="card-title">Alerts</div>
      ${t&&t.alerts.alerts.length>0?s`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>s`<${au} alert=${e} />`)}
          </div>`:s`<div class="empty-state">No command-plane alerts right now.</div>`}
    </section>
  `}function du(){const t=Gt.value;return s`
    <section class="card command-section">
      <div class="card-title">Trace</div>
      ${t&&t.traces.events.length>0?s`<div class="command-trace-stack">
            ${t.traces.events.map(e=>s`<${su} event=${e} />`)}
          </div>`:s`<div class="empty-state">No recent trace events.</div>`}
    </section>
  `}function uu(){const t=Gt.value;return s`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Approval Queue</div>
        ${t&&t.decisions.decisions.length>0?s`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>s`<${iu} decision=${e} />`)}
            </div>`:s`<div class="empty-state">No approval queue items.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Unit Controls</div>
        ${t&&t.capacity.capacity.length>0?s`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>s`<${ou} row=${e} />`)}
            </div>`:s`<div class="empty-state">No capacity rows projected.</div>`}
      </section>
    </div>
  `}function pu(){switch(si.value){case"topology":return s`<${lu} />`;case"alerts":return s`<${cu} />`;case"trace":return s`<${du} />`;case"control":return s`<${uu} />`;case"operations":default:return s`<${ru} />`}}function mu(){return Pt(()=>{Nd()},[]),s`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>Command Plane</h2>
          <p>Operations-first command surface for company → platoon → squad → agent orchestration, approvals, alerts, and traceability.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Xt(()=>Pd())}}
            disabled=${X("dispatch:tick")}
          >
            ${X("dispatch:tick")?"Reconciling…":"Run Tick"}
          </button>
          <button class="control-btn ghost" onClick=${()=>{Ca()}} disabled=${aa.value}>
            ${aa.value?"Refreshing…":"Refresh"}
          </button>
        </div>
      </div>

      ${sa.value?s`<div class="empty-state error">${sa.value}</div>`:null}
      ${ia.value?s`<div class="empty-state error">${ia.value}</div>`:null}

      <${Wd} />
      <${Xd} />
      <${tu} />
      <${Zd} />
      <${pu} />
    </section>
  `}const Sn=f(null),ra=f(!1),te=f(null),F=f(!1),la=f([]);let vu=1;function K(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function D(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function ct(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Oo(t){return typeof t=="boolean"?t:void 0}function fu(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function be(t,e=[]){if(Array.isArray(t))return t;if(!K(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function gu(t){return K(t)?{id:D(t.id),seq:ct(t.seq),from:D(t.from)??D(t.from_agent)??"system",content:D(t.content)??"",timestamp:D(t.timestamp)??new Date().toISOString(),type:D(t.type)}:null}function _u(t){return K(t)?{room_id:D(t.room_id),current_room:D(t.current_room)??D(t.room),project:D(t.project),cluster:D(t.cluster),paused:Oo(t.paused),pause_reason:D(t.pause_reason)??null,paused_by:D(t.paused_by)??null,paused_at:D(t.paused_at)??null}:{}}function Li(t){if(!K(t))return;const e=Object.entries(t).map(([n,a])=>{const i=D(a);return i?[n,i]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function $u(t){if(!K(t))return null;const e=K(t.status)?t.status:void 0,n=K(t.summary)?t.summary:K(e==null?void 0:e.summary)?e.summary:void 0,a=K(t.session)?t.session:K(e==null?void 0:e.session)?e.session:void 0,i=D(t.session_id)??D(n==null?void 0:n.session_id)??D(a==null?void 0:a.session_id);if(!i)return null;const o=Li(t.report_paths)??Li(e==null?void 0:e.report_paths),r=be(t.recent_events,["events"]).filter(K);return{session_id:i,status:D(t.status)??D(n==null?void 0:n.status)??D(a==null?void 0:a.status),progress_pct:ct(t.progress_pct)??ct(n==null?void 0:n.progress_pct),elapsed_sec:ct(t.elapsed_sec)??ct(n==null?void 0:n.elapsed_sec),remaining_sec:ct(t.remaining_sec)??ct(n==null?void 0:n.remaining_sec),done_delta_total:ct(t.done_delta_total)??ct(n==null?void 0:n.done_delta_total),summary:n,team_health:K(t.team_health)?t.team_health:K(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:K(t.communication_metrics)?t.communication_metrics:K(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:K(t.orchestration_state)?t.orchestration_state:K(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:K(t.cascade_metrics)?t.cascade_metrics:K(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:a,recent_events:r}}function hu(t){if(!K(t))return null;const e=D(t.name);if(!e)return null;const n=K(t.context)?t.context:void 0;return{name:e,agent_name:D(t.agent_name),status:D(t.status),autonomy_level:D(t.autonomy_level),context_ratio:ct(t.context_ratio)??ct(n==null?void 0:n.context_ratio),generation:ct(t.generation),active_goal_ids:fu(t.active_goal_ids),last_autonomous_action_at:D(t.last_autonomous_action_at)??null,last_turn_ago_s:ct(t.last_turn_ago_s),model:D(t.model)??D(t.active_model)??D(t.primary_model)}}function yu(t){if(!K(t))return null;const e=D(t.confirm_token)??D(t.token);return e?{confirm_token:e,actor:D(t.actor),action_type:D(t.action_type),target_type:D(t.target_type),target_id:D(t.target_id)??null,delegated_tool:D(t.delegated_tool),created_at:D(t.created_at),preview:t.preview}:null}function bu(t){const e=K(t)?t:{};return{room:_u(e.room),sessions:be(e.sessions,["items","sessions"]).map($u).filter(n=>n!==null),keepers:be(e.keepers,["items","keepers"]).map(hu).filter(n=>n!==null),recent_messages:be(e.recent_messages,["messages"]).map(gu).filter(n=>n!==null),pending_confirms:be(e.pending_confirms,["items","confirms"]).map(yu).filter(n=>n!==null),available_actions:be(e.available_actions,["actions"]).filter(K).map(n=>({action_type:D(n.action_type)??"unknown",target_type:D(n.target_type)??"unknown",description:D(n.description),confirm_required:Oo(n.confirm_required)}))}}function Rn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Pi(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function ca(t){la.value=[{...t,id:vu++,at:new Date().toISOString()},...la.value].slice(0,20)}function Mo(t){return t.confirm_required?Rn(t.preview)||"Confirmation required":Rn(t.result)||Rn(t.executed_action)||Rn(t.delegated_tool_result)||t.status}async function wn(){ra.value=!0,te.value=null;try{const t=await Dr();Sn.value=bu(t)}catch(t){te.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{ra.value=!1}}async function ku(t){F.value=!0,te.value=null;try{const e=await kn(t);return ca({actor:t.actor,action_type:t.action_type,target_label:Pi(t),outcome:e.confirm_required?"preview":"executed",message:Mo(e),delegated_tool:e.delegated_tool}),await wn(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw te.value=n,ca({actor:t.actor,action_type:t.action_type,target_label:Pi(t),outcome:"error",message:n}),e}finally{F.value=!1}}async function xu(t,e){F.value=!0,te.value=null;try{const n=await Or(t,e);return ca({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Mo(n),delegated_tool:n.delegated_tool}),await wn(),n}catch(n){const a=n instanceof Error?n.message:"Operator confirmation failed";throw te.value=a,ca({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),n}finally{F.value=!1}}const zo="masc_dashboard_agent_name";function Au(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(zo))==null?void 0:a.trim())||"dashboard"}const Na=f(Au()),Ye=f(""),Ds=f("Operator pause"),Xe=f(""),da=f(""),Ls=f("2"),ua=f(""),Le=f("note"),pa=f(""),ma=f(""),va=f(""),Ps=f("2"),Is=f("Operator stop request"),Es=f(""),Ze=f("");function Su(t){const e=t.trim()||"dashboard";Na.value=e,localStorage.setItem(zo,e)}function Ii(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function wu(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function fa(t){return typeof t=="string"?t.trim().toLowerCase():""}function Tu(t){var a;const e=fa(t.status);if(e==="paused")return"bad";const n=fa((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function Ei(t){const e=fa(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":(t.context_ratio??0)>=.8||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}async function me(t){const e=Na.value.trim()||"dashboard";try{const n=await ku({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?x("Confirmation queued","warning"):x(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return x(a,"error"),null}}async function Oi(){const t=Ye.value.trim();if(!t)return;await me({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(Ye.value="")}async function Cu(){await me({action_type:"room_pause",target_type:"room",payload:{reason:Ds.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function Nu(){await me({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function Ru(){const t=Xe.value.trim();if(!t)return;await me({action_type:"task_inject",target_type:"room",payload:{title:t,description:da.value.trim()||"Injected from Ops tab",priority:Number.parseInt(Ls.value,10)||2},successMessage:"Task injection submitted"})&&(Xe.value="",da.value="")}async function Du(){var o;const t=Sn.value,e=ua.value||((o=t==null?void 0:t.sessions[0])==null?void 0:o.session_id)||"";if(!e){x("Select a team session first","warning");return}const n={turn_kind:Le.value},a=pa.value.trim();a&&(n.message=a),Le.value==="task"&&(n.task_title=ma.value.trim()||"Operator injected task",n.task_description=va.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(Ps.value,10)||2),await me({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(pa.value="",Le.value==="task"&&(ma.value="",va.value=""))}async function Lu(){var n;const t=Sn.value,e=ua.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){x("Select a team session first","warning");return}await me({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Is.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function Pu(){var i;const t=Sn.value,e=Es.value||((i=t==null?void 0:t.keepers[0])==null?void 0:i.name)||"",n=Ze.value.trim();if(!e){x("Select a keeper first","warning");return}if(!n)return;await me({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(Ze.value="")}async function Iu(t){const e=Na.value.trim()||"dashboard";try{await xu(e,t),x("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";x(a,"error")}}function Eu(){var c;const t=Sn.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],a=(t==null?void 0:t.keepers)??[],i=(t==null?void 0:t.pending_confirms)??[],o=(t==null?void 0:t.recent_messages)??[],r=n.find(l=>l.session_id===ua.value)??n[0]??null,d=a.find(l=>l.name===Es.value)??a[0]??null,p=n.filter(l=>Tu(l)!=="ok"),_=a.filter(l=>Ei(l)!=="ok"),m=[{key:"room",label:"Room Gate",value:e.paused?"Paused":"Open",detail:e.paused?`Resume gate armed${e.pause_reason?` · ${e.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:e.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:i.length,detail:i.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:i.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:p.length,detail:p.length>0?"Team sessions need steering, stop, or checkpoint attention":"Team sessions look healthy from the operator snapshot",tone:p.some(l=>fa(l.status)==="paused")?"bad":p.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:_.length,detail:_.length>0?"At least one keeper is stale, offline, or running hot":"Keepers are available for direct intervention",tone:_.some(l=>Ei(l)==="bad")?"bad":_.length>0?"warn":"ok"}];return s`
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
            value=${Na.value}
            onInput=${l=>Su(l.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{wn()}} disabled=${ra.value||F.value}>
            ${ra.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${te.value?s`
        <section class="ops-banner error">${te.value}</section>
      `:null}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Action Priority</h2>
          <p class="monitor-subheadline">Ops is the command surface. These four signals explain when to intervene before you drop into a specific control panel.</p>
        </div>
        <div class="ops-priority-grid">
          ${m.map(l=>s`
            <div key=${l.key} class="ops-priority-card ${l.tone}">
              <span class="ops-priority-label">${l.label}</span>
              <strong>${l.value}</strong>
              <div class="ops-priority-detail">${l.detail}</div>
            </div>
          `)}
        </div>
      </section>

      ${i.length>0?s`
        <section class="card ops-confirmations">
          <div class="card-title">Pending Confirmations</div>
          <p class="ops-context-note">Only previewed actions that still need an explicit operator confirmation stay here.</p>
          <div class="ops-confirmation-list">
            ${i.map(l=>s`
              <article key=${l.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${l.action_type??"unknown"}</strong>
                  <span>${l.target_type??"target"}${l.target_id?`:${l.target_id}`:""}</span>
                  <span>${l.delegated_tool??"delegated tool pending"}</span>
                </div>
                ${l.preview?s`<pre class="ops-code-block">${Ii(l.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{Iu(l.confirm_token)}} disabled=${F.value}>
                    Confirm
                  </button>
                  <span class="ops-token">${l.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        </section>
      `:null}

      <div class="ops-grid">
        <section class="card ops-panel">
          <div class="card-title">Room Control</div>
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

          <label class="control-label" for="ops-broadcast">Broadcast</label>
          <div class="control-row">
            <input
              id="ops-broadcast"
              class="control-input"
              type="text"
              placeholder="@agent or room-wide operator update"
              value=${Ye.value}
              onInput=${l=>{Ye.value=l.target.value}}
              onKeyDown=${l=>{l.key==="Enter"&&Oi()}}
              disabled=${F.value}
            />
            <button class="control-btn" onClick=${()=>{Oi()}} disabled=${F.value||Ye.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${Ds.value}
              onInput=${l=>{Ds.value=l.target.value}}
              disabled=${F.value}
            />
            <button class="control-btn ghost" onClick=${()=>{Cu()}} disabled=${F.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{Nu()}} disabled=${F.value}>
              Resume
            </button>
          </div>

          <div class="ops-section-head">Task Inject</div>
          <input
            class="control-input"
            type="text"
            placeholder="Task title"
            value=${Xe.value}
            onInput=${l=>{Xe.value=l.target.value}}
            disabled=${F.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${da.value}
            onInput=${l=>{da.value=l.target.value}}
            disabled=${F.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${Ls.value}
              onChange=${l=>{Ls.value=l.target.value}}
              disabled=${F.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{Ru()}} disabled=${F.value||Xe.value.trim()===""}>
              Inject
            </button>
          </div>

          ${o.length>0?s`
            <div class="ops-section-head">Context Tail</div>
            <div class="ops-context-note">Recent room chatter stays available for context, but command work remains the primary focus of this tab.</div>
            <div class="ops-feed-list">
              ${o.slice(0,6).map(l=>s`
                <article key=${l.seq??l.id??l.timestamp} class="ops-feed-item">
                  <div class="ops-feed-meta">
                    <strong>${l.from}</strong>
                    <span>${l.timestamp}</span>
                  </div>
                  <div class="ops-feed-content">${l.content}</div>
                </article>
              `)}
            </div>
          `:null}
        </section>

        <section class="card ops-panel">
          <div class="card-title">Team Sessions</div>
          <div class="ops-entity-list">
            ${n.length===0?s`<div class="ops-empty">No team sessions available.</div>`:n.map(l=>{var g;return s`
              <button
                key=${l.session_id}
                class="ops-entity-card ${(r==null?void 0:r.session_id)===l.session_id?"active":""}"
                onClick=${()=>{ua.value=l.session_id}}
              >
                <div class="ops-entity-title-row">
                  <strong>${l.session_id}</strong>
                  <span class="status-badge ${l.status??"idle"}">${l.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${Math.round(l.progress_pct??0)}%</span>
                  <span>${l.done_delta_total??0} done</span>
                  <span>${(g=l.team_health)!=null&&g.status?String(l.team_health.status):"health n/a"}</span>
                </div>
              </button>
            `})}
          </div>

          ${r?s`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${r.session_id}</div>
              <div class="ops-detail-meta">
                <span>Status: ${r.status??"unknown"}</span>
                <span>Elapsed: ${r.elapsed_sec??0}s</span>
                <span>Remaining: ${r.remaining_sec??0}s</span>
              </div>
              ${r.recent_events&&r.recent_events.length>0?s`
                <pre class="ops-code-block compact">${Ii(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${Le.value}
              onChange=${l=>{Le.value=l.target.value}}
              disabled=${F.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{Du()}} disabled=${F.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${pa.value}
            onInput=${l=>{pa.value=l.target.value}}
            disabled=${F.value||!r}
          ></textarea>
          ${Le.value==="task"?s`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${ma.value}
              onInput=${l=>{ma.value=l.target.value}}
              disabled=${F.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${va.value}
              onInput=${l=>{va.value=l.target.value}}
              disabled=${F.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${Ps.value}
              onChange=${l=>{Ps.value=l.target.value}}
              disabled=${F.value||!r}
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
              value=${Is.value}
              onInput=${l=>{Is.value=l.target.value}}
              disabled=${F.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{Lu()}} disabled=${F.value||!r}>
              Stop
            </button>
          </div>
        </section>

        <section class="card ops-panel">
          <div class="card-title">Keepers</div>
          <div class="ops-entity-list">
            ${a.length===0?s`<div class="ops-empty">No keepers available.</div>`:a.map(l=>s`
              <button
                key=${l.name}
                class="ops-entity-card ${(d==null?void 0:d.name)===l.name?"active":""}"
                onClick=${()=>{Es.value=l.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${l.name}</strong>
                  <span class="status-badge ${l.status??"idle"}">${l.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${l.model??"model n/a"}</span>
                  <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${wu(l.last_turn_ago_s)}</span>
                </div>
              </button>
            `)}
          </div>

          ${d?s`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${d.name}</div>
              <div class="ops-detail-meta">
                <span>Autonomy: ${d.autonomy_level??"n/a"}</span>
                <span>Generation: ${d.generation??0}</span>
                <span>Goals: ${((c=d.active_goal_ids)==null?void 0:c.length)??0}</span>
              </div>
            </div>
          `:null}

          <label class="control-label" for="ops-keeper-message">Keeper Message</label>
          <textarea
            id="ops-keeper-message"
            class="control-textarea"
            rows=${6}
            placeholder="Send a structured intervention or course correction"
            value=${Ze.value}
            onInput=${l=>{Ze.value=l.target.value}}
            disabled=${F.value||!d}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{Pu()}} disabled=${F.value||!d||Ze.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${la.value.length===0?s`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:la.value.map(l=>s`
            <article key=${l.id} class="ops-log-entry ${l.outcome}">
              <div class="ops-log-head">
                <strong>${l.action_type}</strong>
                <span>${l.target_label}</span>
                <span>${l.at}</span>
              </div>
              <div class="ops-log-body">${l.message}</div>
            </article>
          `)}
        </div>
      </section>
    </section>
  `}function Ou({text:t}){if(!t)return null;const e=Mu(t);return s`<div class="markdown-content">${e}</div>`}function Mu(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const i=e[a];if(/^(`{3,}|~{3,})/.test(i)){const r=i.match(/^(`{3,}|~{3,})/)[0],d=i.slice(r.length).trim(),p=[];for(a++;a<e.length&&!e[a].startsWith(r);)p.push(e[a]),a++;a++,n.push(s`<pre><code class=${d?`language-${d}`:""}>${p.join(`
`)}</code></pre>`);continue}if(i.trim()==="<think>"||i.trim().startsWith("<think>")){const r=[],d=i.trim().replace(/^<think>/,"").trim();for(d&&d!=="</think>"&&r.push(d),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const _=e[a].replace("</think>","").trim();_&&r.push(_),a++}const p=r.join(`
`).trim();n.push(s`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Ba(p)}</div>
        </details>
      `);continue}if(i.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(s`<blockquote>${Ba(r.join(`
`))}</blockquote>`);continue}if(i.trim()===""){a++;continue}const o=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;o.push(r),a++}o.length>0&&n.push(s`<p>${Ba(o.join(`
`))}</p>`)}return n}function Ba(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,i;for(;(i=n.exec(t))!==null;){if(i.index>a&&e.push(t.slice(a,i.index)),i[1]){const o=i[1].slice(1,-1);e.push(s`<code>${o}</code>`)}else if(i[2]){const o=i[2].slice(2,-2);e.push(s`<strong>${o}</strong>`)}else if(i[3]){const o=i[3].slice(1,-1);e.push(s`<em>${o}</em>`)}else i[4]&&i[5]&&e.push(s`<a href=${i[5]} target="_blank" rel="noopener">${i[4]}</a>`);a=i.index+i[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const We=f("posts"),Os=f([]),Ms=f([]),tn=f(""),ga=f(!1),en=f(!1),$n=f(""),_a=f(null),bt=f(null),zs=f(!1),Yt=f(null),Hn=f(null);async function Ra(){ga.value=!0,$n.value="";try{const[t,e]=await Promise.all([hl(),yl()]);Os.value=t,Ms.value=e,Yt.value=!0,Hn.value=Date.now()}catch(t){$n.value=t instanceof Error?t.message:"Failed to load council data",Yt.value=!1}finally{ga.value=!1}}oc(Ra);async function Mi(){const t=tn.value.trim();if(t){en.value=!0;try{const e=await bl(t);tn.value="",x(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Ra()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";x(n,"error")}finally{en.value=!1}}}async function zu(t){_a.value=t,zs.value=!0,bt.value=null;try{bt.value=await kl(t)}catch(e){$n.value=e instanceof Error?e.message:"Failed to load debate status",bt.value=null}finally{zs.value=!1}}const jo=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Bn=f(null),nn=f([]),ue=f(!1),ce=f(null),an=f("");function ju(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const qu=f(ju()),sn=f(!1);async function ii(t){ce.value=t,Bn.value=null,nn.value=[],ue.value=!0;try{const e=await Hr(t);if(ce.value!==t)return;Bn.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},nn.value=e.comments??[]}catch{ce.value===t&&(Bn.value=null,nn.value=[])}finally{ce.value===t&&(ue.value=!1)}}async function zi(t){const e=an.value.trim();if(e){sn.value=!0;try{await Br(t,qu.value,e),an.value="",x("Comment posted","success"),await ii(t),qt()}catch{x("Failed to post comment","error")}finally{sn.value=!1}}}function Fu(){const t=pn.value;return s`
    <div class="board-toolbar">
      <div class="board-controls">
        ${jo.map(e=>s`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{pn.value=e.id,qt()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${oe.value?"is-active":""}"
          onClick=${()=>{oe.value=!oe.value,qt()}}
        >
          ${oe.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${qt} disabled=${vn.value}>
          ${vn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function js(){var e;const t=(e=ee.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:s`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?s`<span class="feed-health-meta">Last sync: <${j} timestamp=${t.last_sync_at} /></span>`:s`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function qo({flair:t}){return t?s`<span class="post-flair ${t}">${t}</span>`:null}function Ku(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function ji(t){return t.updated_at!==t.created_at}function qs(){var n;const t=((n=jo.find(a=>a.id===pn.value))==null?void 0:n.label)??pn.value,e=Oe.value.length;return s`
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
        <strong>${ws.value?s`<${j} timestamp=${ws.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Hu({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await lo(t.id,n),qt()}catch{x("Failed to vote","error")}};return s`
    <div class="board-post" onClick=${()=>dr(t.id)}>
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
              <${qo} flair=${t.flair} />
              ${ji(t)?s`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${j} timestamp=${t.created_at} /></span>
            ${ji(t)?s`<span>Updated <${j} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?s`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${Ku(t.content)}</div>
      </div>
    </div>
  `}function Bu({comments:t}){return t.length===0?s`<div class="empty-state" style="font-size:13px">No comments yet</div>`:s`
    <div class="comment-thread">
      ${t.map(e=>s`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${j} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Uu({postId:t}){return s`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${an.value}
        onInput=${e=>{an.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&zi(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${sn.value}
      />
      <button
        onClick=${()=>zi(t)}
        disabled=${sn.value||an.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${sn.value?"...":"Post"}
      </button>
    </div>
  `}function Gu({post:t}){ce.value!==t.id&&!ue.value&&ii(t.id);const e=async n=>{try{await lo(t.id,n),qt()}catch{x("Failed to vote","error")}};return s`
    <div>
      <button class="back-btn" onClick=${()=>Rt("board")}>← Back to Board</button>
      <${S} title=${s`${t.title} <${qo} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Ou} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${j} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?s`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${S} title="Comments (${ue.value?"...":nn.value.length})">
        ${ue.value?s`<div class="loading-indicator">Loading comments...</div>`:s`<${Bu} comments=${nn.value} />`}
        <${Uu} postId=${t.id} />
      <//>
    </div>
  `}function Wu({debate:t}){const e=_a.value===t.id;return s`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>zu(t.id)}
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
  `}function Ju({session:t}){return s`
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
  `}function Fo(){return Yt.value===null||Yt.value&&!Hn.value?null:s`
    <div class="feed-health-banner ${Yt.value===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${Yt.value===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${Hn.value?s`<span class="feed-health-meta">Last sync: <${j} timestamp=${Hn.value} /></span>`:s`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Vu(){const t=Yt.value===!1;return s`
    <div>
      <${Fo} />
      <${S} title="Start Debate" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${tn.value}
            onInput=${e=>{tn.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&Mi()}}
            disabled=${en.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Mi}
            disabled=${en.value||tn.value.trim()===""}
          >
            ${en.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Ra} disabled=${ga.value}>
            ${ga.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${$n.value?s`<div class="council-error">${$n.value}</div>`:null}
      <//>

      <${S} title="Debates" class="section">
        <div class="council-list">
          ${Os.value.length===0?s`<div class="empty-state">${t?"No debates loaded (council feed degraded).":"No debates yet"}</div>`:Os.value.map(e=>s`<${Wu} key=${e.id} debate=${e} />`)}
        </div>
      <//>

      <${S} title=${_a.value?`Debate Detail (${_a.value})`:"Debate Detail"} class="section">
        ${zs.value?s`<div class="loading-indicator">Loading debate detail...</div>`:bt.value?s`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${bt.value.status}</span>
                  <span>Total arguments: ${bt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${bt.value.support_count}</span>
                  <span>Oppose: ${bt.value.oppose_count}</span>
                  <span>Neutral: ${bt.value.neutral_count}</span>
                </div>
                ${bt.value.summary_text?s`<pre class="council-detail">${bt.value.summary_text}</pre>`:null}
              `:s`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Qu(){const t=Yt.value===!1;return s`
    <div>
      <${Fo} />
      <${S} title="Voting Sessions" class="section">
        <div class="council-list">
          ${Ms.value.length===0?s`<div class="empty-state">${t?"No sessions loaded (council feed degraded).":"No active sessions"}</div>`:Ms.value.map(e=>s`<${Ju} key=${e.id} session=${e} />`)}
        </div>
      <//>
    </div>
  `}function Yu(){const t=We.value;return s`
    <div class="overview-sub-tabs" style="margin-bottom: 12px;">
      <button class="sub-tab-btn ${t==="posts"?"active":""}" onClick=${()=>{We.value="posts"}}>Posts</button>
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{We.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{We.value="voting"}}>Voting</button>
    </div>
  `}function Xu(){var a,i;const t=Oe.value,e=vn.value,n=((i=(a=ee.value)==null?void 0:a.data_quality)==null?void 0:i.board_contract_ok)===!1;return s`
    <div>
      <${js} />
      <${qs} />
      <${Fu} />
      ${e?s`<div class="loading-indicator">Loading board...</div>`:t.length===0?s`
              <div class="empty-state">
                ${n?"No posts loaded (board feed degraded). Check board contract sync.":oe.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
              </div>
            `:s`<div class="board-post-list">
              ${t.map(o=>s`<${Hu} key=${o.id} post=${o} />`)}
            </div>`}
    </div>
  `}function Zu(){var i,o;const t=Oe.value,e=Lt.value.postId,n=((o=(i=ee.value)==null?void 0:i.data_quality)==null?void 0:o.board_contract_ok)===!1,a=We.value;if(Pt(()=>{(a==="debates"||a==="voting")&&Ra()},[a]),e){const r=t.find(d=>d.id===e)??(ce.value===e?Bn.value:null);return!r&&ce.value!==e&&!ue.value&&ii(e),r?s`
          <${js} />
          <${qs} />
          <${Gu} post=${r} />
        `:s`
          <div>
            <${js} />
            <${qs} />
            <button class="back-btn" onClick=${()=>Rt("board")}>← Back to Board</button>
            ${ue.value?s`<div class="loading-indicator">Loading post...</div>`:s`
                  <div class="empty-state">
                    ${n?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return s`
    <${Yu} />
    ${a==="debates"?s`<${Vu} />`:a==="voting"?s`<${Qu} />`:s`<${Xu} />`}
  `}function tp(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function ep(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function np(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const Ko=120,ap=12,sp=16,ip=12,Fs=f("all"),op={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},rp={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function lp(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function cp(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:tp(t),actor:ep(t),content:np(t),timestamp:new Date(t.timestamp).toISOString()}}function dp(t,e){var i;const n=(i=t.assignee)==null?void 0:i.trim(),a=t.updated_at??t.created_at;return!n||!a?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:a}}function up(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function Dn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ks(t){return t.last_heartbeat??Dn(t.last_turn_ago_s)??Dn(t.last_proactive_ago_s)??Dn(t.last_handoff_ago_s)??Dn(t.last_compaction_ago_s)}function pp(t,e){const n=Ks(t);if(!n)return null;const a=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${a}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${a}`,timestamp:n}}function Tt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const Hs=ft(()=>{const t=ti.value.map(lp),e=Vn.value.map(cp),n=[...xt.value].sort((o,r)=>Tt(r.updated_at??r.created_at??0)-Tt(o.updated_at??o.created_at??0)).slice(0,ap).map(dp).filter(o=>o!==null),a=[...Oe.value].sort((o,r)=>Tt(r.updated_at||r.created_at)-Tt(o.updated_at||o.created_at)).slice(0,sp).map(up),i=[...Ut.value].sort((o,r)=>Tt(Ks(r)??0)-Tt(Ks(o)??0)).slice(0,ip).map(pp).filter(o=>o!==null);return[...t,...e,...n,...a,...i].sort((o,r)=>Tt(r.timestamp)-Tt(o.timestamp))}),mp=ft(()=>{const t=Hs.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),vp=ft(()=>{const t=Fs.value;return(t==="all"?Hs.value:Hs.value.filter(n=>n.kind===t)).slice(0,Ko)}),fp=ft(()=>{const t=Ta.value,e={activeAssignedCount:0,lastActivityAt:null,lastActivityText:null};return Mt.value.map(n=>({agent:n,motion:t.get(n.name.trim().toLowerCase())??e})).sort((n,a)=>{const i=a.motion.activeAssignedCount-n.motion.activeAssignedCount;return i!==0?i:Tt(a.motion.lastActivityAt??0)-Tt(n.motion.lastActivityAt??0)})});function gp(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function Be({label:t,value:e,color:n}){return s`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function _p({row:t}){return s`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${gp(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${rp[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function $p(){const t=mp.value,e=vp.value,n=e[0],a=fp.value;return s`
    <div class="stats-grid">
      <${Be} label="Visible rows" value=${e.length} />
      <${Be} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${Be} label="Keeper signals" value=${t.keepers} color="#4ade80" />
      <${Be} label="Board signals" value=${t.board} color="#fbbf24" />
      <${Be} label="SSE events" value=${yn.value} color="#c084fc" />
    </div>

    <${S} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(i=>s`
            <button
              class="goal-filter-btn ${Fs.value===i?"active":""}"
              onClick=${()=>{Fs.value=i}}
            >
              ${op[i]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${It.value?"":"pill-stale"}">
            ${It.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?s`Latest: <${j} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${Ko} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      <div class="terminal-feed">
        ${e.length===0?s`<div class="empty-state">Waiting for live or snapshot signals...</div>`:e.map(i=>s`<${_p} key=${i.id} row=${i} />`)}
      </div>
    <//>

    <${S} title="Agent Motion" class="section">
      <div class="activity-motion-list">
        ${a.length===0?s`<div class="empty-state">No active agents</div>`:a.map(({agent:i,motion:o})=>s`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${i.name}</div>
                  <div class="activity-motion-meta">
                    ${o.activeAssignedCount>0?`${o.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${o.lastActivityAt?s` · <${j} timestamp=${o.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${o.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function Ho({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,i=e/2,o=2*Math.PI*a,r=o*((100-t*100)/100);let d="mitosis-safe";return t>=.8?d="mitosis-critical":t>=.5&&(d="mitosis-warn"),s`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${i}" cy="${i}" r="${a}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${d}" 
          cx="${i}" cy="${i}" r="${a}" 
          stroke-width="${n}" 
          stroke-dasharray="${o}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${d}">${Math.round(t*100)}%</span>
    </div>
  `}const Ua=600*1e3,hp=1200*1e3,qi=.8;function Vt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function he(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function yp(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function bp(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function kp(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function xp(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function Ap(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function Sp(t){var p,_;const e=Ta.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-Vt(n)):Number.POSITIVE_INFINITY,i=!!((p=t.current_task)!=null&&p.trim())||e.activeAssignedCount>0;let o="watching",r="ok",d="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",r="bad",d=n?"Offline or inactive":"No recent presence"):a>hp?(o="quiet",r="bad",d=i?"Working without a fresh signal":"No fresh agent signal"):i?(o="working",r=a>Ua?"warn":"ok",d=a>Ua?"Execution looks quiet for too long":"Task and live signal aligned"):a>Ua?(o="quiet",r="warn",d="Quiet but still reachable"):t.status==="idle"&&(o="watching",r="ok",d="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:r,focus:((_=t.current_task)==null?void 0:_.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:d}}function wp(t){const e=yo.value.get(t.name)??"idle",n=bo.value.has(t.name),a=t.context_ratio??0;let i="healthy",o="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(i="critical",o="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=qi)&&(i="warning",o="warn",r=a>=qi?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:i,tone:o,focus:xp(t),note:r}}function Ue({label:t,value:e,color:n,caption:a}){return s`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?s`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Tp({item:t}){const e=t.kind==="agent"?()=>De(t.agent.name):()=>na(t.keeper);return s`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?s`<span><${j} timestamp=${t.timestamp} /></span>`:s`<span>No signal</span>`}
      </div>
    </button>
  `}function Fi({row:t}){const{agent:e,motion:n}=t;return s`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>De(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?s`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Ho} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${At} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${yp(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?s`<span>Signal <${j} timestamp=${t.lastSignalAt} /></span>`:s`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?s`<span>${e.model}</span>`:null}
        ${e.last_seen?s`<span>Seen <${j} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?s`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function Cp({row:t}){const{keeper:e}=t;return s`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>na(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?s`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Ho} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${At} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${bp(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?s`<span>Heartbeat <${j} timestamp=${e.last_heartbeat} /></span>`:s`<span>No heartbeat</span>`}
        <span>${Ap(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${kp(e.context_ratio)}</span>
        ${e.model?s`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?s`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function Np(){const t=[...Mt.value].map(Sp).sort((m,c)=>{const l=he(c.tone)-he(m.tone);if(l!==0)return l;const g=c.activeTaskCount-m.activeTaskCount;return g!==0?g:Vt(c.lastSignalAt)-Vt(m.lastSignalAt)}),e=[...Ut.value].map(wp).sort((m,c)=>{const l=he(c.tone)-he(m.tone);if(l!==0)return l;const g=(c.keeper.context_ratio??0)-(m.keeper.context_ratio??0);return g!==0?g:Vt(c.keeper.last_heartbeat)-Vt(m.keeper.last_heartbeat)}),n=t.filter(m=>m.state!=="offline"),a=t.filter(m=>m.state==="offline"),i=n.length,o=t.filter(m=>m.state==="working").length,r=t.filter(m=>m.lastSignalAt&&Date.now()-Vt(m.lastSignalAt)<=12e4).length,d=t.filter(m=>m.tone!=="ok"),p=e.filter(m=>m.tone!=="ok"),_=[...p.map(m=>({kind:"keeper",key:`keeper-${m.keeper.name}`,tone:m.tone,title:m.keeper.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.keeper.last_heartbeat??null,keeper:m.keeper})),...d.map(m=>({kind:"agent",key:`agent-${m.agent.name}`,tone:m.tone,title:m.agent.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.lastSignalAt,agent:m.agent}))].sort((m,c)=>{const l=he(c.tone)-he(m.tone);return l!==0?l:Vt(c.timestamp)-Vt(m.timestamp)}).slice(0,8);return s`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${Ue} label="Agents online" value=${i} color="#4ade80" caption="active + idle" />
        <${Ue} label="Working now" value=${o} color="#fbbf24" caption="task or claimed load" />
        <${Ue} label="Fresh signals" value=${r} color="#22d3ee" caption="within last 2 minutes" />
        <${Ue} label="Agent alerts" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="quiet or offline" />
        <${Ue} label="Keeper alerts" value=${p.length} color=${p.length>0?"#fb7185":"#4ade80"} caption="stale or high pressure" />
      </div>

      <${S} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${_.length===0?s`<div class="empty-state">No agent or keeper alerts right now</div>`:_.map(m=>s`<${Tp} key=${m.key} item=${m} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${S} title="Keeper Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?s`<div class="empty-state">No keepers active</div>`:e.map(m=>s`<${Cp} key=${m.keeper.name} row=${m} />`)}
          </div>
        <//>

        <${S} title="Agent Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Current task, recent signal, and quiet drift are surfaced together.</p>
          </div>
          <div class="monitor-list">
            ${t.length===0?s`<div class="empty-state">No agents registered</div>`:s`
                ${n.length>0?s`
                  <div class="agent-group-header">
                    Active <span class="group-count">${n.length}</span>
                  </div>
                  ${n.map(m=>s`<${Fi} key=${m.agent.name} row=${m} />`)}
                `:null}
                ${a.length>0?s`
                  <div class="agent-group-header">
                    Offline <span class="group-count">${a.length}</span>
                  </div>
                  ${a.map(m=>s`<${Fi} key=${m.agent.name} row=${m} />`)}
                `:null}
              `}
          </div>
        <//>
      </div>
    </div>
  `}const $a=f("all"),ha=f("all"),Bs=ft(()=>{let t=mn.value;return $a.value!=="all"&&(t=t.filter(e=>e.horizon===$a.value)),ha.value!=="all"&&(t=t.filter(e=>e.status===ha.value)),t}),Rp=ft(()=>{const t={short:[],mid:[],long:[]};for(const e of Bs.value){const n=t[e.horizon];n&&n.push(e)}return t}),Dp=ft(()=>{const t=Array.from(go.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function Lp(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function oi(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function Un(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Pp(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Ki(t){return t.toFixed(4)}function Hi(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function Ip({goal:t}){return s`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${Un(t.horizon)}">
            ${oi(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${Lp(t.priority)}</span>
          ${t.metric?s`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?s`<span class="goal-due">Due: <${j} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?s`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${At} status=${t.status} />
        <div class="goal-updated">
          <${j} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Bi({label:t,timestamp:e,source:n,note:a}){return s`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${a?s`<div class="planning-freshness-source">${a}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?s`<${j} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function Ga({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,i)=>i.priority-a.priority);return s`
    <${S} title="${oi(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(a=>s`<${Ip} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function Ep(){return s`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>s`
          <button
            class="goal-filter-btn ${$a.value===t?"active":""}"
            onClick=${()=>{$a.value=t}}
          >
            ${t==="all"?"All":oi(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>s`
          <button
            class="goal-filter-btn ${ha.value===t?"active":""}"
            onClick=${()=>{ha.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function Op(){const t=mn.value,e=t.filter(i=>i.status==="active").length,n=t.filter(i=>i.status==="completed").length,a={short:0,mid:0,long:0};for(const i of t)i.horizon in a&&a[i.horizon]++;return s`
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
        <div class="goal-summary-value" style="color:${Un("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Un("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Un("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function Mp({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return s`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${At} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Ki(t.baseline_metric)}</span>
          <span>Current ${Ki(t.current_metric)}</span>
          <span class=${Hi(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Hi(t)}
          </span>
          <span>Elapsed ${Pp(t.elapsed_seconds)}</span>
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
  `}function Wa({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return s`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?s`<${j} timestamp=${t.created_at} />`:s`<span>-</span>`}
        ${t.assignee?s`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function zp(){const{todo:t,inProgress:e,done:n}=ho.value;return s`
    <${S} title="Task Backlog" class="section">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?s`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>s`<${Wa} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?s`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>s`<${Wa} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?s`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>s`<${Wa} key=${a.id} task=${a} />`)}
          ${n.length>20?s`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function jp(){const t=Rp.value,e=Dp.value,n=e.filter(d=>d.status==="running").length,a=e.filter(d=>d.recoverable).length,i=mn.value.filter(d=>d.status==="active").length,o=ks.value,r=o==="idle"?"No loop running":o==="error"?xs.value??"MDAL snapshot unavailable":"Current loop snapshot";return s`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${i}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${Bs.value.length}</div>
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

      <${S} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>/api/v1/mdal/loops</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${Xn} disabled=${Ae.value}>
              ${Ae.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${fn} disabled=${Se.value}>
              ${Se.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{Xn(),fn()}}
              disabled=${Ae.value||Se.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${Bi} label="Goals" timestamp=${_o.value} source="masc_goal_list" />
          <${Bi}
            label="MDAL loops"
            timestamp=${$o.value}
            source="/api/v1/mdal/loops"
            note=${r}
          />
        </div>
      <//>

      <${S} title="Goal Pipeline" class="section">
        <${Op} />
        <${Ep} />
      <//>

      ${Ae.value&&mn.value.length===0?s`<div class="loading-indicator">Loading goals...</div>`:Bs.value.length===0?s`<div class="empty-state">No goals match the current filters</div>`:s`
              <${Ga} horizon="short" items=${t.short??[]} />
              <${Ga} horizon="mid" items=${t.mid??[]} />
              <${Ga} horizon="long" items=${t.long??[]} />
            `}

      <${S} title="MDAL Loops" class="section">
        ${Se.value&&e.length===0?s`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&o==="error"?s`
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
                  ${e.map(d=>s`<${Mp} key=${d.loop_id} loop=${d} />`)}
                </div>
              `}
      <//>

      <${zp} />
    </div>
  `}const ke=f(""),Ja=f("ability_check"),Va=f("10"),Qa=f("12"),Ln=f(""),Pn=f("idle"),Qt=f(""),In=f("keeper-late"),Ya=f("player"),Xa=f(""),vt=f("idle"),Za=f(null),En=f(""),ts=f(""),es=f("player"),ns=f(""),as=f(""),ss=f(""),on=f("20"),is=f("20"),os=f(""),On=f("idle"),Us=f(null),Bo=f("overview"),rs=f("all"),ls=f("all"),cs=f("all"),qp=12e4,Da=f(null),Ui=f(Date.now());function Fp(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Kp(t,e){return e>0?Math.round(t/e*100):0}const Hp={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Bp={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Mn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Up(t){const e=t.trim().toLowerCase();return Hp[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Gp(t){const e=t.trim().toLowerCase();return Bp[e]??"상황에 따라 선택되는 전술 액션입니다."}function Zt(t){return typeof t=="object"&&t!==null}function lt(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function Ct(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function hn(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const Wp=new Set(["str","dex","con","int","wis","cha"]);function Jp(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(i){throw new Error(`능력치 JSON 파싱 실패: ${i instanceof Error?i.message:"invalid json"}`)}if(!Zt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([i,o])=>{const r=i.trim();if(r){if(typeof o=="number"&&Number.isFinite(o)){a[r]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const d=Number.parseFloat(o.trim());if(Number.isFinite(d)){a[r]=Math.max(0,Math.trunc(d));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function Vp(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt(on.value.trim(),10);Number.isFinite(a)&&a>n&&(on.value=String(n))}function Gs(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Qp(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Yp(t){Bo.value=t}function Uo(t){const e=Da.value;return e==null||e<=t}function Xp(t){const e=Da.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function ya(){Da.value=null}function Go(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Zp(t,e){Go(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Da.value=Date.now()+qp,x("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function Gn(t){return Uo(t)?(x("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Ws(t,e,n){return Go([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function tm({hp:t,max:e}){const n=Kp(t,e),a=Fp(t,e);return s`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function em({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return s`
    <div class="trpg-actor-stats">
      ${e.map(n=>s`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function nm({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return s`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Wo({actor:t}){var p,_,m,c;const e=(p=t.archetype)==null?void 0:p.trim(),n=(_=t.persona)==null?void 0:_.trim(),a=(m=t.portrait)==null?void 0:m.trim(),i=(c=t.background)==null?void 0:c.trim(),o=t.traits??[],r=t.skills??[],d=Object.entries(t.stats_raw??{}).filter(([l,g])=>Number.isFinite(g)).filter(([l])=>!Wp.has(l.toLowerCase()));return s`
    <div class="trpg-actor">
      ${a?s`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${a}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${l=>{const g=l.target;g&&(g.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${At} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${nm} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?s`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?s`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${tm} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${em} stats=${t.stats} />
          </div>
        `:null}
      ${e?s`<div class="trpg-actor-meta">Archetype: ${Mn(e)}</div>`:null}
      ${i?s`<div class="trpg-actor-meta">Background: ${i}</div>`:null}
      ${n?s`<div class="trpg-actor-persona">${n}</div>`:null}
      ${d.length>0?s`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${d.map(([l,g])=>s`
                <span class="trpg-custom-stat-chip">${Mn(l)} ${g}</span>
              `)}
            </div>
          </div>
        `:null}
      ${o.length>0?s`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${o.map(l=>s`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Mn(l)}</span>
                  <span class="trpg-annot-desc">${Up(l)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?s`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(l=>s`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Mn(l)}</span>
                  <span class="trpg-annot-desc">${Gp(l)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function am({mapStr:t}){return s`<pre class="trpg-map">${t}</pre>`}function Jo({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?s`<div class="empty-state" style="font-size:13px">${e}</div>`:s`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var i;return s`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Qp(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Gs(n)}</strong>
            ${" "}
          ${n.dice_roll?s`<span class="trpg-dice">[${n.dice_roll.notation}: ${(i=n.dice_roll.rolls)==null?void 0:i.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${j} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function sm({events:t}){const e="__none__",n=rs.value,a=ls.value,i=cs.value,o=Array.from(new Set(t.map(Gs).map(c=>c.trim()).filter(c=>c!==""))).sort((c,l)=>c.localeCompare(l)),r=Array.from(new Set(t.map(c=>(c.type??"").trim()).filter(c=>c!==""))).sort((c,l)=>c.localeCompare(l)),d=t.some(c=>(c.type??"").trim()===""),p=Array.from(new Set(t.map(c=>(c.phase??"").trim()).filter(c=>c!==""))).sort((c,l)=>c.localeCompare(l)),_=t.some(c=>(c.phase??"").trim()===""),m=t.filter(c=>{if(n!=="all"&&Gs(c)!==n)return!1;const l=(c.type??"").trim(),g=(c.phase??"").trim();if(a===e){if(l!=="")return!1}else if(a!=="all"&&l!==a)return!1;if(i===e){if(g!=="")return!1}else if(i!=="all"&&g!==i)return!1;return!0});return s`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${c=>{rs.value=c.target.value}}>
          <option value="all">all</option>
          ${o.map(c=>s`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${c=>{ls.value=c.target.value}}>
          <option value="all">all</option>
          ${d?s`<option value=${e}>(none)</option>`:null}
          ${r.map(c=>s`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${i} onChange=${c=>{cs.value=c.target.value}}>
          <option value="all">all</option>
          ${_?s`<option value=${e}>(none)</option>`:null}
          ${p.map(c=>s`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{rs.value="all",ls.value="all",cs.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${m.length} / 전체 ${t.length}
      </span>
    </div>
    <${Jo} events=${m.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function im({outcome:t}){if(!t)return null;const e=o=>{const r=o.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",i=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return s`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?s`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${i?s`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${i}</div>`:null}
    </div>
  `}function Vo({state:t}){const e=t.history??[];return e.length===0?null:s`
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
  `}function om({state:t,nowMs:e}){var _;const n=jt.value||((_=t.session)==null?void 0:_.room)||"",a=Pn.value,i=t.party??[];if(!i.find(m=>m.id===ke.value)&&i.length>0){const m=i[0];m&&(ke.value=m.id)}const r=async()=>{var c,l;if(!n){x("Room ID가 비어 있습니다.","error");return}if(!Gn(e))return;const m=((c=t.current_round)==null?void 0:c.phase)??((l=t.session)==null?void 0:l.status)??"unknown";if(Ws("라운드 실행",n,m)){Pn.value="running";try{const g=await ol(n);Us.value=g,Pn.value="ok";const b=Zt(g.summary)?g.summary:null,A=b?hn(b,"advanced",!1):!1,T=b?lt(b,"progress_reason",""):"";x(A?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${T?`: ${T}`:""}`,A?"success":"warning"),Ft()}catch(g){Us.value=null,Pn.value="error";const b=g instanceof Error?g.message:"라운드 실행에 실패했습니다.";x(b,"error")}finally{ya()}}},d=async()=>{var c,l;if(!n||!Gn(e))return;const m=((c=t.current_round)==null?void 0:c.phase)??((l=t.session)==null?void 0:l.status)??"unknown";if(Ws("턴 강제 진행",n,m))try{await cl(n),x("턴을 다음 단계로 이동했습니다.","success"),Ft()}catch{x("턴 이동에 실패했습니다.","error")}finally{ya()}},p=async()=>{if(!n||!Gn(e))return;const m=ke.value.trim();if(!m){x("먼저 Actor를 선택하세요.","warning");return}const c=Number.parseInt(Va.value,10),l=Number.parseInt(Qa.value,10);if(Number.isNaN(c)||Number.isNaN(l)){x("stat/dc는 숫자여야 합니다.","warning");return}const g=Number.parseInt(Ln.value,10),b=Ln.value.trim()===""||Number.isNaN(g)?void 0:g;try{await ll({roomId:n,actorId:m,action:Ja.value.trim()||"ability_check",statValue:c,dc:l,rawD20:b}),x("주사위 판정을 기록했습니다.","success"),Ft()}catch{x("주사위 판정 기록에 실패했습니다.","error")}};return s`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${m=>{jt.value=m.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${ke.value}
            onChange=${m=>{ke.value=m.target.value}}
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
              value=${Ja.value}
              onInput=${m=>{Ja.value=m.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Va.value}
              onInput=${m=>{Va.value=m.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Qa.value}
              onInput=${m=>{Qa.value=m.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Ln.value}
              onInput=${m=>{Ln.value=m.target.value}}
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
            <button class="trpg-run-btn secondary" onClick=${d}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${a!=="idle"?s`<div class="trpg-run-status ${a}">${a==="running"?"처리 중...":a==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function rm({state:t}){var i;const e=jt.value||((i=t.session)==null?void 0:i.room)||"",n=On.value,a=async()=>{if(!e){x("Room ID가 비어 있습니다.","warning");return}const o=En.value.trim(),r=ts.value.trim();if(!r&&!o){x("이름 또는 Actor ID를 입력하세요.","warning");return}const d=Number.parseInt(on.value.trim(),10),p=Number.parseInt(is.value.trim(),10),_=Number.isFinite(p)?Math.max(1,p):20,m=Number.isFinite(d)?Math.max(0,Math.min(_,d)):_;let c={};try{c=Jp(os.value)}catch(l){x(l instanceof Error?l.message:"능력치 JSON 오류","error");return}On.value="spawning";try{const l=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,g=await dl(e,{actor_id:o||void 0,name:r||void 0,role:es.value,idempotencyKey:l,portrait:as.value.trim()||void 0,background:ss.value.trim()||void 0,hp:m,max_hp:_,alive:m>0,stats:Object.keys(c).length>0?c:void 0}),b=typeof g.actor_id=="string"?g.actor_id.trim():"";if(!b)throw new Error("생성 응답에 actor_id가 없습니다.");const A=ns.value.trim();A&&await ul(e,b,A),ke.value=b,Qt.value=b,o||(En.value=""),On.value="ok",x(`Actor 생성 완료: ${b}`,"success"),await Ft()}catch(l){On.value="error",x(l instanceof Error?l.message:"Actor 생성에 실패했습니다.","error")}};return s`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${ts.value}
            onInput=${o=>{ts.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${es.value}
            onChange=${o=>{es.value=o.target.value}}
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
            value=${ns.value}
            onInput=${o=>{ns.value=o.target.value}}
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
              value=${En.value}
              onInput=${o=>{En.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${as.value}
              onInput=${o=>{as.value=o.target.value}}
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
              value=${on.value}
              onInput=${o=>{on.value=o.target.value}}
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
              value=${is.value}
              onInput=${o=>{const r=o.target.value;is.value=r,Vp(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${ss.value}
              onInput=${o=>{ss.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${os.value}
              onInput=${o=>{os.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?s`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function lm({state:t,nowMs:e}){var l;const n=jt.value||((l=t.session)==null?void 0:l.room)||"",a=t.join_gate,i=Za.value,o=Zt(i)?i:null,r=(t.party??[]).filter(g=>g.role!=="dm"),d=Qt.value.trim(),p=r.some(g=>g.id===d),_=p?d:d?"__manual__":"",m=async()=>{const g=Qt.value.trim(),b=In.value.trim();if(!n||!g){x("Room/Actor가 필요합니다.","warning");return}vt.value="checking";try{const A=await pl(n,g,b||void 0);Za.value=A,vt.value="ok",x("참가 가능 여부를 갱신했습니다.","success")}catch(A){vt.value="error";const T=A instanceof Error?A.message:"참가 가능 여부 확인에 실패했습니다.";x(T,"error")}},c=async()=>{var B,U;const g=Qt.value.trim(),b=In.value.trim(),A=Xa.value.trim();if(!n||!g||!b){x("Room/Actor/Keeper가 필요합니다.","warning");return}if(!Gn(e))return;const T=((B=t.current_round)==null?void 0:B.phase)??((U=t.session)==null?void 0:U.status)??"unknown";if(Ws("Mid-Join 승인 요청",n,T)){vt.value="requesting";try{const z=await ml({room_id:n,actor_id:g,keeper_name:b,role:Ya.value,...A?{name:A}:{}});Za.value=z;const R=Zt(z)?hn(z,"granted",!1):!1,P=Zt(z)?lt(z,"reason_code",""):"";R?x("Mid-Join이 승인되었습니다.","success"):x(`Mid-Join이 거절되었습니다${P?`: ${P}`:""}`,"warning"),vt.value=R?"ok":"error",Ft()}catch(z){vt.value="error";const R=z instanceof Error?z.message:"Mid-Join 요청에 실패했습니다.";x(R,"error")}finally{ya()}}};return s`
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
            value=${_}
            onChange=${g=>{const b=g.target.value;if(b==="__manual__"){(p||!d)&&(Qt.value="");return}Qt.value=b}}
          >
            <option value="">Actor 선택</option>
            ${r.map(g=>s`
              <option value=${g.id}>${g.name} (${g.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${_==="__manual__"?s`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${Qt.value}
                onInput=${g=>{Qt.value=g.target.value}}
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
            value=${In.value}
            onInput=${g=>{In.value=g.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ya.value}
            onChange=${g=>{Ya.value=g.target.value}}
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
            value=${Xa.value}
            onInput=${g=>{Xa.value=g.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${m} disabled=${vt.value==="checking"||vt.value==="requesting"}>
              ${vt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${c} disabled=${vt.value==="checking"||vt.value==="requesting"}>
              ${vt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?s`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${hn(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Ct(o,"effective_score",0)}/${Ct(o,"required_points",0)}</span>
            ${lt(o,"reason_code","")?s`<span style="margin-left:8px;">Reason: ${lt(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Qo({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?s`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:s`
    <div class="trpg-round-list">
      ${e.map(n=>s`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?s`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Yo({state:t}){var n;const e=t.current_round;return e?s`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?s`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Xo(){const t=Us.value;if(!t)return s`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=Zt(e)?e:null,i=(Array.isArray(t.statuses)?t.statuses:[]).filter(Zt).slice(-8),o=t.canon_check,r=Zt(o)?o:null,d=r&&Array.isArray(r.warnings)?r.warnings.filter(P=>typeof P=="string").slice(0,3):[],p=r&&Array.isArray(r.violations)?r.violations.filter(P=>typeof P=="string").slice(0,3):[],_=n?hn(n,"advanced",!1):!1,m=n?lt(n,"progress_reason",""):"",c=n?lt(n,"progress_detail",""):"",l=n?Ct(n,"player_successes",0):0,g=n?Ct(n,"player_required_successes",0):0,b=n?hn(n,"dm_success",!1):!1,A=n?Ct(n,"timeouts",0):0,T=n?Ct(n,"unavailable",0):0,B=n?Ct(n,"reprompts",0):0,U=n?Ct(n,"npc_attacks",0):0,z=n?Ct(n,"keeper_timeout_sec",0):0,R=n?Ct(n,"roll_audit_count",0):0;return s`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${_?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${_?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${b?"DM ok":"DM stalled"} / players ${l}/${g}
          </span>
        </div>
        ${m?s`<div style="margin-top:4px; font-size:12px;">${m}</div>`:null}
        ${c?s`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${c}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${B}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${U}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${z||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${R}</div></div>
      </div>

      ${i.length>0?s`
          <div class="trpg-round-list">
            ${i.map(P=>{const _t=lt(P,"status","unknown"),zt=lt(P,"actor_id","-"),Wt=lt(P,"role","-"),$t=lt(P,"reason",""),ht=lt(P,"action_type",""),H=lt(P,"reply","");return s`
                <div class="trpg-round-item ${_t.includes("fallback")||_t.includes("timeout")?"failed":"active"}">
                  <span>${zt} (${Wt})</span>
                  <span style="margin-left:auto; font-size:11px;">${_t}</span>
                  ${ht?s`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${ht}</div>`:null}
                  ${$t?s`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${$t}</div>`:null}
                  ${H?s`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${H.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?s`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${lt(r,"status","unknown")}</strong>
            </div>
            ${p.length>0?s`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${p.map(P=>s`<div>violation: ${P}</div>`)}
                </div>`:null}
            ${d.length>0?s`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${d.map(P=>s`<div>warning: ${P}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function cm({state:t,nowMs:e}){var r,d,p;const n=jt.value||((r=t.session)==null?void 0:r.room)||"",a=((d=t.current_round)==null?void 0:d.phase)??((p=t.session)==null?void 0:p.status)??"unknown",i=Uo(e),o=Xp(e);return s`
    <${S} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${i?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${i?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${i?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${o}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${a||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${i?s`<button class="trpg-run-btn recommend" onClick=${()=>Zp(n,a)}>잠금 해제 (120초)</button>`:s`<button class="trpg-run-btn secondary" onClick=${()=>{ya(),x("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function dm({active:t}){return s`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>s`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Yp(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function um({state:t}){const e=t.party??[],n=t.story_log??[];return s`
    <div class="trpg-layout">
      <div>
        <${S} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${S} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${Jo} events=${n.slice(-20)} />
        <//>

        ${t.map?s`
            <${S} title="맵" style="margin-top:16px;">
              <${am} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${S} title="현재 라운드">
          <${Yo} state=${t} />
        <//>

        <${S} title="기여도" style="margin-top:16px;">
          <${Qo} state=${t} />
        <//>

        <${S} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>s`<${Wo} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?s`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?s`
            <${S} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${Vo} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function pm({state:t}){const e=t.story_log??[];return s`
    <div class="trpg-layout">
      <div>
        <${S} title=${`이벤트 타임라인 (${e.length})`}>
          <${sm} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${S} title="최근 라운드 결과">
          <${Xo} />
        <//>

        <${S} title="현재 라운드" style="margin-top:16px;">
          <${Yo} state=${t} />
        <//>
      </div>
    </div>
  `}function mm({state:t,nowMs:e}){const n=t.party??[];return s`
    <div>
      <${cm} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${S} title="조작 패널">
            <${om} state=${t} nowMs=${e} />
          <//>

          <${S} title="Actor Spawn" style="margin-top:16px;">
            <${rm} state=${t} />
          <//>

          <${S} title="Mid-Join Gate" style="margin-top:16px;">
            <${lm} state=${t} nowMs=${e} />
          <//>

          <${S} title="최근 라운드 결과" style="margin-top:16px;">
            <${Xo} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${S} title="기여도" style="margin-top:0;">
            <${Qo} state=${t} />
          <//>

          <${S} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>s`<${Wo} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?s`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?s`
              <${S} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${Vo} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function vm(){var d,p,_,m,c;const t=fo.value,e=Ss.value;if(Pt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const l=window.setInterval(()=>{Ui.value=Date.now()},1e3);return()=>{window.clearInterval(l)}},[]),e&&!t)return s`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return s`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Ft()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],i=t.outcome,o=Bo.value,r=Ui.value;return s`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${jt.value||((d=t.session)==null?void 0:d.room)||"-"} · phase: ${((p=t.current_round)==null?void 0:p.phase)??((_=t.session)==null?void 0:_.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Ft()}>새로고침</button>
      </div>

      <${im} outcome=${i} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((m=t.session)==null?void 0:m.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((c=t.current_round)==null?void 0:c.round_number)??0}</div>
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

      <${dm} active=${o} />

      ${o==="overview"?s`<${um} state=${t} />`:o==="timeline"?s`<${pm} state=${t} />`:s`<${mm} state=${t} nowMs=${r} />`}
    </div>
  `}const ri="masc_dashboard_agent_name";function fm(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(ri);return e??n??"dashboard"}const dt=f(fm()),rn=f(""),ln=f(""),ba=f(""),Zo=f(null),ka=f(null),cn=f(!1),we=f(!1),dn=f(!1),un=f(!1),xa=f(!1),Aa=f(!1),La=f(!1);function Sa(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function Wn(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function tr(t){return!t||t.length===0?"none":t.join(", ")}function gm(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Sa(t.quiet_start)}-${Sa(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${Wn(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${Wn(t.interval_s)}.`:`Lodge ticks every ${Wn(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function ze(){xn();try{await pe()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function li(t){const e=t.trim();dt.value=e,e&&localStorage.setItem(ri,e)}function _m(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Js(){const t=dt.value.trim();if(t){dn.value=!0;try{const e=await fl(t),n=_m(e);n&&li(n),La.value=!0,await ze(),x(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";x(n,"error")}finally{dn.value=!1}}}async function $m(){const t=dt.value.trim();if(t){un.value=!0;try{await uo(t),La.value=!1,await ze(),x(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";x(n,"error")}finally{un.value=!1}}}async function hm(){const t=dt.value.trim();if(t)try{await uo(t)}catch{}localStorage.removeItem(ri),li("dashboard"),La.value=!1,await Js()}async function ym(){const t=dt.value.trim();if(t){xa.value=!0;try{await gl(t),await ze(),x("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";x(n,"error")}finally{xa.value=!1}}}async function Gi(){const t=dt.value.trim(),e=rn.value.trim();if(!(!t||!e)){cn.value=!0;try{await co(t,e),rn.value="",await ze(),x("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";x(a,"error")}finally{cn.value=!1}}}async function bm(){const t=ln.value.trim(),e=ba.value.trim()||"Created from dashboard";if(t){we.value=!0;try{await vl(t,e,1),ln.value="",ba.value="",await ze(),x("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";x(a,"error")}finally{we.value=!1}}}async function Wi(){const t=dt.value.trim()||"dashboard";Aa.value=!0,ka.value=null;try{const e=await kn({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=Xs(e.result);Zo.value=n,await ze(),n!=null&&n.skipped_reason?x(n.skipped_reason,"warning"):x(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";ka.value=n,x(n,"error")}finally{Aa.value=!1}}function km({runtime:t}){var i,o;const e=Zo.value??(t==null?void 0:t.last_tick_result)??null;if(ka.value)return s`<div class="control-result-box is-error">${ka.value}</div>`;if(!e)return s`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((i=e.skipped_rows)==null?void 0:i.slice(0,3))??[],a=((o=e.passed_rows)==null?void 0:o.slice(0,3))??[];return s`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?s`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">Last acted: ${tr(e.acted_names)}</div>
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
  `}function xm(t){return t.find(n=>n.name===Je.value)??t[0]??null}function Am(){var a,i;const t=Ut.value,e=((a=ee.value)==null?void 0:a.lodge)??null,n=xm(t);return Pt(()=>{Js()},[]),Pt(()=>{var r;const o=((r=t[0])==null?void 0:r.name)??"";if(!Je.value&&o){zn(o);return}Je.value&&!t.some(d=>d.name===Je.value)&&zn(o)},[t.map(o=>o.name).join("|")]),s`
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
          value=${dt.value}
          onInput=${o=>li(o.target.value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Js()}}
            disabled=${dn.value||dt.value.trim()===""}
          >
            ${dn.value?"Joining...":La.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{$m()}}
            disabled=${un.value||dt.value.trim()===""}
          >
            ${un.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{hm()}}
            disabled=${dn.value||un.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{ym()}}
            disabled=${xa.value||dt.value.trim()===""}
          >
            ${xa.value?"Pinging...":"Heartbeat"}
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
            value=${rn.value}
            onInput=${o=>{rn.value=o.target.value}}
            onKeyDown=${o=>{o.key==="Enter"&&Gi()}}
            disabled=${cn.value}
          />
          <button
            class="control-btn"
            onClick=${()=>{Gi()}}
            disabled=${cn.value||rn.value.trim()===""||dt.value.trim()===""}
          >
            ${cn.value?"Sending...":"Send"}
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
          onInput=${o=>{zn(o.target.value)}}
          disabled=${t.length===0}
        >
          ${t.length===0?s`<option value="">No keepers available</option>`:t.map(o=>s`<option value=${o.name}>${o.name}</option>`)}
        </select>

        <${Co} keeper=${n} />
        <${Ro}
          actor=${dt.value.trim()||"dashboard"}
          keeper=${n}
          onPokeLodge=${()=>{Wi()}}
        />
        <${No}
          keeperName=${(n==null?void 0:n.name)??""}
          placeholder=${t.length===0?"No keeper is active yet":"Direct prompt for the selected keeper"}
        />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${gm(e)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${e!=null&&e.enabled?"enabled":"disabled"}</span>
          <span class="pill">every ${Wn(e==null?void 0:e.interval_s)}</span>
          <span class="pill">quiet ${Sa(e==null?void 0:e.quiet_start)}-${Sa(e==null?void 0:e.quiet_end)} KST</span>
          <span class="pill">${e!=null&&e.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${e!=null&&e.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${e!=null&&e.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${tr((i=e==null?void 0:e.last_tick_result)==null?void 0:i.acted_names)}
        </div>
        ${e!=null&&e.last_skip_reason?s`<div class="control-status-copy">Last skip reason: ${e.last_skip_reason}</div>`:null}

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{Wi()}}
            disabled=${Aa.value}
          >
            ${Aa.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${km} runtime=${e} />
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
          value=${ln.value}
          onInput=${o=>{ln.value=o.target.value}}
          disabled=${we.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${ba.value}
          onInput=${o=>{ba.value=o.target.value}}
          disabled=${we.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${()=>{bm()}}
          disabled=${we.value||ln.value.trim()===""}
        >
          ${we.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
  `}const Ji=[{id:"observe",label:"Observe",description:"Live health, execution state, and room-wide telemetry"},{id:"coordinate",label:"Coordinate",description:"Conversation, decisions, planning, and backlog context"},{id:"command",label:"Command",description:"Direct control surfaces and intervention workflows"}],Vs=[{id:"command",label:"Command",icon:"🧭",group:"command",description:"Company, platoon, squad, and agent command plane with operation and trace visibility"},{id:"overview",label:"Overview",icon:"🏠",group:"observe",description:"Room health, keeper pressure, and top-line execution status"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals, MDAL loops, and task backlog in one planning surface"},{id:"ops",label:"Ops",icon:"🎮",group:"command",description:"Guided operator controls for room, sessions, and keepers"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}],Vi="masc_dashboard_quick_actions_open";function Sm(){const t=It.value;return s`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${yn.value} events</span>
    </div>
  `}function wm(){const t=Lt.value.tab,e=It.value,n=Vs.find(r=>r.id===t),a=Ji.find(r=>r.id===(n==null?void 0:n.group)),[i,o]=Yi(()=>{const r=localStorage.getItem(Vi);return r!=="0"});return Pt(()=>{localStorage.setItem(Vi,i?"1":"0")},[i]),s`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${a?s`<span class="rail-section-chip">${a.label}</span>`:null}
        </div>
        ${Ji.map(r=>s`
          <div class="rail-nav-group" key=${r.id}>
            <div class="rail-group-label">${r.label}</div>
            <div class="rail-group-copy">${r.description}</div>
            <div class="rail-tab-list">
              ${Vs.filter(d=>d.group===r.id).map(d=>s`
                  <button
                    class="rail-tab-btn ${t===d.id?"active":""}"
                    onClick=${()=>Rt(d.id)}
                  >
                    <span class="rail-tab-icon">${d.icon}</span>
                    <span class="rail-tab-copy">
                      <strong>${d.label}</strong>
                      <span>${d.description}</span>
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
            <strong>${Mt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Keepers</span>
            <strong>${Ut.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Tasks</span>
            <strong>${xt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Events</span>
            <strong>${yn.value}</strong>
          </div>
        </div>
        <div class="rail-snapshot-copy">
          <span>Connection ${e?"healthy":"recovering"}</span>
          <span>${(a==null?void 0:a.label)??"Observe"} workspace active</span>
        </div>
        <div class="rail-inline-actions">
          <button
            class="rail-refresh-btn"
            onClick=${()=>{pe(),t==="command"&&Ca(),t==="ops"&&wn(),t==="board"&&qt(),t==="trpg"&&Ft(),t==="goals"&&(Xn(),fn())}}
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
        ${i?s`<div class="rail-fold-body"><${Am} /></div>`:s`<div class="rail-fold-hint">Use inline actions for quick room nudges. Open the Ops tab for structured intervention work.</div>`}
      </section>
    </aside>
  `}function Tm(){switch(Lt.value.tab){case"command":return s`<${mu} />`;case"overview":return s`<${Di} />`;case"ops":return s`<${Eu} />`;case"board":return s`<${Zu} />`;case"agents":return s`<${Np} />`;case"goals":return s`<${jp} />`;case"trpg":return s`<${vm} />`;default:return s`<${Di} />`}}function Cm(){Pt(()=>{ur(),ao(),pe();const n=dc();return uc(),()=>{hr(),n(),pc()}},[]),Pt(()=>{const n=Lt.value.tab;n==="command"&&Ca(),n==="ops"&&wn(),n==="board"&&qt(),n==="trpg"&&Ft(),n==="goals"&&(Xn(),fn())},[Lt.value.tab]);const t=Lt.value.tab,e=Vs.find(n=>n.id===t);return s`
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
            class="activity-panel-toggle ${Ie.value?"active":""}"
            onClick=${Bc}
            title="Toggle Activity Panel"
          >
            Activity
          </button>
          <${Sm} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${wm} />
        <main class="dashboard-main">
          ${As.value&&!It.value?s`<div class="loading-indicator">Loading dashboard...</div>`:s`<${Tm} />`}
        </main>
      </div>

      ${Ie.value?s`
        <div class="activity-panel-backdrop" onClick=${wi} />
        <aside class="activity-panel">
          <div class="activity-panel-header">
            <h3>Activity Feed</h3>
            <button class="activity-panel-close" onClick=${wi}>Close</button>
          </div>
          <div class="activity-panel-body">
            <${$p} />
          </div>
        </aside>
      `:null}

      <${Kc} />
      <${bc} />
      <${gc} />
    </div>
  `}const Qi=document.getElementById("app");Qi&&ir(s`<${Cm} />`,Qi);
