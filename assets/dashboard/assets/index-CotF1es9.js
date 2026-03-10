var br=Object.defineProperty;var kr=(t,e,n)=>e in t?br(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var ve=(t,e,n)=>kr(t,typeof e!="symbol"?e+"":e,n);import{e as xr,_ as Sr,c as v,b as ft,y as it,A as Vo,d as Ya,G as Ar}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var o=xr.bind(Sr);const Cr=["mission","intervene","command","overview","board","goals","agents","ops","trpg"],Yo={tab:"mission",params:{},postId:null},wr={overview:"mission",journal:"mission",mdal:"goals",tasks:"goals",execution:"mission",council:"board",activity:"mission",ops:"intervene"};function mo(t){return!!t&&Cr.includes(t)}function ca(t){if(t)return wr[t]??t}function In(t){try{return decodeURIComponent(t)}catch{return t}}function da(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Tr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Xo(t,e){if(t[0]==="chains"){const r={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(r.operation=In(t[2])),{tab:"command",params:r,postId:null}}const n=ca(t[0]),s=ca(e.tab),a=mo(n)?n:mo(s)?s:"mission";let i=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=In(t[2]):t[0]==="post"&&t[1]&&(i=In(t[1]))),{tab:a,params:e,postId:i}}function Gn(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Yo;const n=In(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const l=n.indexOf("?");l>=0&&(s=n.slice(0,l),a=n.slice(l+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=da(a),r=Tr(s);return Xo(r,i)}function Rr(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Yo,params:da(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=da(e.replace(/^\?/,""));return Xo(s,a)}function Qo(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const Z=v(Gn(window.location.hash));window.addEventListener("hashchange",()=>{Z.value=Gn(window.location.hash)});function tt(t,e){const s={tab:ca(t)??t,params:e??{},postId:null};window.location.hash=Qo(s)}function Nr(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Lr(){if(window.location.hash&&window.location.hash!=="#"){Z.value=Gn(window.location.hash);return}const t=Rr(window.location.pathname,window.location.search);if(t){Z.value=t;const e=Qo(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",Z.value=Gn(window.location.hash)}const vo="masc_dashboard_sse_session_id",Pr=1e3,Mr=15e3,Dt=v(!1),ks=v(0),Zo=v(null),Jn=v([]);function Dr(){let t=sessionStorage.getItem(vo);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(vo,t)),t}const Er=200;function Ir(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};Jn.value=[a,...Jn.value].slice(0,Er)}function ua(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function _o(t,e){const n=ua(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function gt(t,e,n,s,a={}){Ir(t,e,n,{eventType:s,...a})}let xt=null,ke=null,pa=0;function ti(){ke&&(clearTimeout(ke),ke=null)}function zr(){if(ke)return;pa++;const t=Math.min(pa,5),e=Math.min(Mr,Pr*Math.pow(2,t));ke=setTimeout(()=>{ke=null,ei()},e)}function ei(){ti(),xt&&(xt.close(),xt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Dr());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);xt=i,i.onopen=()=>{xt===i&&(pa=0,Dt.value=!0)},i.onerror=()=>{xt===i&&(Dt.value=!1,i.close(),xt=null,zr())},i.onmessage=r=>{try{const l=JSON.parse(r.data);ks.value++,Zo.value=l,Or(l)}catch{}}}function Or(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":gt(n,"Joined","system","agent_joined");break;case"agent_left":gt(n,"Left","system","agent_left");break;case"broadcast":gt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":gt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":gt(n,_o("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:ua(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":gt(n,_o("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:ua(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":gt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":gt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":gt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":gt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:gt(n,e,"system","unknown")}}function jr(){ti(),xt&&(xt.close(),xt=null),Dt.value=!1}function ni(){return new URLSearchParams(window.location.search)}function si(){const t=ni(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function ai(){return{...si(),"Content-Type":"application/json"}}const Fr=15e3,Xa=3e4,qr=6e4,fo=new Set([408,425,429,500,502,503,504]);class gn extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);ve(this,"method");ve(this,"path");ve(this,"status");ve(this,"statusText");ve(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function Qa(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new gn({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function Kr(){var e,n;const t=ni();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function Y(t){const e=await Qa(t,{headers:si()},Fr);if(!e.ok)throw new gn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Ur(t){return new Promise(e=>setTimeout(e,t))}function Hr(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function Br(t){if(t instanceof gn)return t.timeout||typeof t.status=="number"&&fo.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=Hr(t.message);return e!==null&&fo.has(e)}async function Re(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!Br(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${i}ms`,a),await Ur(i),s+=1}}async function Tt(t,e,n,s=Xa){const a=await Qa(t,{method:"POST",headers:{...ai(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new gn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function Wr(t,e,n,s=Xa){const a=await Qa(t,{method:"POST",headers:{...ai(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new gn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function Gr(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Jr(t){var e,n,s,a,i,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const u=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(u)}return((l=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function jt(t,e){const n=await Wr("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},qr),s=Gr(n);return Jr(s)}function Vr(t="compact"){return Y(`/api/v1/dashboard?mode=${t}`)}function Yr(){return Y("/api/v1/dashboard/mission")}function Xr(){return Y("/api/v1/agents?limit=100")}function Qr(t){const e=new URLSearchParams({limit:"200"});return e.set("include_done","true"),e.set("include_cancelled","true"),Y(`/api/v1/tasks?${e}`)}function Zr(t){const e=new URLSearchParams({limit:"50"});return t!=null&&t>0&&e.set("since_seq",String(t)),Y(`/api/v1/messages?${e}`)}function tl(t={}){return Re("fetchMdalLoops",async()=>{const e=new URLSearchParams;t.limit!=null&&e.set("limit",String(t.limit)),t.historyLimit!=null&&e.set("history_limit",String(t.historyLimit)),t.status&&e.set("status",t.status);const n=e.toString();return Y(`/api/v1/mdal/loops${n?`?${n}`:""}`)})}function el(){return Y("/api/v1/operator")}function oi(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return Y(`/api/v1/operator/digest${n?`?${n}`:""}`)}function nl(){return Y("/api/v1/command-plane")}function sl(){return Y("/api/v1/command-plane/summary")}function al(){return Y("/api/v1/chains/summary")}function ol(t){return Y(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function il(){return Y("/api/v1/command-plane/help")}function rl(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return Y(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function ll(t,e){return Tt(t,e)}function cl(t){switch(t.action_type){case"keeper_msg":case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return Xa}}function xs(t){return Tt("/api/v1/operator/action",t,void 0,cl(t))}function dl(t,e){return Tt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const ul=new Set(["lodge-system","team-session"]);function Ae(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function pl(t){return ul.has(t.trim().toLowerCase())}function ml(t){return t.filter(e=>!pl(e.author))}function vl(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function ii(t){if(!I(t))return null;const e=h(t.id,"").trim(),n=h(t.author,"").trim(),s=h(t.content,"").trim();if(!e||!n)return null;const a=j(t.score,0),i=j(t.votes_up,0),r=j(t.votes_down,0),l=j(t.votes,a||i-r),u=j(t.comment_count,j(t.reply_count,0)),_=(()=>{const y=t.flair;if(typeof y=="string"&&y.trim())return y.trim();if(I(y)){const w=h(y.name,"").trim();if(w)return w}return h(t.flair_name,"").trim()||void 0})(),d=h(t.created_at_iso,"").trim()||Ae(t.created_at),f=h(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Ae(t.updated_at):d),$=h(t.title,"").trim()||vl(s);return{id:e,author:n,title:$,content:s,tags:[],votes:l,vote_balance:a,comment_count:u,created_at:d,updated_at:f,flair:_,hearth_count:j(t.hearth_count,0)}}function _l(t){if(!I(t))return null;const e=h(t.id,"").trim(),n=h(t.post_id,"").trim(),s=h(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:h(t.content,""),created_at:Ae(t.created_at)}}async function fl(t,e){return Re("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const s=n.toString(),a=await Y(`/api/v1/board${s?`?${s}`:""}`),i=Array.isArray(a.posts)?a.posts.map(ii).filter(l=>l!==null):[];return{posts:e!=null&&e.excludeSystem?ml(i):i}})}async function gl(t){return Re("fetchBoardPost",async()=>{const e=await Y(`/api/v1/board/${t}?format=flat`),n=I(e.post)?e.post:e,s=ii(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(_l).filter(r=>r!==null);return{...s,comments:i}})}function ri(t,e){return Tt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Kr()})}function $l(t,e,n){return Tt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function hl(t){const e=h(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function st(...t){for(const e of t){const n=h(e,"");if(n.trim())return n.trim()}return""}function go(t){const e=hl(st(t.outcome,t.result,t.result_code));if(!e)return;const n=st(t.reason,t.reason_code,t.description,t.detail),s=st(t.summary,t.summary_ko,t.summary_en,t.note),a=st(t.details,t.details_text,t.text,t.note),i=st(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=st(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=st(t.raw_reason,t.raw_reason_code,t.error_message),u=(()=>{const f=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof f=="string"?[f]:Array.isArray(f)?f.map(g=>{if(typeof g=="string")return g.trim();if(I(g)){const $=h(g.summary,"").trim();if($)return $;const y=h(g.text,"").trim();if(y)return y;const A=h(g.type,"").trim();return A||h(g.event_id,"").trim()}return""}).filter(g=>g.length>0):[]})(),_=(()=>{const f=j(t.turn,Number.NaN);if(Number.isFinite(f))return f;const g=j(t.turn_number,Number.NaN);if(Number.isFinite(g))return g;const $=j(t.current_turn,Number.NaN);if(Number.isFinite($))return $;const y=j(t.round,Number.NaN);return Number.isFinite(y)?y:void 0})(),d=st(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:u.length>0?u:void 0,raw_reason:l||void 0,turn:_,phase:d||void 0}}function yl(t,e){const n=I(t.state)?t.state:{};if(h(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>I(r)?h(r.type,"")==="session.outcome":!1),i=I(n.session_outcome)?n.session_outcome:{};if(I(i)&&Object.keys(i).length>0){const r=go(i);if(r)return r}if(I(a))return go(I(a.payload)?a.payload:{})}function I(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function j(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function bl(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function ma(t,e=!1){return typeof t=="boolean"?t:e}function Ee(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(I(e)){const n=h(e.name,"").trim(),s=h(e.id,"").trim(),a=h(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function kl(t){const e={};if(!I(t)&&!Array.isArray(t))return e;if(I(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=h(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!I(n))continue;const s=st(n.to,n.target,n.actor_id,n.name,n.id),a=st(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function xl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function vt(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const Sl=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Al(t){const e=I(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const i=s.trim();i&&(Sl.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function Cl(t,e){if(t!=="dice.rolled")return;const n=j(e.raw_d20,0),s=j(e.total,0),a=j(e.bonus,0),i=h(e.action,"roll"),r=j(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function wl(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Tl(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Rl(t,e,n,s){const a=n||e||h(s.actor_id,"")||h(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=h(s.proposed_action,h(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=h(s.reply,h(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return h(s.reply,h(s.content,h(s.text,"Narration")));case"dice.rolled":{const i=h(s.action,"roll"),r=j(s.total,0),l=j(s.dc,0),u=h(s.label,""),_=a||"actor",d=l>0?` vs DC ${l}`:"",f=u?` (${u})`:"";return`${_} ${i}: ${r}${d}${f}`}case"turn.started":return`Turn ${j(s.turn,1)} started`;case"phase.changed":return`Phase: ${h(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(s.name,I(s.actor)?h(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${h(s.keeper_name,h(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${h(s.keeper_name,h(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${j(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${j(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||h(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||h(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${h(s.reason_code,"unknown")}`;case"memory.signal":{const i=I(s.entity_refs)?s.entity_refs:{},r=h(i.requested_tier,""),l=h(i.effective_tier,""),u=ma(i.guardrail_applied,!1),_=h(s.summary_en,h(s.summary_ko,"Memory signal"));if(!r&&!l)return _;const d=r&&l?`${r}->${l}`:l||r;return`${_} [${d}${u?" (guardrail)":""}]`}case"world.event":{if(h(s.event_type,"")==="canon.check"){const r=h(s.status,"unknown"),l=h(s.contract_id,"n/a");return`Canon ${r}: ${l}`}return h(s.description,h(s.summary,"World event"))}case"combat.attack":return h(s.summary,h(s.result,"Attack resolved"));case"combat.defense":return h(s.summary,h(s.result,"Defense resolved"));case"session.outcome":return h(s.summary,h(s.outcome,"Session ended"));default:{const i=wl(s);return i?`${t}: ${i}`:t}}}function Nl(t,e){const n=I(t)?t:{},s=h(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=h(n.actor_name,"").trim()||e[a]||h(I(n.payload)?n.payload.actor_name:"",""),r=I(n.payload)?n.payload:{},l=h(n.ts,h(n.timestamp,new Date().toISOString())),u=h(n.phase,h(r.phase,"")),_=h(n.category,"");return{type:s,actor:i||a||h(r.actor_name,""),actor_id:a||h(r.actor_id,""),actor_name:i,seq:n.seq,room_id:h(n.room_id,""),phase:u||void 0,category:_||Tl(s),visibility:h(n.visibility,h(r.visibility,"public")),event_id:h(n.event_id,""),content:Rl(s,a,i,r),dice_roll:Cl(s,r),timestamp:l}}function Ll(t,e,n){var lt,ct;const s=h(t.room_id,"")||n||"default",a=I(t.state)?t.state:{},i=I(a.party)?a.party:{},r=I(a.actor_control)?a.actor_control:{},l=I(a.join_gate)?a.join_gate:{},u=I(a.contribution_ledger)?a.contribution_ledger:{},_=Object.entries(i).map(([U,Q])=>{const b=I(Q)?Q:{},Qt=vt(b,"max_hp",void 0,10),De=vt(b,"hp",void 0,Qt),yn=vt(b,"max_mp",void 0,0),bn=vt(b,"mp",void 0,0),E=vt(b,"level",void 0,1),Zt=vt(b,"xp",void 0,0),kn=ma(b.alive,De>0),uo=r[U],po=typeof uo=="string"?uo:void 0,vr=xl(b.role,U,po),_r=bl(b.generation),fr=st(b.joined_at,b.joinedAt,b.started_at,b.startedAt),gr=st(b.claimed_at,b.claimedAt,b.assigned_at,b.assignedAt,b.assigned_time),$r=st(b.last_seen,b.lastSeen,b.last_seen_at,b.lastSeenAt,b.last_active,b.lastActive),hr=st(b.scene,b.current_scene,b.currentScene,b.world_scene,b.scene_name,b.sceneName),yr=st(b.location,b.current_location,b.currentLocation,b.position,b.zone,b.area);return{id:U,name:h(b.name,U),role:vr,keeper:po,archetype:h(b.archetype,""),persona:h(b.persona,""),portrait:h(b.portrait,"")||void 0,background:h(b.background,"")||void 0,traits:Ee(b.traits),skills:Ee(b.skills),stats_raw:Al(b),status:kn?"active":"dead",generation:_r,joined_at:fr||void 0,claimed_at:gr||void 0,last_seen:$r||void 0,scene:hr||void 0,location:yr||void 0,inventory:Ee(b.inventory),notes:Ee(b.notes),relationships:kl(b.relationships),stats:{hp:De,max_hp:Qt,mp:bn,max_mp:yn,level:E,xp:Zt,strength:vt(b,"strength","str",10),dexterity:vt(b,"dexterity","dex",10),constitution:vt(b,"constitution","con",10),intelligence:vt(b,"intelligence","int",10),wisdom:vt(b,"wisdom","wis",10),charisma:vt(b,"charisma","cha",10)}}}),d=_.filter(U=>U.status!=="dead"),f=yl(t,e),g={phase_open:ma(l.phase_open,!0),min_points:j(l.min_points,3),window:h(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},$=Object.entries(u).map(([U,Q])=>{const b=I(Q)?Q:{};return{actor_id:U,score:j(b.score,0),last_reason:h(b.last_reason,"")||null,reasons:Ee(b.reasons)}}),y=_.reduce((U,Q)=>(U[Q.id]=Q.name,U),{}),A=e.map(U=>Nl(U,y)),w=j(a.turn,1),D=h(a.phase,"round"),O=h(a.map,""),M=I(a.world)?a.world:{},R=O||h(M.ascii_map,h(M.map,"")),N=A.filter((U,Q)=>{const b=e[Q];if(!I(b))return!1;const Qt=I(b.payload)?b.payload:{};return j(Qt.turn,-1)===w}),p=(N.length>0?N:A).slice(-12),q=h(a.status,"active");return{session:{id:s,room:s,status:q==="ended"?"ended":q==="paused"?"paused":"active",round:w,actors:d,created_at:((lt=A[0])==null?void 0:lt.timestamp)??new Date().toISOString()},current_round:{round_number:w,phase:D,events:p,timestamp:((ct=A[A.length-1])==null?void 0:ct.timestamp)??new Date().toISOString()},map:R||void 0,join_gate:g,contribution_ledger:$,outcome:f,party:d,story_log:A,history:[]}}async function Pl(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await Y(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Ml(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([Y(`/api/v1/trpg/state${e}`),Pl(t)]);return Ll(n,s,t)}function Dl(t){return Tt("/api/v1/trpg/rounds/run",{room_id:t})}function El(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Il(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Tt("/api/v1/trpg/dice/roll",e)}function zl(t,e){const n=El();return Tt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function Ol(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Tt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function jl(t,e,n){return Tt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Fl(t,e,n){const s=await jt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function ql(t){const e=await jt("trpg.mid_join.request",t);return JSON.parse(e)}async function Kl(t,e){await jt("masc_broadcast",{agent_name:t,message:e})}async function Ul(t=40){return(await jt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Hl(t,e=20){return jt("masc_task_history",{task_id:t,limit:e})}async function Bl(){return Re("fetchDebates",async()=>{const t=await Y("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!I(e))return null;const n=h(e.id,"").trim(),s=h(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,status:h(e.status,"open"),argument_count:j(e.argument_count,0),created_at:Ae(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Wl(){return Re("fetchCouncilSessions",async()=>{const t=await Y("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!I(e))return null;const n=h(e.id,"").trim(),s=h(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,initiator:h(e.initiator,"system"),votes:j(e.votes,0),quorum:j(e.quorum,0),state:h(e.state,"open"),created_at:Ae(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Gl(t){const e=await jt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Jl(t){return Re("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await Y(`/api/v1/council/debates/${e}/summary`);if(!I(n))return null;const s=h(n.id,"").trim();return s?{id:s,topic:h(n.topic,""),status:h(n.status,"open"),support_count:j(n.support_count,0),oppose_count:j(n.oppose_count,0),neutral_count:j(n.neutral_count,0),total_arguments:j(n.total_arguments,0),created_at:Ae(n.created_at_iso??n.created_at),summary_text:h(n.summary_text,"")}:null})}function Vl(t,e,n){return jt("masc_keeper_msg",{name:t,message:e})}async function Yl(){try{const t=await jt("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const Xl=v(""),Et=v({}),at=v({}),va=v({}),_a=v({}),fa=v({}),ga=v({}),It=v({});function nt(t,e,n){t.value={...t.value,[e]:n}}function Ft(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function K(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function ht(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function he(t){return typeof t=="boolean"?t:void 0}function $a(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function ha(t){return Array.isArray(t)?t.map(e=>K(e)).filter(e=>!!e):[]}function Ql(t){var n;const e=(n=K(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Zl(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Is(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!Ft(s))continue;const a=K(s.name);if(!a)continue;const i=K(s[e]);e==="summary"?n.push({name:a,summary:i}):n.push({name:a,reason:i})}return n}function tc(t){if(!Ft(t))return null;const e=K(t.name);return e?{name:e,trigger:K(t.trigger),outcome:K(t.outcome),summary:K(t.summary),reason:K(t.reason)}:null}function ec(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function nc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function li(t,e,n){return K(t)??nc(e,n)}function ci(t,e){return typeof t=="boolean"?t:e==="recover"}function Vn(t){if(!Ft(t))return null;const e=K(t.health_state),n=K(t.next_action_path),s=K(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:K(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:$a(t.last_reply_at),last_reply_preview:K(t.last_reply_preview)??null,last_error:K(t.last_error)??null,next_eligible_at_s:ht(t.next_eligible_at_s)??null,recoverable:ci(t.recoverable,n),summary:li(t.summary,e,K(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function di(t){return Ft(t)?{hour:ht(t.hour),checked:ht(t.checked)??0,acted:ht(t.acted)??0,acted_names:ha(t.acted_names),activity_report:K(t.activity_report),quiet_hours_overridden:he(t.quiet_hours_overridden),skipped_reason:K(t.skipped_reason),acted_rows:Is(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:Is(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:Is(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(tc).filter(e=>e!==null):[]}:null}function sc(t){return Ft(t)?{enabled:he(t.enabled)??!1,interval_s:ht(t.interval_s)??0,quiet_start:ht(t.quiet_start),quiet_end:ht(t.quiet_end),quiet_active:he(t.quiet_active),use_planner:he(t.use_planner),delegate_llm:he(t.delegate_llm),agent_count:ht(t.agent_count),agents:ha(t.agents),last_tick_ago_s:ht(t.last_tick_ago_s)??null,last_tick_ago:K(t.last_tick_ago),total_ticks:ht(t.total_ticks),total_checkins:ht(t.total_checkins),last_skip_reason:K(t.last_skip_reason)??null,last_tick_result:di(t.last_tick_result),active_self_heartbeats:ha(t.active_self_heartbeats)}:null}function ac(t){return Ft(t)?{status:t.status,diagnostic:Vn(t.diagnostic)}:null}function oc(t){return Ft(t)?{recovered:he(t.recovered)??!1,skipped_reason:K(t.skipped_reason)??null,before:Vn(t.before),after:Vn(t.after),down:t.down,up:t.up}:null}function ic(t,e){var O,M;if(!(t!=null&&t.name))return null;const n=K((O=t.agent)==null?void 0:O.status)??K(t.status)??"unknown",s=K((M=t.agent)==null?void 0:M.error)??null,a=t.presence_keepalive??!0,i=t.keepalive_running??!1,r=t.turn_count??0,l=t.last_turn_ago_s??null,u=t.proactive_enabled??!1,_=t.proactive_cooldown_sec??0,d=t.last_proactive_ago_s??null,f=u&&d!=null?Math.max(0,_-d):null,g=r<=0||l==null?"never":l>900?"stale":"fresh",$=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,y=s??(a&&!i?"keeper keepalive is not running":null),A=n==="offline"||n==="inactive"?"offline":y?"degraded":g==="stale"?"stale":g==="never"?"idle":"healthy",w=y?ec(y):e!=null&&e.quiet_active&&g!=="fresh"?"quiet_hours":a&&!i?"disabled":r<=0?"never_started":f!=null&&f>0?"min_gap":g==="fresh"||g==="stale"?"no_recent_activity":"unknown",D=A==="offline"||A==="degraded"||A==="stale"?"recover":w==="quiet_hours"?"manual_lodge_poke":w==="unknown"?"probe":"direct_message";return{health_state:A,quiet_reason:w,next_action_path:D,last_reply_status:g,last_reply_at:$,last_reply_preview:null,last_error:y,next_eligible_at_s:f!=null&&f>0?f:null,recoverable:ci(void 0,D),summary:li(void 0,A,w),keepalive_running:i}}function rc(t,e){if(!Ft(t))return null;const n=Ql(t.role),s=K(t.content)??K(t.preview);if(!s)return null;const a=$a(t.ts_unix)??$a(t.timestamp);return{id:`${n}-${a??"entry"}-${e}`,role:n,label:Zl(n),text:s,timestamp:a,delivery:"history"}}function lc(t,e,n){const s=Ft(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((i,r)=>rc(i,r)).filter(i=>i!==null):[];return{name:t,diagnostic:Vn(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function $o(t,e){const n=at.value[t]??[];at.value={...at.value,[t]:[...n,e].slice(-50)}}function cc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function dc(t,e){const s=(at.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(i=>cc(a,i)));at.value={...at.value,[t]:[...e,...s].slice(-50)}}function Ss(t,e){Et.value={...Et.value,[t]:e},dc(t,e.history)}function ho(t,e){const n=Et.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Ss(t,{...n,diagnostic:{...s,...e}})}async function Za(){an();try{await ue()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function uc(t){Xl.value=t.trim()}async function ui(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Et.value[n])return Et.value[n];nt(va,n,!0),nt(It,n,null);try{const s=await jt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const i=lc(n,s,a);return Ss(n,i),i}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return nt(It,n,a),null}finally{nt(va,n,!1)}}async function pc(t,e){const n=t.trim(),s=e.trim();if(!n||!s)return;const a=`local-${Date.now()}`;$o(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),nt(_a,n,!0),nt(It,n,null);try{const i=await Vl(n,s);at.value={...at.value,[n]:(at.value[n]??[]).map(r=>r.id===a?{...r,delivery:"delivered"}:r)},$o(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),ho(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await Za()}catch(i){const r=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw at.value={...at.value,[n]:(at.value[n]??[]).map(l=>l.id===a?{...l,delivery:"error",error:r}:l)},ho(n,{last_reply_status:"error",last_error:r}),nt(It,n,r),i}finally{nt(_a,n,!1)}}async function mc(t,e){const n=t.trim();if(!n)return null;nt(fa,n,!0),nt(It,n,null);try{const s=await xs({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=ac(s.result),i=(a==null?void 0:a.diagnostic)??null;if(i){const r=Et.value[n];Ss(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??at.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Za(),i}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw nt(It,n,a),s}finally{nt(fa,n,!1)}}async function vc(t,e){const n=t.trim();if(!n)return null;nt(ga,n,!0),nt(It,n,null);try{const s=await xs({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=oc(s.result),i=(a==null?void 0:a.after)??null;if(i){const r=Et.value[n];Ss(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??at.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Za(),i}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw nt(It,n,a),s}finally{nt(ga,n,!1)}}function te(t){return(t??"").trim().toLowerCase()}function dt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function zn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function xn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ie(t){return t.last_heartbeat??xn(t.last_turn_ago_s)??xn(t.last_proactive_ago_s)??xn(t.last_handoff_ago_s)??xn(t.last_compaction_ago_s)}function _c(t){const e=t.title.trim();return e||zn(t.content)}function fc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function gc(t,e,n,s,a={}){var M;const i=te(t),r=e.filter(R=>te(R.assignee)===i&&(R.status==="claimed"||R.status==="in_progress")).length,l=n.filter(R=>te(R.from)===i).sort((R,N)=>dt(N.timestamp)-dt(R.timestamp))[0],u=s.filter(R=>te(R.agent)===i||te(R.author)===i).sort((R,N)=>dt(N.timestamp)-dt(R.timestamp))[0],_=(a.boardPosts??[]).filter(R=>te(R.author)===i).sort((R,N)=>dt(N.updated_at||N.created_at)-dt(R.updated_at||R.created_at))[0],d=(a.keepers??[]).filter(R=>te(R.name)===i&&Ie(R)!==null).sort((R,N)=>dt(Ie(N)??0)-dt(Ie(R)??0))[0],f=l?dt(l.timestamp):0,g=u?dt(u.timestamp):0,$=_?dt(_.updated_at||_.created_at):0,y=d?dt(Ie(d)??0):0,A=a.lastSeen?dt(a.lastSeen):0,w=((M=a.currentTask)==null?void 0:M.trim())||(r>0?`${r} claimed tasks`:null);if(f===0&&g===0&&$===0&&y===0&&A===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:w};const O=[l?{timestamp:l.timestamp,ts:f,text:zn(l.content)}:null,_?{timestamp:_.updated_at||_.created_at,ts:$,text:`Post: ${zn(_c(_))}`}:null,d?{timestamp:Ie(d),ts:y,text:fc(d)}:null,u?{timestamp:new Date(u.timestamp).toISOString(),ts:g,text:zn(u.text)}:null].filter(R=>R!==null).sort((R,N)=>N.ts-R.ts)[0];return O&&O.ts>=A?{activeAssignedCount:r,lastActivityAt:O.timestamp,lastActivityText:O.text}:{activeAssignedCount:r,lastActivityAt:a.lastSeen??null,lastActivityText:w??"Presence heartbeat"}}const wt=v([]),yt=v([]),tn=v([]),pe=v([]),Ne=v(null),$c=v(null),ya=v(new Map),Le=v([]),en=v("hot"),se=v(!0),pi=v(null),Mt=v(""),nn=v([]),ye=v(!1),mi=v(new Map),ba=v("unknown"),ka=v(null),xa=v(!1),sn=v(!1),Sa=v(!1),be=v(!1),hc=v(null),Aa=v(null),vi=v(null),_i=v(null);ft(()=>wt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const yc=ft(()=>{const t=yt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),fi=ft(()=>{const t=new Map,e=yt.value,n=tn.value,s=Jn.value,a=Le.value,i=pe.value;for(const r of wt.value)t.set(r.name.trim().toLowerCase(),gc(r.name,e,n,s,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:a,keepers:i}));return t});function bc(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const kc=ft(()=>{const t=new Map;for(const e of pe.value)t.set(e.name,bc(e));return t}),xc=12e4;function Sc(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof a=="number"?Date.now()-a*1e3:null}const Ac=ft(()=>{const t=Date.now(),e=new Set,n=ya.value;for(const s of pe.value){const a=Sc(s,n);a!=null&&t-a>xc&&e.add(s.name)}return e}),Yn={},Cc=5e3;let zs=null;function wc(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function an(){delete Yn.compact,delete Yn.full}function ot(t){return typeof t=="object"&&t!==null}function x(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function C(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function le(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Ca(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function gi(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Tc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function $i(t){if(!ot(t))return null;const e=x(t.name);return e?{name:e,status:gi(t.status),current_task:x(t.current_task)??null,last_seen:x(t.last_seen),emoji:x(t.emoji),koreanName:x(t.koreanName)??x(t.korean_name),model:x(t.model),traits:le(t.traits),interests:le(t.interests),activityLevel:C(t.activityLevel)??C(t.activity_level),primaryValue:x(t.primaryValue)??x(t.primary_value)}:null}function hi(t){if(!ot(t))return null;const e=x(t.id),n=x(t.title);return!e||!n?null:{id:e,title:n,status:Tc(t.status),priority:C(t.priority),assignee:x(t.assignee),description:x(t.description),created_at:x(t.created_at),updated_at:x(t.updated_at)}}function yi(t){if(!ot(t))return null;const e=x(t.from)??x(t.from_agent)??"system",n=x(t.content)??"",s=x(t.timestamp)??new Date().toISOString();return{id:x(t.id),seq:C(t.seq),from:e,content:n,timestamp:s,type:x(t.type)}}function Rc(t){return Array.isArray(t)?t.map(e=>{if(!ot(e))return null;const n=C(e.ts_unix);if(n==null)return null;const s=ot(e.handoff)?e.handoff:null;return{ts:n,context_ratio:C(e.context_ratio)??0,context_tokens:C(e.context_tokens)??0,context_max:C(e.context_max)??0,latency_ms:C(e.latency_ms)??0,generation:C(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:C(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:C(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?C(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function yo(t){if(!ot(t))return null;const e=x(t.health_state),n=x(t.next_action_path),s=x(t.last_reply_status);if(!e||!n||!s)return null;const a=x(t.quiet_reason)??null,i=x(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:Ca(t.last_reply_at)??x(t.last_reply_at)??null,last_reply_preview:x(t.last_reply_preview)??null,last_error:x(t.last_error)??null,next_eligible_at_s:C(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:i,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Nc(t,e){return(Array.isArray(t)?t:ot(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!ot(s))return null;const a=ot(s.agent)?s.agent:null,i=ot(s.context)?s.context:null,r=ot(s.metrics_window)?s.metrics_window:void 0,l=x(s.name);if(!l)return null;const u=C(s.context_ratio)??C(i==null?void 0:i.context_ratio),_=x(s.status)??x(a==null?void 0:a.status)??"offline",d=gi(_),f=x(s.model)??x(s.active_model)??x(s.primary_model),g=le(s.skill_secondary),$=i?{source:x(i.source),context_ratio:C(i.context_ratio),context_tokens:C(i.context_tokens),context_max:C(i.context_max),message_count:C(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,y=a?{name:x(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:x(a.error),status:x(a.status),current_task:x(a.current_task)??null,last_seen:x(a.last_seen),last_seen_ago_s:C(a.last_seen_ago_s),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,A=Rc(s.metrics_series),w={name:l,emoji:x(s.emoji),koreanName:x(s.koreanName)??x(s.korean_name),agent_name:x(s.agent_name),trace_id:x(s.trace_id),model:f,primary_model:x(s.primary_model),active_model:x(s.active_model),next_model_hint:x(s.next_model_hint)??null,status:d,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:C(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:C(s.proactive_idle_sec),proactive_cooldown_sec:C(s.proactive_cooldown_sec),last_heartbeat:x(s.last_heartbeat)??x(a==null?void 0:a.last_seen),generation:C(s.generation),turn_count:C(s.turn_count)??C(s.total_turns),keeper_age_s:C(s.keeper_age_s),last_turn_ago_s:C(s.last_turn_ago_s),last_handoff_ago_s:C(s.last_handoff_ago_s),last_compaction_ago_s:C(s.last_compaction_ago_s),last_proactive_ago_s:C(s.last_proactive_ago_s),context_ratio:u,context_tokens:C(s.context_tokens)??C(i==null?void 0:i.context_tokens),context_max:C(s.context_max)??C(i==null?void 0:i.context_max),context_source:x(s.context_source)??x(i==null?void 0:i.source),context:$,traits:le(s.traits),interests:le(s.interests),primaryValue:x(s.primaryValue)??x(s.primary_value),activityLevel:C(s.activityLevel)??C(s.activity_level),memory_recent_note:x(s.memory_recent_note)??null,conversation_tail_count:C(s.conversation_tail_count),k2k_count:C(s.k2k_count),handoff_count_total:C(s.handoff_count_total)??C(s.trace_history_count),compaction_count:C(s.compaction_count),last_compaction_saved_tokens:C(s.last_compaction_saved_tokens),diagnostic:yo(s.diagnostic),skill_primary:x(s.skill_primary)??null,skill_secondary:g,skill_reason:x(s.skill_reason)??null,metrics_series:A.length>0?A:void 0,metrics_window:r,agent:y};return w.diagnostic=yo(s.diagnostic)??ic(w,(e==null?void 0:e.lodge)??null),w}).filter(s=>s!==null)}function Lc(t){return ot(t)?{...t,lodge:sc(t.lodge)??void 0}:null}function Pc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function Mc(t){if(!ot(t))return null;const e=C(t.iteration);if(e==null)return null;const n=C(t.metric_before)??0,s=C(t.metric_after)??n,a=ot(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:C(t.delta)??s-n,changes:x(t.changes)??"",failed_attempts:x(t.failed_attempts)??"",next_suggestion:x(t.next_suggestion)??"",elapsed_ms:C(t.elapsed_ms)??0,cost_usd:C(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:x(a.worker_model)??"",tool_call_count:C(a.tool_call_count)??0,tool_names:le(a.tool_names)??[],session_id:x(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function Dc(t){var i,r;if(!ot(t))return null;const e=x(t.loop_id);if(!e)return null;const n=C(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(Mc).filter(l=>l!==null):[],a=C(t.current_metric)??((i=s[0])==null?void 0:i.metric_after)??n;return{loop_id:e,profile:x(t.profile)??"unknown",status:Pc(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:x(t.error_message)??x(t.error_reason)??null,stop_reason:x(t.stop_reason)??x(t.reason)??null,current_iteration:C(t.current_iteration)??((r=s[0])==null?void 0:r.iteration)??0,max_iterations:C(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:x(t.target)??"",stagnation_streak:C(t.stagnation_streak)??0,stagnation_limit:C(t.stagnation_limit)??0,elapsed_seconds:C(t.elapsed_seconds)??0,updated_at:Ca(t.updated_at)??null,stopped_at:Ca(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:x(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:C(t.latest_tool_call_count)??0,latest_tool_names:le(t.latest_tool_names)??[],session_id:x(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function ue(t="full"){var s,a,i;const e=Date.now(),n=Yn[t];if(!(n&&e-n.time<Cc)){xa.value=!0;try{const r=await Vr(t);Yn[t]={data:r,time:e},wt.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map($i).filter(u=>u!==null),yt.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map(hi).filter(u=>u!==null),tn.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(yi).filter(u=>u!==null);const l=Lc(r.status);Ne.value=l,pe.value=Nc(r.keepers,l),$c.value=r.perpetual??null,hc.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{xa.value=!1}}}async function Ec(){try{const t=await Xr(),e=(Array.isArray(t.agents)?t.agents:[]).map($i).filter(a=>a!==null),n=wt.value,s=new Map(n.map(a=>[a.name,a]));wt.value=e.map(a=>{const i=s.get(a.name);return i?{...i,status:a.status,current_task:a.current_task}:a})}catch(t){console.error("Agents selective fetch error:",t)}}async function Ic(){try{const t=await Qr({includeDone:!0,includeCancelled:!0}),e=(Array.isArray(t.tasks)?t.tasks:[]).map(hi).filter(a=>a!==null),n=yt.value,s=new Map(n.map(a=>[a.id,a]));yt.value=e.map(a=>{const i=s.get(a.id);return i?{...i,status:a.status,priority:a.priority??i.priority,assignee:a.assignee??i.assignee}:a})}catch(t){console.error("Tasks selective fetch error:",t)}}async function zc(){try{const t=tn.value,e=t.reduce((l,u)=>Math.max(l,u.seq??0),0),n=await Zr(e),s=(Array.isArray(n.messages)?n.messages:[]).map(yi).filter(l=>l!==null);if(s.length===0)return;const a=new Set(t.map(l=>l.seq).filter(l=>l!=null)),i=new Set(t.filter(l=>l.seq==null).map(l=>`${l.timestamp}|${l.from}`)),r=s.filter(l=>{if(l.seq!=null)return!a.has(l.seq);const u=`${l.timestamp}|${l.from}`;return i.has(u)?!1:(i.add(u),!0)});if(r.length>0){const l=[...t,...r];tn.value=l.length>500?l.slice(-500):l}}catch(t){console.error("Messages selective fetch error:",t)}}async function At(){sn.value=!0;try{const t=await fl(en.value,{excludeSystem:se.value});Le.value=t.posts??[],Aa.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{sn.value=!1}}async function Ct(){var t;Sa.value=!0;try{const e=Mt.value||((t=Ne.value)==null?void 0:t.room)||"default";Mt.value||(Mt.value=e);const n=await Ml(e);pi.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Sa.value=!1}}async function on(){ye.value=!0;try{const t=await Yl();nn.value=Array.isArray(t)?t:[],vi.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{ye.value=!1}}async function Ce(){be.value=!0;try{const t=await tl(),e=Array.isArray(t.loops)?t.loops:[],n=new Map;for(const s of e){const a=Dc(s);a&&n.set(a.loop_id,a)}mi.value=n,_i.value=new Date().toISOString(),ka.value=null,ba.value=n.size===0?"idle":"ready"}catch(t){console.error("MDAL fetch error:",t),ba.value="error",ka.value=t instanceof Error?t.message:String(t)}finally{be.value=!1}}let On=null;function Oc(t){On=t}let jn=null;function jc(t){jn=t}let Fn=null;function Fc(t){Fn=t}const ae={};function ee(t,e,n=500){ae[t]&&clearTimeout(ae[t]),ae[t]=setTimeout(()=>{e(),delete ae[t]},n)}function qc(){const t=Zo.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(ya.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),ya.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&ee("agents",Ec),wc(e.type)&&(an(),zs||(zs=setTimeout(()=>{ue(),jn==null||jn(),Fn==null||Fn(),zs=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&ee("tasks",Ic),e.type==="broadcast"&&ee("messages",zc),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&ee("dashboard",()=>{an(),ue()}),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&ee("board",At),e.type.startsWith("decision_")&&ee("council",()=>On==null?void 0:On()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&ee("mdal",Ce,350)}});return()=>{t();for(const e of Object.keys(ae))clearTimeout(ae[e]),delete ae[e]}}let Ue=null;function Kc(){Ue||(Ue=setInterval(()=>{Dt.value||an(),ue()},1e4))}function Uc(){Ue&&(clearInterval(Ue),Ue=null)}function T({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}const bi=v(null),wa=v(!1),Xn=v(null);function G(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function P(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function B(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function to(t){return typeof t=="boolean"?t:void 0}function Lt(t,e=[]){if(Array.isArray(t))return t;if(!G(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function As(t){if(!G(t))return null;const e=P(t.kind),n=P(t.summary),s=P(t.target_type);return!e||!n||!s?null:{kind:e,severity:P(t.severity)??"warn",summary:n,target_type:s,target_id:P(t.target_id)??null,actor:P(t.actor)??null,evidence:t.evidence}}function Cs(t){if(!G(t))return null;const e=P(t.action_type),n=P(t.target_type),s=P(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:P(t.target_id)??null,severity:P(t.severity)??"warn",reason:s,confirm_required:to(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Hc(t){if(!G(t))return null;const e=P(t.session_id);return e?{session_id:e,goal:P(t.goal),status:P(t.status),health:P(t.health),scale_profile:P(t.scale_profile),control_profile:P(t.control_profile),planned_worker_count:B(t.planned_worker_count),active_agent_count:B(t.active_agent_count),last_turn_age_sec:B(t.last_turn_age_sec)??null,attention_count:B(t.attention_count),recommended_action_count:B(t.recommended_action_count),top_attention:As(t.top_attention),top_recommendation:Cs(t.top_recommendation)}:null}function Bc(t){if(!G(t))return null;const e=P(t.session_id);return e?{session_id:e,status:P(t.status),progress_pct:B(t.progress_pct),elapsed_sec:B(t.elapsed_sec),remaining_sec:B(t.remaining_sec),done_delta_total:B(t.done_delta_total),summary:G(t.summary)?t.summary:void 0,team_health:G(t.team_health)?t.team_health:void 0,communication_metrics:G(t.communication_metrics)?t.communication_metrics:void 0,orchestration_state:G(t.orchestration_state)?t.orchestration_state:void 0,cascade_metrics:G(t.cascade_metrics)?t.cascade_metrics:void 0,report_paths:G(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([n,s])=>{const a=P(s);return a?[n,a]:null}).filter(n=>n!==null)):void 0,session:G(t.session)?t.session:void 0,recent_events:Lt(t.recent_events,["events"]).filter(G)}:null}function Wc(t){if(!G(t))return null;const e=P(t.name);return e?{name:e,agent_name:P(t.agent_name),status:P(t.status),autonomy_level:P(t.autonomy_level),context_ratio:B(t.context_ratio),generation:B(t.generation),active_goal_ids:Lt(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:P(t.last_autonomous_action_at)??null,last_turn_ago_s:B(t.last_turn_ago_s),model:P(t.model)}:null}function Gc(t){if(!G(t))return null;const e=P(t.confirm_token)??P(t.token);return e?{confirm_token:e,actor:P(t.actor),action_type:P(t.action_type),target_type:P(t.target_type),target_id:P(t.target_id)??null,delegated_tool:P(t.delegated_tool),created_at:P(t.created_at),preview:t.preview}:null}function Jc(t){if(!G(t))return null;const e=P(t.action_type),n=P(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:P(t.description),confirm_required:to(t.confirm_required)}}function Vc(t){const e=G(t)?t:{};return{room_health:P(e.room_health),cluster:P(e.cluster),project:P(e.project),current_room:P(e.current_room)??null,paused:to(e.paused),tempo_interval_s:B(e.tempo_interval_s),active_agents:B(e.active_agents),keeper_pressure:B(e.keeper_pressure),active_operations:B(e.active_operations),pending_approvals:B(e.pending_approvals),incident_count:B(e.incident_count),recommended_action_count:B(e.recommended_action_count),top_attention:As(e.top_attention),top_action:Cs(e.top_action)}}function Yc(t){const e=G(t)?t:{},n=G(e.swarm_overview)?e.swarm_overview:{};return{health:P(e.health),active_operations:B(e.active_operations),pending_approvals:B(e.pending_approvals),swarm_overview:{active_lanes:B(n.active_lanes),moving_lanes:B(n.moving_lanes),stalled_lanes:B(n.stalled_lanes),projected_lanes:B(n.projected_lanes),last_movement_at:P(n.last_movement_at)??null},top_attention:As(e.top_attention),top_action:Cs(e.top_action),session_cards:Lt(e.session_cards).map(Hc).filter(s=>s!==null)}}function Xc(t){const e=G(t)?t:{};return{sessions:Lt(e.sessions,["items"]).map(Bc).filter(n=>n!==null),keepers:Lt(e.keepers,["items"]).map(Wc).filter(n=>n!==null),pending_confirms:Lt(e.pending_confirms).map(Gc).filter(n=>n!==null),available_actions:Lt(e.available_actions).map(Jc).filter(n=>n!==null)}}function Qc(t){const e=G(t)?t:{};return{generated_at:P(e.generated_at),summary:Vc(e.summary),incidents:Lt(e.incidents).map(As).filter(n=>n!==null),recommended_actions:Lt(e.recommended_actions).map(Cs).filter(n=>n!==null),command_focus:Yc(e.command_focus),operator_targets:Xc(e.operator_targets)}}async function Ta(){wa.value=!0,Xn.value=null;try{const t=await Yr();bi.value=Qc(t)}catch(t){Xn.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{wa.value=!1}}function pt(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}function bo(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:`${Math.round(n/3600)}h 전`}function ki(t){return t?t.target_type==="room"||t.target_type==="team_session"||t.target_type==="keeper"?()=>tt("intervene"):()=>tt("command"):()=>tt("intervene")}function _e({label:t,value:e,detail:n,tone:s}){return o`
    <article class="mission-stat-card ${pt(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function Zc({item:t}){return o`
    <article class="mission-incident-card ${pt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${pt(t.severity)}">${t.severity}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <strong>${t.summary}</strong>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>tt("intervene")}>개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>tt("command")}>지휘면 보기</button>
      </div>
    </article>
  `}function td({action:t}){return o`
    <article class="mission-action-card ${pt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${pt(t.severity)}">${t.action_type}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.reason}</p>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${ki(t)}>개입 워크스페이스</button>
      </div>
    </article>
  `}function ed({session:t}){return o`
    <article class="mission-session-card ${pt(t.health)}">
      <div class="mission-card-head">
        <strong>${t.goal??t.session_id}</strong>
        <span class="command-chip ${pt(t.health)}">${t.health??"ok"}</span>
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
  `}function Os(){var r,l,u;const t=bi.value;if(wa.value&&!t)return o`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(Xn.value&&!t)return o`<div class="empty-state error">${Xn.value}</div>`;if(!t)return o`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;const e=t.summary,n=t.incidents[0]??e.top_attention??null,s=t.recommended_actions[0]??e.top_action??null,a=t.command_focus.session_cards.slice(0,3),i=t.operator_targets.keepers.slice(0,4);return o`
    <section class="dashboard-panel mission-view">
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 문제, 다음 액션, 운영 포커스를 한 번에 보는 운영 랜딩입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${pt(e.room_health)}">${e.room_health??"ok"}</span>
          <span class="command-chip">${e.project??"room"}${e.current_room?` · ${e.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?bo(t.generated_at):"fresh"}</span>
        </div>
      </div>

      <div class="mission-stat-grid">
        <${_e} label="활성 에이전트" value=${e.active_agents??0} detail="실시간 응답 가능한 agent 수" tone=${e.active_agents&&e.active_agents>0?"ok":"warn"} />
        <${_e} label="Keeper 압력" value=${e.keeper_pressure??0} detail="stale / hot keeper 수" tone=${(e.keeper_pressure??0)>0?"warn":"ok"} />
        <${_e} label="활성 작전" value=${e.active_operations??0} detail="command plane active operation" tone=${(e.active_operations??0)>0?"ok":"warn"} />
        <${_e} label="승인 대기" value=${e.pending_approvals??0} detail="사람 확인이 필요한 decision" tone=${(e.pending_approvals??0)>0?"warn":"ok"} />
        <${_e} label="우선 Incident" value=${e.incident_count??t.incidents.length} detail="지금 우선순위로 볼 attention item" tone=${(n==null?void 0:n.severity)??"ok"} />
        <${_e} label="다음 액션" value=${e.recommended_action_count??t.recommended_actions.length} detail="digest 기준 추천 액션 수" tone=${(s==null?void 0:s.severity)??"ok"} />
      </div>

      <div class="mission-primary-grid">
        <${T} title="지금 가장 먼저 볼 것" class="mission-hero-card">
          ${n?o`
                <div class="mission-priority-block ${pt(n.severity)}">
                  <div class="mission-card-head">
                    <span class="command-chip ${pt(n.severity)}">${n.kind}</span>
                    <span class="mission-card-target">${n.target_type}${n.target_id?` · ${n.target_id}`:""}</span>
                  </div>
                  <strong>${n.summary}</strong>
                </div>
              `:o`<div class="empty-state">우선 incident가 없습니다.</div>`}
          ${s?o`
                <div class="mission-action-highlight">
                  <div class="mission-card-head">
                    <span class="command-chip ${pt(s.severity)}">${s.action_type}</span>
                    <span class="mission-card-target">${s.target_type}${s.target_id?` · ${s.target_id}`:""}</span>
                  </div>
                  <p>${s.reason}</p>
                  <div class="mission-card-actions">
                    <button class="control-btn ghost" onClick=${ki(s)}>개입하러 가기</button>
                    <button class="control-btn ghost" onClick=${()=>tt("command",{surface:"swarm"})}>지휘면 상세</button>
                  </div>
                </div>
              `:null}
        <//>

        <${T} title="운영 포커스" class="mission-focus-card">
          <div class="mission-focus-grid">
            <div class="mission-focus-item">
              <span>지휘 건강도</span>
              <strong class=${pt(t.command_focus.health)}>${t.command_focus.health??"ok"}</strong>
            </div>
            <div class="mission-focus-item">
              <span>활성 레인</span>
              <strong>${((r=t.command_focus.swarm_overview)==null?void 0:r.active_lanes)??0}</strong>
            </div>
            <div class="mission-focus-item">
              <span>이동 레인</span>
              <strong>${((l=t.command_focus.swarm_overview)==null?void 0:l.moving_lanes)??0}</strong>
            </div>
            <div class="mission-focus-item">
              <span>마지막 이동</span>
              <strong>${bo((u=t.command_focus.swarm_overview)==null?void 0:u.last_movement_at)}</strong>
            </div>
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>tt("command")}>지휘면 열기</button>
            <button class="control-btn ghost" onClick=${()=>tt("command",{surface:"swarm"})}>스웜 상세</button>
          </div>
        <//>
      </div>

      <div class="mission-content-grid">
        <${T} title="우선 Incident" class="mission-list-card">
          <div class="mission-list-stack">
            ${t.incidents.length>0?t.incidents.slice(0,5).map(_=>o`<${Zc} item=${_} />`):o`<div class="empty-state">attention item이 없습니다.</div>`}
          </div>
        <//>

        <${T} title="추천 액션" class="mission-list-card">
          <div class="mission-list-stack">
            ${t.recommended_actions.length>0?t.recommended_actions.slice(0,4).map(_=>o`<${td} action=${_} />`):o`<div class="empty-state">추천 액션이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-content-grid">
        <${T} title="집중 세션" class="mission-list-card">
          <div class="mission-list-stack">
            ${a.length>0?a.map(_=>o`<${ed} session=${_} />`):o`<div class="empty-state">지금 강조할 session이 없습니다.</div>`}
          </div>
        <//>

        <${T} title="바로 개입할 대상" class="mission-list-card">
          <div class="mission-target-grid">
            <div class="mission-target-block">
              <span class="mission-target-title">Keepers</span>
              ${i.length>0?i.map(_=>o`<div class="mission-target-row"><strong>${_.name}</strong><span class="command-chip ${pt(_.status)}">${_.status??"unknown"}</span></div>`):o`<div class="mission-target-empty">keeper 대상이 없습니다.</div>`}
            </div>
            <div class="mission-target-block">
              <span class="mission-target-title">대기 중 confirm</span>
              <strong>${t.operator_targets.pending_confirms.length}</strong>
              <span class="mission-target-title">가능 액션</span>
              <strong>${t.operator_targets.available_actions.length}</strong>
            </div>
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>tt("intervene")}>개입 워크스페이스</button>
          </div>
        <//>
      </div>
    </section>
  `}const nd="modulepreload",sd=function(t){return"/dashboard/"+t},ko={},ad=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let r=function(_){return Promise.all(_.map(d=>Promise.resolve(d).then(f=>({status:"fulfilled",value:f}),f=>({status:"rejected",reason:f}))))};document.getElementsByTagName("link");const l=document.querySelector("meta[property=csp-nonce]"),u=(l==null?void 0:l.nonce)||(l==null?void 0:l.getAttribute("nonce"));a=r(n.map(_=>{if(_=sd(_),_ in ko)return;ko[_]=!0;const d=_.endsWith(".css"),f=d?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${_}"]${f}`))return;const g=document.createElement("link");if(g.rel=d?"stylesheet":nd,d||(g.as="script"),g.crossOrigin="",g.href=_,u&&g.setAttribute("nonce",u),document.head.appendChild(g),d)return new Promise(($,y)=>{g.addEventListener("load",$),g.addEventListener("error",()=>y(new Error(`Unable to preload CSS for ${_}`)))})}))}function i(r){const l=new Event("vite:preloadError",{cancelable:!0});if(l.payload=r,window.dispatchEvent(l),!l.defaultPrevented)throw r}return a.then(r=>{for(const l of r||[])l.status==="rejected"&&i(l.reason);return e().catch(i)})},eo=v(null),Rt=v(null),Qn=v(!1),Zn=v(!1),ts=v(null),es=v(null),Ra=v(null),ns=v(null),mt=v("operations"),$n=v(null),Na=v(!1),ss=v(null),ws=v(null),La=v(!1),as=v(null),Ts=v(null),Pa=v(!1),os=v(null),rn=v(null),is=v(!1),ln=v(null),xe=v(null);let qe=null;function no(t){return t!=="summary"&&t!=="swarm"}function S(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function c(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function m(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function W(t){return typeof t=="boolean"?t:void 0}function rt(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function xi(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,i)=>{t.has(i)||t.set(i,a)}),t}function od(){const e=xi().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function id(){const e=xi().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function rd(t){if(S(t))return{policy_class:c(t.policy_class),approval_class:c(t.approval_class),tool_allowlist:rt(t.tool_allowlist),model_allowlist:rt(t.model_allowlist),requires_human_for:rt(t.requires_human_for),autonomy_level:c(t.autonomy_level),escalation_timeout_sec:m(t.escalation_timeout_sec),kill_switch:W(t.kill_switch),frozen:W(t.frozen)}}function ld(t){if(S(t))return{headcount_cap:m(t.headcount_cap),active_operation_cap:m(t.active_operation_cap),max_cost_usd:m(t.max_cost_usd),max_tokens:m(t.max_tokens)}}function so(t){if(!S(t))return null;const e=c(t.unit_id),n=c(t.label),s=c(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:c(t.parent_unit_id)??null,leader_id:c(t.leader_id)??null,roster:rt(t.roster),capability_profile:rt(t.capability_profile),source:c(t.source),created_at:c(t.created_at),updated_at:c(t.updated_at),policy:rd(t.policy),budget:ld(t.budget)}}function Si(t){if(!S(t))return null;const e=so(t.unit);return e?{unit:e,leader_status:c(t.leader_status),roster_total:m(t.roster_total),roster_live:m(t.roster_live),active_operation_count:m(t.active_operation_count),health:c(t.health),reasons:rt(t.reasons),children:Array.isArray(t.children)?t.children.map(Si).filter(n=>n!==null):[]}:null}function cd(t){if(S(t))return{total_units:m(t.total_units),company_count:m(t.company_count),platoon_count:m(t.platoon_count),squad_count:m(t.squad_count),leaf_agent_unit_count:m(t.leaf_agent_unit_count),live_agent_count:m(t.live_agent_count),managed_unit_count:m(t.managed_unit_count),active_operation_count:m(t.active_operation_count)}}function Ai(t){const e=S(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),source:c(e.source),summary:cd(e.summary),units:Array.isArray(e.units)?e.units.map(Si).filter(n=>n!==null):[]}}function dd(t){if(!S(t))return null;const e=c(t.kind),n=c(t.status);return!e||!n?null:{kind:e,chain_id:c(t.chain_id)??null,goal:c(t.goal)??null,run_id:c(t.run_id)??null,status:n,viewer_path:c(t.viewer_path)??null,last_sync_at:c(t.last_sync_at)??null}}function Rs(t){if(!S(t))return null;const e=c(t.operation_id),n=c(t.objective),s=c(t.assigned_unit_id),a=c(t.trace_id),i=c(t.status);return!e||!n||!s||!a||!i?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:c(t.autonomy_level),policy_class:c(t.policy_class),budget_class:c(t.budget_class),detachment_session_id:c(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:c(t.checkpoint_ref)??null,active_goal_ids:rt(t.active_goal_ids),note:c(t.note)??null,created_by:c(t.created_by),source:c(t.source),status:i,chain:dd(t.chain),created_at:c(t.created_at),updated_at:c(t.updated_at)}}function ud(t){if(!S(t))return null;const e=Rs(t.operation);return e?{operation:e,assigned_unit_label:c(t.assigned_unit_label)}:null}function ze(t){if(S(t))return{tone:c(t.tone),pending_ops:m(t.pending_ops),blocked_ops:m(t.blocked_ops),in_flight_ops:m(t.in_flight_ops),pipeline_stalls:m(t.pipeline_stalls),bus_traffic:m(t.bus_traffic),l1_hit_rate:m(t.l1_hit_rate),invalidation_count:m(t.invalidation_count),current_pending:m(t.current_pending),current_in_flight:m(t.current_in_flight),cdb_wakeups:m(t.cdb_wakeups),total_stolen:m(t.total_stolen),avg_best_score:m(t.avg_best_score),avg_candidate_count:m(t.avg_candidate_count),best_first_operations:m(t.best_first_operations),active_sessions:m(t.active_sessions),commit_rate:m(t.commit_rate),total_speculations:m(t.total_speculations)}}function pd(t){if(!S(t))return;const e=S(t.pipeline)?t.pipeline:void 0,n=S(t.cache)?t.cache:void 0,s=S(t.ooo)?t.ooo:void 0,a=S(t.speculative)?t.speculative:void 0,i=S(t.search_fabric)?t.search_fabric:void 0,r=S(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:m(e.total_ops),completed_ops:m(e.completed_ops),stalled_cycles:m(e.stalled_cycles),hazards_detected:m(e.hazards_detected),forwarding_used:m(e.forwarding_used),pipeline_flushes:m(e.pipeline_flushes),ipc:m(e.ipc)}:void 0,cache:n?{total_reads:m(n.total_reads),total_writes:m(n.total_writes),l1_hit_rate:m(n.l1_hit_rate),invalidation_count:m(n.invalidation_count),writeback_count:m(n.writeback_count),bus_traffic:m(n.bus_traffic)}:void 0,ooo:s?{agent_count:m(s.agent_count),total_added:m(s.total_added),total_issued:m(s.total_issued),total_completed:m(s.total_completed),total_stolen:m(s.total_stolen),cdb_wakeups:m(s.cdb_wakeups),stall_cycles:m(s.stall_cycles),global_cdb_events:m(s.global_cdb_events),current_pending:m(s.current_pending),current_in_flight:m(s.current_in_flight)}:void 0,speculative:a?{total_speculations:m(a.total_speculations),total_commits:m(a.total_commits),total_aborts:m(a.total_aborts),commit_rate:m(a.commit_rate),total_fast_calls:m(a.total_fast_calls),total_cost_usd:m(a.total_cost_usd),active_sessions:m(a.active_sessions)}:void 0,search_fabric:i?{total_operations:m(i.total_operations),best_first_operations:m(i.best_first_operations),legacy_operations:m(i.legacy_operations),blocked_operations:m(i.blocked_operations),ready_operations:m(i.ready_operations),research_pipeline_operations:m(i.research_pipeline_operations),avg_candidate_count:m(i.avg_candidate_count),avg_best_score:m(i.avg_best_score),top_stage:c(i.top_stage)??null}:void 0,signals:r?{issue_pressure:ze(r.issue_pressure),cache_contention:ze(r.cache_contention),scheduler_efficiency:ze(r.scheduler_efficiency),routing_confidence:ze(r.routing_confidence),speculative_posture:ze(r.speculative_posture)}:void 0}}function Ci(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),summary:n?{total:m(n.total),active:m(n.active),paused:m(n.paused),managed:m(n.managed),projected:m(n.projected)}:void 0,microarch:pd(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(ud).filter(s=>s!==null):[]}}function wi(t){if(!S(t))return null;const e=c(t.detachment_id),n=c(t.operation_id),s=c(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:c(t.leader_id)??null,roster:rt(t.roster),session_id:c(t.session_id)??null,checkpoint_ref:c(t.checkpoint_ref)??null,runtime_kind:c(t.runtime_kind)??null,runtime_ref:c(t.runtime_ref)??null,source:c(t.source),status:c(t.status),last_event_at:c(t.last_event_at)??null,last_progress_at:c(t.last_progress_at)??null,heartbeat_deadline:c(t.heartbeat_deadline)??null,created_at:c(t.created_at),updated_at:c(t.updated_at)}}function md(t){if(!S(t))return null;const e=wi(t.detachment);return e?{detachment:e,assigned_unit_label:c(t.assigned_unit_label),operation:Rs(t.operation)}:null}function Ti(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),summary:n?{total:m(n.total),active:m(n.active),projected:m(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(md).filter(s=>s!==null):[]}}function vd(t){if(!S(t))return null;const e=c(t.decision_id),n=c(t.trace_id),s=c(t.requested_action),a=c(t.scope_type),i=c(t.scope_id);return!e||!n||!s||!a||!i?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:i,operation_id:c(t.operation_id)??null,target_unit_id:c(t.target_unit_id)??null,requested_by:c(t.requested_by),status:c(t.status),reason:c(t.reason)??null,source:c(t.source),detail:t.detail,created_at:c(t.created_at),decided_at:c(t.decided_at)??null,expires_at:c(t.expires_at)??null}}function Ri(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),summary:n?{total:m(n.total),pending:m(n.pending),approved:m(n.approved),denied:m(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(vd).filter(s=>s!==null):[]}}function _d(t){if(!S(t))return null;const e=so(t.unit);return e?{unit:e,roster_total:m(t.roster_total),roster_live:m(t.roster_live),headcount_cap:m(t.headcount_cap),active_operations:m(t.active_operations),active_operation_cap:m(t.active_operation_cap),utilization:m(t.utilization)}:null}function fd(t){const e=S(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(_d).filter(n=>n!==null):[]}}function gd(t){if(!S(t))return null;const e=c(t.alert_id);return e?{alert_id:e,severity:c(t.severity),kind:c(t.kind),scope_type:c(t.scope_type),scope_id:c(t.scope_id),title:c(t.title),detail:c(t.detail),timestamp:c(t.timestamp)}:null}function Ni(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),summary:n?{total:m(n.total),bad:m(n.bad),warn:m(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(gd).filter(s=>s!==null):[]}}function Li(t){if(!S(t))return null;const e=c(t.event_id),n=c(t.trace_id),s=c(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:c(t.operation_id)??null,unit_id:c(t.unit_id)??null,actor:c(t.actor)??null,source:c(t.source),timestamp:c(t.timestamp),detail:t.detail}}function $d(t){const e=S(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),events:Array.isArray(e.events)?e.events.map(Li).filter(n=>n!==null):[]}}function hd(t){if(!S(t))return null;const e=c(t.code),n=c(t.severity),s=c(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function yd(t){if(!S(t))return null;const e=c(t.lane_id),n=c(t.label),s=c(t.kind),a=c(t.phase),i=c(t.motion_state),r=c(t.source_of_truth),l=c(t.movement_reason),u=c(t.current_step);if(!e||!n||!s||!a||!i||!r||!l||!u)return null;const _=S(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:W(t.present)??!1,phase:a,motion_state:i,source_of_truth:r,last_movement_at:c(t.last_movement_at)??null,movement_reason:l,current_step:u,blockers:rt(t.blockers),counts:{operations:m(_.operations),detachments:m(_.detachments),workers:m(_.workers),approvals:m(_.approvals),alerts:m(_.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(hd).filter(d=>d!==null):[]}}function bd(t){if(!S(t))return null;const e=c(t.event_id),n=c(t.lane_id),s=c(t.kind),a=c(t.timestamp),i=c(t.title),r=c(t.detail),l=c(t.tone),u=c(t.source);return!e||!n||!s||!a||!i||!r||!l||!u?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:i,detail:r,tone:l,source:u}}function kd(t){if(!S(t))return null;const e=c(t.code),n=c(t.severity),s=c(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,lane_ids:rt(t.lane_ids),count:m(t.count)??0}}function Pi(t){if(!S(t))return;const e=S(t.overview)?t.overview:{},n=S(t.gaps)?t.gaps:{},s=S(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:c(t.generated_at),overview:{active_lanes:m(e.active_lanes),moving_lanes:m(e.moving_lanes),stalled_lanes:m(e.stalled_lanes),projected_lanes:m(e.projected_lanes),last_movement_at:c(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(yd).filter(a=>a!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(bd).filter(a=>a!==null):[],gaps:{count:m(n.count),items:Array.isArray(n.items)?n.items.map(kd).filter(a=>a!==null):[]},recommended_next_action:s?{tool:c(s.tool)??"masc_operator_snapshot",label:c(s.label)??"Observe operator state",reason:c(s.reason)??"",lane_id:c(s.lane_id)??null}:void 0}}function xd(t){if(!S(t))return;const e=S(t.workers)?t.workers:{},n=W(t.pass);return{status:c(t.status)??"missing",source:c(t.source)??"none",run_id:c(t.run_id)??null,captured_at:c(t.captured_at)??null,...n!==void 0?{pass:n}:{},...m(t.peak_hot_slots)!=null?{peak_hot_slots:m(t.peak_hot_slots)}:{},...m(t.ctx_per_slot)!=null?{ctx_per_slot:m(t.ctx_per_slot)}:{},workers:{expected:m(e.expected),joined:m(e.joined),current_task_bound:m(e.current_task_bound),fresh_heartbeats:m(e.fresh_heartbeats),done:m(e.done),final:m(e.final)},artifact_ref:c(t.artifact_ref)??null,missing_reason:c(t.missing_reason)??null}}function Sd(t){const e=S(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),topology:Ai(e.topology),operations:Ci(e.operations),detachments:Ti(e.detachments),alerts:Ni(e.alerts),decisions:Ri(e.decisions),capacity:fd(e.capacity),traces:$d(e.traces),swarm_status:Pi(e.swarm_status)}}function Ad(t){const e=S(t)?t:{},n=Ai(e.topology),s=Ci(e.operations),a=Ti(e.detachments),i=Ni(e.alerts),r=Ri(e.decisions);return{version:c(e.version),generated_at:c(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:i.version,generated_at:i.generated_at,summary:i.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:Pi(e.swarm_status),swarm_proof:xd(e.swarm_proof)}}function Cd(t){return S(t)?{chain_id:c(t.chain_id)??null,started_at:m(t.started_at)??null,progress:m(t.progress)??null,elapsed_sec:m(t.elapsed_sec)??null}:null}function Mi(t){if(!S(t))return null;const e=c(t.event);return e?{event:e,chain_id:c(t.chain_id)??null,timestamp:c(t.timestamp)??null,duration_ms:m(t.duration_ms)??null,message:c(t.message)??null,tokens:m(t.tokens)??null}:null}function wd(t){if(!S(t))return null;const e=Rs(t.operation);return e?{operation:e,runtime:Cd(t.runtime),history:Mi(t.history),mermaid:c(t.mermaid)??null,preview_run:Di(t.preview_run)}:null}function Td(t){const e=S(t)?t:{};return{status:c(e.status)??"disconnected",base_url:c(e.base_url)??null,message:c(e.message)??null}}function Rd(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),connection:Td(e.connection),summary:n?{linked_operations:m(n.linked_operations),active_chains:m(n.active_chains),running_operations:m(n.running_operations),recent_failures:m(n.recent_failures),last_history_event_at:c(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(wd).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(Mi).filter(s=>s!==null):[]}}function Nd(t){if(!S(t))return null;const e=c(t.id);return e?{id:e,type:c(t.type),status:c(t.status),duration_ms:m(t.duration_ms)??null,error:c(t.error)??null}:null}function Di(t){if(!S(t))return null;const e=c(t.run_id),n=c(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:m(t.duration_ms),success:W(t.success),mermaid:c(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(Nd).filter(s=>s!==null):[]}:null}function Ld(t){const e=S(t)?t:{};return{run:Di(e.run)}}function Pd(t){if(!S(t))return null;const e=c(t.title),n=c(t.path);return!e||!n?null:{title:e,path:n}}function Md(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function Dd(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.tool),a=c(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:rt(t.success_signals),pitfalls:rt(t.pitfalls)}}function Ed(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.summary),a=c(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(Dd).filter(i=>i!==null):[]}}function Id(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:rt(t.tools)}}function zd(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.symptom),a=c(t.why),i=c(t.fix_tool),r=c(t.fix_summary);return!e||!n||!s||!a||!i||!r?null:{id:e,title:n,symptom:s,why:a,fix_tool:i,fix_summary:r}}function Od(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.path_id),a=c(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:rt(t.notes)}}function jd(t){const e=S(t)?t:{};return{version:c(e.version),generated_at:c(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(Pd).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(Md).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(Ed).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Id).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(zd).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Od).filter(n=>n!==null):[]}}function Fd(t){if(!S(t))return null;const e=c(t.id),n=c(t.title),s=c(t.status),a=c(t.detail),i=c(t.next_tool);return!e||!n||!s||!a||!i?null:{id:e,title:n,status:s,detail:a,next_tool:i}}function qd(t){if(!S(t))return null;const e=c(t.code),n=c(t.severity),s=c(t.title),a=c(t.detail),i=c(t.next_tool);return!e||!n||!s||!a||!i?null:{code:e,severity:n,title:s,detail:a,next_tool:i}}function Kd(t){if(!S(t))return null;const e=c(t.from),n=c(t.content),s=c(t.timestamp),a=m(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function Ud(t){if(!S(t))return null;const e=c(t.name),n=c(t.role),s=c(t.lane),a=c(t.status),i=c(t.claim_marker),r=c(t.done_marker),l=c(t.final_marker);if(!e||!n||!s||!a||!i||!r||!l)return null;const u=(()=>{if(!S(t.last_message))return null;const _=m(t.last_message.seq),d=c(t.last_message.content),f=c(t.last_message.timestamp);return _==null||!d||!f?null:{seq:_,content:d,timestamp:f}})();return{name:e,role:n,lane:s,joined:W(t.joined)??!1,live_presence:W(t.live_presence)??!1,completed:W(t.completed)??!1,status:a,current_task:c(t.current_task)??null,bound_task_id:c(t.bound_task_id)??null,bound_task_title:c(t.bound_task_title)??null,bound_task_status:c(t.bound_task_status)??null,current_task_matches_run:W(t.current_task_matches_run)??!1,squad_member:W(t.squad_member)??!1,detachment_member:W(t.detachment_member)??!1,last_seen:c(t.last_seen)??null,heartbeat_age_sec:m(t.heartbeat_age_sec)??null,heartbeat_fresh:W(t.heartbeat_fresh)??!1,claim_marker_seen:W(t.claim_marker_seen)??!1,done_marker_seen:W(t.done_marker_seen)??!1,final_marker_seen:W(t.final_marker_seen)??!1,claim_marker:i,done_marker:r,final_marker:l,last_message:u}}function Hd(t){if(!S(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!S(n))return null;const s=c(n.timestamp),a=m(n.active_slots);if(!s||a==null)return null;const i=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:i}}).filter(n=>n!==null):[];return{slot_url:c(t.slot_url)??null,provider_base_url:c(t.provider_base_url)??null,provider_reachable:W(t.provider_reachable)??null,provider_status_code:m(t.provider_status_code)??null,provider_model_id:c(t.provider_model_id)??null,actual_model_id:c(t.actual_model_id)??null,expected_slots:m(t.expected_slots),actual_slots:m(t.actual_slots),expected_ctx:m(t.expected_ctx),actual_ctx:m(t.actual_ctx),slot_reachable:W(t.slot_reachable)??null,slot_status_code:m(t.slot_status_code)??null,runtime_blocker:c(t.runtime_blocker)??null,detail:c(t.detail)??null,checked_at:c(t.checked_at)??null,total_slots:m(t.total_slots),ctx_per_slot:m(t.ctx_per_slot),active_slots_now:m(t.active_slots_now),peak_active_slots:m(t.peak_active_slots),sample_count:m(t.sample_count),last_sample_at:c(t.last_sample_at)??null,timeline:e}}function Bd(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:c(e.version),generated_at:c(e.generated_at),run_id:c(e.run_id),room_id:c(e.room_id),operation_id:c(e.operation_id)??null,recommended_next_tool:c(e.recommended_next_tool),summary:n?{expected_workers:m(n.expected_workers),joined_workers:m(n.joined_workers),live_workers:m(n.live_workers),squad_roster_size:m(n.squad_roster_size),detachment_roster_size:m(n.detachment_roster_size),current_task_bound:m(n.current_task_bound),fresh_heartbeats:m(n.fresh_heartbeats),claim_markers_seen:m(n.claim_markers_seen),done_markers_seen:m(n.done_markers_seen),final_markers_seen:m(n.final_markers_seen),completed_workers:m(n.completed_workers),peak_hot_slots:m(n.peak_hot_slots),hot_window_ok:W(n.hot_window_ok),pass_hot_concurrency:W(n.pass_hot_concurrency),pass_end_to_end:W(n.pass_end_to_end),pending_decisions:m(n.pending_decisions),pass:W(n.pass)}:void 0,provider:Hd(e.provider),operation:Rs(e.operation),squad:so(e.squad),detachment:wi(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Ud).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Fd).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(qd).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Kd).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(Li).filter(s=>s!==null):[],truth_notes:rt(e.truth_notes)}}function cn(t){mt.value=t,no(t)&&Wd()}async function Ei(){Qn.value=!0,ts.value=null;try{const t=await sl();eo.value=Ad(t)}catch(t){ts.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{Qn.value=!1}}function ao(t){xe.value=t}async function oo(){Zn.value=!0,es.value=null;try{const t=await nl();Rt.value=Sd(t)}catch(t){es.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{Zn.value=!1}}async function Wd(){Rt.value||Zn.value||await oo()}async function ce(){await Ei(),no(mt.value)&&await oo()}async function Ht(){var t;Pa.value=!0,os.value=null;try{const e=await al(),n=Rd(e);Ts.value=n;const s=xe.value;n.operations.length===0?xe.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(xe.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){os.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{Pa.value=!1}}function Gd(){qe=null,rn.value=null,is.value=!1,ln.value=null}async function Jd(t){qe=t,is.value=!0,ln.value=null;try{const e=await ol(t);if(qe!==t)return;rn.value=Ld(e)}catch(e){if(qe!==t)return;rn.value=null,ln.value=e instanceof Error?e.message:"Failed to load chain run"}finally{qe===t&&(is.value=!1)}}async function Vd(){Na.value=!0,ss.value=null;try{const t=await il();$n.value=jd(t)}catch(t){ss.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Na.value=!1}}async function Pt(t=od(),e=id()){La.value=!0,as.value=null;try{const n=await rl(t,e);ws.value=Bd(n)}catch(n){as.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{La.value=!1}}async function Yt(t,e,n){Ra.value=t,ns.value=null;try{await ll(e,n),await Ei(),(Rt.value||no(mt.value))&&await oo(),await Pt(),await Ht()}catch(s){throw ns.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{Ra.value=null}}function Yd(t){return Yt(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Xd(t){return Yt(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function Qd(t){return Yt(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Zd(t={}){return Yt("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function tu(t){return Yt(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function eu(t){return Yt(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function nu(t,e){return Yt(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function su(t,e){return Yt(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}jc(()=>{ce(),Ht(),(mt.value==="swarm"||ws.value!==null)&&Pt()});function au(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function X(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function ou(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function iu(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function z(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let xo=!1,ru=0,js=null;async function lu(){js||(js=ad(()=>import("./mermaid.core-CHIjIme3.js").then(e=>e.bE),[]).then(e=>e.default));const t=await js;return xo||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),xo=!0),t}function Bt(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Ns(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function cu(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function hn(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function ne(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:hn(t/e*100)}function du(t,e){const n=hn(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function Ii(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const zi=[{id:"operations",label:"작전"},{id:"swarm",label:"스웜"},{id:"chains",label:"체인"},{id:"topology",label:"토폴로지"},{id:"alerts",label:"알림"},{id:"trace",label:"트레이스"},{id:"control",label:"제어"},{id:"summary",label:"요약"}],uu=zi.map(t=>t.id),pu=["chain_start","node_start","node_complete","chain_complete","chain_error"],mu={operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function vu(t){return!!t&&uu.includes(t)}function _u(t){if(t==="operations")return{};if(t==="chains"){const e=xe.value;return e?{surface:t,operation:e}:{surface:t}}return{surface:t}}function fu(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function gu(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function et(t){return Ra.value===t}function Ls(){return eo.value}function $u(t){var a,i,r,l,u,_,d;const e=eo.value,n=ws.value,s=Ts.value;switch(t){case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((r=(i=e==null?void 0:e.swarm_status)==null?void 0:i.recommended_next_action)==null?void 0:r.tool)??"masc_observe_traces",reason:((u=(l=e==null?void 0:e.swarm_status)==null?void 0:l.recommended_next_action)==null?void 0:u.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(d=(_=s==null?void 0:s.operations[0])==null?void 0:_.preview_run)!=null&&d.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function hu(){const t=mt.value,e=mu[t],n=$u(t);return o`
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
  `}function Sn({label:t,value:e,subtext:n,percent:s,color:a}){return o`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${du(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(hn(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function An({label:t,value:e,detail:n,percent:s,tone:a}){return o`
    <article class="command-signal-rail ${z(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${z(a)}" style=${`width: ${Math.max(8,Math.round(hn(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function yu(){var lt,ct,U,Q;const t=Ls(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,i=t==null?void 0:t.alerts.summary,r=(lt=t==null?void 0:t.swarm_status)==null?void 0:lt.overview,l=t==null?void 0:t.swarm_proof,u=t==null?void 0:t.operations.microarch,_=(e==null?void 0:e.managed_unit_count)??0,d=(e==null?void 0:e.total_units)??0,f=(n==null?void 0:n.active)??0,g=(s==null?void 0:s.active)??0,$=(r==null?void 0:r.moving_lanes)??0,y=(r==null?void 0:r.active_lanes)??0,A=(l==null?void 0:l.workers.done)??0,w=(l==null?void 0:l.workers.expected)??0,D=(i==null?void 0:i.bad)??0,O=(i==null?void 0:i.warn)??0,M=(a==null?void 0:a.pending)??0,R=(a==null?void 0:a.total)??0,N=f+g,p=((ct=u==null?void 0:u.cache)==null?void 0:ct.l1_hit_rate)??((Q=(U=u==null?void 0:u.signals)==null?void 0:U.cache_contention)==null?void 0:Q.l1_hit_rate)??0,q=f>0||g>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",Nt=f>0||$>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return o`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${q}</h3>
        <p>${Nt}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${z(f>0?"ok":"warn")}">활성 작전 ${f}</span>
          <span class="command-chip ${z($>0?"ok":(y>0,"warn"))}">이동 레인 ${$}/${Math.max(y,$)}</span>
          <span class="command-chip ${z(D>0?"bad":O>0?"warn":"ok")}">치명 알림 ${D}</span>
          <span class="command-chip ${z(M>0?"warn":"ok")}">승인 대기 ${M}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${Sn}
          label="관리 단위 범위"
          value=${`${_}/${Math.max(d,_)}`}
          subtext=${d>0?`${d-_}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${ne(_,Math.max(d,_))}
          color="#67e8f9"
        />
        <${Sn}
          label="실행 열도"
          value=${String(N)}
          subtext=${`${f}개 작전 + ${g}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${ne(N,Math.max(_,N||1))}
          color="#4ade80"
        />
        <${Sn}
          label="스웜 이동감"
          value=${`${$}/${Math.max(y,$)}`}
          subtext=${r!=null&&r.last_movement_at?`마지막 이동 ${X(r.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${ne($,Math.max(y,$||1))}
          color="#fbbf24"
        />
        <${Sn}
          label="증거 수집률"
          value=${`${A}/${Math.max(w,A)}`}
          subtext=${l!=null&&l.status?`증거 소스 ${l.source} · ${l.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${ne(A,Math.max(w,A||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${An}
        label="승인 대기열"
        value=${`${M}건 대기`}
        detail=${`현재 정책 창에서 ${R}개 결정을 추적 중입니다`}
        percent=${ne(M,Math.max(R,M||1))}
        tone=${M>0?"warn":"ok"}
      />
      <${An}
        label="알림 압력"
        value=${`${D} bad / ${O} warn`}
        detail=${D>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${ne(D*2+O,Math.max((D+O)*2,1))}
        tone=${D>0?"bad":O>0?"warn":"ok"}
      />
      <${An}
        label="디스패치 점유"
          value=${`${g}개 가동`}
        detail=${_>0?`${_}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${ne(g,Math.max(_,g||1))}
        tone=${g>0?"ok":"warn"}
      />
      <${An}
        label="캐시 신뢰도"
        value=${p?Ns(p):"n/a"}
        detail=${p?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${hn((p??0)*100)}
        tone=${p>=.75?"ok":p>=.4?"warn":"bad"}
      />
    </div>
  `}function bu(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Oi(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,i)=>{t.has(i)||t.set(i,a)}),t}function ku(){const e=Oi().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function xu(){const e=Oi().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Su(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function Au(t){return t.status==="claimed"||t.status==="in_progress"}function Cu(t){const e=$n.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function Fs(t){var e;return((e=$n.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function wu(t){const e=$n.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function Wt(t){try{await t()}catch{}}function Tu(){var d,f,g,$,y;const t=Ls(),e=Ts.value,n=t==null?void 0:t.topology.summary,s=t==null?void 0:t.operations.summary,a=(d=t==null?void 0:t.swarm_status)==null?void 0:d.overview,i=t==null?void 0:t.operations.microarch,r=t==null?void 0:t.decisions.summary,l=t==null?void 0:t.alerts.summary,u=(f=i==null?void 0:i.signals)==null?void 0:f.issue_pressure,_=i==null?void 0:i.cache;return o`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(n==null?void 0:n.total_units)??0}</strong><small>${(n==null?void 0:n.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(s==null?void 0:s.active)??0}</strong><small>${((g=t==null?void 0:t.detachments.summary)==null?void 0:g.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(r==null?void 0:r.pending)??0}</strong><small>${(r==null?void 0:r.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card"><span>알림</span><strong>${(l==null?void 0:l.bad)??0}</strong><small>${(l==null?void 0:l.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${(($=e==null?void 0:e.summary)==null?void 0:$.active_chains)??0}</strong><small>${((y=e==null?void 0:e.summary)==null?void 0:y.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card"><span>스웜</span><strong>${(a==null?void 0:a.active_lanes)??0}</strong><small>${a?`${a.stalled_lanes??0}개 정체 · ${X(a.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card"><span>마이크로아크</span><strong>${(u==null?void 0:u.pending_ops)??0}</strong><small>${(_==null?void 0:_.l1_hit_rate)!=null?`${Ns(_.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(u==null?void 0:u.tone)??"n/a"}</small></div>
    </div>
  `}function ji(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function Ru({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const i=a.motion_state;i in e?e[i]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return o`
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
  `}function Nu({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return o`
    <div class="swarm-worker-grid">
      ${a.map(()=>o`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?o`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function Lu({lane:t}){const e=t.counts??{},n=ji(t),s=e.workers??0,a=e.operations??0,i=e.detachments??0,r=a+i,l=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return o`
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
          <span class="command-chip">${X(t.last_movement_at)}</span>
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
        ${s>0?o`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${Nu} total=${s} />
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
              ${t.hard_flags.map(u=>o`<span class="command-chip ${z(u.severity)}">${u.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Pu({lanes:t}){const e=t.slice(0,4);return e.length===0?null:o`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=ji(n),a=n.counts.workers??0,i=n.counts.operations??0,r=n.counts.detachments??0;return o`
          <article class="swarm-story-card ${z(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${z(s)}">${n.motion_state}</span>
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
  `}function Mu({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return o`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${z(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?o`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function Du({gap:t}){return o`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${z(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function Eu({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return o`
    <div class="command-guide-card ${z(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${z(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?o`
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${X(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.artifact_ref?o`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?o`<p>${t.missing_reason}</p>`:null}
          `:o`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function Iu(){const t=Ls(),e=t==null?void 0:t.swarm_status,n=t==null?void 0:t.swarm_proof,s=(e==null?void 0:e.lanes.filter(_=>_.present))??[],a=(e==null?void 0:e.gaps.items)??[],i=(e==null?void 0:e.timeline.slice(0,8))??[],r=e==null?void 0:e.overview,l=e==null?void 0:e.recommended_next_action,u=s.length<=1;return o`
    <section class="card command-section">
      <div class="card-title">스웜</div>
      ${e?o`
            <${Pu} lanes=${s} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(r==null?void 0:r.active_lanes)??0}</strong><small>${(r==null?void 0:r.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(r==null?void 0:r.stalled_lanes)??0}</strong><small>${(r==null?void 0:r.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${X(r==null?void 0:r.last_movement_at)}</strong><small>${e.generated_at?`스냅샷 ${X(e.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(l==null?void 0:l.label)??"운영자 상태 확인"}</strong><small>${(l==null?void 0:l.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${s.length>0?o`<${Ru} lanes=${s} />`:null}

            <div class="command-swarm-layout ${u?"compact":""}">
              <div class="command-card-stack">
                ${s.length>0?s.map(_=>o`<${Lu} lane=${_} />`):o`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight">
                  <div class="command-guide-head">
                    <strong>${(l==null?void 0:l.label)??"운영자 상태 확인"}</strong>
                    <span class="command-chip">${(l==null?void 0:l.lane_id)??"전체"}</span>
                  </div>
                  <p>${(l==null?void 0:l.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="command-card-foot">${(l==null?void 0:l.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${Eu} proof=${n} />

                <div class="command-guide-card ${a.length>0?"warn":"ok"}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${z(a.some(_=>_.severity==="bad")?"bad":a.length>0?"warn":"ok")}">${a.length}</span>
                  </div>
                  ${a.length>0?o`<div class="swarm-event-rail">${a.slice(0,4).map(_=>o`<${Du} gap=${_} />`)}</div>`:o`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${i.length}</span>
                  </div>
                  ${i.length>0?o`<div class="swarm-event-rail">${i.map(_=>o`<${Mu} event=${_} />`)}</div>`:o`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:o`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function zu(){return o`
    <div class="command-surface-tabs">
      ${zi.map(t=>o`
        <button
          class="command-surface-tab ${mt.value===t.id?"active":""}"
          onClick=${()=>{cn(t.id),tt("command",_u(t.id))}}
        >
          ${t.label}
        </button>
      `)}
    </div>
  `}function Ou(){var lt,ct,U,Q,b,Qt,De,yn,bn;const t=Ls(),e=Rt.value,n=Ne.value,s=bu(),a=s?wt.value.find(E=>E.name===s)??null:null,i=s?yt.value.filter(E=>E.assignee===s&&Au(E)):[],r=((lt=t==null?void 0:t.operations.summary)==null?void 0:lt.active)??0,l=((ct=t==null?void 0:t.detachments.summary)==null?void 0:ct.total)??0,u=((U=t==null?void 0:t.decisions.summary)==null?void 0:U.pending)??0,_=e==null?void 0:e.detachments.detachments.find(E=>{const Zt=E.detachment.heartbeat_deadline,kn=Zt?Date.parse(Zt):Number.NaN;return E.detachment.status==="stalled"||!Number.isNaN(kn)&&kn<=Date.now()}),d=e==null?void 0:e.alerts.alerts.find(E=>E.severity==="bad"),f=!!(n!=null&&n.room||n!=null&&n.project),g=(a==null?void 0:a.current_task)??null,$=Su(a==null?void 0:a.last_seen),y=$!=null?$<=120:null,A=[f?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?i.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:yt.value.length>0?"masc_claim":"masc_add_task"}:g?y===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${g} 이지만 heartbeat가 stale 합니다 (${$}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${g}${$!=null?` · 마지막 활동 ${$}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((Q=t.topology.summary)==null?void 0:Q.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:r===0?{title:"작전 준비도",tone:"warn",detail:`${((b=t.topology.summary)==null?void 0:b.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((Qt=t.topology.summary)==null?void 0:Qt.managed_unit_count)??0}개 관리 단위 위에서 ${r}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},u>0?{title:"디스패치 준비도",tone:"warn",detail:`${u}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:r>0&&l===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:_||d?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${_?` · detachment ${_.detachment.detachment_id} 가 stalled 상태입니다`:""}${d?` · alert ${d.title??d.alert_id}`:""}${!e&&!_&&!d?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:u>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${l}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],w=f?!s||!a?"masc_join":i.length===0?yt.value.length>0?"masc_claim":"masc_add_task":g?y===!1?"masc_heartbeat":!t||(((De=t.topology.summary)==null?void 0:De.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":u>0?"masc_policy_approve":r>0&&l===0||_||d?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",D=Cu(w),M=wu(w==="masc_set_room"?["repo-root-room"]:w==="masc_plan_set_task"?["claimed-not-current"]:w==="masc_heartbeat"?["heartbeat-stale"]:w==="masc_dispatch_tick"?["no-detachments"]:w==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),R=Fs("room_task_hygiene"),N=Fs("cpv2_benchmark"),p=Fs("supervisor_session"),q=((yn=$n.value)==null?void 0:yn.docs)??[],Nt=[R,N,p].filter(E=>E!==null);return o`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title">즉시 조치</div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(D==null?void 0:D.title)??w}</strong>
            <span class="command-chip ok">${w}</span>
          </div>
          <p>${(D==null?void 0:D.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(bn=D==null?void 0:D.success_signals)!=null&&bn.length?o`<div class="command-tag-row">
                ${D.success_signals.map(E=>o`<span class="command-tag ok">${E}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${A.map(E=>o`
            <article class="command-readiness-row ${z(E.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${E.title}</strong>
                  <span class="command-chip ${z(E.tone)}">${E.tone}</span>
                </div>
                <p>${E.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${E.tool}</div>
            </article>
          `)}
        </div>

        ${M.length>0?o`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${M.length}</span>
                </div>
                <div class="command-guide-list">
                  ${M.map(E=>o`
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
        <div class="card-title">운영 경로</div>
        ${Na.value?o`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:ss.value?o`<div class="empty-state error">${ss.value}</div>`:o`
                <div class="command-path-grid">
                  ${Nt.map(E=>o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${E.title}</strong>
                        <span class="command-chip">${E.id}</span>
                      </div>
                      <p>${E.summary}</p>
                      <div class="command-card-sub">${E.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${E.steps.slice(0,4).map(Zt=>o`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Zt.tool}</span>
                            <span>${Zt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${q.length>0?o`<div class="command-doc-links">
                      ${q.map(E=>o`<span class="command-tag">${E.title}: ${E.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function ju(){return o`
    <${yu} />
    <${Tu} />
    <${Ou} />
  `}function Fu(){return Zn.value?o`<div class="empty-state">command-plane detail 불러오는 중…</div>`:es.value?o`<div class="empty-state error">${es.value}</div>`:o`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function Fi({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,i=t.unit.policy;return o`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${gu(t.unit.kind)}</span>
            <span class="command-chip ${z(t.health)}">${t.health??"ok"}</span>
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
            ${t.children.map(r=>o`<${Fi} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function qu({source:t}){const e=Vo(null),[n,s]=Ya(null);return it(()=>{let a=!1;const i=e.current;return i?(i.innerHTML="",s(null),(async()=>{try{const l=await lu(),{svg:u}=await l.render(`command-chain-${++ru}`,t);if(a||!e.current)return;e.current.innerHTML=u}catch(l){if(a)return;s(l instanceof Error?l.message:"Mermaid render failed")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),o`
    <div class="command-chain-graph-shell">
      ${n?o`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function Ku({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return o`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${Bt(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?o`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?o`<span class="command-tag ${Bt(s==null?void 0:s.status)}">${Ns(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${Ii(t.history)}</div>
    </button>
  `}function Uu({item:t}){return o`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${Bt(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${X(t.timestamp)}</div>
      <div class="command-card-sub">${Ii(t)}</div>
    </article>
  `}function Hu({node:t}){return o`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${Bt(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?o`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function Bu({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,i=e.chain,r=(i==null?void 0:i.run_id)??null;return o`
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
        <span>Updated</span><span>${X(e.updated_at)}</span>
      </div>
      ${i?o`
            <div class="command-tag-row">
              <span class="command-tag">${i.kind}</span>
              <span class="command-tag ${Bt(i.status)}">${i.status}</span>
              ${i.chain_id?o`<span class="command-tag">${i.chain_id}</span>`:null}
              ${i.run_id?o`<span class="command-tag">run ${i.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?o`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{cn("swarm"),tt("command",{surface:"swarm",operation_id:e.operation_id,...r?{run_id:r}:{}})}}
        >
          Swarm Live
        </button>
        ${i?o`
              <button
                class="control-btn ghost"
                onClick=${()=>{ao(e.operation_id),cn("chains"),tt("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?o`
              <button class="control-btn ghost" disabled=${et(n)} onClick=${()=>Wt(()=>Yd(e.operation_id))}>
                ${et(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${et(a)} onClick=${()=>Wt(()=>Qd(e.operation_id))}>
                ${et(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?o`
              <button class="control-btn ghost" disabled=${et(s)} onClick=${()=>Wt(()=>Xd(e.operation_id))}>
                ${et(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Wu({card:t}){var n;const e=t.detachment;return o`
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
        <span>Progress</span><span>${X(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${iu(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${X(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?o`<span class="command-tag ${ou(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Gu({alert:t}){return o`
    <article class="command-alert ${z(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${z(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${X(t.timestamp)}</span>
      </div>
      ${t.detail?o`<p>${t.detail}</p>`:null}
    </article>
  `}function qi({event:t}){return o`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${X(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${au(t.detail)}</pre>
    </article>
  `}function Ju({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return o`
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
        <span>Created</span><span>${X(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!s?o`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${et(e)} onClick=${()=>Wt(()=>tu(t.decision_id))}>
                ${et(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${et(n)} onClick=${()=>Wt(()=>eu(t.decision_id))}>
                ${et(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?o`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function Vu({row:t}){var l,u,_;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((l=e.policy)!=null&&l.frozen),i=!!((u=e.policy)!=null&&u.kill_switch),r=Math.round((t.utilization??0)*100);return o`
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
        <span>Autonomy</span><span>${((_=e.policy)==null?void 0:_.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${a?"yes":"no"}</span>
        <span>Kill Switch</span><span>${i?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${et(n)} onClick=${()=>Wt(()=>nu(e.unit_id,!a))}>
          ${et(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${et(s)} onClick=${()=>Wt(()=>su(e.unit_id,!i))}>
          ${et(s)?"Applying…":i?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function Yu({item:t}){return o`
    <article class="command-guide-card ${z(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${z(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Xu({blocker:t}){return o`
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
  `}function Qu({worker:t}){return o`
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
      ${t.last_message?o`<div class="command-card-foot">${X(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function Zu(){var u,_,d,f,g,$,y,A,w,D,O,M,R,N,p,q,Nt,lt,ct,U,Q;const t=ws.value,e=ku(),n=xu(),s=(u=t==null?void 0:t.provider)!=null&&u.runtime_blocker?"blocked":(_=t==null?void 0:t.provider)!=null&&_.provider_reachable?"ready":"check",a=((d=t==null?void 0:t.provider)==null?void 0:d.actual_slots)??((f=t==null?void 0:t.provider)==null?void 0:f.total_slots)??0,i=((g=t==null?void 0:t.provider)==null?void 0:g.expected_slots)??"n/a",r=(($=t==null?void 0:t.provider)==null?void 0:$.actual_ctx)??((y=t==null?void 0:t.provider)==null?void 0:y.ctx_per_slot)??0,l=((A=t==null?void 0:t.provider)==null?void 0:A.expected_ctx)??"n/a";return o`
    <div class="command-section-stack">
      <${Iu} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title">스웜 라이브 런</div>
          ${La.value?o`<div class="empty-state">Loading swarm live state…</div>`:as.value?o`<div class="empty-state error">${as.value}</div>`:t?o`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((w=t.summary)==null?void 0:w.joined_workers)??0}/${((D=t.summary)==null?void 0:D.expected_workers)??0}</strong><small>${((O=t.summary)==null?void 0:O.live_workers)??0}개 가동 · ${((M=t.summary)==null?void 0:M.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${i} · ctx ${r}/${l}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(R=t.summary)!=null&&R.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((N=t.provider)==null?void 0:N.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(p=t.summary)!=null&&p.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((q=t.operation)==null?void 0:q.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((Nt=t.squad)==null?void 0:Nt.label)??"없음"}</span>
                      <span>실행체</span><span>${((lt=t.detachment)==null?void 0:lt.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((ct=t.summary)==null?void 0:ct.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((U=t.summary)==null?void 0:U.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((Q=t.provider)==null?void 0:Q.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?o`<div class="command-tag-row">
                          ${t.truth_notes.map(b=>o`<span class="command-tag">${b}</span>`)}
                        </div>`:null}
                  `:o`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">체크리스트</div>
          ${t&&t.checklist.length>0?o`<div class="command-card-stack">
                ${t.checklist.map(b=>o`<${Yu} item=${b} />`)}
              </div>`:o`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">워커</div>
          ${t&&t.workers.length>0?o`<div class="command-card-stack">
                ${t.workers.map(b=>o`<${Qu} worker=${b} />`)}
              </div>`:o`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">런타임</div>
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
                  <span>Last Sample</span><span>${t.provider.last_sample_at?X(t.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${t.provider.checked_at?X(t.provider.checked_at):"n/a"}</span>
                </div>
                ${t.provider.detail?o`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?o`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(b=>o`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${b.active_slots} active</strong>
                              <span class="command-chip">${X(b.timestamp)}</span>
                            </div>
                            <div class="command-card-sub">slots ${b.active_slot_ids.join(", ")||"none"}</div>
                          </div>
                        </article>
                      `)}
                    </div>`:o`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:o`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">막힘 요인</div>
          ${t&&t.blockers.length>0?o`<div class="command-card-stack">
                ${t.blockers.map(b=>o`<${Xu} blocker=${b} />`)}
              </div>`:o`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">최근 메시지</div>
          ${t&&t.recent_messages.length>0?o`<div class="command-trace-stack">
                ${t.recent_messages.map(b=>o`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${b.from}</strong>
                        <span class="command-chip">${X(b.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${b.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${b.content}</pre>
                  </article>
                `)}
              </div>`:o`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">최근 트레이스 이벤트</div>
          ${t&&t.recent_trace_events.length>0?o`<div class="command-trace-stack">
                ${t.recent_trace_events.map(b=>o`<${qi} event=${b} />`)}
              </div>`:o`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function tp(){const t=Rt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Operations</div>
        ${t&&t.operations.operations.length>0?o`<div class="command-card-stack">
              ${t.operations.operations.map(e=>o`<${Bu} card=${e} />`)}
            </div>`:o`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title">Detachments</div>
        ${t&&t.detachments.detachments.length>0?o`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>o`<${Wu} card=${e} />`)}
            </div>`:o`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function ep(){var l,u,_,d,f,g,$,y,A,w,D,O,M,R,N,p;const t=Ts.value,e=(t==null?void 0:t.operations)??[],n=xe.value,s=e.find(q=>q.operation.operation_id===n)??e[0]??null,a=((l=s==null?void 0:s.operation.chain)==null?void 0:l.run_id)??null,i=((u=rn.value)==null?void 0:u.run)??(s==null?void 0:s.preview_run)??null,r=!((_=rn.value)!=null&&_.run)&&!!(s!=null&&s.preview_run);return it(()=>{a?Jd(a):Gd()},[a]),o`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title">Chains</div>
        <article class="command-guide-card ${Bt(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${Bt(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(t==null?void 0:t.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((d=t==null?void 0:t.summary)==null?void 0:d.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((f=t==null?void 0:t.summary)==null?void 0:f.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((g=t==null?void 0:t.summary)==null?void 0:g.recent_failures)??0}</span>
            <span>Last Event</span><span>${X(($=t==null?void 0:t.summary)==null?void 0:$.last_history_event_at)}</span>
          </div>
        </article>

        ${os.value?o`<div class="empty-state error">${os.value}</div>`:null}

        ${Pa.value&&!t?o`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?o`
                <div class="command-chain-list">
                  ${e.map(q=>o`
                    <${Ku}
                      overlay=${q}
                      selected=${(s==null?void 0:s.operation.operation_id)===q.operation.operation_id}
                      onSelect=${()=>ao(q.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(q=>o`<${Uu} item=${q} />`)}
                </div>
              `:o`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title">Chain Detail</div>
        ${s?o`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${Bt((y=s.operation.chain)==null?void 0:y.status)}">
                    ${((A=s.operation.chain)==null?void 0:A.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((w=s.operation.chain)==null?void 0:w.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((D=s.operation.chain)==null?void 0:D.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${Ns((O=s.runtime)==null?void 0:O.progress)}</span>
                  <span>Elapsed</span><span>${cu((M=s.runtime)==null?void 0:M.elapsed_sec)}</span>
                  <span>Updated</span><span>${X(((R=s.operation.chain)==null?void 0:R.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(N=s.operation.chain)!=null&&N.goal?o`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?o`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((p=s.operation.chain)==null?void 0:p.chain_id)??"graph"}</span>
                      </div>
                      <${qu} source=${s.mermaid} />
                    </div>
                  `:o`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(i==null?void 0:i.success)===!1?"bad":"ok"}">
                    ${i?i.success===!1?"failed":r?"preview":"captured":"pending"}
                  </span>
                </div>
                ${is.value?o`<div class="empty-state">Loading run detail…</div>`:ln.value?o`<div class="empty-state error">${ln.value}</div>`:i&&i.nodes.length>0?o`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${i.chain_id}</span>
                            <span>Run</span><span>${i.run_id??"preview only"}</span>
                            <span>Duration</span><span>${i.duration_ms!=null?`${i.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${i.nodes.length}</span>
                          </div>
                          ${r?o`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${i.nodes.map(q=>o`<${Hu} node=${q} />`)}
                          </div>
                        `:o`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:o`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function np(){const t=Rt.value;return o`
    <section class="card command-section">
      <div class="card-title">지휘 계층</div>
      ${t&&t.topology.units.length>0?o`${t.topology.units.map(e=>o`<${Fi} node=${e} />`)}`:o`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function sp(){const t=Rt.value;return o`
    <section class="card command-section">
      <div class="card-title">경보</div>
      ${t&&t.alerts.alerts.length>0?o`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>o`<${Gu} alert=${e} />`)}
          </div>`:o`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function ap(){const t=Rt.value;return o`
    <section class="card command-section">
      <div class="card-title">최근 트레이스</div>
      ${t&&t.traces.events.length>0?o`<div class="command-trace-stack">
            ${t.traces.events.map(e=>o`<${qi} event=${e} />`)}
          </div>`:o`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function op(){const t=Rt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">승인 대기</div>
        ${t&&t.decisions.decisions.length>0?o`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>o`<${Ju} decision=${e} />`)}
            </div>`:o`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Unit 제어</div>
        ${t&&t.capacity.capacity.length>0?o`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>o`<${Vu} row=${e} />`)}
            </div>`:o`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function ip(){if(mt.value==="summary")return o`<${ju} />`;if(mt.value==="swarm")return o`<${Zu} />`;if(!Rt.value)return o`<${Fu} />`;switch(mt.value){case"chains":return o`<${ep} />`;case"topology":return o`<${np} />`;case"alerts":return o`<${sp} />`;case"trace":return o`<${ap} />`;case"control":return o`<${op} />`;case"operations":default:return o`<${tp} />`}}function rp(){return it(()=>{ce(),Ht(),Vd(),Pt()},[]),it(()=>{if(Z.value.tab!=="command")return;const t=Z.value.params.surface,e=Z.value.params.operation;vu(t)?cn(t):t||cn("operations"),e&&ao(e),t==="swarm"&&Pt()},[Z.value.tab,Z.value.params.surface,Z.value.params.operation,Z.value.params.operation_id,Z.value.params.run_id]),it(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,ce(),Ht(),mt.value==="swarm"&&Pt()},250))},n=new EventSource(fu()),s=pu.map(a=>{const i=()=>e();return n.addEventListener(a,i),{type:a,handler:i}});return n.onerror=()=>{e()},()=>{s.forEach(({type:a,handler:i})=>{n.removeEventListener(a,i)}),n.close(),t&&window.clearTimeout(t)}},[]),o`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면 / Command Plane</h2>
          <p>기본 진입은 현재 작전입니다. 여기서는 지금 무엇이 움직이고 막히는지 확인한 뒤, 필요한 surface로만 더 깊게 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Wt(()=>Zd())}}
            disabled=${et("dispatch:tick")}
          >
            ${et("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{ce(),Ht(),Pt()}}
            disabled=${Qn.value}
          >
            ${Qn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${ts.value?o`<div class="empty-state error">${ts.value}</div>`:null}
      ${ns.value?o`<div class="empty-state error">${ns.value}</div>`:null}
      <${hu} />
      <${zu} />
      <${ip} />
    </section>
  `}let lp=0;const oe=v([]);function L(t,e="success",n=4e3){const s=++lp;oe.value=[...oe.value,{id:s,message:t,type:e}],setTimeout(()=>{oe.value=oe.value.filter(a=>a.id!==s)},n)}function cp(t){oe.value=oe.value.filter(e=>e.id!==t)}function dp(){const t=oe.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>cp(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Pe=v(null),Ki=v(null),zt=v(null),rs=v(!1),Jt=v(null),dn=v(!1),we=v(null),H=v(!1),ls=v([]);let up=1;function F(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function k(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function J(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ps(t){return typeof t=="boolean"?t:void 0}function pp(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function St(t,e=[]){if(Array.isArray(t))return t;if(!F(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function mp(t){return F(t)?{id:k(t.id),seq:J(t.seq),from:k(t.from)??k(t.from_agent)??"system",content:k(t.content)??"",timestamp:k(t.timestamp)??new Date().toISOString(),type:k(t.type)}:null}function vp(t){return F(t)?{room_id:k(t.room_id),current_room:k(t.current_room)??k(t.room),project:k(t.project),cluster:k(t.cluster),paused:Ps(t.paused),pause_reason:k(t.pause_reason)??null,paused_by:k(t.paused_by)??null,paused_at:k(t.paused_at)??null}:{}}function So(t){if(!F(t))return;const e=Object.entries(t).map(([n,s])=>{const a=k(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Ui(t){if(!F(t))return null;const e=k(t.kind),n=k(t.summary),s=k(t.target_type);return!e||!n||!s?null:{kind:e,severity:k(t.severity)??"warn",summary:n,target_type:s,target_id:k(t.target_id)??null,actor:k(t.actor)??null,evidence:t.evidence}}function Hi(t){if(!F(t))return null;const e=k(t.action_type),n=k(t.target_type),s=k(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:k(t.target_id)??null,severity:k(t.severity)??"warn",reason:s,confirm_required:Ps(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function _p(t){return F(t)?{actor:k(t.actor)??null,spawn_agent:k(t.spawn_agent)??null,spawn_role:k(t.spawn_role)??null,spawn_model:k(t.spawn_model)??null,worker_class:k(t.worker_class)??null,parent_actor:k(t.parent_actor)??null,capsule_mode:k(t.capsule_mode)??null,runtime_pool:k(t.runtime_pool)??null,lane_id:k(t.lane_id)??null,controller_level:k(t.controller_level)??null,control_domain:k(t.control_domain)??null,supervisor_actor:k(t.supervisor_actor)??null,model_tier:k(t.model_tier)??null,task_profile:k(t.task_profile)??null,risk_level:k(t.risk_level)??null,routing_confidence:J(t.routing_confidence)??null,routing_reason:k(t.routing_reason)??null,status:k(t.status)??"unknown",turn_count:J(t.turn_count)??0,empty_note_turn_count:J(t.empty_note_turn_count)??0,has_turn:Ps(t.has_turn)??!1,last_turn_ts_iso:k(t.last_turn_ts_iso)??null}:null}function fp(t){if(!F(t))return null;const e=k(t.session_id);return e?{session_id:e,goal:k(t.goal),status:k(t.status),health:k(t.health),scale_profile:k(t.scale_profile),control_profile:k(t.control_profile),planned_worker_count:J(t.planned_worker_count),active_agent_count:J(t.active_agent_count),last_turn_age_sec:J(t.last_turn_age_sec)??null,attention_count:J(t.attention_count),recommended_action_count:J(t.recommended_action_count),top_attention:Ui(t.top_attention),top_recommendation:Hi(t.top_recommendation)}:null}function Bi(t){const e=F(t)?t:{};return{trace_id:k(e.trace_id),target_type:k(e.target_type)??"room",target_id:k(e.target_id)??null,health:k(e.health),swarm_status:F(e.swarm_status)?e.swarm_status:void 0,attention_items:St(e.attention_items).map(Ui).filter(n=>n!==null),recommended_actions:St(e.recommended_actions).map(Hi).filter(n=>n!==null),session_cards:St(e.session_cards).map(fp).filter(n=>n!==null),worker_cards:St(e.worker_cards).map(_p).filter(n=>n!==null)}}function gp(t){if(!F(t))return null;const e=F(t.status)?t.status:void 0,n=F(t.summary)?t.summary:F(e==null?void 0:e.summary)?e.summary:void 0,s=F(t.session)?t.session:F(e==null?void 0:e.session)?e.session:void 0,a=k(t.session_id)??k(n==null?void 0:n.session_id)??k(s==null?void 0:s.session_id);if(!a)return null;const i=So(t.report_paths)??So(e==null?void 0:e.report_paths),r=St(t.recent_events,["events"]).filter(F);return{session_id:a,status:k(t.status)??k(n==null?void 0:n.status)??k(s==null?void 0:s.status),progress_pct:J(t.progress_pct)??J(n==null?void 0:n.progress_pct),elapsed_sec:J(t.elapsed_sec)??J(n==null?void 0:n.elapsed_sec),remaining_sec:J(t.remaining_sec)??J(n==null?void 0:n.remaining_sec),done_delta_total:J(t.done_delta_total)??J(n==null?void 0:n.done_delta_total),summary:n,team_health:F(t.team_health)?t.team_health:F(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:F(t.communication_metrics)?t.communication_metrics:F(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:F(t.orchestration_state)?t.orchestration_state:F(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:F(t.cascade_metrics)?t.cascade_metrics:F(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:s,recent_events:r}}function $p(t){if(!F(t))return null;const e=k(t.name);if(!e)return null;const n=F(t.context)?t.context:void 0;return{name:e,agent_name:k(t.agent_name),status:k(t.status),autonomy_level:k(t.autonomy_level),context_ratio:J(t.context_ratio)??J(n==null?void 0:n.context_ratio),generation:J(t.generation),active_goal_ids:pp(t.active_goal_ids),last_autonomous_action_at:k(t.last_autonomous_action_at)??null,last_turn_ago_s:J(t.last_turn_ago_s),model:k(t.model)??k(t.active_model)??k(t.primary_model)}}function hp(t){if(!F(t))return null;const e=k(t.confirm_token)??k(t.token);return e?{confirm_token:e,actor:k(t.actor),action_type:k(t.action_type),target_type:k(t.target_type),target_id:k(t.target_id)??null,delegated_tool:k(t.delegated_tool),created_at:k(t.created_at),preview:t.preview}:null}function yp(t){const e=F(t)?t:{};return{room:vp(e.room),sessions:St(e.sessions,["items","sessions"]).map(gp).filter(n=>n!==null),keepers:St(e.keepers,["items","keepers"]).map($p).filter(n=>n!==null),recent_messages:St(e.recent_messages,["messages"]).map(mp).filter(n=>n!==null),pending_confirms:St(e.pending_confirms,["items","confirms"]).map(hp).filter(n=>n!==null),available_actions:St(e.available_actions,["actions"]).filter(F).map(n=>({action_type:k(n.action_type)??"unknown",target_type:k(n.target_type)??"unknown",description:k(n.description),confirm_required:Ps(n.confirm_required)}))}}function Cn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Ao(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function cs(t){ls.value=[{...t,id:up++,at:new Date().toISOString()},...ls.value].slice(0,20)}function Wi(t){return t.confirm_required?Cn(t.preview)||"Confirmation required":Cn(t.result)||Cn(t.executed_action)||Cn(t.delegated_tool_result)||t.status}async function Vt(){rs.value=!0,Jt.value=null;try{const t=await el();Pe.value=yp(t)}catch(t){Jt.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{rs.value=!1}}async function Ot(){dn.value=!0,we.value=null;try{const t=await oi({targetType:"room"});Ki.value=Bi(t)}catch(t){we.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{dn.value=!1}}async function un(t){if(!t){zt.value=null;return}dn.value=!0,we.value=null;try{const e=await oi({targetType:"team_session",targetId:t,includeWorkers:!0});zt.value=Bi(e)}catch(e){we.value=e instanceof Error?e.message:"Failed to load session digest"}finally{dn.value=!1}}async function bp(t){var e;H.value=!0,Jt.value=null;try{const n=await xs(t);return cs({actor:t.actor,action_type:t.action_type,target_label:Ao(t),outcome:n.confirm_required?"preview":"executed",message:Wi(n),delegated_tool:n.delegated_tool}),await Vt(),await Ot(),(e=zt.value)!=null&&e.target_id&&await un(zt.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw Jt.value=s,cs({actor:t.actor,action_type:t.action_type,target_label:Ao(t),outcome:"error",message:s}),n}finally{H.value=!1}}async function kp(t,e){var n;H.value=!0,Jt.value=null;try{const s=await dl(t,e);return cs({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Wi(s),delegated_tool:s.delegated_tool}),await Vt(),await Ot(),(n=zt.value)!=null&&n.target_id&&await un(zt.value.target_id),s}catch(s){const a=s instanceof Error?s.message:"Operator confirmation failed";throw Jt.value=a,cs({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),s}finally{H.value=!1}}Fc(()=>{var t;Vt(),Ot(),(t=zt.value)!=null&&t.target_id&&un(zt.value.target_id)});const Gi="masc_dashboard_agent_name";function xp(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Gi))==null?void 0:s.trim())||"dashboard"}const Ms=v(xp()),He=v(""),Ma=v("운영 점검"),Be=v(""),ds=v(""),Da=v("2"),us=v(""),ie=v("note"),ps=v(""),ms=v(""),vs=v(""),Ea=v("2"),Ia=v("운영자 중지 요청"),za=v(""),We=v("");function Sp(t){const e=t.trim()||"dashboard";Ms.value=e,localStorage.setItem(Gi,e)}function Co(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Ap(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function Te(t){return typeof t=="string"?t.trim().toLowerCase():""}function Cp(t){var s;const e=Te(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=Te((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function wo(t){const e=Te(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function To(t){return t.some(e=>Te(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function wp(t){return t.target_type==="team_session"}function Tp(t){return t.target_type==="keeper"}function wn(t){switch(t){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_stop":return"세션 중지";case"keeper_msg":return"keeper 메시지";case"task_inject":return"작업 주입";default:return(t==null?void 0:t.trim())||"액션"}}function Tn(t){switch(t){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";default:return(t==null?void 0:t.trim())||"target"}}function Oe(t){switch(Te(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Ro(t){return t?"확인 후 실행":"즉시 실행"}function Rp(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";case"checkpoint":return"체크포인트";default:return t}}async function me(t){const e=Ms.value.trim()||"dashboard";try{const n=await bp({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?L("확인 대기열에 올렸습니다","warning"):L(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return L(s,"error"),null}}async function No(){const t=He.value.trim();if(!t)return;await me({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(He.value="")}async function Np(){await me({action_type:"room_pause",target_type:"room",payload:{reason:Ma.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function Lp(){await me({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function Pp(){const t=Be.value.trim();if(!t)return;await me({action_type:"task_inject",target_type:"room",payload:{title:t,description:ds.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(Da.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(Be.value="",ds.value="")}async function Mp(){var i;const t=Pe.value,e=us.value||((i=t==null?void 0:t.sessions[0])==null?void 0:i.session_id)||"";if(!e){L("먼저 세션을 고르세요","warning");return}const n={turn_kind:ie.value},s=ps.value.trim();s&&(n.message=s),ie.value==="task"&&(n.task_title=ms.value.trim()||"운영자 주입 작업",n.task_description=vs.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(Ea.value,10)||2),await me({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(ps.value="",ie.value==="task"&&(ms.value="",vs.value=""))}async function Dp(){var n;const t=Pe.value,e=us.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){L("먼저 세션을 고르세요","warning");return}await me({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Ia.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function Ep(){var a;const t=Pe.value,e=za.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=We.value.trim();if(!e){L("먼저 keeper를 고르세요","warning");return}if(!n)return;await me({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`${e}에게 메시지를 보냈습니다`})&&(We.value="")}async function Ip(t){const e=Ms.value.trim()||"dashboard";try{await kp(e,t),L("확인 실행을 완료했습니다","success")}catch(n){const s=n instanceof Error?n.message:"확인 실행에 실패했습니다";L(s,"error")}}function Lo(){var M,R,N;const t=Pe.value,e=Ki.value,n=zt.value,s=(t==null?void 0:t.room)??{},a=(t==null?void 0:t.sessions)??[],i=(t==null?void 0:t.keepers)??[],r=(t==null?void 0:t.pending_confirms)??[],l=(t==null?void 0:t.recent_messages)??[],u=(e==null?void 0:e.recommended_actions)??[],_=(t==null?void 0:t.available_actions)??[],d=a.find(p=>p.session_id===us.value)??a[0]??null,f=i.find(p=>p.name===za.value)??i[0]??null,g=(e==null?void 0:e.attention_items)??[],$=g.filter(wp),y=g.filter(Tp),A=a.filter(p=>Cp(p)!=="ok"),w=i.filter(p=>wo(p)!=="ok"),D=l.slice(0,5);it(()=>{Ot()},[]),it(()=>{const p=(d==null?void 0:d.session_id)??null;un(p)},[d==null?void 0:d.session_id]);const O=[{key:"room",label:"Room 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:r.length,detail:r.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:r.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:$.length>0?$.length:a.length,detail:$.length>0?((M=$[0])==null?void 0:M.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:$.length>0?To($):a.length===0?"warn":A.some(p=>Te(p.status)==="paused")?"bad":A.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:y.length>0?y.length:w.length,detail:y.length>0?((R=y[0])==null?void 0:R.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":w.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:y.length>0?To(y):w.some(p=>wo(p)==="bad")?"bad":w.length>0?"warn":"ok"}];return o`
    <section class="ops-view">
      <div class="ops-header card">
        <div>
          <div class="card-title">Intervene</div>
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
            value=${Ms.value}
            onInput=${p=>Sp(p.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{Vt(),Ot(),un((d==null?void 0:d.session_id)??null)}}
            disabled=${rs.value||H.value}
          >
            ${rs.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Jt.value?o`<section class="ops-banner error">${Jt.value}</section>`:null}
      ${we.value?o`<section class="ops-banner error">${we.value}</section>`:null}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 room인지, session인지, keeper인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${O.map(p=>o`
            <div key=${p.key} class="ops-priority-card ${p.tone}">
              <span class="ops-priority-label">${p.label}</span>
              <strong>${p.value}</strong>
              <div class="ops-priority-detail">${p.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel">
            <div class="card-title">Room 개입</div>
            <p class="ops-context-note">전체 room에 영향 주는 액션입니다. 방송, 정지/재개, 작업 주입을 여기서 처리합니다.</p>

            <div class="ops-stat-grid">
              <div class="ops-stat">
                <span>Room</span>
                <strong>${s.current_room??s.room_id??"default"}</strong>
              </div>
              <div class="ops-stat">
                <span>프로젝트</span>
                <strong>${s.project??"확인 없음"}</strong>
              </div>
              <div class="ops-stat">
                <span>클러스터</span>
                <strong>${s.cluster??"확인 없음"}</strong>
              </div>
              <div class="ops-stat ${s.paused?"warn":"ok"}">
                <span>상태</span>
                <strong>${s.paused?"일시정지":"진행 중"}</strong>
              </div>
            </div>

            <label class="control-label" for="ops-broadcast">Room 방송</label>
            <div class="control-row">
              <input
                id="ops-broadcast"
                class="control-input"
                type="text"
                placeholder="@agent 또는 room 전체 공지"
                value=${He.value}
                onInput=${p=>{He.value=p.target.value}}
                onKeyDown=${p=>{p.key==="Enter"&&No()}}
                disabled=${H.value}
              />
              <button class="control-btn" onClick=${()=>{No()}} disabled=${H.value||He.value.trim()===""}>
                보내기
              </button>
            </div>

            <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
            <div class="control-row ops-split-row">
              <input
                id="ops-pause-reason"
                class="control-input"
                type="text"
                value=${Ma.value}
                onInput=${p=>{Ma.value=p.target.value}}
                disabled=${H.value}
              />
              <button class="control-btn ghost" onClick=${()=>{Np()}} disabled=${H.value}>
                일시정지
              </button>
              <button class="control-btn ghost" onClick=${()=>{Lp()}} disabled=${H.value}>
                재개
              </button>
            </div>

            <div class="ops-section-head">작업 주입</div>
            <input
              class="control-input"
              type="text"
              placeholder="작업 제목"
              value=${Be.value}
              onInput=${p=>{Be.value=p.target.value}}
              disabled=${H.value}
            />
            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="작업 설명"
              value=${ds.value}
              onInput=${p=>{ds.value=p.target.value}}
              disabled=${H.value}
            ></textarea>
            <div class="control-row ops-split-row">
              <select
                class="control-input ops-select"
                value=${Da.value}
                onChange=${p=>{Da.value=p.target.value}}
                disabled=${H.value}
              >
                <option value="1">P1</option>
                <option value="2">P2</option>
                <option value="3">P3</option>
                <option value="4">P4</option>
                <option value="5">P5</option>
              </select>
              <button class="control-btn" onClick=${()=>{Pp()}} disabled=${H.value||Be.value.trim()===""}>
                주입
              </button>
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title">추천 개입</div>
            <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
            ${dn.value&&!e?o`
              <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
            `:u.length>0?o`
              <div class="ops-log-list">
                ${u.map(p=>o`
                  <article key=${`${p.action_type}:${p.target_type}:${p.target_id??"room"}`} class="ops-log-entry ${p.severity}">
                    <div class="ops-log-head">
                      <strong>${wn(p.action_type)}</strong>
                      <span>${Tn(p.target_type)}${p.target_id?` · ${p.target_id}`:""}</span>
                      <span>${Ro(p.confirm_required)}</span>
                    </div>
                    <div class="ops-log-body">${p.reason}</div>
                  </article>
                `)}
              </div>
            `:o`
              <div class="ops-empty">지금 떠 있는 추천 개입은 없습니다.</div>
            `}
          </section>

          <section class="card ops-panel">
            <div class="card-title">승인 대기</div>
            <p class="ops-context-note">미리보기만 끝났고 아직 사람이 눌러줘야 하는 액션만 남깁니다.</p>
            ${r.length>0?o`
              <div class="ops-confirmation-list">
                ${r.map(p=>o`
                  <article key=${p.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${wn(p.action_type)}</strong>
                      <span>${Tn(p.target_type)}${p.target_id?` · ${p.target_id}`:""}</span>
                      <span>${p.delegated_tool??"위임 도구 확인 필요"}</span>
                    </div>
                    ${p.preview?o`<pre class="ops-code-block compact">${Co(p.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{Ip(p.confirm_token)}} disabled=${H.value}>
                        실행
                      </button>
                      <span class="ops-token">${p.confirm_token}</span>
                    </div>
                  </article>
                `)}
              </div>
            `:o`<div class="ops-empty">지금 승인 대기는 없습니다.</div>`}
          </section>

          <section class="card ops-panel">
            <div class="card-title">최근 Room 메시지</div>
            <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
            ${D.length>0?o`
              <div class="ops-feed-list">
                ${D.map(p=>o`
                  <article key=${p.seq??p.id??p.timestamp} class="ops-feed-item">
                    <div class="ops-feed-meta">
                      <strong>${p.from}</strong>
                      <span>${p.timestamp}</span>
                    </div>
                    <div class="ops-feed-content">${p.content}</div>
                  </article>
                `)}
              </div>
            `:o`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel">
            <div class="card-title">Session 개입</div>
            <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

            <div class="ops-entity-list">
              ${a.length===0?o`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:a.map(p=>{var q;return o`
                <button
                  key=${p.session_id}
                  class="ops-entity-card ${(d==null?void 0:d.session_id)===p.session_id?"active":""}"
                  onClick=${()=>{us.value=p.session_id}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${p.session_id}</strong>
                    <span class="status-badge ${p.status??"idle"}">${Oe(p.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round(p.progress_pct??0)}%</span>
                    <span>${p.done_delta_total??0}건 완료</span>
                    <span>${(q=p.team_health)!=null&&q.status?Oe(String(p.team_health.status)):"상태 확인 필요"}</span>
                  </div>
                </button>
              `})}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title">선택한 Session 요약</div>
            <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
            ${d&&n?o`
              <div class="ops-log-list">
                ${n.attention_items.length>0?n.attention_items.map(p=>o`
                  <article key=${`${p.kind}:${p.target_id??"session"}`} class="ops-log-entry ${p.severity}">
                    <div class="ops-log-head">
                      <strong>${p.kind}</strong>
                      <span>${Tn(p.target_type)}${p.target_id?` · ${p.target_id}`:""}</span>
                    </div>
                    <div class="ops-log-body">${p.summary}</div>
                  </article>
                `):o`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
                ${n.worker_cards.length>0?n.worker_cards.map(p=>o`
                  <article key=${`${p.actor??p.spawn_role??"worker"}:${p.spawn_agent??p.runtime_pool??"runtime"}`} class="ops-log-entry">
                    <div class="ops-log-head">
                      <strong>${p.actor??p.spawn_role??"worker"}</strong>
                      <span>${Oe(p.status)}</span>
                      <span>${p.spawn_agent??p.runtime_pool??"runtime 확인 필요"}</span>
                    </div>
                    <div class="ops-log-body">
                      ${p.worker_class??"worker"}${p.lane_id?` · ${p.lane_id}`:""}${p.routing_reason?` · ${p.routing_reason}`:""}
                    </div>
                  </article>
                `):null}
              </div>
            `:o`
              <div class="ops-empty">세션을 고르면 세부 요약을 불러옵니다.</div>
            `}
          </section>

          <section class="card ops-panel ops-lane-panel">
            <div class="card-title">선택한 Session 액션</div>
            <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>

            ${d?o`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${d.session_id}</div>
                <div class="ops-detail-meta">
                  <span>상태: ${Oe(d.status)}</span>
                  <span>경과: ${d.elapsed_sec??0}초</span>
                  <span>남은 시간: ${d.remaining_sec??0}초</span>
                </div>
                ${d.recent_events&&d.recent_events.length>0?o`
                  <pre class="ops-code-block compact">${Co(d.recent_events.slice(-3))}</pre>
                `:null}
              </div>
            `:o`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

            <label class="control-label" for="ops-turn-kind">세션 액션</label>
            <div class="control-row ops-split-row">
              <select
                id="ops-turn-kind"
                class="control-input ops-select"
                value=${ie.value}
                onChange=${p=>{ie.value=p.target.value}}
                disabled=${H.value||!d}
              >
                <option value="note">노트</option>
                <option value="broadcast">방송</option>
                <option value="task">작업</option>
                <option value="checkpoint">체크포인트</option>
              </select>
              <button class="control-btn" onClick=${()=>{Mp()}} disabled=${H.value||!d}>
                적용
              </button>
            </div>
            <div class="ops-context-note">현재 선택: ${Rp(ie.value)}</div>

            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="세션에 남길 메시지"
              value=${ps.value}
              onInput=${p=>{ps.value=p.target.value}}
              disabled=${H.value||!d}
            ></textarea>

            ${ie.value==="task"?o`
              <input
                class="control-input"
                type="text"
                placeholder="주입할 작업 제목"
                value=${ms.value}
                onInput=${p=>{ms.value=p.target.value}}
                disabled=${H.value||!d}
              />
              <textarea
                class="control-textarea"
                rows=${2}
                placeholder="주입할 작업 설명"
                value=${vs.value}
                onInput=${p=>{vs.value=p.target.value}}
                disabled=${H.value||!d}
              ></textarea>
              <select
                class="control-input ops-select"
                value=${Ea.value}
                onChange=${p=>{Ea.value=p.target.value}}
                disabled=${H.value||!d}
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
                value=${Ia.value}
                onInput=${p=>{Ia.value=p.target.value}}
                disabled=${H.value||!d}
              />
              <button class="control-btn ghost" onClick=${()=>{Dp()}} disabled=${H.value||!d}>
                세션 중지
              </button>
            </div>
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel">
            <div class="card-title">Keeper 개입</div>
            <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

            <div class="ops-entity-list">
              ${i.length===0?o`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:i.map(p=>o`
                <button
                  key=${p.name}
                  class="ops-entity-card ${(f==null?void 0:f.name)===p.name?"active":""}"
                  onClick=${()=>{za.value=p.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${p.name}</strong>
                    <span class="status-badge ${p.status??"idle"}">${Oe(p.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${p.model??"model 확인 필요"}</span>
                    <span>${typeof p.context_ratio=="number"?`${Math.round(p.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                    <span>${Ap(p.last_turn_ago_s)}</span>
                  </div>
                </button>
              `)}
            </div>
          </section>

          <section class="card ops-panel ops-lane-panel">
            <div class="card-title">선택한 Keeper 액션</div>
            <p class="ops-context-note">선택한 keeper에만 직접 메시지를 보내서 probe, 수정, 재지시를 합니다.</p>

            ${f?o`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${f.name}</div>
                <div class="ops-detail-meta">
                  <span>자율성: ${f.autonomy_level??"확인 없음"}</span>
                  <span>세대: ${f.generation??0}</span>
                  <span>활성 목표: ${((N=f.active_goal_ids)==null?void 0:N.length)??0}</span>
                </div>
              </div>
            `:o`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

            <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
            <textarea
              id="ops-keeper-message"
              class="control-textarea"
              rows=${6}
              placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
              value=${We.value}
              onInput=${p=>{We.value=p.target.value}}
              disabled=${H.value||!f}
            ></textarea>
            <div class="control-row">
              <button class="control-btn" onClick=${()=>{Ep()}} disabled=${H.value||!f||We.value.trim()===""}>
                keeper에 보내기
              </button>
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title">가능한 액션 목록</div>
            <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
            <div class="ops-log-list">
              ${_.length?_.map(p=>o`
                    <article key=${`${p.action_type}:${p.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${wn(p.action_type)}</strong>
                        <span>${Tn(p.target_type)}</span>
                        <span>${Ro(p.confirm_required)}</span>
                      </div>
                      <div class="ops-log-body">${p.description??"설명이 아직 없습니다."}</div>
                    </article>
                  `):o`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title">최근 개입 로그</div>
            <div class="ops-log-list">
              ${ls.value.length===0?o`
                <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
              `:ls.value.map(p=>o`
                <article key=${p.id} class="ops-log-entry ${p.outcome}">
                  <div class="ops-log-head">
                    <strong>${wn(p.action_type)}</strong>
                    <span>${p.target_label}</span>
                    <span>${p.at}</span>
                  </div>
                  <div class="ops-log-body">${p.message}</div>
                </article>
              `)}
            </div>
          </section>
        </div>
      </div>
    </section>
  `}function zp(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function V({timestamp:t}){const e=zp(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}function Op({text:t}){if(!t)return null;const e=jp(t);return o`<div class="markdown-content">${e}</div>`}function jp(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],l=a.slice(r.length).trim(),u=[];for(s++;s<e.length&&!e[s].startsWith(r);)u.push(e[s]),s++;s++,n.push(o`<pre><code class=${l?`language-${l}`:""}>${u.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],l=a.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const _=e[s].replace("</think>","").trim();_&&r.push(_),s++}const u=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${qs(u)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${qs(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${qs(i.join(`
`))}</p>`)}return n}function qs(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Ke=v("posts"),Oa=v([]),ja=v([]),Ge=v(""),_s=v(!1),Je=v(!1),pn=v(""),fs=v(null),$t=v(null),Fa=v(!1),Ut=v(null),qn=v(null);async function Ds(){_s.value=!0,pn.value="";try{const[t,e]=await Promise.all([Bl(),Wl()]);Oa.value=t,ja.value=e,Ut.value=!0,qn.value=Date.now()}catch(t){pn.value=t instanceof Error?t.message:"Failed to load council data",Ut.value=!1}finally{_s.value=!1}}Oc(Ds);async function Po(){const t=Ge.value.trim();if(t){Je.value=!0;try{const e=await Gl(t);Ge.value="",L(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Ds()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";L(n,"error")}finally{Je.value=!1}}}async function Fp(t){fs.value=t,Fa.value=!0,$t.value=null;try{$t.value=await Jl(t)}catch(e){pn.value=e instanceof Error?e.message:"Failed to load debate status",$t.value=null}finally{Fa.value=!1}}const Ji=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Kn=v(null),Ve=v([]),de=v(!1),re=v(null),Ye=v("");function qp(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Kp=v(qp()),Xe=v(!1);async function io(t){re.value=t,Kn.value=null,Ve.value=[],de.value=!0;try{const e=await gl(t);if(re.value!==t)return;Kn.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},Ve.value=e.comments??[]}catch{re.value===t&&(Kn.value=null,Ve.value=[])}finally{re.value===t&&(de.value=!1)}}async function Mo(t){const e=Ye.value.trim();if(e){Xe.value=!0;try{await $l(t,Kp.value,e),Ye.value="",L("Comment posted","success"),await io(t),At()}catch{L("Failed to post comment","error")}finally{Xe.value=!1}}}function Up(){const t=en.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Ji.map(e=>o`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{en.value=e.id,At()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${se.value?"is-active":""}"
          onClick=${()=>{se.value=!se.value,At()}}
        >
          ${se.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${At} disabled=${sn.value}>
          ${sn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function qa(){var e;const t=(e=Ne.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${V} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Vi({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Hp(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function Do(t){return t.updated_at!==t.created_at}function Ka(){var n;const t=((n=Ji.find(s=>s.id===en.value))==null?void 0:n.label)??en.value,e=Le.value.length;return o`
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
        <strong>${se.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Aa.value?o`<${V} timestamp=${Aa.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Bp({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await ri(t.id,n),At()}catch{L("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>Nr(t.id)}>
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
              <${Vi} flair=${t.flair} />
              ${Do(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${V} timestamp=${t.created_at} /></span>
            ${Do(t)?o`<span>Updated <${V} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${Hp(t.content)}</div>
      </div>
    </div>
  `}function Wp({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${V} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Gp({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Ye.value}
        onInput=${e=>{Ye.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Mo(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Xe.value}
      />
      <button
        onClick=${()=>Mo(t)}
        disabled=${Xe.value||Ye.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Xe.value?"...":"Post"}
      </button>
    </div>
  `}function Jp({post:t}){re.value!==t.id&&!de.value&&io(t.id);const e=async n=>{try{await ri(t.id,n),At()}catch{L("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>tt("board")}>← Back to Board</button>
      <${T} title=${o`${t.title} <${Vi} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Op} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${V} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${T} title="Comments (${de.value?"...":Ve.value.length})">
        ${de.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Wp} comments=${Ve.value} />`}
        <${Gp} postId=${t.id} />
      <//>
    </div>
  `}function Vp({debate:t}){const e=fs.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Fp(t.id)}
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
  `}function Yp({session:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.state?o`<span>State: ${t.state}</span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function Yi(){return Ut.value===null||Ut.value&&!qn.value?null:o`
    <div class="feed-health-banner ${Ut.value===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${Ut.value===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${qn.value?o`<span class="feed-health-meta">Last sync: <${V} timestamp=${qn.value} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Xp(){const t=Ut.value===!1;return o`
    <div>
      <${Yi} />
      <${T} title="Start Debate" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Ge.value}
            onInput=${e=>{Ge.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&Po()}}
            disabled=${Je.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Po}
            disabled=${Je.value||Ge.value.trim()===""}
          >
            ${Je.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Ds} disabled=${_s.value}>
            ${_s.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${pn.value?o`<div class="council-error">${pn.value}</div>`:null}
      <//>

      <${T} title="Debates" class="section">
        <div class="council-list">
          ${Oa.value.length===0?o`<div class="empty-state">${t?"No debates loaded (council feed degraded).":"No debates yet"}</div>`:Oa.value.map(e=>o`<${Vp} key=${e.id} debate=${e} />`)}
        </div>
      <//>

      <${T} title=${fs.value?`Debate Detail (${fs.value})`:"Debate Detail"} class="section">
        ${Fa.value?o`<div class="loading-indicator">Loading debate detail...</div>`:$t.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${$t.value.status}</span>
                  <span>Total arguments: ${$t.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${$t.value.support_count}</span>
                  <span>Oppose: ${$t.value.oppose_count}</span>
                  <span>Neutral: ${$t.value.neutral_count}</span>
                </div>
                ${$t.value.summary_text?o`<pre class="council-detail">${$t.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Qp(){const t=Ut.value===!1;return o`
    <div>
      <${Yi} />
      <${T} title="Voting Sessions" class="section">
        <div class="council-list">
          ${ja.value.length===0?o`<div class="empty-state">${t?"No sessions loaded (council feed degraded).":"No active sessions"}</div>`:ja.value.map(e=>o`<${Yp} key=${e.id} session=${e} />`)}
        </div>
      <//>
    </div>
  `}function Zp(){const t=Ke.value;return o`
    <div class="overview-sub-tabs" style="margin-bottom: 12px;">
      <button class="sub-tab-btn ${t==="posts"?"active":""}" onClick=${()=>{Ke.value="posts"}}>Posts</button>
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{Ke.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{Ke.value="voting"}}>Voting</button>
    </div>
  `}function tm(){var s,a;const t=Le.value,e=sn.value,n=((a=(s=Ne.value)==null?void 0:s.data_quality)==null?void 0:a.board_contract_ok)===!1;return o`
    <div>
      <${qa} />
      <${Ka} />
      <${Up} />
      ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
              <div class="empty-state">
                ${n?"No posts loaded (board feed degraded). Check board contract sync.":se.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
              </div>
            `:o`<div class="board-post-list">
              ${t.map(i=>o`<${Bp} key=${i.id} post=${i} />`)}
            </div>`}
    </div>
  `}function em(){var a,i;const t=Le.value,e=Z.value.postId,n=((i=(a=Ne.value)==null?void 0:a.data_quality)==null?void 0:i.board_contract_ok)===!1,s=Ke.value;if(it(()=>{(s==="debates"||s==="voting")&&Ds()},[s]),e){const r=t.find(l=>l.id===e)??(re.value===e?Kn.value:null);return!r&&re.value!==e&&!de.value&&io(e),r?o`
          <${qa} />
          <${Ka} />
          <${Jp} post=${r} />
        `:o`
          <div>
            <${qa} />
            <${Ka} />
            <button class="back-btn" onClick=${()=>tt("board")}>← Back to Board</button>
            ${de.value?o`<div class="loading-indicator">Loading post...</div>`:o`
                  <div class="empty-state">
                    ${n?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return o`
    <${Zp} />
    ${s==="debates"?o`<${Xp} />`:s==="voting"?o`<${Qp} />`:o`<${tm} />`}
  `}const nm=40;function sm({items:t,itemHeight:e,overscan:n=5,renderItem:s,getKey:a,className:i=""}){const r=Vo(null),[l,u]=Ya({start:0,end:30}),_=t.length>nm;if(it(()=>{if(!_)return;const $=r.current;if(!$)return;let y=!1;const A=()=>{const{scrollTop:M,clientHeight:R}=$,N=Math.max(0,Math.floor(M/e)-n),p=Math.min(t.length,Math.ceil((M+R)/e)+n);u(q=>q.start===N&&q.end===p?q:{start:N,end:p})};let w=!1;const D=()=>{w||y||(w=!0,requestAnimationFrame(()=>{y||A(),w=!1}))},O=new ResizeObserver(()=>{y||A()});return A(),$.addEventListener("scroll",D,{passive:!0}),O.observe($),()=>{y=!0,$.removeEventListener("scroll",D),O.disconnect()}},[_,t.length,e,n]),!_)return o`
      <div class=${i}>
        ${t.map(($,y)=>s($,y))}
      </div>
    `;const d=t.length*e,f=l.start*e,g=t.slice(l.start,l.end);return o`
    <div ref=${r} class=${i}>
      <div class="virtual-list-spacer" style=${{height:`${d}px`,position:"relative"}}>
        <div
          class="virtual-list-viewport"
          style=${{position:"absolute",top:0,left:0,right:0,willChange:"transform",transform:`translateY(${f}px)`}}
        >
          ${g.map(($,y)=>{const A=l.start+y;return o`<div key=${a($)}>${s($,A)}</div>`})}
        </div>
      </div>
    </div>
  `}function am(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function om(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function im(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const Xi=120,rm=12,lm=16,cm=12,Un=v("all"),dm={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},um={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function pm(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function mm(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:am(t),actor:om(t),content:im(t),timestamp:new Date(t.timestamp).toISOString()}}function vm(t,e){var a;const n=(a=t.assignee)==null?void 0:a.trim(),s=t.updated_at??t.created_at;return!n||!s?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:s}}function _m(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function Rn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ua(t){return t.last_heartbeat??Rn(t.last_turn_ago_s)??Rn(t.last_proactive_ago_s)??Rn(t.last_handoff_ago_s)??Rn(t.last_compaction_ago_s)}function fm(t,e){const n=Ua(t);if(!n)return null;const s=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${s}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${s}`,timestamp:n}}function bt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const Ha=ft(()=>{const t=tn.value.map(pm),e=Jn.value.map(mm),n=[...yt.value].sort((i,r)=>bt(r.updated_at??r.created_at??0)-bt(i.updated_at??i.created_at??0)).slice(0,rm).map(vm).filter(i=>i!==null),s=[...Le.value].sort((i,r)=>bt(r.updated_at||r.created_at)-bt(i.updated_at||i.created_at)).slice(0,lm).map(_m),a=[...pe.value].sort((i,r)=>bt(Ua(r)??0)-bt(Ua(i)??0)).slice(0,cm).map(fm).filter(i=>i!==null);return[...t,...e,...n,...s,...a].sort((i,r)=>bt(r.timestamp)-bt(i.timestamp))}),gm=ft(()=>{const t=Ha.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),$m=ft(()=>{const t=Un.value;return(t==="all"?Ha.value:Ha.value.filter(n=>n.kind===t)).slice(0,Xi)}),hm=ft(()=>{const t=fi.value,e={activeAssignedCount:0,lastActivityAt:null,lastActivityText:null};return wt.value.map(n=>({agent:n,motion:t.get(n.name.trim().toLowerCase())??e})).sort((n,s)=>{const a=s.motion.activeAssignedCount-n.motion.activeAssignedCount;return a!==0?a:bt(s.motion.lastActivityAt??0)-bt(n.motion.lastActivityAt??0)})});function ym(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function je({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function bm({row:t}){return o`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${ym(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${um[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function km(){const t=gm.value,e=$m.value,n=e[0],s=hm.value;return o`
    <div class="stats-grid">
      <${je} label="Visible rows 표시 행" value=${e.length} />
      <${je} label="Tracked messages 추적 메시지" value=${t.messages} color="#47b8ff" />
      <${je} label="Keeper signals 키퍼 신호" value=${t.keepers} color="#4ade80" />
      <${je} label="Board signals 보드 신호" value=${t.board} color="#fbbf24" />
      <${je} label="SSE events SSE 이벤트" value=${ks.value} color="#c084fc" />
    </div>

    <${T} title="Unified Activity 통합 활동" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(a=>o`
            <button
              class="goal-filter-btn ${Un.value===a?"active":""}"
              aria-pressed="${Un.value===a}"
              onClick=${()=>{Un.value=a}}
            >
              ${dm[a]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${Dt.value?"":"pill-stale"}">
            ${Dt.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?o`Latest: <${V} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${Xi} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      ${e.length===0?o`<div class="terminal-feed"><div class="empty-state">Waiting for live or snapshot signals...</div></div>`:o`<${sm}
            items=${e}
            itemHeight=${28}
            overscan=${8}
            getKey=${a=>a.id}
            renderItem=${a=>o`<${bm} row=${a} />`}
            className="terminal-feed"
          />`}
    <//>

    <${T} title="Agent Motion 에이전트 동향" class="section">
      <div class="activity-motion-list">
        ${s.length===0?o`<div class="empty-state">No active agents</div>`:s.map(({agent:a,motion:i})=>o`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${a.name}</div>
                  <div class="activity-motion-meta">
                    ${i.activeAssignedCount>0?`${i.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${i.lastActivityAt?o` · <${V} timestamp=${i.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${i.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function Xt({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Qi({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${l}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${l}">${Math.round(t*100)}%</span>
    </div>
  `}function xm(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Sm(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Am(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Eo(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function Zi(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Cm(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function tr(t){if(!t)return null;const e=Et.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function wm({keeper:t,showRawStatus:e=!1}){if(it(()=>{t!=null&&t.name&&ui(t.name)},[t==null?void 0:t.name]),!t)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Et.value[t.name],s=tr(t),a=va.value[t.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${xm(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Sm((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?o` · ${Zi(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?o` · next eligible ${Cm(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?o`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Tm({keeperName:t,placeholder:e}){const[n,s]=Ya("");it(()=>{t&&ui(t)},[t]);const a=at.value[t]??[],i=_a.value[t]??!1,r=It.value[t],l=async()=>{const u=n.trim();if(!(!t||!u)){s("");try{await pc(t,u)}catch(_){const d=_ instanceof Error?_.message:`Failed to message ${t}`;L(d,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?o`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(u=>o`
              <div class="keeper-conversation-item" key=${u.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Eo(u)}`}>${u.label}</span>
                  <span class=${`keeper-role-chip ${Eo(u)}`}>${Am(u)}</span>
                  ${u.timestamp?o`<span class="keeper-conversation-time">${Zi(u.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${u.text}</div>
                ${u.error?o`<div class="keeper-conversation-error">${u.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${e}
          value=${n}
          onInput=${u=>{s(u.target.value)}}
          disabled=${i||!t}
        ></textarea>
        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${()=>{l()}}
            disabled=${i||n.trim()===""||!t}
          >
            ${i?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${r?o`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function Rm({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=tr(e),a=fa.value[e.name]??!1,i=ga.value[e.name]??!1,r=(s==null?void 0:s.next_action_path)??"direct_message",l=(s==null?void 0:s.recoverable)??r==="recover";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{mc(e.name,t).catch(u=>{const _=u instanceof Error?u.message:`Failed to probe ${e.name}`;L(_,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{vc(e.name,t).catch(u=>{const _=u instanceof Error?u.message:`Failed to recover ${e.name}`;L(_,"error")})}}
        disabled=${i||!l||!t.trim()}
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
  `}const ro=v(null);function er(t){ro.value=t,uc(t.name)}function Io(){ro.value=null}const ge=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Nm(t){if(!t)return 0;const e=ge.findIndex(n=>n.level===t);return e>=0?e:0}function Lm({keeper:t}){const e=Nm(t.autonomy_level),n=ge[e]??ge[0];if(!n)return null;const s=(e+1)/ge.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${ge.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${ge.map((a,i)=>o`
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
            <strong><${V} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Hn(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Pm({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Hn(t.context_tokens)}</div>
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
  `}function Mm({keeper:t}){var d,f;const e=t.metrics_series??[];if(e.length<2){const g=(((d=t.context)==null?void 0:d.context_ratio)??0)*100,$=g>85?"#ef4444":g>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${g.toFixed(1)}%;background:${$}"></div>
        </div>
        <span class="chart-pct">${g.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((g,$)=>{const y=a+$/(i-1)*(n-2*a),A=s-a-(g.context_ratio??0)*(s-2*a);return{x:y,y:A,p:g}}),l=r.map(({x:g,y:$})=>`${g.toFixed(1)},${$.toFixed(1)}`).join(" "),u=(((f=e[e.length-1])==null?void 0:f.context_ratio)??0)*100,_=u>85?"#ef4444":u>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:g})=>g.is_handoff).map(({x:g})=>o`
          <line x1="${g.toFixed(1)}" y1="${a}" x2="${g.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${_}" stroke-width="1.5"/>
        ${r.filter(({p:g})=>g.is_compaction).map(({x:g,y:$})=>o`
          <circle cx="${g.toFixed(1)}" cy="${$.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${u.toFixed(1)}%</span>
    </div>`}const Ks=v("");function Dm({keeper:t}){var a,i,r,l;const e=Ks.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(u=>u.title.toLowerCase().includes(e)||u.key.includes(e)||u.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Ks.value}
        onInput=${u=>{Ks.value=u.target.value}}
      />
      ${s.map(u=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${u.title}</span>
          <span class="keeper-field-key">${u.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${u.value}</span>
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Hn(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Hn(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Hn(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Em({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function Im({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function zm({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function zo({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Us(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Om({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Us(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Us(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Us(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function nr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function jm(){try{const t=await xs({actor:nr(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=di(t.result);an(),await ue(),e!=null&&e.skipped_reason?L(e.skipped_reason,"warning"):L(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";L(e,"error")}}function Fm({keeper:t}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${wm} keeper=${t} />
          <${Rm}
            actor=${nr()}
            keeper=${t}
            onPokeLodge=${()=>{jm()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Tm}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function qm(){var e,n,s;const t=ro.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Io()}}
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
            <${Xt} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Io()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Pm} keeper=${t} />

        ${""}
        <${Mm} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${T} title="Field Dictionary">
            <${Dm} keeper=${t} />
          <//>

          ${""}
          <${T} title="Profile">
            <${zo} traits=${t.traits??[]} label="Traits" />
            <${zo} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${V} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${T} title="Autonomy">
                <${Lm} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${T} title="TRPG Stats">
                <${Em} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${T} title="Equipment (${t.inventory.length})">
                <${Im} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${T} title="Relationships (${Object.keys(t.relationships).length})">
                <${zm} rels=${t.relationships} />
              <//>
            `:null}

          <${T} title="Runtime Signals">
            <${Om} keeper=${t} />
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
        <${Fm} keeper=${t} />
      </div>
    </div>
  `:null}const Km="masc_dashboard_agent_name",Me=v(null),gs=v(!1),mn=v(""),$s=v([]),vn=v([]),Se=v(""),Qe=v(!1);function sr(t){Me.value=t,lo()}function Oo(){Me.value=null,mn.value="",$s.value=[],vn.value=[],Se.value=""}function Um(){const t=Me.value;return t?wt.value.find(e=>e.name===t)??null:null}function ar(t){return t?yt.value.filter(e=>e.assignee===t):[]}async function lo(){const t=Me.value;if(t){gs.value=!0,mn.value="",$s.value=[],vn.value=[];try{const e=await Ul(80);$s.value=e.filter(a=>a.includes(t)).slice(0,20);const n=ar(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await Hl(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));vn.value=s}catch(e){mn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{gs.value=!1}}}async function jo(){var s;const t=Me.value,e=Se.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Km))==null?void 0:s.trim())||"dashboard";Qe.value=!0;try{await Kl(n,`@${t} ${e}`),Se.value="",L(`Mention sent to ${t}`,"success"),lo()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";L(i,"error")}finally{Qe.value=!1}}function Hm({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Xt} status=${t.status} />
    </div>
  `}function Bm({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Wm(){var a,i,r,l;const t=Me.value;if(!t)return null;const e=Um(),n=ar(t),s=$s.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${u=>{u.target.classList.contains("agent-detail-overlay")&&Oo()}}
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
                        <${Xt} status=${e.status} />
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
                ${(i=e==null?void 0:e.traits)==null?void 0:i.map(u=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${u}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(l=e==null?void 0:e.interests)==null?void 0:l.map(u=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${u}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${V} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{lo()}} disabled=${gs.value}>
              ${gs.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Oo}>Close</button>
          </div>
        </div>

        ${mn.value?o`<div class="council-error">${mn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${T} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(u=>o`<${Hm} key=${u.id} task=${u} />`)}</div>`}
          <//>

          <${T} title="Recent Activity">
            ${s.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${s.map((u,_)=>o`<div key=${_} class="agent-activity-line">${u}</div>`)}</div>`}
          <//>
        </div>

        <${T} title="Task History">
          ${vn.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${vn.value.map(u=>o`<${Bm} key=${u.taskId} row=${u} />`)}</div>`}
        <//>

        <${T} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Se.value}
              onInput=${u=>{Se.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&jo()}}
              disabled=${Qe.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{jo()}}
              disabled=${Qe.value||Se.value.trim()===""}
            >
              ${Qe.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const Hs=600*1e3,Gm=1200*1e3,Fo=.8;function qt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function fe(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Jm(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function Vm(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Ym(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Xm(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function Qm(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function Zm(t){var u,_;const e=fi.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,s=n?Math.max(0,Date.now()-qt(n)):Number.POSITIVE_INFINITY,a=!!((u=t.current_task)!=null&&u.trim())||e.activeAssignedCount>0;let i="watching",r="ok",l="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",l=n?"Offline or inactive":"No recent presence"):s>Gm?(i="quiet",r="bad",l=a?"Working without a fresh signal":"No fresh agent signal"):a?(i="working",r=s>Hs?"warn":"ok",l=s>Hs?"Execution looks quiet for too long":"Task and live signal aligned"):s>Hs?(i="quiet",r="warn",l="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",l="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((_=t.current_task)==null?void 0:_.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:l}}function tv(t){const e=kc.value.get(t.name)??"idle",n=Ac.value.has(t.name),s=t.context_ratio??0;let a="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(a="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||s>=Fo)&&(a="warning",i="warn",r=s>=Fo?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:a,tone:i,focus:Xm(t),note:r}}function Fe({label:t,value:e,color:n,caption:s}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?o`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function ev({item:t}){const e=t.kind==="agent"?()=>sr(t.agent.name):()=>er(t.keeper);return o`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?o`<span><${V} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </button>
  `}function qo({row:t}){const{agent:e,motion:n}=t;return o`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>sr(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Qi} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Xt} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${Jm(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${V} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
        ${e.last_seen?o`<span>Seen <${V} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?o`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function nv({row:t}){const{keeper:e}=t;return o`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>er(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Qi} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Xt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Vm(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?o`<span>Heartbeat <${V} timestamp=${e.last_heartbeat} /></span>`:o`<span>No heartbeat</span>`}
        <span>${Qm(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${Ym(e.context_ratio)}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?o`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function sv(){const t=[...wt.value].map(Zm).sort((d,f)=>{const g=fe(f.tone)-fe(d.tone);if(g!==0)return g;const $=f.activeTaskCount-d.activeTaskCount;return $!==0?$:qt(f.lastSignalAt)-qt(d.lastSignalAt)}),e=[...pe.value].map(tv).sort((d,f)=>{const g=fe(f.tone)-fe(d.tone);if(g!==0)return g;const $=(f.keeper.context_ratio??0)-(d.keeper.context_ratio??0);return $!==0?$:qt(f.keeper.last_heartbeat)-qt(d.keeper.last_heartbeat)}),n=t.filter(d=>d.state!=="offline"),s=t.filter(d=>d.state==="offline"),a=n.length,i=t.filter(d=>d.state==="working").length,r=t.filter(d=>d.lastSignalAt&&Date.now()-qt(d.lastSignalAt)<=12e4).length,l=t.filter(d=>d.tone!=="ok"),u=e.filter(d=>d.tone!=="ok"),_=[...u.map(d=>({kind:"keeper",key:`keeper-${d.keeper.name}`,tone:d.tone,title:d.keeper.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.keeper.last_heartbeat??null,keeper:d.keeper})),...l.map(d=>({kind:"agent",key:`agent-${d.agent.name}`,tone:d.tone,title:d.agent.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt,agent:d.agent}))].sort((d,f)=>{const g=fe(f.tone)-fe(d.tone);return g!==0?g:qt(f.timestamp)-qt(d.timestamp)}).slice(0,8);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${Fe} label="Agents online 온라인" value=${a} color="#4ade80" caption="활성 + 대기 에이전트" />
        <${Fe} label="Working now 작업중" value=${i} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${Fe} label="Fresh signals 최신 신호" value=${r} color="#22d3ee" caption="최근 2분 이내" />
        <${Fe} label="Agent alerts 에이전트 경고" value=${l.length} color=${l.length>0?"#fb7185":"#4ade80"} caption="비활성 또는 오프라인" />
        <${Fe} label="Keeper alerts 키퍼 경고" value=${u.length} color=${u.length>0?"#fb7185":"#4ade80"} caption="오래되거나 높은 부하" />
      </div>

      <${T} title="Attention Queue 주의 필요" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${_.length===0?o`<div class="empty-state">No agent or keeper alerts right now</div>`:_.map(d=>o`<${ev} key=${d.key} item=${d} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${T} title="Active Agents 활성 에이전트" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Live agents stay grouped here first so execution drift is visible before you scan offline history.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?o`<div class="empty-state">No active agents visible</div>`:n.map(d=>o`<${qo} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>

        <${T} title="Keeper Watch 키퍼 감시" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?o`<div class="empty-state">No keepers active</div>`:e.map(d=>o`<${nv} key=${d.keeper.name} row=${d} />`)}
          </div>
        <//>

        <${T} title="Offline Agents 오프라인" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who dropped out of the live loop</h2>
            <p class="monitor-subheadline">Offline rows are separated so they do not drown the active execution monitor.</p>
          </div>
          <div class="monitor-list">
            ${s.length===0?o`<div class="empty-state">No offline agents right now</div>`:s.map(d=>o`<${qo} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const hs=v("all"),ys=v("all"),Ba=ft(()=>{let t=nn.value;return hs.value!=="all"&&(t=t.filter(e=>e.horizon===hs.value)),ys.value!=="all"&&(t=t.filter(e=>e.status===ys.value)),t}),av=ft(()=>{const t={short:[],mid:[],long:[]};for(const e of Ba.value){const n=t[e.horizon];n&&n.push(e)}return t}),ov=ft(()=>{const t=Array.from(mi.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function iv(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function co(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function Bn(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function rv(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Ko(t){return t.toFixed(4)}function Uo(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function lv({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${Bn(t.horizon)}">
            ${co(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${iv(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${V} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${Xt} status=${t.status} />
        <div class="goal-updated">
          <${V} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Ho({label:t,timestamp:e,source:n,note:s}){return o`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${s?o`<div class="planning-freshness-source">${s}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?o`<${V} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function Bs({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${T} title="${co(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(s=>o`<${lv} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function cv(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${hs.value===t?"active":""}"
            onClick=${()=>{hs.value=t}}
          >
            ${t==="all"?"All":co(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${ys.value===t?"active":""}"
            onClick=${()=>{ys.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function dv(){const t=nn.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${Bn("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Bn("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Bn("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function uv({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return o`
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
          <span>Baseline ${Ko(t.baseline_metric)}</span>
          <span>Current ${Ko(t.current_metric)}</span>
          <span class=${Uo(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Uo(t)}
          </span>
          <span>Elapsed ${rv(t.elapsed_seconds)}</span>
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
  `}function Ws({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${V} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function pv(){const{todo:t,inProgress:e,done:n}=yc.value;return o`
    <${T} title="Task Backlog" class="section">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>o`<${Ws} key=${s.id} task=${s} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>o`<${Ws} key=${s.id} task=${s} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>o`<${Ws} key=${s.id} task=${s} />`)}
          ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function mv(){const t=av.value,e=ov.value,n=e.filter(l=>l.status==="running").length,s=e.filter(l=>l.recoverable).length,a=nn.value.filter(l=>l.status==="active").length,i=ba.value,r=i==="idle"?"No loop running":i==="error"?ka.value??"MDAL snapshot unavailable":"Current loop snapshot";return o`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${a}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${Ba.value.length}</div>
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

      <${T} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>/api/v1/mdal/loops</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${on} disabled=${ye.value}>
              ${ye.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${Ce} disabled=${be.value}>
              ${be.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{on(),Ce()}}
              disabled=${ye.value||be.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${Ho} label="Goals" timestamp=${vi.value} source="masc_goal_list" />
          <${Ho}
            label="MDAL loops"
            timestamp=${_i.value}
            source="/api/v1/mdal/loops"
            note=${r}
          />
        </div>
      <//>

      <${T} title="Goal Pipeline" class="section">
        <${dv} />
        <${cv} />
      <//>

      ${ye.value&&nn.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:Ba.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${Bs} horizon="short" items=${t.short??[]} />
              <${Bs} horizon="mid" items=${t.mid??[]} />
              <${Bs} horizon="long" items=${t.long??[]} />
            `}

      <${T} title="MDAL Loops" class="section">
        ${be.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&i==="error"?o`
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
                  ${e.map(l=>o`<${uv} key=${l.loop_id} loop=${l} />`)}
                </div>
              `}
      <//>

      <${pv} />
    </div>
  `}const $e=v(""),Gs=v("ability_check"),Js=v("10"),Vs=v("12"),Nn=v(""),Ln=v("idle"),Kt=v(""),Pn=v("keeper-late"),Ys=v("player"),Xs=v(""),_t=v("idle"),Qs=v(null),Mn=v(""),Zs=v(""),ta=v("player"),ea=v(""),na=v(""),sa=v(""),Ze=v("20"),aa=v("20"),oa=v(""),Dn=v("idle"),Wa=v(null),or=v("overview"),ia=v("all"),ra=v("all"),la=v("all"),vv=12e4,Es=v(null),Bo=v(Date.now());function _v(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function fv(t,e){return e>0?Math.round(t/e*100):0}const gv={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},$v={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function En(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function hv(t){const e=t.trim().toLowerCase();return gv[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function yv(t){const e=t.trim().toLowerCase();return $v[e]??"상황에 따라 선택되는 전술 액션입니다."}function Gt(t){return typeof t=="object"&&t!==null}function ut(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function kt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function _n(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const bv=new Set(["str","dex","con","int","wis","cha"]);function kv(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!Gt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const r=a.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){s[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const l=Number.parseFloat(i.trim());if(Number.isFinite(l)){s[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),s}function xv(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(Ze.value.trim(),10);Number.isFinite(s)&&s>n&&(Ze.value=String(n))}function Ga(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Sv(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Av(t){or.value=t}function ir(t){const e=Es.value;return e==null||e<=t}function Cv(t){const e=Es.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function bs(){Es.value=null}function rr(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function wv(t,e){rr(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Es.value=Date.now()+vv,L("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function Wn(t){return ir(t)?(L("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Ja(t,e,n){return rr([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Tv({hp:t,max:e}){const n=fv(t,e),s=_v(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Rv({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Nv({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function lr({actor:t}){var u,_,d,f;const e=(u=t.archetype)==null?void 0:u.trim(),n=(_=t.persona)==null?void 0:_.trim(),s=(d=t.portrait)==null?void 0:d.trim(),a=(f=t.background)==null?void 0:f.trim(),i=t.traits??[],r=t.skills??[],l=Object.entries(t.stats_raw??{}).filter(([g,$])=>Number.isFinite($)).filter(([g])=>!bv.has(g.toLowerCase()));return o`
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
        <${Xt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Nv} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Tv} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Rv} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${En(e)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${l.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${l.map(([g,$])=>o`
                <span class="trpg-custom-stat-chip">${En(g)} ${$}</span>
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
                  <span class="trpg-annot-name">${En(g)}</span>
                  <span class="trpg-annot-desc">${hv(g)}</span>
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
                  <span class="trpg-annot-name">${En(g)}</span>
                  <span class="trpg-annot-desc">${yv(g)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Lv({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function cr({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Sv(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Ga(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${V} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Pv({events:t}){const e="__none__",n=ia.value,s=ra.value,a=la.value,i=Array.from(new Set(t.map(Ga).map(f=>f.trim()).filter(f=>f!==""))).sort((f,g)=>f.localeCompare(g)),r=Array.from(new Set(t.map(f=>(f.type??"").trim()).filter(f=>f!==""))).sort((f,g)=>f.localeCompare(g)),l=t.some(f=>(f.type??"").trim()===""),u=Array.from(new Set(t.map(f=>(f.phase??"").trim()).filter(f=>f!==""))).sort((f,g)=>f.localeCompare(g)),_=t.some(f=>(f.phase??"").trim()===""),d=t.filter(f=>{if(n!=="all"&&Ga(f)!==n)return!1;const g=(f.type??"").trim(),$=(f.phase??"").trim();if(s===e){if(g!=="")return!1}else if(s!=="all"&&g!==s)return!1;if(a===e){if($!=="")return!1}else if(a!=="all"&&$!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${f=>{ia.value=f.target.value}}>
          <option value="all">all</option>
          ${i.map(f=>o`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${f=>{ra.value=f.target.value}}>
          <option value="all">all</option>
          ${l?o`<option value=${e}>(none)</option>`:null}
          ${r.map(f=>o`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${f=>{la.value=f.target.value}}>
          <option value="all">all</option>
          ${_?o`<option value=${e}>(none)</option>`:null}
          ${u.map(f=>o`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{ia.value="all",ra.value="all",la.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${d.length} / 전체 ${t.length}
      </span>
    </div>
    <${cr} events=${d.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Mv({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function dr({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function Dv({state:t,nowMs:e}){var _;const n=Mt.value||((_=t.session)==null?void 0:_.room)||"",s=Ln.value,a=t.party??[];if(!a.find(d=>d.id===$e.value)&&a.length>0){const d=a[0];d&&($e.value=d.id)}const r=async()=>{var f,g;if(!n){L("Room ID가 비어 있습니다.","error");return}if(!Wn(e))return;const d=((f=t.current_round)==null?void 0:f.phase)??((g=t.session)==null?void 0:g.status)??"unknown";if(Ja("라운드 실행",n,d)){Ln.value="running";try{const $=await Dl(n);Wa.value=$,Ln.value="ok";const y=Gt($.summary)?$.summary:null,A=y?_n(y,"advanced",!1):!1,w=y?ut(y,"progress_reason",""):"";L(A?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${w?`: ${w}`:""}`,A?"success":"warning"),Ct()}catch($){Wa.value=null,Ln.value="error";const y=$ instanceof Error?$.message:"라운드 실행에 실패했습니다.";L(y,"error")}finally{bs()}}},l=async()=>{var f,g;if(!n||!Wn(e))return;const d=((f=t.current_round)==null?void 0:f.phase)??((g=t.session)==null?void 0:g.status)??"unknown";if(Ja("턴 강제 진행",n,d))try{await zl(n),L("턴을 다음 단계로 이동했습니다.","success"),Ct()}catch{L("턴 이동에 실패했습니다.","error")}finally{bs()}},u=async()=>{if(!n||!Wn(e))return;const d=$e.value.trim();if(!d){L("먼저 Actor를 선택하세요.","warning");return}const f=Number.parseInt(Js.value,10),g=Number.parseInt(Vs.value,10);if(Number.isNaN(f)||Number.isNaN(g)){L("stat/dc는 숫자여야 합니다.","warning");return}const $=Number.parseInt(Nn.value,10),y=Nn.value.trim()===""||Number.isNaN($)?void 0:$;try{await Il({roomId:n,actorId:d,action:Gs.value.trim()||"ability_check",statValue:f,dc:g,rawD20:y}),L("주사위 판정을 기록했습니다.","success"),Ct()}catch{L("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${d=>{Mt.value=d.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${$e.value}
            onChange=${d=>{$e.value=d.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(d=>o`<option value=${d.id}>${d.name} (${d.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${Gs.value}
              onInput=${d=>{Gs.value=d.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Js.value}
              onInput=${d=>{Js.value=d.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Vs.value}
              onInput=${d=>{Vs.value=d.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Nn.value}
              onInput=${d=>{Nn.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&u()}}
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

      ${s!=="idle"?o`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function Ev({state:t}){var a;const e=Mt.value||((a=t.session)==null?void 0:a.room)||"",n=Dn.value,s=async()=>{if(!e){L("Room ID가 비어 있습니다.","warning");return}const i=Mn.value.trim(),r=Zs.value.trim();if(!r&&!i){L("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt(Ze.value.trim(),10),u=Number.parseInt(aa.value.trim(),10),_=Number.isFinite(u)?Math.max(1,u):20,d=Number.isFinite(l)?Math.max(0,Math.min(_,l)):_;let f={};try{f=kv(oa.value)}catch(g){L(g instanceof Error?g.message:"능력치 JSON 오류","error");return}Dn.value="spawning";try{const g=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,$=await Ol(e,{actor_id:i||void 0,name:r||void 0,role:ta.value,idempotencyKey:g,portrait:na.value.trim()||void 0,background:sa.value.trim()||void 0,hp:d,max_hp:_,alive:d>0,stats:Object.keys(f).length>0?f:void 0}),y=typeof $.actor_id=="string"?$.actor_id.trim():"";if(!y)throw new Error("생성 응답에 actor_id가 없습니다.");const A=ea.value.trim();A&&await jl(e,y,A),$e.value=y,Kt.value=y,i||(Mn.value=""),Dn.value="ok",L(`Actor 생성 완료: ${y}`,"success"),await Ct()}catch(g){Dn.value="error",L(g instanceof Error?g.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Zs.value}
            onInput=${i=>{Zs.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${ta.value}
            onChange=${i=>{ta.value=i.target.value}}
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
            value=${ea.value}
            onInput=${i=>{ea.value=i.target.value}}
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
              value=${Mn.value}
              onInput=${i=>{Mn.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${na.value}
              onInput=${i=>{na.value=i.target.value}}
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
              value=${Ze.value}
              onInput=${i=>{Ze.value=i.target.value}}
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
              value=${aa.value}
              onInput=${i=>{const r=i.target.value;aa.value=r,xv(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${sa.value}
              onInput=${i=>{sa.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${oa.value}
              onInput=${i=>{oa.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Iv({state:t,nowMs:e}){var g;const n=Mt.value||((g=t.session)==null?void 0:g.room)||"",s=t.join_gate,a=Qs.value,i=Gt(a)?a:null,r=(t.party??[]).filter($=>$.role!=="dm"),l=Kt.value.trim(),u=r.some($=>$.id===l),_=u?l:l?"__manual__":"",d=async()=>{const $=Kt.value.trim(),y=Pn.value.trim();if(!n||!$){L("Room/Actor가 필요합니다.","warning");return}_t.value="checking";try{const A=await Fl(n,$,y||void 0);Qs.value=A,_t.value="ok",L("참가 가능 여부를 갱신했습니다.","success")}catch(A){_t.value="error";const w=A instanceof Error?A.message:"참가 가능 여부 확인에 실패했습니다.";L(w,"error")}},f=async()=>{var D,O;const $=Kt.value.trim(),y=Pn.value.trim(),A=Xs.value.trim();if(!n||!$||!y){L("Room/Actor/Keeper가 필요합니다.","warning");return}if(!Wn(e))return;const w=((D=t.current_round)==null?void 0:D.phase)??((O=t.session)==null?void 0:O.status)??"unknown";if(Ja("Mid-Join 승인 요청",n,w)){_t.value="requesting";try{const M=await ql({room_id:n,actor_id:$,keeper_name:y,role:Ys.value,...A?{name:A}:{}});Qs.value=M;const R=Gt(M)?_n(M,"granted",!1):!1,N=Gt(M)?ut(M,"reason_code",""):"";R?L("Mid-Join이 승인되었습니다.","success"):L(`Mid-Join이 거절되었습니다${N?`: ${N}`:""}`,"warning"),_t.value=R?"ok":"error",Ct()}catch(M){_t.value="error";const R=M instanceof Error?M.message:"Mid-Join 요청에 실패했습니다.";L(R,"error")}finally{bs()}}};return o`
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
            value=${_}
            onChange=${$=>{const y=$.target.value;if(y==="__manual__"){(u||!l)&&(Kt.value="");return}Kt.value=y}}
          >
            <option value="">Actor 선택</option>
            ${r.map($=>o`
              <option value=${$.id}>${$.name} (${$.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${_==="__manual__"?o`
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
            value=${Pn.value}
            onInput=${$=>{Pn.value=$.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ys.value}
            onChange=${$=>{Ys.value=$.target.value}}
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
            value=${Xs.value}
            onInput=${$=>{Xs.value=$.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${d} disabled=${_t.value==="checking"||_t.value==="requesting"}>
              ${_t.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${f} disabled=${_t.value==="checking"||_t.value==="requesting"}>
              ${_t.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${_n(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${kt(i,"effective_score",0)}/${kt(i,"required_points",0)}</span>
            ${ut(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${ut(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function ur({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function pr({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function mr(){const t=Wa.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=Gt(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(Gt).slice(-8),i=t.canon_check,r=Gt(i)?i:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(N=>typeof N=="string").slice(0,3):[],u=r&&Array.isArray(r.violations)?r.violations.filter(N=>typeof N=="string").slice(0,3):[],_=n?_n(n,"advanced",!1):!1,d=n?ut(n,"progress_reason",""):"",f=n?ut(n,"progress_detail",""):"",g=n?kt(n,"player_successes",0):0,$=n?kt(n,"player_required_successes",0):0,y=n?_n(n,"dm_success",!1):!1,A=n?kt(n,"timeouts",0):0,w=n?kt(n,"unavailable",0):0,D=n?kt(n,"reprompts",0):0,O=n?kt(n,"npc_attacks",0):0,M=n?kt(n,"keeper_timeout_sec",0):0,R=n?kt(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${_?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${_?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${y?"DM ok":"DM stalled"} / players ${g}/${$}
          </span>
        </div>
        ${d?o`<div style="margin-top:4px; font-size:12px;">${d}</div>`:null}
        ${f?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${f}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${w}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${D}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${O}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${M||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${R}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(N=>{const p=ut(N,"status","unknown"),q=ut(N,"actor_id","-"),Nt=ut(N,"role","-"),lt=ut(N,"reason",""),ct=ut(N,"action_type",""),U=ut(N,"reply","");return o`
                <div class="trpg-round-item ${p.includes("fallback")||p.includes("timeout")?"failed":"active"}">
                  <span>${q} (${Nt})</span>
                  <span style="margin-left:auto; font-size:11px;">${p}</span>
                  ${ct?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${ct}</div>`:null}
                  ${lt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${lt}</div>`:null}
                  ${U?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${U.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${ut(r,"status","unknown")}</strong>
            </div>
            ${u.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${u.map(N=>o`<div>violation: ${N}</div>`)}
                </div>`:null}
            ${l.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${l.map(N=>o`<div>warning: ${N}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function zv({state:t,nowMs:e}){var r,l,u;const n=Mt.value||((r=t.session)==null?void 0:r.room)||"",s=((l=t.current_round)==null?void 0:l.phase)??((u=t.session)==null?void 0:u.status)??"unknown",a=ir(e),i=Cv(e);return o`
    <${T} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>wv(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{bs(),L("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Ov({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Av(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function jv({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${T} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${T} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${cr} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${T} title="맵" style="margin-top:16px;">
              <${Lv} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${T} title="현재 라운드">
          <${pr} state=${t} />
        <//>

        <${T} title="기여도" style="margin-top:16px;">
          <${ur} state=${t} />
        <//>

        <${T} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>o`<${lr} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${dr} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Fv({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${T} title=${`이벤트 타임라인 (${e.length})`}>
          <${Pv} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${T} title="최근 라운드 결과">
          <${mr} />
        <//>

        <${T} title="현재 라운드" style="margin-top:16px;">
          <${pr} state=${t} />
        <//>
      </div>
    </div>
  `}function qv({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${zv} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${T} title="조작 패널">
            <${Dv} state=${t} nowMs=${e} />
          <//>

          <${T} title="Actor Spawn" style="margin-top:16px;">
            <${Ev} state=${t} />
          <//>

          <${T} title="Mid-Join Gate" style="margin-top:16px;">
            <${Iv} state=${t} nowMs=${e} />
          <//>

          <${T} title="최근 라운드 결과" style="margin-top:16px;">
            <${mr} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${T} title="기여도" style="margin-top:0;">
            <${ur} state=${t} />
          <//>

          <${T} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${lr} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${dr} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Kv(){var l,u,_,d,f;const t=pi.value,e=Sa.value;if(it(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const g=window.setInterval(()=>{Bo.value=Date.now()},1e3);return()=>{window.clearInterval(g)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Ct()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,i=or.value,r=Bo.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Mt.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((u=t.current_round)==null?void 0:u.phase)??((_=t.session)==null?void 0:_.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Ct()}>새로고침</button>
      </div>

      <${Mv} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((d=t.session)==null?void 0:d.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((f=t.current_round)==null?void 0:f.round_number)??0}</div>
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

      <${Ov} active=${i} />

      ${i==="overview"?o`<${jv} state=${t} />`:i==="timeline"?o`<${Fv} state=${t} />`:o`<${qv} state=${t} nowMs=${r} />`}
    </div>
  `}const Wo=[{id:"observe",label:"먼저 보기",description:"지금 상태와 우선순위를 먼저 읽는 운영 랜딩"},{id:"coordinate",label:"보조 공간",description:"대화, 계획, 에이전트 상태를 보조 작업 공간으로 분리"},{id:"command",label:"통제",description:"개입과 지휘를 실행하는 통제 표면"}],Va=[{id:"mission",label:"상황판",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"intervene",label:"개입",icon:"🎮",group:"command",description:"room, session, supervisor 액션을 실행하는 개입 화면"},{id:"command",label:"지휘",icon:"🧭",group:"command",description:"유닛 계층, 작전 체인, 추적 이력을 보는 상세 화면"},{id:"agents",label:"에이전트",icon:"🤖",group:"observe",description:"agent 상태, 활동 신호, 작업 배정을 보는 모니터"},{id:"board",label:"보드",icon:"💬",group:"coordinate",description:"사람과 agent 대화를 시스템 노이즈를 줄여서 보는 피드"},{id:"goals",label:"계획",icon:"🎯",group:"coordinate",description:"goal, 메트릭 루프, backlog를 보는 계획 화면"},{id:"trpg",label:"TRPG 롤플레이",icon:"⚔️",group:"command",description:"서사 세션 제어와 게임 상태"}],fn=v(!1);function Go(){fn.value=!1}function Uv(){fn.value=!fn.value}function Hv(){const t=Dt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${ks.value} events</span>
    </div>
  `}function Bv({currentTab:t,currentSectionLabel:e}){const n=Dt.value;return o`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>Snapshot</h3>
        <span class="rail-section-chip ${n?"ok":"bad"}">${n?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agents</span>
          <strong>${wt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keepers</span>
          <strong>${pe.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Tasks</span>
          <strong>${yt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Events</span>
          <strong>${ks.value}</strong>
        </div>
      </div>
      <div class="rail-snapshot-copy">
        <span>Connection ${n?"healthy":"recovering"}</span>
        <span>${e} workspace active</span>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{ue(),t==="command"&&(ce(),Ht(),mt.value==="swarm"&&Pt()),(t==="mission"||t==="overview")&&Ta(),(t==="intervene"||t==="ops")&&(Vt(),Ot()),t==="board"&&At(),t==="trpg"&&Ct(),t==="goals"&&(on(),Ce())}}
        >
          Refresh Now
        </button>
        <button class="rail-secondary-btn" onClick=${()=>tt("intervene")}>
          Open Intervene
        </button>
      </div>
    </section>
  `}function Wv(){const t=Pe.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return o`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
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
          onClick=${()=>{Vt(),Ot()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>tt("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function Gv(){const t=Z.value.tab,e=Va.find(s=>s.id===t),n=Wo.find(s=>s.id===(e==null?void 0:e.group));return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${n?o`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${Wo.map(s=>o`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${Va.filter(a=>a.group===s.id).map(a=>o`
                  <button
                    class="rail-tab-btn ${t===a.id?"active":""}"
                    onClick=${()=>tt(a.id)}
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

      <${Bv} currentTab=${t} currentSectionLabel=${(n==null?void 0:n.label)??"Observe"} />
      <${Wv} />
    </aside>
  `}function Jv(){switch(Z.value.tab){case"mission":return o`<${Os} />`;case"intervene":return o`<${Lo} />`;case"command":return o`<${rp} />`;case"overview":return o`<${Os} />`;case"ops":return o`<${Lo} />`;case"board":return o`<${em} />`;case"agents":return o`<${sv} />`;case"goals":return o`<${mv} />`;case"trpg":return o`<${Kv} />`;default:return o`<${Os} />`}}function Vv(){it(()=>{Lr(),ei(),ue();const n=qc();return Kc(),()=>{jr(),n(),Uc()}},[]),it(()=>{const n=setInterval(()=>{const s=Z.value.tab;s==="command"?(ce(),Ht(),mt.value==="swarm"&&Pt()):s==="mission"||s==="overview"?Ta():s==="intervene"||s==="ops"?(Vt(),Ot()):s==="board"?At():s==="trpg"?Ct():s==="goals"&&(on(),Ce())},15e3);return()=>{clearInterval(n)}},[]),it(()=>{const n=Z.value.tab;n==="command"&&(ce(),Ht(),mt.value==="swarm"&&Pt()),(n==="mission"||n==="overview")&&Ta(),(n==="intervene"||n==="ops")&&(Vt(),Ot()),n==="board"&&At(),n==="trpg"&&Ct(),n==="goals"&&(on(),Ce())},[Z.value.tab]);const t=Z.value.tab,e=Va.find(n=>n.id===t);return o`
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
            class="activity-panel-toggle ${fn.value?"active":""}"
            onClick=${Uv}
            title="Toggle Activity Panel"
          >
            Activity
          </button>
          <${Hv} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${Gv} />
        <main class="dashboard-main">
          ${xa.value&&!Dt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${Jv} />`}
        </main>
      </div>

      ${fn.value?o`
        <div class="activity-panel-backdrop" onClick=${Go} />
        <aside class="activity-panel">
          <div class="activity-panel-header">
            <h3>Activity Feed</h3>
            <button class="activity-panel-close" onClick=${Go}>Close</button>
          </div>
          <div class="activity-panel-body">
            <${km} />
          </div>
        </aside>
      `:null}

      <${qm} />
      <${Wm} />
      <${dp} />
    </div>
  `}const Jo=document.getElementById("app");Jo&&Ar(o`<${Vv} />`,Jo);export{ad as _};
