var cr=Object.defineProperty;var dr=(t,e,n)=>e in t?cr(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var $e=(t,e,n)=>dr(t,typeof e!="symbol"?e+"":e,n);import{e as ur,_ as pr,c as f,b as yt,y as Ct,d as Zi,G as mr}from"./vendor-Bda-OZ-N.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const o of s)if(o.type==="childList")for(const r of o.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const o={};return s.integrity&&(o.integrity=s.integrity),s.referrerPolicy&&(o.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?o.credentials="include":s.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function a(s){if(s.ep)return;s.ep=!0;const o=n(s);fetch(s.href,o)}})();var i=ur.bind(pr);const vr=["command","overview","board","goals","agents","ops","trpg"],to={tab:"overview",params:{},postId:null},fr={journal:"overview",mdal:"goals",tasks:"goals",execution:"overview",council:"board",activity:"overview"};function pi(t){return!!t&&vr.includes(t)}function mi(t){if(t)return fr[t]??t}function us(t){try{return decodeURIComponent(t)}catch{return t}}function ps(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function gr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function eo(t,e){const n=mi(t[0]),a=mi(e.tab),s=pi(n)?n:pi(a)?a:"overview";let o=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?o=us(t[2]):t[0]==="post"&&t[1]&&(o=us(t[1]))),{tab:s,params:e,postId:o}}function Xn(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return to;const n=us(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const d=n.indexOf("?");d>=0&&(a=n.slice(0,d),s=n.slice(d+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const o=ps(s),r=gr(a);return eo(r,o)}function _r(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...to,params:ps(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=ps(e.replace(/^\?/,""));return eo(a,s)}function no(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const Tt=f(Xn(window.location.hash));window.addEventListener("hashchange",()=>{Tt.value=Xn(window.location.hash)});function Et(t,e){const n={tab:t,params:{},postId:null};window.location.hash=no(n)}function $r(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function hr(){if(window.location.hash&&window.location.hash!=="#"){Tt.value=Xn(window.location.hash);return}const t=_r(window.location.pathname,window.location.search);if(t){Tt.value=t;const e=no(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",Tt.value=Xn(window.location.hash)}const vi="masc_dashboard_sse_session_id",yr=1e3,br=15e3,qt=f(!1),An=f(0),ao=f(null),Zn=f([]);function kr(){let t=sessionStorage.getItem(vi);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(vi,t)),t}const xr=200;function Sr(t,e,n="system",a={}){const s={agent:t,text:e,timestamp:Date.now(),kind:n,...a};Zn.value=[s,...Zn.value].slice(0,xr)}function ms(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function fi(t,e){const n=ms(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function St(t,e,n,a,s={}){Sr(t,e,n,{eventType:a,...s})}let It=null,Ne=null,vs=0;function so(){Ne&&(clearTimeout(Ne),Ne=null)}function Ar(){if(Ne)return;vs++;const t=Math.min(vs,5),e=Math.min(br,yr*Math.pow(2,t));Ne=setTimeout(()=>{Ne=null,io()},e)}function io(){so(),It&&(It.close(),It=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",kr());const s=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(s);It=o,o.onopen=()=>{It===o&&(vs=0,qt.value=!0)},o.onerror=()=>{It===o&&(qt.value=!1,o.close(),It=null,Ar())},o.onmessage=r=>{try{const d=JSON.parse(r.data);An.value++,ao.value=d,wr(d)}catch{}}}function wr(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":St(n,"Joined","system","agent_joined");break;case"agent_left":St(n,"Left","system","agent_left");break;case"broadcast":St(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":St(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":St(n,fi("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:ms(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":St(n,fi("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:ms(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":St(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":St(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":St(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":St(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:St(n,e,"system","unknown")}}function Tr(){so(),It&&(It.close(),It=null),qt.value=!1}function oo(){return new URLSearchParams(window.location.search)}function ro(){const t=oo(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function lo(){return{...ro(),"Content-Type":"application/json"}}const Cr=15e3,Ys=3e4,Nr=6e4,gi=new Set([408,425,429,500,502,503,504]);class wn extends Error{constructor(n){const a=n.method.toUpperCase(),s=n.timeout===!0,o=s?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);$e(this,"method");$e(this,"path");$e(this,"status");$e(this,"statusText");$e(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=s}}async function Xs(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new wn({method:r,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(s)}}function Rr(){var e,n;const t=oo();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function nt(t){const e=await Xs(t,{headers:ro()},Cr);if(!e.ok)throw new wn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Lr(t){return new Promise(e=>setTimeout(e,t))}function Dr(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function Pr(t){if(t instanceof wn)return t.timeout||typeof t.status=="number"&&gi.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=Dr(t.message);return e!==null&&gi.has(e)}async function ze(t,e,n=2){let a=0;for(;;)try{return await e()}catch(s){if(!Pr(s)||a>=n)throw s;const o=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${o}ms`,s),await Lr(o),a+=1}}async function jt(t,e,n,a=Ys){const s=await Xs(t,{method:"POST",headers:{...lo(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new wn({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.json()}async function Ir(t,e,n,a=Ys){const s=await Xs(t,{method:"POST",headers:{...lo(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new wn({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.text()}function Er(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Mr(t){var e,n,a,s,o,r,d;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const p=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(p)}return((d=(r=(o=t.result)==null?void 0:o.content)==null?void 0:r[0])==null?void 0:d.text)??""}async function ft(t,e){const n=await Ir("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Nr),a=Er(n);return Mr(a)}function Or(t="compact"){return nt(`/api/v1/dashboard?mode=${t}`)}function zr(){return nt("/api/v1/agents?limit=100")}function qr(t){const e=new URLSearchParams({limit:"200"});return e.set("include_done","true"),e.set("include_cancelled","true"),nt(`/api/v1/tasks?${e}`)}function jr(t){const e=new URLSearchParams({limit:"50"});return t!=null&&t>0&&e.set("since_seq",String(t)),nt(`/api/v1/messages?${e}`)}function Fr(t={}){return ze("fetchMdalLoops",async()=>{const e=new URLSearchParams;t.limit!=null&&e.set("limit",String(t.limit)),t.historyLimit!=null&&e.set("history_limit",String(t.historyLimit)),t.status&&e.set("status",t.status);const n=e.toString();return nt(`/api/v1/mdal/loops${n?`?${n}`:""}`)})}function Kr(){return nt("/api/v1/operator")}function Hr(){return nt("/api/v1/command-plane")}function Ur(){return nt("/api/v1/command-plane/help")}function Br(t){const e=new URLSearchParams;t&&e.set("run_id",t);const n=e.toString();return nt(`/api/v1/command-plane/swarm${n?`?${n}`:""}`)}function Wr(t,e){return jt(t,e)}function Gr(t){switch(t.action_type){case"keeper_msg":case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return Ys}}function Tn(t){return jt("/api/v1/operator/action",t,void 0,Gr(t))}function Jr(t,e){return jt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const Vr=new Set(["lodge-system","team-session"]);function Ie(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function Qr(t){return Vr.has(t.trim().toLowerCase())}function Yr(t){return t.filter(e=>!Qr(e.author))}function Xr(t){var s;const e=t.trim(),a=((s=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:s.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function co(t){if(!E(t))return null;const e=$(t.id,"").trim(),n=$(t.author,"").trim(),a=$(t.content,"").trim();if(!e||!n)return null;const s=O(t.score,0),o=O(t.votes_up,0),r=O(t.votes_down,0),d=O(t.votes,s||o-r),p=O(t.comment_count,O(t.reply_count,0)),_=(()=>{const b=t.flair;if(typeof b=="string"&&b.trim())return b.trim();if(E(b)){const C=$(b.name,"").trim();if(C)return C}return $(t.flair_name,"").trim()||void 0})(),v=$(t.created_at_iso,"").trim()||Ie(t.created_at),c=$(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Ie(t.updated_at):v),g=$(t.title,"").trim()||Xr(a);return{id:e,author:n,title:g,content:a,tags:[],votes:d,vote_balance:s,comment_count:p,created_at:v,updated_at:c,flair:_,hearth_count:O(t.hearth_count,0)}}function Zr(t){if(!E(t))return null;const e=$(t.id,"").trim(),n=$(t.post_id,"").trim(),a=$(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:$(t.content,""),created_at:Ie(t.created_at)}}async function tl(t,e){return ze("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const a=n.toString(),s=await nt(`/api/v1/board${a?`?${a}`:""}`),o=Array.isArray(s.posts)?s.posts.map(co).filter(d=>d!==null):[];return{posts:e!=null&&e.excludeSystem?Yr(o):o}})}async function el(t){return ze("fetchBoardPost",async()=>{const e=await nt(`/api/v1/board/${t}?format=flat`),n=E(e.post)?e.post:e,a=co(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},o=(Array.isArray(e.comments)?e.comments:[]).map(Zr).filter(r=>r!==null);return{...a,comments:o}})}function uo(t,e){return jt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Rr()})}function nl(t,e,n){return jt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function al(t){const e=$(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function at(...t){for(const e of t){const n=$(e,"");if(n.trim())return n.trim()}return""}function _i(t){const e=al(at(t.outcome,t.result,t.result_code));if(!e)return;const n=at(t.reason,t.reason_code,t.description,t.detail),a=at(t.summary,t.summary_ko,t.summary_en,t.note),s=at(t.details,t.details_text,t.text,t.note),o=at(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=at(t.winner_actor_id,t.winner_actor,t.actor_winner_id),d=at(t.raw_reason,t.raw_reason_code,t.error_message),p=(()=>{const c=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof c=="string"?[c]:Array.isArray(c)?c.map(l=>{if(typeof l=="string")return l.trim();if(E(l)){const g=$(l.summary,"").trim();if(g)return g;const b=$(l.text,"").trim();if(b)return b;const x=$(l.type,"").trim();return x||$(l.event_id,"").trim()}return""}).filter(l=>l.length>0):[]})(),_=(()=>{const c=O(t.turn,Number.NaN);if(Number.isFinite(c))return c;const l=O(t.turn_number,Number.NaN);if(Number.isFinite(l))return l;const g=O(t.current_turn,Number.NaN);if(Number.isFinite(g))return g;const b=O(t.round,Number.NaN);return Number.isFinite(b)?b:void 0})(),v=at(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:s||void 0,winner:o||void 0,winner_actor_id:r||void 0,evidence:p.length>0?p:void 0,raw_reason:d||void 0,turn:_,phase:v||void 0}}function sl(t,e){const n=E(t.state)?t.state:{};if($(n.status,"active").toLowerCase()!=="ended")return;const s=[...e].reverse().find(r=>E(r)?$(r.type,"")==="session.outcome":!1),o=E(n.session_outcome)?n.session_outcome:{};if(E(o)&&Object.keys(o).length>0){const r=_i(o);if(r)return r}if(E(s))return _i(E(s.payload)?s.payload:{})}function E(t){return typeof t=="object"&&t!==null}function $(t,e=""){return typeof t=="string"?t:e}function O(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function il(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function fs(t,e=!1){return typeof t=="boolean"?t:e}function Ue(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(E(e)){const n=$(e.name,"").trim(),a=$(e.id,"").trim(),s=$(e.skill,"").trim();return n||a||s}return""}).filter(e=>e.length>0):[]}function ol(t){const e={};if(!E(t)&&!Array.isArray(t))return e;if(E(t))return Object.entries(t).forEach(([n,a])=>{const s=n.trim(),o=$(a,"").trim();!s||!o||(e[s]=o)}),e;for(const n of t){if(!E(n))continue;const a=at(n.to,n.target,n.actor_id,n.name,n.id),s=at(n.relationship,n.relation,n.type,n.kind);!a||!s||(e[a]=s)}return e}function rl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function _t(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return a}const ll=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function cl(t){const e=E(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,s])=>{const o=a.trim();o&&(ll.has(o.toLowerCase())||typeof s=="number"&&Number.isFinite(s)&&(n[o]=s))}),n}function dl(t,e){if(t!=="dice.rolled")return;const n=O(e.raw_d20,0),a=O(e.total,0),s=O(e.bonus,0),o=$(e.action,"roll"),r=O(e.dc,0);return{notation:r>0?`${o} (DC ${r})`:o,rolls:n>0?[n]:[],total:a,modifier:s}}function ul(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function pl(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function ml(t,e,n,a){const s=n||e||$(a.actor_id,"")||$(a.actor_name,"");switch(t){case"turn.action.proposed":{const o=$(a.proposed_action,$(a.reply,""));return o?`${s||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=$(a.reply,$(a.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return $(a.reply,$(a.content,$(a.text,"Narration")));case"dice.rolled":{const o=$(a.action,"roll"),r=O(a.total,0),d=O(a.dc,0),p=$(a.label,""),_=s||"actor",v=d>0?` vs DC ${d}`:"",c=p?` (${p})`:"";return`${_} ${o}: ${r}${v}${c}`}case"turn.started":return`Turn ${O(a.turn,1)} started`;case"phase.changed":return`Phase: ${$(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${$(a.name,E(a.actor)?$(a.actor.name,s||"unknown"):s||"unknown")}`;case"actor.claimed":return`${$(a.keeper_name,$(a.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${$(a.keeper_name,$(a.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${O(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${O(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||$(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||$(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${$(a.reason_code,"unknown")}`;case"memory.signal":{const o=E(a.entity_refs)?a.entity_refs:{},r=$(o.requested_tier,""),d=$(o.effective_tier,""),p=fs(o.guardrail_applied,!1),_=$(a.summary_en,$(a.summary_ko,"Memory signal"));if(!r&&!d)return _;const v=r&&d?`${r}->${d}`:d||r;return`${_} [${v}${p?" (guardrail)":""}]`}case"world.event":{if($(a.event_type,"")==="canon.check"){const r=$(a.status,"unknown"),d=$(a.contract_id,"n/a");return`Canon ${r}: ${d}`}return $(a.description,$(a.summary,"World event"))}case"combat.attack":return $(a.summary,$(a.result,"Attack resolved"));case"combat.defense":return $(a.summary,$(a.result,"Defense resolved"));case"session.outcome":return $(a.summary,$(a.outcome,"Session ended"));default:{const o=ul(a);return o?`${t}: ${o}`:t}}}function vl(t,e){const n=E(t)?t:{},a=$(n.type,"event"),s=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=$(n.actor_name,"").trim()||e[s]||$(E(n.payload)?n.payload.actor_name:"",""),r=E(n.payload)?n.payload:{},d=$(n.ts,$(n.timestamp,new Date().toISOString())),p=$(n.phase,$(r.phase,"")),_=$(n.category,"");return{type:a,actor:o||s||$(r.actor_name,""),actor_id:s||$(r.actor_id,""),actor_name:o,seq:n.seq,room_id:$(n.room_id,""),phase:p||void 0,category:_||pl(a),visibility:$(n.visibility,$(r.visibility,"public")),event_id:$(n.event_id,""),content:ml(a,s,o,r),dice_roll:dl(a,r),timestamp:d}}function fl(t,e,n){var kt,xt;const a=$(t.room_id,"")||n||"default",s=E(t.state)?t.state:{},o=E(s.party)?s.party:{},r=E(s.actor_control)?s.actor_control:{},d=E(s.join_gate)?s.join_gate:{},p=E(s.contribution_ledger)?s.contribution_ledger:{},_=Object.entries(o).map(([B,Y])=>{const k=E(Y)?Y:{},Rt=_t(k,"max_hp",void 0,10),Vt=_t(k,"hp",void 0,Rt),se=_t(k,"max_mp",void 0,0),P=_t(k,"mp",void 0,0),Lt=_t(k,"level",void 0,1),ie=_t(k,"xp",void 0,0),Ln=fs(k.alive,Vt>0),Ke=r[B],He=typeof Ke=="string"?Ke:void 0,m=rl(k.role,B,He),N=il(k.generation),z=at(k.joined_at,k.joinedAt,k.started_at,k.startedAt),X=at(k.claimed_at,k.claimedAt,k.assigned_at,k.assignedAt,k.assigned_time),M=at(k.last_seen,k.lastSeen,k.last_seen_at,k.lastSeenAt,k.last_active,k.lastActive),lt=at(k.scene,k.current_scene,k.currentScene,k.world_scene,k.scene_name,k.sceneName),G=at(k.location,k.current_location,k.currentLocation,k.position,k.zone,k.area);return{id:B,name:$(k.name,B),role:m,keeper:He,archetype:$(k.archetype,""),persona:$(k.persona,""),portrait:$(k.portrait,"")||void 0,background:$(k.background,"")||void 0,traits:Ue(k.traits),skills:Ue(k.skills),stats_raw:cl(k),status:Ln?"active":"dead",generation:N,joined_at:z||void 0,claimed_at:X||void 0,last_seen:M||void 0,scene:lt||void 0,location:G||void 0,inventory:Ue(k.inventory),notes:Ue(k.notes),relationships:ol(k.relationships),stats:{hp:Vt,max_hp:Rt,mp:P,max_mp:se,level:Lt,xp:ie,strength:_t(k,"strength","str",10),dexterity:_t(k,"dexterity","dex",10),constitution:_t(k,"constitution","con",10),intelligence:_t(k,"intelligence","int",10),wisdom:_t(k,"wisdom","wis",10),charisma:_t(k,"charisma","cha",10)}}}),v=_.filter(B=>B.status!=="dead"),c=sl(t,e),l={phase_open:fs(d.phase_open,!0),min_points:O(d.min_points,3),window:$(d.window,"round_boundary_only"),last_opened_turn:typeof d.last_opened_turn=="number"?d.last_opened_turn:null,last_closed_turn:typeof d.last_closed_turn=="number"?d.last_closed_turn:null},g=Object.entries(p).map(([B,Y])=>{const k=E(Y)?Y:{};return{actor_id:B,score:O(k.score,0),last_reason:$(k.last_reason,"")||null,reasons:Ue(k.reasons)}}),b=_.reduce((B,Y)=>(B[Y.id]=Y.name,B),{}),x=e.map(B=>vl(B,b)),C=O(s.turn,1),H=$(s.phase,"round"),D=$(s.map,""),q=E(s.world)?s.world:{},R=D||$(q.ascii_map,$(q.map,"")),I=x.filter((B,Y)=>{const k=e[Y];if(!E(k))return!1;const Rt=E(k.payload)?k.payload:{};return O(Rt.turn,-1)===C}),bt=(I.length>0?I:x).slice(-12),Ft=$(s.status,"active");return{session:{id:a,room:a,status:Ft==="ended"?"ended":Ft==="paused"?"paused":"active",round:C,actors:v,created_at:((kt=x[0])==null?void 0:kt.timestamp)??new Date().toISOString()},current_round:{round_number:C,phase:H,events:bt,timestamp:((xt=x[x.length-1])==null?void 0:xt.timestamp)??new Date().toISOString()},map:R||void 0,join_gate:l,contribution_ledger:g,outcome:c,party:v,story_log:x,history:[]}}async function gl(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await nt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function _l(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([nt(`/api/v1/trpg/state${e}`),gl(t)]);return fl(n,a,t)}function $l(t){return jt("/api/v1/trpg/rounds/run",{room_id:t})}function hl(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function yl(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),jt("/api/v1/trpg/dice/roll",e)}function bl(t,e){const n=hl();return jt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function kl(t,e){var s;const n=(s=e.idempotencyKey)==null?void 0:s.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),jt("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function xl(t,e,n){return jt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Sl(t,e,n){const a=await ft("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function Al(t){const e=await ft("trpg.mid_join.request",t);return JSON.parse(e)}async function po(t,e){await ft("masc_broadcast",{agent_name:t,message:e})}async function wl(t,e,n=1){await ft("masc_add_task",{title:t,description:e,priority:n})}async function Tl(t){return ft("masc_join",{agent_name:t})}async function mo(t){await ft("masc_leave",{agent_name:t})}async function Cl(t){await ft("masc_heartbeat",{agent_name:t})}async function Nl(t=40){return(await ft("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Rl(t,e=20){return ft("masc_task_history",{task_id:t,limit:e})}async function Ll(){return ze("fetchDebates",async()=>{const t=await nt("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!E(e))return null;const n=$(e.id,"").trim(),a=$(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:$(e.status,"open"),argument_count:O(e.argument_count,0),created_at:Ie(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Dl(){return ze("fetchCouncilSessions",async()=>{const t=await nt("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!E(e))return null;const n=$(e.id,"").trim(),a=$(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:$(e.initiator,"system"),votes:O(e.votes,0),quorum:O(e.quorum,0),state:$(e.state,"open"),created_at:Ie(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Pl(t){const e=await ft("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Il(t){return ze("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await nt(`/api/v1/council/debates/${e}/summary`);if(!E(n))return null;const a=$(n.id,"").trim();return a?{id:a,topic:$(n.topic,""),status:$(n.status,"open"),support_count:O(n.support_count,0),oppose_count:O(n.oppose_count,0),neutral_count:O(n.neutral_count,0),total_arguments:O(n.total_arguments,0),created_at:Ie(n.created_at_iso??n.created_at),summary_text:$(n.summary_text,"")}:null})}function El(t,e,n){return ft("masc_keeper_msg",{name:t,message:e})}async function Ml(){try{const t=await ft("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const Ye=f(""),Ht=f({}),it=f({}),gs=f({}),_s=f({}),$s=f({}),hs=f({}),Ut=f({});function et(t,e,n){t.value={...t.value,[e]:n}}function Bt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function F(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function wt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ae(t){return typeof t=="boolean"?t:void 0}function ys(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function bs(t){return Array.isArray(t)?t.map(e=>F(e)).filter(e=>!!e):[]}function Ol(t){var n;const e=(n=F(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function zl(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Ma(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!Bt(a))continue;const s=F(a.name);if(!s)continue;const o=F(a[e]);e==="summary"?n.push({name:s,summary:o}):n.push({name:s,reason:o})}return n}function ql(t){if(!Bt(t))return null;const e=F(t.name);return e?{name:e,trigger:F(t.trigger),outcome:F(t.outcome),summary:F(t.summary),reason:F(t.reason)}:null}function jl(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Fl(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function vo(t,e,n){return F(t)??Fl(e,n)}function fo(t,e){return typeof t=="boolean"?t:e==="recover"}function ta(t){if(!Bt(t))return null;const e=F(t.health_state),n=F(t.next_action_path),a=F(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:F(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:ys(t.last_reply_at),last_reply_preview:F(t.last_reply_preview)??null,last_error:F(t.last_error)??null,next_eligible_at_s:wt(t.next_eligible_at_s)??null,recoverable:fo(t.recoverable,n),summary:vo(t.summary,e,F(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Zs(t){return Bt(t)?{hour:wt(t.hour),checked:wt(t.checked)??0,acted:wt(t.acted)??0,acted_names:bs(t.acted_names),activity_report:F(t.activity_report),quiet_hours_overridden:Ae(t.quiet_hours_overridden),skipped_reason:F(t.skipped_reason),acted_rows:Ma(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:Ma(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:Ma(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(ql).filter(e=>e!==null):[]}:null}function Kl(t){return Bt(t)?{enabled:Ae(t.enabled)??!1,interval_s:wt(t.interval_s)??0,quiet_start:wt(t.quiet_start),quiet_end:wt(t.quiet_end),quiet_active:Ae(t.quiet_active),use_planner:Ae(t.use_planner),delegate_llm:Ae(t.delegate_llm),agent_count:wt(t.agent_count),agents:bs(t.agents),last_tick_ago_s:wt(t.last_tick_ago_s)??null,last_tick_ago:F(t.last_tick_ago),total_ticks:wt(t.total_ticks),total_checkins:wt(t.total_checkins),last_skip_reason:F(t.last_skip_reason)??null,last_tick_result:Zs(t.last_tick_result),active_self_heartbeats:bs(t.active_self_heartbeats)}:null}function Hl(t){return Bt(t)?{status:t.status,diagnostic:ta(t.diagnostic)}:null}function Ul(t){return Bt(t)?{recovered:Ae(t.recovered)??!1,skipped_reason:F(t.skipped_reason)??null,before:ta(t.before),after:ta(t.after),down:t.down,up:t.up}:null}function Bl(t,e){var D,q;if(!(t!=null&&t.name))return null;const n=F((D=t.agent)==null?void 0:D.status)??F(t.status)??"unknown",a=F((q=t.agent)==null?void 0:q.error)??null,s=t.presence_keepalive??!0,o=t.keepalive_running??!1,r=t.turn_count??0,d=t.last_turn_ago_s??null,p=t.proactive_enabled??!1,_=t.proactive_cooldown_sec??0,v=t.last_proactive_ago_s??null,c=p&&v!=null?Math.max(0,_-v):null,l=r<=0||d==null?"never":d>900?"stale":"fresh",g=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,b=a??(s&&!o?"keeper keepalive is not running":null),x=n==="offline"||n==="inactive"?"offline":b?"degraded":l==="stale"?"stale":l==="never"?"idle":"healthy",C=b?jl(b):e!=null&&e.quiet_active&&l!=="fresh"?"quiet_hours":s&&!o?"disabled":r<=0?"never_started":c!=null&&c>0?"min_gap":l==="fresh"||l==="stale"?"no_recent_activity":"unknown",H=x==="offline"||x==="degraded"||x==="stale"?"recover":C==="quiet_hours"?"manual_lodge_poke":C==="unknown"?"probe":"direct_message";return{health_state:x,quiet_reason:C,next_action_path:H,last_reply_status:l,last_reply_at:g,last_reply_preview:null,last_error:b,next_eligible_at_s:c!=null&&c>0?c:null,recoverable:fo(void 0,H),summary:vo(void 0,x,C),keepalive_running:o}}function Wl(t,e){if(!Bt(t))return null;const n=Ol(t.role),a=F(t.content)??F(t.preview);if(!a)return null;const s=ys(t.ts_unix)??ys(t.timestamp);return{id:`${n}-${s??"entry"}-${e}`,role:n,label:zl(n),text:a,timestamp:s,delivery:"history"}}function Gl(t,e,n){const a=Bt(n)?n:null,s=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((o,r)=>Wl(o,r)).filter(o=>o!==null):[];return{name:t,diagnostic:ta(a==null?void 0:a.diagnostic),history:s,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function $i(t,e){const n=it.value[t]??[];it.value={...it.value,[t]:[...n,e].slice(-50)}}function Jl(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Vl(t,e){const a=(it.value[t]??[]).filter(s=>s.delivery!=="history"&&!e.some(o=>Jl(s,o)));it.value={...it.value,[t]:[...e,...a].slice(-50)}}function Ra(t,e){Ht.value={...Ht.value,[t]:e},Vl(t,e.history)}function hi(t,e){const n=Ht.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Ra(t,{...n,diagnostic:{...a,...e}})}async function ti(){Cn();try{await ve()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Kn(t){Ye.value=t.trim()}async function go(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Ht.value[n])return Ht.value[n];et(gs,n,!0),et(Ut,n,null);try{const a=await ft("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let s=null;try{s=JSON.parse(a)}catch{s=null}const o=Gl(n,a,s);return Ra(n,o),o}catch(a){const s=a instanceof Error?a.message:`Failed to inspect ${n}`;return et(Ut,n,s),null}finally{et(gs,n,!1)}}async function Ql(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const s=`local-${Date.now()}`;$i(n,{id:s,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),et(_s,n,!0),et(Ut,n,null);try{const o=await El(n,a);it.value={...it.value,[n]:(it.value[n]??[]).map(r=>r.id===s?{...r,delivery:"delivered"}:r)},$i(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),hi(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await ti()}catch(o){const r=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw it.value={...it.value,[n]:(it.value[n]??[]).map(d=>d.id===s?{...d,delivery:"error",error:r}:d)},hi(n,{last_reply_status:"error",last_error:r}),et(Ut,n,r),o}finally{et(_s,n,!1)}}async function Yl(t,e){const n=t.trim();if(!n)return null;et($s,n,!0),et(Ut,n,null);try{const a=await Tn({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),s=Hl(a.result),o=(s==null?void 0:s.diagnostic)??null;if(o){const r=Ht.value[n];Ra(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??it.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await ti(),o}catch(a){const s=a instanceof Error?a.message:`Failed to probe ${n}`;throw et(Ut,n,s),a}finally{et($s,n,!1)}}async function Xl(t,e){const n=t.trim();if(!n)return null;et(hs,n,!0),et(Ut,n,null);try{const a=await Tn({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),s=Ul(a.result),o=(s==null?void 0:s.after)??null;if(o){const r=Ht.value[n];Ra(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??it.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await ti(),o}catch(a){const s=a instanceof Error?a.message:`Failed to recover ${n}`;throw et(Ut,n,s),a}finally{et(hs,n,!1)}}function oe(t){return(t??"").trim().toLowerCase()}function dt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Hn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Dn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Be(t){return t.last_heartbeat??Dn(t.last_turn_ago_s)??Dn(t.last_proactive_ago_s)??Dn(t.last_handoff_ago_s)??Dn(t.last_compaction_ago_s)}function Zl(t){const e=t.title.trim();return e||Hn(t.content)}function tc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function ec(t,e,n,a,s={}){var q;const o=oe(t),r=e.filter(R=>oe(R.assignee)===o&&(R.status==="claimed"||R.status==="in_progress")).length,d=n.filter(R=>oe(R.from)===o).sort((R,I)=>dt(I.timestamp)-dt(R.timestamp))[0],p=a.filter(R=>oe(R.agent)===o||oe(R.author)===o).sort((R,I)=>dt(I.timestamp)-dt(R.timestamp))[0],_=(s.boardPosts??[]).filter(R=>oe(R.author)===o).sort((R,I)=>dt(I.updated_at||I.created_at)-dt(R.updated_at||R.created_at))[0],v=(s.keepers??[]).filter(R=>oe(R.name)===o&&Be(R)!==null).sort((R,I)=>dt(Be(I)??0)-dt(Be(R)??0))[0],c=d?dt(d.timestamp):0,l=p?dt(p.timestamp):0,g=_?dt(_.updated_at||_.created_at):0,b=v?dt(Be(v)??0):0,x=s.lastSeen?dt(s.lastSeen):0,C=((q=s.currentTask)==null?void 0:q.trim())||(r>0?`${r} claimed tasks`:null);if(c===0&&l===0&&g===0&&b===0&&x===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:C};const D=[d?{timestamp:d.timestamp,ts:c,text:Hn(d.content)}:null,_?{timestamp:_.updated_at||_.created_at,ts:g,text:`Post: ${Hn(Zl(_))}`}:null,v?{timestamp:Be(v),ts:b,text:tc(v)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:l,text:Hn(p.text)}:null].filter(R=>R!==null).sort((R,I)=>I.ts-R.ts)[0];return D&&D.ts>=x?{activeAssignedCount:r,lastActivityAt:D.timestamp,lastActivityText:D.text}:{activeAssignedCount:r,lastActivityAt:s.lastSeen??null,lastActivityText:C??"Presence heartbeat"}}const ht=f([]),vt=f([]),fn=f([]),Wt=f([]),ne=f(null),Ve=f(null),ks=f(new Map),qe=f([]),gn=f("hot"),le=f(!0),_o=f(null),Kt=f(""),_n=f([]),we=f(!1),$o=f(new Map),xs=f("unknown"),Ss=f(null),As=f(!1),$n=f(!1),ws=f(!1),Te=f(!1),nc=f(null),Ts=f(null),ho=f(null),yo=f(null),ac=yt(()=>ht.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle")),bo=yt(()=>{const t=vt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),La=yt(()=>{const t=new Map,e=vt.value,n=fn.value,a=Zn.value,s=qe.value,o=Wt.value;for(const r of ht.value)t.set(r.name.trim().toLowerCase(),ec(r.name,e,n,a,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:s,keepers:o}));return t});function sc(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const s=a.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const ko=yt(()=>{const t=new Map;for(const e of Wt.value)t.set(e.name,sc(e));return t}),ic=12e4;function oc(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const s=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof s=="number"?Date.now()-s*1e3:null}const xo=yt(()=>{const t=Date.now(),e=new Set,n=ks.value;for(const a of Wt.value){const s=oc(a,n);s!=null&&t-s>ic&&e.add(a.name)}return e}),ea={},rc=5e3;function Cn(){delete ea.compact,delete ea.full}function ot(t){return typeof t=="object"&&t!==null}function h(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function S(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function pe(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Cs(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function So(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function lc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Ao(t){if(!ot(t))return null;const e=h(t.name);return e?{name:e,status:So(t.status),current_task:h(t.current_task)??null,last_seen:h(t.last_seen),emoji:h(t.emoji),koreanName:h(t.koreanName)??h(t.korean_name),model:h(t.model),traits:pe(t.traits),interests:pe(t.interests),activityLevel:S(t.activityLevel)??S(t.activity_level),primaryValue:h(t.primaryValue)??h(t.primary_value)}:null}function wo(t){if(!ot(t))return null;const e=h(t.id),n=h(t.title);return!e||!n?null:{id:e,title:n,status:lc(t.status),priority:S(t.priority),assignee:h(t.assignee),description:h(t.description),created_at:h(t.created_at),updated_at:h(t.updated_at)}}function To(t){if(!ot(t))return null;const e=h(t.from)??h(t.from_agent)??"system",n=h(t.content)??"",a=h(t.timestamp)??new Date().toISOString();return{id:h(t.id),seq:S(t.seq),from:e,content:n,timestamp:a,type:h(t.type)}}function cc(t){return Array.isArray(t)?t.map(e=>{if(!ot(e))return null;const n=S(e.ts_unix);if(n==null)return null;const a=ot(e.handoff)?e.handoff:null;return{ts:n,context_ratio:S(e.context_ratio)??0,context_tokens:S(e.context_tokens)??0,context_max:S(e.context_max)??0,latency_ms:S(e.latency_ms)??0,generation:S(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:S(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:S(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?S(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function yi(t){if(!ot(t))return null;const e=h(t.health_state),n=h(t.next_action_path),a=h(t.last_reply_status);if(!e||!n||!a)return null;const s=h(t.quiet_reason)??null,o=h(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":s==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":s==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":s==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:s,next_action_path:n,last_reply_status:a,last_reply_at:Cs(t.last_reply_at)??h(t.last_reply_at)??null,last_reply_preview:h(t.last_reply_preview)??null,last_error:h(t.last_error)??null,next_eligible_at_s:S(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function dc(t,e){return(Array.isArray(t)?t:ot(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!ot(a))return null;const s=ot(a.agent)?a.agent:null,o=ot(a.context)?a.context:null,r=ot(a.metrics_window)?a.metrics_window:void 0,d=h(a.name);if(!d)return null;const p=S(a.context_ratio)??S(o==null?void 0:o.context_ratio),_=h(a.status)??h(s==null?void 0:s.status)??"offline",v=So(_),c=h(a.model)??h(a.active_model)??h(a.primary_model),l=pe(a.skill_secondary),g=o?{source:h(o.source),context_ratio:S(o.context_ratio),context_tokens:S(o.context_tokens),context_max:S(o.context_max),message_count:S(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,b=s?{name:h(s.name),exists:typeof s.exists=="boolean"?s.exists:void 0,error:h(s.error),status:h(s.status),current_task:h(s.current_task)??null,last_seen:h(s.last_seen),last_seen_ago_s:S(s.last_seen_ago_s),is_zombie:typeof s.is_zombie=="boolean"?s.is_zombie:void 0}:void 0,x=cc(a.metrics_series),C={name:d,emoji:h(a.emoji),koreanName:h(a.koreanName)??h(a.korean_name),agent_name:h(a.agent_name),trace_id:h(a.trace_id),model:c,primary_model:h(a.primary_model),active_model:h(a.active_model),next_model_hint:h(a.next_model_hint)??null,status:v,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:S(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:S(a.proactive_idle_sec),proactive_cooldown_sec:S(a.proactive_cooldown_sec),last_heartbeat:h(a.last_heartbeat)??h(s==null?void 0:s.last_seen),generation:S(a.generation),turn_count:S(a.turn_count)??S(a.total_turns),keeper_age_s:S(a.keeper_age_s),last_turn_ago_s:S(a.last_turn_ago_s),last_handoff_ago_s:S(a.last_handoff_ago_s),last_compaction_ago_s:S(a.last_compaction_ago_s),last_proactive_ago_s:S(a.last_proactive_ago_s),context_ratio:p,context_tokens:S(a.context_tokens)??S(o==null?void 0:o.context_tokens),context_max:S(a.context_max)??S(o==null?void 0:o.context_max),context_source:h(a.context_source)??h(o==null?void 0:o.source),context:g,traits:pe(a.traits),interests:pe(a.interests),primaryValue:h(a.primaryValue)??h(a.primary_value),activityLevel:S(a.activityLevel)??S(a.activity_level),memory_recent_note:h(a.memory_recent_note)??null,conversation_tail_count:S(a.conversation_tail_count),k2k_count:S(a.k2k_count),handoff_count_total:S(a.handoff_count_total)??S(a.trace_history_count),compaction_count:S(a.compaction_count),last_compaction_saved_tokens:S(a.last_compaction_saved_tokens),diagnostic:yi(a.diagnostic),skill_primary:h(a.skill_primary)??null,skill_secondary:l,skill_reason:h(a.skill_reason)??null,metrics_series:x.length>0?x:void 0,metrics_window:r,agent:b};return C.diagnostic=yi(a.diagnostic)??Bl(C,(e==null?void 0:e.lodge)??null),C}).filter(a=>a!==null)}function uc(t){return ot(t)?{...t,lodge:Kl(t.lodge)??void 0}:null}function pc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function mc(t){if(!ot(t))return null;const e=S(t.iteration);if(e==null)return null;const n=S(t.metric_before)??0,a=S(t.metric_after)??n,s=ot(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:a,delta:S(t.delta)??a-n,changes:h(t.changes)??"",failed_attempts:h(t.failed_attempts)??"",next_suggestion:h(t.next_suggestion)??"",elapsed_ms:S(t.elapsed_ms)??0,cost_usd:S(t.cost_usd)??null,evidence:s?{worker_engine:(s.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:h(s.worker_model)??"",tool_call_count:S(s.tool_call_count)??0,tool_names:pe(s.tool_names)??[],session_id:h(s.session_id)??"",evidence_status:s.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function vc(t){var o,r;if(!ot(t))return null;const e=h(t.loop_id);if(!e)return null;const n=S(t.baseline_metric)??0,a=Array.isArray(t.history)?t.history.map(mc).filter(d=>d!==null):[],s=S(t.current_metric)??((o=a[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:h(t.profile)??"unknown",status:pc(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:h(t.error_message)??h(t.error_reason)??null,stop_reason:h(t.stop_reason)??h(t.reason)??null,current_iteration:S(t.current_iteration)??((r=a[0])==null?void 0:r.iteration)??0,max_iterations:S(t.max_iterations)??0,baseline_metric:n,current_metric:s,target:h(t.target)??"",stagnation_streak:S(t.stagnation_streak)??0,stagnation_limit:S(t.stagnation_limit)??0,elapsed_seconds:S(t.elapsed_seconds)??0,updated_at:Cs(t.updated_at)??null,stopped_at:Cs(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:h(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:S(t.latest_tool_call_count)??0,latest_tool_names:pe(t.latest_tool_names)??[],session_id:h(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:a}}async function ve(t="full"){var a,s,o;const e=Date.now(),n=ea[t];if(!(n&&e-n.time<rc)){As.value=!0;try{const r=await Or(t);ea[t]={data:r,time:e},ht.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(Ao).filter(p=>p!==null),vt.value=(Array.isArray((s=r.tasks)==null?void 0:s.tasks)?r.tasks.tasks:[]).map(wo).filter(p=>p!==null),fn.value=(Array.isArray((o=r.messages)==null?void 0:o.messages)?r.messages.messages:[]).map(To).filter(p=>p!==null);const d=uc(r.status);ne.value=d,Wt.value=dc(r.keepers,d),Ve.value=r.perpetual??null,nc.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{As.value=!1}}}async function fc(){try{const t=await zr(),e=(Array.isArray(t.agents)?t.agents:[]).map(Ao).filter(s=>s!==null),n=ht.value,a=new Map(n.map(s=>[s.name,s]));ht.value=e.map(s=>{const o=a.get(s.name);return o?{...o,status:s.status,current_task:s.current_task}:s})}catch(t){console.error("Agents selective fetch error:",t)}}async function gc(){try{const t=await qr({includeDone:!0,includeCancelled:!0}),e=(Array.isArray(t.tasks)?t.tasks:[]).map(wo).filter(s=>s!==null),n=vt.value,a=new Map(n.map(s=>[s.id,s]));vt.value=e.map(s=>{const o=a.get(s.id);return o?{...o,status:s.status,priority:s.priority??o.priority,assignee:s.assignee??o.assignee}:s})}catch(t){console.error("Tasks selective fetch error:",t)}}async function _c(){try{const t=fn.value,e=t.reduce((r,d)=>Math.max(r,d.seq??0),0),n=await jr(e),a=(Array.isArray(n.messages)?n.messages:[]).map(To).filter(r=>r!==null);if(a.length===0)return;const s=new Set(t.map(r=>r.seq).filter(r=>r!=null)),o=a.filter(r=>r.seq==null||!s.has(r.seq));if(o.length>0){const r=[...t,...o];fn.value=r.length>500?r.slice(-500):r}}catch(t){console.error("Messages selective fetch error:",t)}}async function Ot(){$n.value=!0;try{const t=await tl(gn.value,{excludeSystem:le.value});qe.value=t.posts??[],Ts.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{$n.value=!1}}async function zt(){var t;ws.value=!0;try{const e=Kt.value||((t=ne.value)==null?void 0:t.room)||"default";Kt.value||(Kt.value=e);const n=await _l(e);_o.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{ws.value=!1}}async function hn(){we.value=!0;try{const t=await Ml();_n.value=Array.isArray(t)?t:[],ho.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{we.value=!1}}async function Ee(){Te.value=!0;try{const t=await Fr(),e=Array.isArray(t.loops)?t.loops:[],n=new Map;for(const a of e){const s=vc(a);s&&n.set(s.loop_id,s)}$o.value=n,yo.value=new Date().toISOString(),Ss.value=null,xs.value=n.size===0?"idle":"ready"}catch(t){console.error("MDAL fetch error:",t),xs.value="error",Ss.value=t instanceof Error?t.message:String(t)}finally{Te.value=!1}}let Un=null;function $c(t){Un=t}const Re={};function re(t,e,n=500){Re[t]||(Re[t]=setTimeout(()=>{e(),delete Re[t]},n))}function hc(){const t=ao.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(ks.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),ks.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&re("agents",fc),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&re("tasks",gc),e.type==="broadcast"&&re("messages",_c),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&re("dashboard",()=>{Cn(),ve()}),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&re("board",Ot),e.type.startsWith("decision_")&&re("council",()=>Un==null?void 0:Un()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&re("mdal",Ee,350)}});return()=>{t();for(const e of Object.keys(Re))clearTimeout(Re[e]),delete Re[e]}}let Xe=null;function yc(){Xe||(Xe=setInterval(()=>{qt.value||Cn(),ve()},1e4))}function bc(){Xe&&(clearInterval(Xe),Xe=null)}function w({title:t,class:e,children:n}){return i`
    <div class="card ${e??""}">
      ${t?i`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function Nt({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function kc(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const o=Math.floor(s/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function j({timestamp:t}){const e=kc(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return i`<span class="time-ago" title=${n}>${e}</span>`}function J(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Z(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function ce(t){return(t??"").trim().toLowerCase()}function st(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function Mt(t){return typeof t!="number"||Number.isNaN(t)?3:t}function ei(t){const e=Mt(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}let xc=0;const de=f([]);function A(t,e="success",n=4e3){const a=++xc;de.value=[...de.value,{id:a,message:t,type:e}],setTimeout(()=>{de.value=de.value.filter(s=>s.id!==a)},n)}function Sc(t){de.value=de.value.filter(e=>e.id!==t)}function Ac(){const t=de.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Sc(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const wc="masc_dashboard_agent_name",je=f(null),na=f(!1),yn=f(""),aa=f([]),bn=f([]),Le=f(""),Ze=f(!1);function De(t){je.value=t,ni()}function bi(){je.value=null,yn.value="",aa.value=[],bn.value=[],Le.value=""}function Tc(){const t=je.value;return t?ht.value.find(e=>e.name===t)??null:null}function Co(t){return t?vt.value.filter(e=>e.assignee===t):[]}async function ni(){const t=je.value;if(t){na.value=!0,yn.value="",aa.value=[],bn.value=[];try{const e=await Nl(80);aa.value=e.filter(s=>s.includes(t)).slice(0,20);const n=Co(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const o=await Rl(s.id,25);return{taskId:s.id,text:o.trim()}}catch(o){const r=o instanceof Error?o.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));bn.value=a}catch(e){yn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{na.value=!1}}}async function ki(){var a;const t=je.value,e=Le.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(wc))==null?void 0:a.trim())||"dashboard";Ze.value=!0;try{await po(n,`@${t} ${e}`),Le.value="",A(`Mention sent to ${t}`,"success"),ni()}catch(s){const o=s instanceof Error?s.message:"Failed to send mention";A(o,"error")}finally{Ze.value=!1}}function Cc({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Nt} status=${t.status} />
    </div>
  `}function Nc({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Rc(){var s,o,r,d;const t=je.value;if(!t)return null;const e=Tc(),n=Co(t),a=aa.value;return i`
    <div
      class="agent-detail-overlay"
      onClick=${p=>{p.target.classList.contains("agent-detail-overlay")&&bi()}}
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
                        <${Nt} status=${e.status} />
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
                ${(d=e==null?void 0:e.interests)==null?void 0:d.map(p=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${p}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?i`
                    ${e.current_task?i`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?i`<span>Last seen: <${j} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{ni()}} disabled=${na.value}>
              ${na.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${bi}>Close</button>
          </div>
        </div>

        ${yn.value?i`<div class="council-error">${yn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${w} title="Assigned Tasks">
            ${n.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${n.map(p=>i`<${Cc} key=${p.id} task=${p} />`)}</div>`}
          <//>

          <${w} title="Recent Activity">
            ${a.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${a.map((p,_)=>i`<div key=${_} class="agent-activity-line">${p}</div>`)}</div>`}
          <//>
        </div>

        <${w} title="Task History">
          ${bn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${bn.value.map(p=>i`<${Nc} key=${p.taskId} row=${p} />`)}</div>`}
        <//>

        <${w} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Le.value}
              onInput=${p=>{Le.value=p.target.value}}
              onKeyDown=${p=>{p.key==="Enter"&&ki()}}
              disabled=${Ze.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{ki()}}
              disabled=${Ze.value||Le.value.trim()===""}
            >
              ${Ze.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const sa=600*1e3,Bn=1200*1e3;function No(t){switch(t){case"in_progress":return"In Progress";case"claimed":return"Claimed";case"done":return"Done";case"cancelled":return"Cancelled";default:return"Todo"}}function Ro(t){switch(t){case"dispatchable":return"Dispatch";case"drift":return"Drift";case"quiet":return"Quiet";case"offline":return"Offline";default:return"Loaded"}}function Lc(t){return t.updated_at??t.created_at??null}function xi(t,e,n){var C,H;const a=ce(t.assignee),s=a?e.get(a)??null:null,o=s?n.get(a)??null:null,r=(o==null?void 0:o.lastActivityAt)??(s==null?void 0:s.last_seen)??null,d=r?Math.max(0,Date.now()-J(r)):Number.POSITIVE_INFINITY,p=st(t.description),_=st(s==null?void 0:s.current_task)??(o==null?void 0:o.lastActivityText)??null,v=t.status==="claimed"||t.status==="in_progress";let c="ok",l="Fresh owner coverage",g=_??p??t.id,b=!1,x=!1;return t.status==="todo"?t.assignee?s?s.status==="offline"||s.status==="inactive"?(b=!0,c="bad",l="Assigned owner is offline",g="Queue item is blocked until ownership changes."):d>sa?(c="warn",l="Owner exists but live signal is quiet",g=_??"Owner may need a nudge before pickup."):((o==null?void 0:o.activeAssignedCount)??0)>0||(C=s.current_task)!=null&&C.trim()?(c="warn",l="Owner is already carrying active work",g=_??`${(o==null?void 0:o.activeAssignedCount)??0} active tasks already assigned.`):(l="Ready and covered by a fresh operator",g=_??p??"This can be picked up immediately."):(b=!0,c="bad",l="Assigned owner is not present in the room",g="Reassign or bring the owner back online."):(b=!0,c=Mt(t.priority)<=2?"bad":"warn",l=Mt(t.priority)<=2?"Urgent ready work has no owner":"Ready work has no owner",g="Assign an agent before this queue item slips."):v&&(t.assignee?s?s.status==="offline"||s.status==="inactive"?(b=!0,c="bad",l="Assigned owner is offline",g=_??"Execution has no live operator right now."):d>Bn?(x=!0,c="bad",l="Assigned owner has gone quiet",g=_??"Fresh operator signal is missing."):d>sa?(x=!0,c="warn",l="Execution has been quiet for too long",g=_??"Check whether this work is blocked."):(H=s.current_task)!=null&&H.trim()?(l="Execution has fresh owner coverage",g=_??p??t.id):(c="warn",l=t.status==="claimed"?"Claimed work is waiting for explicit focus":"Owner is live but current_task is empty",g=_??"Task state and agent focus are drifting apart."):(b=!0,c="bad",l="Assigned owner is not active in the room",g="Execution is orphaned until ownership is restored."):(b=!0,c="bad",l="Active work has no assignee",g="Claim or reassign this task immediately.")),{task:t,assigneeAgent:s,motion:o,tone:c,note:l,focus:g,lastSignalAt:r,lastTouchedAt:Lc(t),ownerGap:b,quiet:x}}function Dc(t,e){var l;const n=e.get(ce(t.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},a=n.lastActivityAt??t.last_seen??null,s=a?Math.max(0,Date.now()-J(a)):Number.POSITIVE_INFINITY,o=!!((l=t.current_task)!=null&&l.trim()),r=n.activeAssignedCount,d=o||r>0;let p="loaded",_="ok",v="Healthy active load",c=st(t.current_task)??n.lastActivityText??"Ready for assignment";return t.status==="offline"||t.status==="inactive"?(p="offline",_="bad",v="Agent is unavailable"):d&&s>Bn?(p="quiet",_="bad",v="Working without a fresh signal"):r>0&&!o?(p="drift",_="warn",v="Claimed work exists but current_task is empty",c=`${r} active tasks need explicit focus.`):o&&r===0?(p="drift",_="warn",v="current_task has no matching claimed work",c=st(t.current_task)??"Task metadata and operator state drifted."):!d&&s<=sa?(p="dispatchable",_="ok",v="Fresh signal and no active load",c=n.lastActivityText??"Ready for assignment."):d?s>sa&&(p="loaded",_="warn",v="Execution load is healthy but slightly quiet",c=st(t.current_task)??`${r} active tasks in flight.`):(p="quiet",_=s>Bn?"bad":"warn",v=s>Bn?"No fresh signal while idle":"Reachable, but not freshly active",c=n.lastActivityText??"Likely available after a quick check-in."),{agent:t,motion:n,tone:_,state:p,note:v,focus:c,lastSignalAt:a,activeTaskCount:r}}function We({label:t,value:e,color:n,caption:a}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?i`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Pc({item:t}){return i`
    <div class="execution-alert ${t.tone}">
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="task"?ei(t.taskRow.task.priority):Ro(t.agentRow.state)}
        </span>
        ${t.kind==="task"?i`<span>${No(t.taskRow.task.status)}</span>`:i`<span>${t.agentRow.agent.name}</span>`}
        ${t.timestamp?i`<span><${j} timestamp=${t.timestamp} /></span>`:i`<span>No signal</span>`}
      </div>
    </div>
  `}function Si({row:t}){var e;return i`
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
        ${t.assigneeAgent?i`<${Nt} status=${t.assigneeAgent.status} />`:i`<span class="monitor-sub">No owner</span>`}
        <span class="monitor-pill ${t.tone}">${No(t.task.status)}</span>
      </div>

      <div class="monitor-meta">
        ${t.task.assignee?i`<span>Owner ${t.task.assignee}</span>`:i`<span>Unassigned</span>`}
        ${t.lastTouchedAt?i`<span>Touched <${j} timestamp=${t.lastTouchedAt} /></span>`:null}
        ${t.lastSignalAt?i`<span>Signal <${j} timestamp=${t.lastSignalAt} /></span>`:i`<span>No live signal</span>`}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${(e=t.assigneeAgent)!=null&&e.current_task&&st(t.assigneeAgent.current_task)!==t.focus?i`<div class="monitor-footnote">Owner focus: ${st(t.assigneeAgent.current_task)}</div>`:null}
    </div>
  `}function Ic({row:t}){const{agent:e}=t;return i`
    <button class="monitor-row ${t.tone}" onClick=${()=>De(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Nt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Ro(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?i`<span>Signal <${j} timestamp=${t.lastSignalAt} /></span>`:i`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
    </button>
  `}function Ec(){const t=ht.value,e=vt.value,n=new Map(t.map(c=>[ce(c.name),c])),a=La.value,s=e.filter(c=>c.status==="claimed"||c.status==="in_progress").map(c=>xi(c,n,a)).sort((c,l)=>{const g=Z(l.tone)-Z(c.tone);return g!==0?g:J(l.lastSignalAt??l.lastTouchedAt)-J(c.lastSignalAt??c.lastTouchedAt)}),o=e.filter(c=>c.status==="todo").map(c=>xi(c,n,a)).sort((c,l)=>{const g=Z(l.tone)-Z(c.tone);if(g!==0)return g;const b=Mt(c.task.priority)-Mt(l.task.priority);return b!==0?b:J(c.lastTouchedAt)-J(l.lastTouchedAt)}),r=t.map(c=>Dc(c,a)).filter(c=>c.state==="dispatchable"||c.state==="drift"||c.state==="quiet").sort((c,l)=>{if(c.state==="dispatchable"&&l.state!=="dispatchable")return-1;if(l.state==="dispatchable"&&c.state!=="dispatchable")return 1;const g=Z(l.tone)-Z(c.tone);return g!==0?g:J(l.lastSignalAt)-J(c.lastSignalAt)}),d=[...s.filter(c=>c.tone!=="ok").map(c=>({kind:"task",key:`active-${c.task.id}`,tone:c.tone,title:c.task.title,subtitle:`${c.note} · ${c.focus}`,timestamp:c.lastSignalAt??c.lastTouchedAt,taskRow:c})),...o.filter(c=>c.tone==="bad").map(c=>({kind:"task",key:`ready-${c.task.id}`,tone:c.tone,title:c.task.title,subtitle:`${c.note} · ${c.focus}`,timestamp:c.lastTouchedAt,taskRow:c})),...r.filter(c=>c.state==="drift"||c.tone==="bad").map(c=>({kind:"agent",key:`agent-${c.agent.name}`,tone:c.tone,title:c.agent.name,subtitle:`${c.note} · ${c.focus}`,timestamp:c.lastSignalAt,agentRow:c}))].sort((c,l)=>{const g=Z(l.tone)-Z(c.tone);return g!==0?g:J(l.timestamp)-J(c.timestamp)}).slice(0,8),p=r.filter(c=>c.state==="dispatchable"),_=[...s,...o].filter(c=>c.ownerGap),v=s.filter(c=>c.quiet);return i`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${We} label="Active work" value=${s.length} color="#fbbf24" caption="claimed + in progress" />
        <${We} label="Needs intervention" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="stalled or drifting now" />
        <${We} label="Ownership gaps" value=${_.length} color=${_.length>0?"#fb7185":"#4ade80"} caption="missing or unavailable owners" />
        <${We} label="Dispatchable agents" value=${p.length} color="#22d3ee" caption="fresh signal, no active load" />
        <${We} label="Quiet execution" value=${v.length} color=${v.length>0?"#fbbf24":"#4ade80"} caption="active tasks with aging signals" />
      </div>

      <${w} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs a nudge right now</h2>
          <p class="monitor-subheadline">Severity comes first, then the freshest evidence we have about the stall or drift.</p>
        </div>
        <div class="monitor-alert-list">
          ${d.length===0?i`<div class="empty-state">No active execution risks right now</div>`:d.map(c=>i`<${Pc} key=${c.key} item=${c} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${w} title="Ready Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Ready work, sorted by dispatch risk</h2>
            <p class="monitor-subheadline">Ownerless or owner-unavailable items float to the top before healthy assigned queue items.</p>
          </div>
          <div class="monitor-list">
            ${o.length===0?i`<div class="empty-state">No ready tasks in the queue</div>`:o.slice(0,10).map(c=>i`<${Si} key=${c.task.id} row=${c} />`)}
          </div>
        <//>

        <${w} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity appears first. Task-state drift stays visible so owners can clean up metadata fast.</p>
          </div>
          <div class="monitor-list">
            ${r.length===0?i`<div class="empty-state">No agent capacity or drift signals right now</div>`:r.map(c=>i`<${Ic} key=${c.agent.name} row=${c} />`)}
          </div>
        <//>
      </div>

      <${w} title="Active Execution Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Claimed and in-progress work</h2>
          <p class="monitor-subheadline">Rows are sorted by risk first, then by the freshest operator signal tied to each task.</p>
        </div>
        <div class="monitor-list">
          ${s.length===0?i`<div class="empty-state">No active execution tasks</div>`:s.map(c=>i`<${Si} key=${c.task.id} row=${c} />`)}
        </div>
      <//>
    </div>
  `}function Mc(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Oc(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function zc(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Ai(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function Lo(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function qc(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Do(t){if(!t)return null;const e=Ht.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function Po({keeper:t,showRawStatus:e=!1}){if(Ct(()=>{t!=null&&t.name&&go(t.name)},[t==null?void 0:t.name]),!t)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Ht.value[t.name],a=Do(t),s=gs.value[t.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(a==null?void 0:a.health_state)??"unknown"}</span>
        <span class="pill">${Mc(a==null?void 0:a.quiet_reason)}</span>
        <span class="pill">next ${Oc((a==null?void 0:a.next_action_path)??"direct_message")}</span>
        ${s?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(a==null?void 0:a.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(a==null?void 0:a.last_reply_status)??"unknown"}
        ${a!=null&&a.last_reply_at?i` · ${Lo(a.last_reply_at)}`:null}
        ${a!=null&&a.next_eligible_at_s?i` · next eligible ${qc(a.next_eligible_at_s)}`:null}
      </div>
      ${a!=null&&a.last_error?i`<div class="control-status-copy control-error-copy">${a.last_error}</div>`:null}
      ${e?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Io({keeperName:t,placeholder:e}){const[n,a]=Zi("");Ct(()=>{t&&go(t)},[t]);const s=it.value[t]??[],o=_s.value[t]??!1,r=Ut.value[t],d=async()=>{const p=n.trim();if(!(!t||!p)){a("");try{await Ql(t,p)}catch(_){const v=_ instanceof Error?_.message:`Failed to message ${t}`;A(v,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${s.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:s.map(p=>i`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Ai(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${Ai(p)}`}>${zc(p)}</span>
                  ${p.timestamp?i`<span class="keeper-conversation-time">${Lo(p.timestamp)}</span>`:null}
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
            onClick=${()=>{d()}}
            disabled=${o||n.trim()===""||!t}
          >
            ${o?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${r?i`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function Eo({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const a=Do(e),s=$s.value[e.name]??!1,o=hs.value[e.name]??!1,r=(a==null?void 0:a.next_action_path)??"direct_message",d=(a==null?void 0:a.recoverable)??r==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{Yl(e.name,t).catch(p=>{const _=p instanceof Error?p.message:`Failed to probe ${e.name}`;A(_,"error")})}}
        disabled=${s||!t.trim()}
      >
        ${s?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{Xl(e.name,t).catch(p=>{const _=p instanceof Error?p.message:`Failed to recover ${e.name}`;A(_,"error")})}}
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
  `}const ai=f(null);function ia(t){ai.value=t,Kn(t.name)}function wi(){ai.value=null}const ke=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function jc(t){if(!t)return 0;const e=ke.findIndex(n=>n.level===t);return e>=0?e:0}function Fc({keeper:t}){const e=jc(t.autonomy_level),n=ke[e]??ke[0];if(!n)return null;const a=(e+1)/ke.length*100;return i`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${ke.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${ke.map((s,o)=>i`
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
            <strong><${j} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?i`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Wn(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Kc({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",s=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${s.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Wn(t.context_tokens)}</div>
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
  `}function Hc({keeper:t}){var v,c;const e=t.metrics_series??[];if(e.length<2){const l=(((v=t.context)==null?void 0:v.context_ratio)??0)*100,g=l>85?"#ef4444":l>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${l.toFixed(1)}%;background:${g}"></div>
        </div>
        <span class="chart-pct">${l.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,o=e.length,r=e.map((l,g)=>{const b=s+g/(o-1)*(n-2*s),x=a-s-(l.context_ratio??0)*(a-2*s);return{x:b,y:x,p:l}}),d=r.map(({x:l,y:g})=>`${l.toFixed(1)},${g.toFixed(1)}`).join(" "),p=(((c=e[e.length-1])==null?void 0:c.context_ratio)??0)*100,_=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${s}" y1="${(a-s-.5*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.5*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.7*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.7*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.85*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.85*(a-2*s)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:l})=>l.is_handoff).map(({x:l})=>i`
          <line x1="${l.toFixed(1)}" y1="${s}" x2="${l.toFixed(1)}" y2="${a-s}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${d}" fill="none" stroke="${_}" stroke-width="1.5"/>
        ${r.filter(({p:l})=>l.is_compaction).map(({x:l,y:g})=>i`
          <circle cx="${l.toFixed(1)}" cy="${g.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}const Oa=f("");function Uc({keeper:t}){var s,o,r,d;const e=Oa.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],a=e?n.filter(p=>p.title.toLowerCase().includes(e)||p.key.includes(e)||p.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Oa.value}
        onInput=${p=>{Oa.value=p.target.value}}
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
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Wn(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Wn(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Wn(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((d=t.context)==null?void 0:d.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Bc({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
  `}function Wc({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Gc({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function Ti({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function za(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Jc({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:za(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:za(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:za(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(a=>i`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function Mo(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function Vc(){try{const t=await Tn({actor:Mo(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Zs(t.result);Cn(),await ve(),e!=null&&e.skipped_reason?A(e.skipped_reason,"warning"):A(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";A(e,"error")}}function Qc({keeper:t}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Po} keeper=${t} />
          <${Eo}
            actor=${Mo()}
            keeper=${t}
            onPokeLodge=${()=>{Vc()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Io}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function Yc(){var e,n,a;const t=ai.value;return t?i`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&wi()}}
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
            <${Nt} status=${t.status} />
            ${t.model?i`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>wi()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Kc} keeper=${t} />

        ${""}
        <${Hc} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${w} title="Field Dictionary">
            <${Uc} keeper=${t} />
          <//>

          ${""}
          <${w} title="Profile">
            <${Ti} traits=${t.traits??[]} label="Traits" />
            <${Ti} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${j} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?i`
              <${w} title="Autonomy">
                <${Fc} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?i`
              <${w} title="TRPG Stats">
                <${Bc} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${w} title="Equipment (${t.inventory.length})">
                <${Wc} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${w} title="Relationships (${Object.keys(t.relationships).length})">
                <${Gc} rels=${t.relationships} />
              <//>
            `:null}

          <${w} title="Runtime Signals">
            <${Jc} keeper=${t} />
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
              ${t.memory_recent_note?i`
                  <div class="keeper-memory-note">
                    ${t.memory_recent_note}
                  </div>
                `:i`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${Qc} keeper=${t} />
      </div>
    </div>
  `:null}const Me=f(!1);function Xc(){Me.value=!0}function Ci(){Me.value=!1}function Zc(){Me.value=!Me.value}const qa=600*1e3,ja=1200*1e3,Ni=.8,Fa=f("triage");function he(t){const e=(t??"").toLowerCase();return e==="bad"?"bad":e==="warn"?"warn":"ok"}function Pn(t){switch(t){case"bad":return"#fb7185";case"warn":return"#fbbf24";default:return"#4ade80"}}function Ri(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function Li(t){if(t==null||!Number.isFinite(t))return"unknown";if(t<60)return`${Math.round(t)}s`;const e=Math.round(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function td(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function Ka(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function ed(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function nd(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function ad(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function sd(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Ri(t.quiet_start)}-${Ri(t.quiet_end)} KST are active.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${Li(t.interval_s)}, but no tick has run yet.`:`Lodge ticks every ${Li(t.interval_s)} with planner ${t.use_planner?"on":"off"} and delegated LLM ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled.":"Lodge runtime status is unavailable in the current dashboard payload."}function Di(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function ye({label:t,value:e,color:n,caption:a}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
      ${a?i`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function id({item:t}){return i`
    <button class="monitor-alert ${t.tone}" onClick=${t.action}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.detail}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">${t.tone==="bad"?"Act now":t.tone==="warn"?"Watch":"Stable"}</span>
        ${t.timestamp?i`<span><${j} timestamp=${t.timestamp} /></span>`:null}
      </div>
    </button>
  `}function Ha({tone:t,title:e,subtitle:n,meta:a,focus:s,onClick:o}){return i`
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
  `}function Pi(){var bt,Ft,Jt,kt,xt,B,Y,k,Rt,Vt,se,P,Lt,ie,Ln,Ke,He;const t=ne.value,e=ht.value,n=vt.value,a=Wt.value,s=bo.value,o=(bt=t==null?void 0:t.monitoring)==null?void 0:bt.board,r=(Ft=t==null?void 0:t.monitoring)==null?void 0:Ft.council,d=qt.value,p=new Map(e.map(m=>[ce(m.name),m])),_=La.value,v=e.map(m=>{var ui;const N=_.get(ce(m.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},z=N.lastActivityAt??m.last_seen??null,X=z?Math.max(0,Date.now()-J(z)):Number.POSITIVE_INFINITY,M=N.activeAssignedCount,lt=!!((ui=m.current_task)!=null&&ui.trim()),G=lt||M>0;let V="ok",gt="Fresh and ready",ge=!1,_e=!1;return m.status==="offline"||m.status==="inactive"?(V=G?"bad":"warn",gt=G?"Load without an available owner":"Offline"):G&&X>ja?(V="bad",gt="Execution is stale"):M>0&&!lt?(V="warn",gt="Claimed work has no current_task",_e=!0):lt&&M===0?(V="warn",gt="current_task has no claimed work",_e=!0):!G&&X<=qa?(V="ok",gt="Dispatchable now",ge=!0):!G&&X>ja?(V="warn",gt="Idle but not freshly active"):G&&X>qa&&(V="warn",gt="Execution is getting quiet"),{agent:m,lastSignalAt:z,activeTaskCount:M,tone:V,note:gt,focus:st(m.current_task)??N.lastActivityText??(ge?"Ready for assignment.":"Waiting for a clearer signal."),dispatchable:ge,drift:_e}}).sort((m,N)=>{const z=Z(N.tone)-Z(m.tone);return z!==0?z:J(N.lastSignalAt)-J(m.lastSignalAt)}),c=a.map(m=>{var V;const N=ko.value.get(m.name)??"idle",z=xo.value.has(m.name),X=m.context_ratio??0,M=m.diagnostic??null;let lt="ok",G="Healthy keeper";return z||m.status==="offline"||N==="handoff-imminent"||(M==null?void 0:M.health_state)==="offline"||(M==null?void 0:M.health_state)==="degraded"?(lt="bad",G=st(M==null?void 0:M.summary,56)??(z?"Heartbeat stale":N==="handoff-imminent"?"Handoff imminent":(M==null?void 0:M.health_state)==="degraded"?"Keeper degraded":"Keeper offline")):((M==null?void 0:M.health_state)==="stale"||X>=Ni||N==="preparing"||N==="compacting")&&(lt="warn",G=st(M==null?void 0:M.summary,56)??(X>=Ni?"High context pressure":`Lifecycle ${N}`)),{keeper:m,tone:lt,note:G,focus:st(M==null?void 0:M.summary,120)??st((V=m.agent)==null?void 0:V.current_task)??m.skill_primary??m.last_proactive_reason??m.memory_recent_note??"No active focus",timestamp:m.last_heartbeat??null}}).sort((m,N)=>{const z=Z(N.tone)-Z(m.tone);return z!==0?z:J(N.timestamp)-J(m.timestamp)}),l=n.filter(m=>m.status==="todo"||m.status==="claimed"||m.status==="in_progress").map(m=>{var ge,_e;const N=m.assignee?p.get(ce(m.assignee))??null:null,z=N?_.get(ce(N.name))??null:null,X=(z==null?void 0:z.lastActivityAt)??(N==null?void 0:N.last_seen)??null,M=X?Math.max(0,Date.now()-J(X)):Number.POSITIVE_INFINITY,lt=m.status==="claimed"||m.status==="in_progress";let G="ok",V="Covered",gt=!1;return m.assignee?!N||N.status==="offline"||N.status==="inactive"?(G="bad",V="Assigned owner is unavailable",gt=!0):lt&&M>ja?(G="bad",V="Execution has lost a fresh signal"):lt&&M>qa?(G="warn",V="Execution is drifting quiet"):m.status==="todo"&&Mt(m.priority)<=2&&!((ge=N.current_task)!=null&&ge.trim())&&((z==null?void 0:z.activeAssignedCount)??0)===0?(G="ok",V="Ready for dispatch"):lt&&!((_e=N.current_task)!=null&&_e.trim())&&(G="warn",V="Owner focus is not explicit"):(G=Mt(m.priority)<=2?"bad":"warn",V=lt?"Active work has no owner":"Ready work has no owner",gt=!0),{task:m,owner:N,lastSignalAt:X,tone:G,note:V,focus:st(N==null?void 0:N.current_task)??(z==null?void 0:z.lastActivityText)??st(m.description)??"Needs operator attention.",ownerGap:gt}}).sort((m,N)=>{const z=Z(N.tone)-Z(m.tone);if(z!==0)return z;const X=Mt(m.task.priority)-Mt(N.task.priority);return X!==0?X:J(N.lastSignalAt??N.task.updated_at??N.task.created_at)-J(m.lastSignalAt??m.task.updated_at??m.task.created_at)}),g=l.filter(m=>m.task.status==="todo"&&Mt(m.task.priority)<=2),b=l.filter(m=>m.ownerGap).length,x=v.filter(m=>m.dispatchable),C=v.filter(m=>m.drift||m.tone!=="ok"),H=c.filter(m=>m.tone!=="ok"),D=t!=null&&t.paused?"bad":((Jt=t==null?void 0:t.data_quality)==null?void 0:Jt.board_contract_ok)===!1||((kt=t==null?void 0:t.data_quality)==null?void 0:kt.council_feed_ok)===!1?"warn":d?"ok":"warn",q=[];t!=null&&t.paused&&q.push({key:"paused",tone:"bad",title:"Room is paused",detail:t.tempo?`Tempo is ${t.tempo}. Resume from Ops when ready.`:"Resume from Ops when ready.",timestamp:((xt=t.data_quality)==null?void 0:xt.last_sync_at)??null,action:()=>Et("ops")}),d||q.push({key:"live-connection",tone:"warn",title:"Live feed is reconnecting",detail:"Dashboard telemetry is stale until the SSE stream recovers.",timestamp:null,action:Xc}),he(o==null?void 0:o.alert_level)!=="ok"&&q.push({key:"board-monitor",tone:he(o==null?void 0:o.alert_level),title:"Board feed needs attention",detail:`Freshness ${Ka(o==null?void 0:o.last_activity_age_s)} · ${(o==null?void 0:o.unanswered_posts)??0} unanswered posts.`,timestamp:null,action:()=>Et("board")}),he(r==null?void 0:r.alert_level)!=="ok"&&q.push({key:"council-monitor",tone:he(r==null?void 0:r.alert_level),title:"Council quorum risk is elevated",detail:`${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum · freshness ${Ka(r==null?void 0:r.last_activity_age_s)}.`,timestamp:null,action:()=>Et("board")}),(((B=t==null?void 0:t.data_quality)==null?void 0:B.board_contract_ok)===!1||((Y=t==null?void 0:t.data_quality)==null?void 0:Y.council_feed_ok)===!1)&&q.push({key:"data-quality",tone:"warn",title:"Dashboard data quality is degraded",detail:`${((k=t.data_quality)==null?void 0:k.board_contract_ok)===!1?"Board contract":"Board contract ok"} · ${((Rt=t.data_quality)==null?void 0:Rt.council_feed_ok)===!1?"Council feed degraded":"Council feed ok"}.`,timestamp:((Vt=t.data_quality)==null?void 0:Vt.last_sync_at)??null,action:()=>Et("ops")});const R=[...q,...l.filter(m=>m.tone!=="ok").slice(0,3).map(m=>({key:`task-${m.task.id}`,tone:m.tone,title:m.task.title,detail:`${m.note} · ${m.focus}`,timestamp:m.lastSignalAt??m.task.updated_at??m.task.created_at??null,action:()=>Et("overview")})),...H.slice(0,2).map(m=>({key:`keeper-${m.keeper.name}`,tone:m.tone,title:m.keeper.name,detail:`${m.note} · ${m.focus}`,timestamp:m.timestamp,action:()=>ia(m.keeper)})),...C.slice(0,2).map(m=>({key:`agent-${m.agent.name}`,tone:m.tone,title:m.agent.name,detail:`${m.note} · ${m.focus}`,timestamp:m.lastSignalAt,action:()=>De(m.agent.name)}))].sort((m,N)=>{const z=Z(N.tone)-Z(m.tone);return z!==0?z:J(N.timestamp)-J(m.timestamp)}).slice(0,8),I=Fa.value;return i`
    <div class="overview-sub-tabs">
      <button
        class="sub-tab-btn ${I==="triage"?"active":""}"
        onClick=${()=>{Fa.value="triage"}}
      >Triage</button>
      <button
        class="sub-tab-btn ${I==="dispatch"?"active":""}"
        onClick=${()=>{Fa.value="dispatch"}}
      >Dispatch</button>
    </div>

    ${I==="dispatch"?i`<${Ec} />`:i`<div class="stats-grid">
      <${ye}
        label="Room State"
        value=${t!=null&&t.paused?"Paused":"Running"}
        color=${Pn(D)}
        caption=${(t==null?void 0:t.room)??(t==null?void 0:t.project)??"default room"}
      />
      <${ye}
        label="Urgent Queue"
        value=${g.length}
        color=${g.length>0?"#fb7185":"#4ade80"}
        caption="todo tasks at P1/P2"
      />
      <${ye}
        label="Active Work"
        value=${s.inProgress.length}
        color="#fbbf24"
        caption="claimed + in progress"
      />
      <${ye}
        label="Dispatchable"
        value=${x.length}
        color="#22d3ee"
        caption="fresh agents with no load"
      />
      <${ye}
        label="Keeper Pressure"
        value=${H.length}
        color=${H.length>0?"#fbbf24":"#4ade80"}
        caption="stale or high-context keepers"
      />
      <${ye}
        label="Owner Gaps"
        value=${b}
        color=${b>0?"#fb7185":"#4ade80"}
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
          <div class="stat-value" style=${`color:${d?"#4ade80":"#fbbf24"}`}>${d?"Online":"Retrying"}</div>
          <div class="monitor-stat-caption">${An.value} events seen in this session</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Board Feed</div>
          <div class="stat-value" style=${`color:${Pn(he(o==null?void 0:o.alert_level))}`}>${Di(o==null?void 0:o.alert_level)}</div>
          <div class="monitor-stat-caption">Freshness ${Ka(o==null?void 0:o.last_activity_age_s)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Council Feed</div>
          <div class="stat-value" style=${`color:${Pn(he(r==null?void 0:r.alert_level))}`}>${Di(r==null?void 0:r.alert_level)}</div>
          <div class="monitor-stat-caption">${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Runtime</div>
          <div class="stat-value" style=${`color:${Pn(D)}`}>${t!=null&&t.paused?"Paused":"Stable"}</div>
          <div class="monitor-stat-caption">Uptime ${td((t==null?void 0:t.uptime_seconds)??0)}</div>
        </div>
      </div>
      <div class="overview-note-stack">
        <div class="overview-inline-note">
          ${(se=t==null?void 0:t.data_quality)!=null&&se.last_sync_at?i`Last sync <${j} timestamp=${t.data_quality.last_sync_at} />`:i`No sync metadata yet`}
        </div>
        <div class="overview-inline-note">
          ${t!=null&&t.tempo?`Tempo ${t.tempo}`:"Tempo unavailable"}${(t==null?void 0:t.tempo_interval_s)!=null?` · ${t.tempo_interval_s}s interval`:""}
        </div>
        <div class="overview-inline-note">${sd(t==null?void 0:t.lodge)}</div>
        ${(P=t==null?void 0:t.lodge)!=null&&P.last_skip_reason?i`<div class="overview-inline-note">Last Lodge skip: ${t.lodge.last_skip_reason}</div>`:null}
      </div>
    <//>

    <div class="grid-2col">
      <${w} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs intervention right now</h2>
          <p class="monitor-subheadline">Room-level risks, stalled work, and keeper/agent drift are sorted into one operator-facing queue.</p>
        </div>
        <div class="monitor-alert-list">
          ${R.length===0?i`<div class="empty-state">No immediate intervention required</div>`:R.map(m=>i`<${id} key=${m.key} item=${m} />`)}
        </div>
      <//>

      <${w} title="Dispatch Window" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who can pick up work next</h2>
          <p class="monitor-subheadline">Fresh capacity stays visible here so dispatch does not require opening the full Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${x.length===0?i`<div class="empty-state">No fully dispatchable agents right now</div>`:x.slice(0,5).map(m=>i`
                <${Ha}
                  key=${m.agent.name}
                  tone=${m.tone}
                  title=${m.agent.name}
                  subtitle=${m.note}
                  meta=${[m.lastSignalAt?`Signal ${new Date(m.lastSignalAt).toLocaleTimeString()}`:"No recent signal",m.agent.model??"model n/a",m.agent.koreanName??"room agent"]}
                  focus=${m.focus}
                  onClick=${()=>De(m.agent.name)}
                />
              `)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${w} title="Execution Pulse" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Priority work and ownership drift</h2>
          <p class="monitor-subheadline">Urgent ready tasks and active execution issues stay visible without duplicating the full Execution surface.</p>
        </div>
        <div class="monitor-list">
          ${l.length===0?i`<div class="empty-state">No active or ready tasks</div>`:l.slice(0,6).map(m=>i`
                <${Ha}
                  key=${m.task.id}
                  tone=${m.tone}
                  title=${m.task.title}
                  subtitle=${`${ei(m.task.priority)} · ${m.note}`}
                  meta=${[m.task.assignee?`Owner ${m.task.assignee}`:"Unassigned",m.lastSignalAt?`Signal ${new Date(m.lastSignalAt).toLocaleTimeString()}`:"No live signal",m.task.updated_at?`Touched ${new Date(m.task.updated_at).toLocaleTimeString()}`:"No task timestamp"]}
                  focus=${m.focus}
                  onClick=${()=>Et("overview")}
                />
              `)}
        </div>
      <//>

      <${w} title="Keeper Pressure" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Long-running keepers under pressure</h2>
          <p class="monitor-subheadline">Only keepers with real pressure stay in the Overview. The full keeper census still lives in the Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${H.length===0?i`<div class="empty-state">No keeper pressure signals right now</div>`:H.slice(0,5).map(m=>{var N;return i`
                <${Ha}
                  key=${m.keeper.name}
                  tone=${m.tone}
                  title=${m.keeper.name}
                  subtitle=${(N=m.keeper.diagnostic)!=null&&N.health_state?`${m.note} · ${m.keeper.diagnostic.health_state}`:m.note}
                  meta=${[m.timestamp?`Heartbeat ${new Date(m.timestamp).toLocaleTimeString()}`:"No heartbeat",`Context ${typeof m.keeper.context_ratio=="number"?Math.round(m.keeper.context_ratio*100):0}%`,m.keeper.model?`Model ${m.keeper.model}`:"model n/a",m.keeper.diagnostic?`${nd(m.keeper.diagnostic.quiet_reason)} · next ${ad(m.keeper.diagnostic.next_action_path)} · reply ${m.keeper.diagnostic.last_reply_status}`:"Diagnostic unavailable"]}
                  focus=${m.focus}
                  onClick=${()=>ia(m.keeper)}
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
          ${C.length===0?i`<div class="empty-state">No agent drift or stale load right now</div>`:C.slice(0,5).map(m=>i`
                <button class="monitor-row ${m.tone}" onClick=${()=>De(m.agent.name)}>
                  <div class="monitor-row-header">
                    <div class="monitor-row-title">
                      <div class="monitor-name-line">
                        <span class="monitor-title">${m.agent.name}</span>
                        ${m.agent.koreanName?i`<span class="monitor-sub">${m.agent.koreanName}</span>`:null}
                      </div>
                      <div class="monitor-note">${m.note}</div>
                    </div>
                    <${Nt} status=${m.agent.status} />
                    <span class="monitor-pill ${m.tone}">${m.dispatchable?"Ready":m.drift?"Drift":"Watch"}</span>
                  </div>
                  <div class="monitor-meta">
                    ${m.lastSignalAt?i`<span>Signal <${j} timestamp=${m.lastSignalAt} /></span>`:i`<span>No recent signal</span>`}
                    <span>${m.activeTaskCount>0?`${m.activeTaskCount} active tasks`:"No active tasks"}</span>
                    ${m.agent.model?i`<span>${m.agent.model}</span>`:null}
                  </div>
                  <div class="monitor-focus">${m.focus}</div>
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
            ${t!=null&&t.version?`Version ${t.version}`:"Version unavailable"} · Active agents ${ac.value.length} · Total tasks ${n.length}
          </div>
          <div class="overview-inline-note">
            ${Ve.value?`Perpetual runtime ${Ve.value.running?"running":"stopped"}${Ve.value.goal?` · ${st(Ve.value.goal,120)}`:""}`:"Perpetual runtime unavailable"}
          </div>
          <div class="overview-inline-note">
            Lodge ${(Lt=t==null?void 0:t.lodge)!=null&&Lt.enabled?"enabled":"disabled"} · Last tick ${((ie=t==null?void 0:t.lodge)==null?void 0:ie.last_tick_ago)??"never"} · Self heartbeats ${((Ke=(Ln=t==null?void 0:t.lodge)==null?void 0:Ln.active_self_heartbeats)==null?void 0:Ke.length)??0}${(He=t==null?void 0:t.lodge)!=null&&He.last_skip_reason?` · Skip ${t.lodge.last_skip_reason}`:""}
          </div>
          <div class="overview-inline-note">
            ${a.length>0?`Hot keepers: ${H.length} · Highest context ${ed(Math.max(...a.map(m=>m.context_tokens??0)))}`:"No keepers registered"}
          </div>
        </div>
      <//>
    </div>`}
  `}const Gt=f(null),oa=f(!1),ra=f(null),Ns=f(null),la=f(null),si=f("operations"),Nn=f(null),Rs=f(!1),ca=f(null),Oo=f(null),Ls=f(!1),da=f(null);function T(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function u(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function y(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Q(t){return typeof t=="boolean"?t:void 0}function rt(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function od(){if(typeof window>"u")return;const e=new URLSearchParams(window.location.search).get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function rd(t){if(T(t))return{policy_class:u(t.policy_class),approval_class:u(t.approval_class),tool_allowlist:rt(t.tool_allowlist),model_allowlist:rt(t.model_allowlist),requires_human_for:rt(t.requires_human_for),autonomy_level:u(t.autonomy_level),escalation_timeout_sec:y(t.escalation_timeout_sec),kill_switch:Q(t.kill_switch),frozen:Q(t.frozen)}}function ld(t){if(T(t))return{headcount_cap:y(t.headcount_cap),active_operation_cap:y(t.active_operation_cap),max_cost_usd:y(t.max_cost_usd),max_tokens:y(t.max_tokens)}}function ii(t){if(!T(t))return null;const e=u(t.unit_id),n=u(t.label),a=u(t.kind);return!e||!n||!a?null:{unit_id:e,label:n,kind:a,parent_unit_id:u(t.parent_unit_id)??null,leader_id:u(t.leader_id)??null,roster:rt(t.roster),capability_profile:rt(t.capability_profile),source:u(t.source),created_at:u(t.created_at),updated_at:u(t.updated_at),policy:rd(t.policy),budget:ld(t.budget)}}function zo(t){if(!T(t))return null;const e=ii(t.unit);return e?{unit:e,leader_status:u(t.leader_status),roster_total:y(t.roster_total),roster_live:y(t.roster_live),active_operation_count:y(t.active_operation_count),health:u(t.health),reasons:rt(t.reasons),children:Array.isArray(t.children)?t.children.map(zo).filter(n=>n!==null):[]}:null}function cd(t){if(T(t))return{total_units:y(t.total_units),company_count:y(t.company_count),platoon_count:y(t.platoon_count),squad_count:y(t.squad_count),leaf_agent_unit_count:y(t.leaf_agent_unit_count),live_agent_count:y(t.live_agent_count),managed_unit_count:y(t.managed_unit_count),active_operation_count:y(t.active_operation_count)}}function dd(t){const e=T(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),source:u(e.source),summary:cd(e.summary),units:Array.isArray(e.units)?e.units.map(zo).filter(n=>n!==null):[]}}function oi(t){if(!T(t))return null;const e=u(t.operation_id),n=u(t.objective),a=u(t.assigned_unit_id),s=u(t.trace_id),o=u(t.status);return!e||!n||!a||!s||!o?null:{operation_id:e,objective:n,assigned_unit_id:a,autonomy_level:u(t.autonomy_level),policy_class:u(t.policy_class),budget_class:u(t.budget_class),detachment_session_id:u(t.detachment_session_id)??null,trace_id:s,checkpoint_ref:u(t.checkpoint_ref)??null,active_goal_ids:rt(t.active_goal_ids),note:u(t.note)??null,created_by:u(t.created_by),source:u(t.source),status:o,created_at:u(t.created_at),updated_at:u(t.updated_at)}}function ud(t){if(!T(t))return null;const e=oi(t.operation);return e?{operation:e,assigned_unit_label:u(t.assigned_unit_label)}:null}function pd(t){const e=T(t)?t:{},n=T(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:y(n.total),active:y(n.active),paused:y(n.paused),managed:y(n.managed),projected:y(n.projected)}:void 0,operations:Array.isArray(e.operations)?e.operations.map(ud).filter(a=>a!==null):[]}}function qo(t){if(!T(t))return null;const e=u(t.detachment_id),n=u(t.operation_id),a=u(t.assigned_unit_id);return!e||!n||!a?null:{detachment_id:e,operation_id:n,assigned_unit_id:a,leader_id:u(t.leader_id)??null,roster:rt(t.roster),session_id:u(t.session_id)??null,checkpoint_ref:u(t.checkpoint_ref)??null,runtime_kind:u(t.runtime_kind)??null,runtime_ref:u(t.runtime_ref)??null,source:u(t.source),status:u(t.status),last_event_at:u(t.last_event_at)??null,last_progress_at:u(t.last_progress_at)??null,heartbeat_deadline:u(t.heartbeat_deadline)??null,created_at:u(t.created_at),updated_at:u(t.updated_at)}}function md(t){if(!T(t))return null;const e=qo(t.detachment);return e?{detachment:e,assigned_unit_label:u(t.assigned_unit_label),operation:oi(t.operation)}:null}function vd(t){const e=T(t)?t:{},n=T(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:y(n.total),active:y(n.active),projected:y(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(md).filter(a=>a!==null):[]}}function fd(t){if(!T(t))return null;const e=u(t.decision_id),n=u(t.trace_id),a=u(t.requested_action),s=u(t.scope_type),o=u(t.scope_id);return!e||!n||!a||!s||!o?null:{decision_id:e,trace_id:n,requested_action:a,scope_type:s,scope_id:o,operation_id:u(t.operation_id)??null,target_unit_id:u(t.target_unit_id)??null,requested_by:u(t.requested_by),status:u(t.status),reason:u(t.reason)??null,source:u(t.source),detail:t.detail,created_at:u(t.created_at),decided_at:u(t.decided_at)??null,expires_at:u(t.expires_at)??null}}function gd(t){const e=T(t)?t:{},n=T(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:y(n.total),pending:y(n.pending),approved:y(n.approved),denied:y(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(fd).filter(a=>a!==null):[]}}function _d(t){if(!T(t))return null;const e=ii(t.unit);return e?{unit:e,roster_total:y(t.roster_total),roster_live:y(t.roster_live),headcount_cap:y(t.headcount_cap),active_operations:y(t.active_operations),active_operation_cap:y(t.active_operation_cap),utilization:y(t.utilization)}:null}function $d(t){const e=T(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(_d).filter(n=>n!==null):[]}}function hd(t){if(!T(t))return null;const e=u(t.alert_id);return e?{alert_id:e,severity:u(t.severity),kind:u(t.kind),scope_type:u(t.scope_type),scope_id:u(t.scope_id),title:u(t.title),detail:u(t.detail),timestamp:u(t.timestamp)}:null}function yd(t){const e=T(t)?t:{},n=T(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:y(n.total),bad:y(n.bad),warn:y(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(hd).filter(a=>a!==null):[]}}function jo(t){if(!T(t))return null;const e=u(t.event_id),n=u(t.trace_id),a=u(t.event_type);return!e||!n||!a?null:{event_id:e,trace_id:n,event_type:a,operation_id:u(t.operation_id)??null,unit_id:u(t.unit_id)??null,actor:u(t.actor)??null,source:u(t.source),timestamp:u(t.timestamp),detail:t.detail}}function bd(t){const e=T(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),events:Array.isArray(e.events)?e.events.map(jo).filter(n=>n!==null):[]}}function kd(t){if(!T(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a}}function xd(t){if(!T(t))return null;const e=u(t.lane_id),n=u(t.label),a=u(t.kind),s=u(t.phase),o=u(t.motion_state),r=u(t.source_of_truth),d=u(t.movement_reason),p=u(t.current_step);if(!e||!n||!a||!s||!o||!r||!d||!p)return null;const _=T(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:a,present:Q(t.present)??!1,phase:s,motion_state:o,source_of_truth:r,last_movement_at:u(t.last_movement_at)??null,movement_reason:d,current_step:p,blockers:rt(t.blockers),counts:{operations:y(_.operations),detachments:y(_.detachments),workers:y(_.workers),approvals:y(_.approvals),alerts:y(_.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(kd).filter(v=>v!==null):[]}}function Sd(t){if(!T(t))return null;const e=u(t.event_id),n=u(t.lane_id),a=u(t.kind),s=u(t.timestamp),o=u(t.title),r=u(t.detail),d=u(t.tone),p=u(t.source);return!e||!n||!a||!s||!o||!r||!d||!p?null:{event_id:e,lane_id:n,kind:a,timestamp:s,title:o,detail:r,tone:d,source:p}}function Ad(t){if(!T(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a,lane_ids:rt(t.lane_ids),count:y(t.count)??0}}function wd(t){if(!T(t))return;const e=T(t.overview)?t.overview:{},n=T(t.gaps)?t.gaps:{},a=T(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:u(t.generated_at),overview:{active_lanes:y(e.active_lanes),moving_lanes:y(e.moving_lanes),stalled_lanes:y(e.stalled_lanes),projected_lanes:y(e.projected_lanes),last_movement_at:u(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(xd).filter(s=>s!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(Sd).filter(s=>s!==null):[],gaps:{count:y(n.count),items:Array.isArray(n.items)?n.items.map(Ad).filter(s=>s!==null):[]},recommended_next_action:a?{tool:u(a.tool)??"masc_operator_snapshot",label:u(a.label)??"Observe operator state",reason:u(a.reason)??"",lane_id:u(a.lane_id)??null}:void 0}}function Td(t){const e=T(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),topology:dd(e.topology),operations:pd(e.operations),detachments:vd(e.detachments),alerts:yd(e.alerts),decisions:gd(e.decisions),capacity:$d(e.capacity),traces:bd(e.traces),swarm_status:wd(e.swarm_status)}}function Cd(t){if(!T(t))return null;const e=u(t.title),n=u(t.path);return!e||!n?null:{title:e,path:n}}function Nd(t){if(!T(t))return null;const e=u(t.id),n=u(t.title),a=u(t.summary);return!e||!n||!a?null:{id:e,title:n,summary:a}}function Rd(t){if(!T(t))return null;const e=u(t.id),n=u(t.title),a=u(t.tool),s=u(t.summary);return!e||!n||!a||!s?null:{id:e,title:n,tool:a,summary:s,success_signals:rt(t.success_signals),pitfalls:rt(t.pitfalls)}}function Ld(t){if(!T(t))return null;const e=u(t.id),n=u(t.title),a=u(t.summary),s=u(t.when_to_use);return!e||!n||!a||!s?null:{id:e,title:n,summary:a,when_to_use:s,steps:Array.isArray(t.steps)?t.steps.map(Rd).filter(o=>o!==null):[]}}function Dd(t){if(!T(t))return null;const e=u(t.id),n=u(t.title),a=u(t.description);return!e||!n||!a?null:{id:e,title:n,description:a,tools:rt(t.tools)}}function Pd(t){if(!T(t))return null;const e=u(t.id),n=u(t.title),a=u(t.symptom),s=u(t.why),o=u(t.fix_tool),r=u(t.fix_summary);return!e||!n||!a||!s||!o||!r?null:{id:e,title:n,symptom:a,why:s,fix_tool:o,fix_summary:r}}function Id(t){if(!T(t))return null;const e=u(t.id),n=u(t.title),a=u(t.path_id),s=u(t.transport);return!e||!n||!a||!s?null:{id:e,title:n,path_id:a,transport:s,request:t.request,response:t.response,notes:rt(t.notes)}}function Ed(t){const e=T(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(Cd).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(Nd).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(Ld).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Dd).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Pd).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Id).filter(n=>n!==null):[]}}function Md(t){if(!T(t))return null;const e=u(t.id),n=u(t.title),a=u(t.status),s=u(t.detail),o=u(t.next_tool);return!e||!n||!a||!s||!o?null:{id:e,title:n,status:a,detail:s,next_tool:o}}function Od(t){if(!T(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.title),s=u(t.detail),o=u(t.next_tool);return!e||!n||!a||!s||!o?null:{code:e,severity:n,title:a,detail:s,next_tool:o}}function zd(t){if(!T(t))return null;const e=u(t.from),n=u(t.content),a=u(t.timestamp),s=y(t.seq);return!e||!n||!a||s==null?null:{seq:s,from:e,content:n,timestamp:a}}function qd(t){if(!T(t))return null;const e=u(t.name),n=u(t.role),a=u(t.lane),s=u(t.status),o=u(t.claim_marker),r=u(t.done_marker),d=u(t.final_marker);if(!e||!n||!a||!s||!o||!r||!d)return null;const p=(()=>{if(!T(t.last_message))return null;const _=y(t.last_message.seq),v=u(t.last_message.content),c=u(t.last_message.timestamp);return _==null||!v||!c?null:{seq:_,content:v,timestamp:c}})();return{name:e,role:n,lane:a,joined:Q(t.joined)??!1,live_presence:Q(t.live_presence)??!1,completed:Q(t.completed)??!1,status:s,current_task:u(t.current_task)??null,bound_task_id:u(t.bound_task_id)??null,bound_task_title:u(t.bound_task_title)??null,bound_task_status:u(t.bound_task_status)??null,current_task_matches_run:Q(t.current_task_matches_run)??!1,squad_member:Q(t.squad_member)??!1,detachment_member:Q(t.detachment_member)??!1,last_seen:u(t.last_seen)??null,heartbeat_age_sec:y(t.heartbeat_age_sec)??null,heartbeat_fresh:Q(t.heartbeat_fresh)??!1,claim_marker_seen:Q(t.claim_marker_seen)??!1,done_marker_seen:Q(t.done_marker_seen)??!1,final_marker_seen:Q(t.final_marker_seen)??!1,claim_marker:o,done_marker:r,final_marker:d,last_message:p}}function jd(t){if(!T(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!T(n))return null;const a=u(n.timestamp),s=y(n.active_slots);if(!a||s==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:a,active_slots:s,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:u(t.slot_url)??null,total_slots:y(t.total_slots),ctx_per_slot:y(t.ctx_per_slot),active_slots_now:y(t.active_slots_now),peak_active_slots:y(t.peak_active_slots),sample_count:y(t.sample_count),last_sample_at:u(t.last_sample_at)??null,timeline:e}}function Fd(t){const e=T(t)?t:{},n=T(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),run_id:u(e.run_id),room_id:u(e.room_id),operation_id:u(e.operation_id)??null,recommended_next_tool:u(e.recommended_next_tool),summary:n?{expected_workers:y(n.expected_workers),joined_workers:y(n.joined_workers),live_workers:y(n.live_workers),squad_roster_size:y(n.squad_roster_size),detachment_roster_size:y(n.detachment_roster_size),current_task_bound:y(n.current_task_bound),fresh_heartbeats:y(n.fresh_heartbeats),claim_markers_seen:y(n.claim_markers_seen),done_markers_seen:y(n.done_markers_seen),final_markers_seen:y(n.final_markers_seen),completed_workers:y(n.completed_workers),peak_hot_slots:y(n.peak_hot_slots),hot_window_ok:Q(n.hot_window_ok),pass_hot_concurrency:Q(n.pass_hot_concurrency),pass_end_to_end:Q(n.pass_end_to_end),pending_decisions:y(n.pending_decisions),pass:Q(n.pass)}:void 0,provider:jd(e.provider),operation:oi(e.operation),squad:ii(e.squad),detachment:qo(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(qd).filter(a=>a!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Md).filter(a=>a!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Od).filter(a=>a!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(zd).filter(a=>a!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(jo).filter(a=>a!==null):[],truth_notes:rt(e.truth_notes)}}function Kd(t){si.value=t}async function kn(){oa.value=!0,ra.value=null;try{const t=await Hr();Gt.value=Td(t)}catch(t){ra.value=t instanceof Error?t.message:"Failed to load command plane snapshot"}finally{oa.value=!1}}async function Hd(){Rs.value=!0,ca.value=null;try{const t=await Ur();Nn.value=Ed(t)}catch(t){ca.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Rs.value=!1}}async function Fo(t=od()){Ls.value=!0,da.value=null;try{const e=await Br(t);Oo.value=Fd(e)}catch(e){da.value=e instanceof Error?e.message:"Failed to load command-plane swarm view"}finally{Ls.value=!1}}async function ae(t,e,n){Ns.value=t,la.value=null;try{await Wr(e,n),await kn(),await Fo()}catch(a){throw la.value=a instanceof Error?a.message:"Failed to execute command-plane action",a}finally{Ns.value=null}}function Ud(t){return ae(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Bd(t){return ae(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function Wd(t){return ae(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Gd(t={}){return ae("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function Jd(t){return ae(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Vd(t){return ae(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Qd(t,e){return ae(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Yd(t,e){return ae(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}function Xd(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function ct(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function Zd(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function tu(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function W(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}function eu(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function tt(t){return Ns.value===t}function nu(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function au(){if(typeof window>"u")return null;const e=new URLSearchParams(window.location.search).get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function su(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function iu(t){return t.status==="claimed"||t.status==="in_progress"}function ou(t){const e=Nn.value;if(!e)return null;for(const n of e.golden_paths){const a=n.steps.find(s=>s.tool===t);if(a)return a}return null}function Ua(t){var e;return((e=Nn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function ru(t){const e=Nn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(a=>n.has(a.id))}async function Zt(t){try{await t()}catch{}}function lu(){var o;const t=Gt.value,e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,a=t==null?void 0:t.decisions.summary,s=t==null?void 0:t.alerts.summary;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>Units</span><strong>${(e==null?void 0:e.total_units)??0}</strong><small>${(e==null?void 0:e.managed_unit_count)??0} managed</small></div>
      <div class="monitor-stat-card"><span>Ops</span><strong>${(n==null?void 0:n.active)??0}</strong><small>${((o=t==null?void 0:t.detachments.summary)==null?void 0:o.active)??0} detachments</small></div>
      <div class="monitor-stat-card"><span>Approvals</span><strong>${(a==null?void 0:a.pending)??0}</strong><small>${(a==null?void 0:a.total)??0} tracked</small></div>
      <div class="monitor-stat-card"><span>Alerts</span><strong>${(s==null?void 0:s.bad)??0}</strong><small>${(s==null?void 0:s.warn)??0} warn</small></div>
    </div>
  `}function cu(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function du({lane:t}){const e=t.counts??{},n=cu(t);return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.label}</strong>
          <div class="command-card-sub">${t.source_of_truth}</div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${W(n)}">${t.phase}</span>
          <span class="command-chip ${W(n)}">${t.motion_state}</span>
          <span class="command-chip">${ct(t.last_movement_at)}</span>
        </div>
      </div>
      <div class="command-card-grid">
        <span>Movement</span><span>${t.movement_reason}</span>
        <span>Step</span><span>${t.current_step}</span>
        <span>Counts</span><span>${e.operations??0} ops · ${e.detachments??0} dets · ${e.workers??0} workers · ${e.approvals??0} approvals · ${e.alerts??0} alerts</span>
      </div>
      ${t.blockers.length>0?i`<div class="command-card-foot">Blockers: ${t.blockers.join(" · ")}</div>`:null}
      ${t.hard_flags.length>0?i`
            <div class="command-tag-row">
              ${t.hard_flags.map(a=>i`<span class="command-tag ${W(a.severity)}">${a.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function uu({event:t}){return i`
    <div class="command-trace-row">
      <div class="command-trace-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${W(t.tone)}">${t.lane_id}</span>
        <span class="command-chip">${t.kind}</span>
        <span class="command-chip">${ct(t.timestamp)}</span>
      </div>
      <div class="command-card-sub">${t.source}</div>
      <div class="command-card-foot">${t.detail}</div>
    </div>
  `}function pu({gap:t}){return i`
    <div class="command-guide-inline">
      <div class="command-guide-head">
        <strong>${t.code}</strong>
        <span class="command-chip ${W(t.severity)}">${t.count}</span>
      </div>
      <p>${t.summary}</p>
      ${t.lane_ids.length>0?i`<div class="command-tag-row">${t.lane_ids.map(e=>i`<span class="command-tag">${e}</span>`)}</div>`:null}
    </div>
  `}function mu(){var r;const t=(r=Gt.value)==null?void 0:r.swarm_status,e=(t==null?void 0:t.lanes.filter(d=>d.present))??[],n=(t==null?void 0:t.gaps.items)??[],a=(t==null?void 0:t.timeline.slice(0,6))??[],s=t==null?void 0:t.overview,o=t==null?void 0:t.recommended_next_action;return i`
    <section class="card command-section">
      <div class="card-title">Swarm</div>
      ${t?i`
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>Active Lanes</span><strong>${(s==null?void 0:s.active_lanes)??0}</strong><small>${(s==null?void 0:s.moving_lanes)??0} moving</small></div>
              <div class="monitor-stat-card"><span>Stalled</span><strong>${(s==null?void 0:s.stalled_lanes)??0}</strong><small>${(s==null?void 0:s.projected_lanes)??0} projected</small></div>
              <div class="monitor-stat-card"><span>Last Movement</span><strong>${ct(s==null?void 0:s.last_movement_at)}</strong><small>${t.generated_at?`snapshot ${ct(t.generated_at)}`:"snapshot now"}</small></div>
              <div class="monitor-stat-card"><span>Next Action</span><strong>${(o==null?void 0:o.label)??"Observe operator state"}</strong><small>${(o==null?void 0:o.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            <div class="command-swarm-layout">
              <div class="command-card-stack">
                ${e.length>0?e.map(d=>i`<${du} lane=${d} />`):i`<div class="empty-state">No active swarm lanes.</div>`}
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
                    <span class="command-chip ${W(n.some(d=>d.severity==="bad")?"bad":n.length>0?"warn":"ok")}">${n.length}</span>
                  </div>
                  ${n.length>0?i`<div class="command-card-stack">${n.slice(0,4).map(d=>i`<${pu} gap=${d} />`)}</div>`:i`<p>No hard gaps are currently visible.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>Movement Timeline</strong>
                    <span class="command-chip">${a.length}</span>
                  </div>
                  ${a.length>0?i`<div class="command-card-stack">${a.map(d=>i`<${uu} event=${d} />`)}</div>`:i`<p>No recent movement events are attached yet.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">Swarm status is unavailable.</div>`}
    </section>
  `}function vu(){return i`
    <div class="command-surface-tabs">
      ${["swarm","operations","topology","alerts","trace","control"].map(e=>i`
        <button
          class="command-surface-tab ${si.value===e?"active":""}"
          onClick=${()=>Kd(e)}
        >
          ${e}
        </button>
      `)}
    </div>
  `}function fu(){var Jt,kt,xt,B,Y,k,Rt,Vt,se;const t=Gt.value,e=ne.value,n=nu(),a=n?ht.value.find(P=>P.name===n)??null:null,s=n?vt.value.filter(P=>P.assignee===n&&iu(P)):[],o=((Jt=t==null?void 0:t.operations.summary)==null?void 0:Jt.active)??0,r=((kt=t==null?void 0:t.detachments.summary)==null?void 0:kt.total)??0,d=((xt=t==null?void 0:t.decisions.summary)==null?void 0:xt.pending)??0,p=t==null?void 0:t.detachments.detachments.find(P=>{const Lt=P.detachment.heartbeat_deadline,ie=Lt?Date.parse(Lt):Number.NaN;return P.detachment.status==="stalled"||!Number.isNaN(ie)&&ie<=Date.now()}),_=t==null?void 0:t.alerts.alerts.find(P=>P.severity==="bad"),v=!!(e!=null&&e.room||e!=null&&e.project),c=(a==null?void 0:a.current_task)??null,l=su(a==null?void 0:a.last_seen),g=l!=null?l<=120:null,b=[v?{title:"Room readiness",tone:"ok",detail:`${(e==null?void 0:e.room)??(e==null?void 0:e.project)??"unknown"} · base ${(e==null?void 0:e.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room readiness",tone:"bad",detail:"No room snapshot yet. Set room to repo root before joining.",tool:"masc_set_room"},n?a?s.length===0?{title:"Task readiness",tone:"warn",detail:`${n} has no claimed task. Claim one or create one first.`,tool:vt.value.length>0?"masc_claim":"masc_add_task"}:c?g===!1?{title:"Task readiness",tone:"warn",detail:`${n} current_task=${c}, but heartbeat is stale (${l}s).`,tool:"masc_heartbeat"}:{title:"Task readiness",tone:"ok",detail:`${n} current_task=${c}${l!=null?` · last seen ${l}s ago`:""}`,tool:"masc_plan_get_task"}:{title:"Task readiness",tone:"bad",detail:`${n} has a claimed task but no session current_task binding.`,tool:"masc_plan_set_task"}:{title:"Task readiness",tone:"bad",detail:`${n} is not visible in the room roster.`,tool:"masc_join"}:{title:"Task readiness",tone:"warn",detail:"No ?agent= query param. Dashboard can show room health but not agent-specific next steps.",tool:"masc_join"},!t||(((B=t.topology.summary)==null?void 0:B.managed_unit_count)??0)===0?{title:"Operation readiness",tone:"warn",detail:"No managed units defined yet. CPv2 benchmark cannot start before hierarchy exists.",tool:"masc_unit_define"}:o===0?{title:"Operation readiness",tone:"warn",detail:`${((Y=t.topology.summary)==null?void 0:Y.managed_unit_count)??0} managed units are ready, but there is no active operation.`,tool:"masc_operation_start"}:{title:"Operation readiness",tone:"ok",detail:`${o} active operation(s) across ${((k=t.topology.summary)==null?void 0:k.managed_unit_count)??0} managed unit(s).`,tool:"masc_observe_operations"},d>0?{title:"Dispatch readiness",tone:"warn",detail:`${d} pending approval(s) are blocking strict actions.`,tool:"masc_policy_approve"}:o>0&&r===0?{title:"Dispatch readiness",tone:"bad",detail:"Active operation exists but no detachment has been materialized yet.",tool:"masc_dispatch_tick"}:p||_?{title:"Dispatch readiness",tone:"warn",detail:`Dispatch needs reconciliation${p?` · detachment ${p.detachment.detachment_id} is stalled`:""}${_?` · alert ${_.title??_.alert_id}`:""}.`,tool:d>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"Dispatch readiness",tone:"ok",detail:`${r} detachment(s) visible and no strict approval backlog.`,tool:"masc_detachment_list"}],x=v?!n||!a?"masc_join":s.length===0?vt.value.length>0?"masc_claim":"masc_add_task":c?g===!1?"masc_heartbeat":!t||(((Rt=t.topology.summary)==null?void 0:Rt.managed_unit_count)??0)===0?"masc_unit_define":o===0?"masc_operation_start":d>0?"masc_policy_approve":o>0&&r===0||p||_?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",C=ou(x),D=ru(x==="masc_set_room"?["repo-root-room"]:x==="masc_plan_set_task"?["claimed-not-current"]:x==="masc_heartbeat"?["heartbeat-stale"]:x==="masc_dispatch_tick"?["no-detachments"]:x==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),q=Ua("room_task_hygiene"),R=Ua("cpv2_benchmark"),I=Ua("supervisor_session"),bt=((Vt=Nn.value)==null?void 0:Vt.docs)??[],Ft=[q,R,I].filter(P=>P!==null);return i`
    <div class="command-guide-grid">
      <section class="card command-section">
        <div class="card-title">Readiness</div>
        <div class="command-guide-readiness">
          ${b.map(P=>i`
            <article class="command-guide-card ${W(P.tone)}">
              <div class="command-guide-head">
                <strong>${P.title}</strong>
                <span class="command-chip ${W(P.tone)}">${P.tone}</span>
              </div>
              <p>${P.detail}</p>
              <div class="command-card-foot">Next tool: ${P.tool}</div>
            </article>
          `)}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title">Next Step</div>
        <article class="command-guide-card highlight">
          <div class="command-guide-head">
            <strong>${(C==null?void 0:C.title)??x}</strong>
            <span class="command-chip ok">${x}</span>
          </div>
          <p>${(C==null?void 0:C.summary)??"Use the next tool in the canonical flow to remove the current blocker."}</p>
          ${(se=C==null?void 0:C.success_signals)!=null&&se.length?i`<div class="command-tag-row">
                ${C.success_signals.map(P=>i`<span class="command-tag ok">${P}</span>`)}
              </div>`:null}
          ${D.length>0?i`<div class="command-guide-list">
                ${D.map(P=>i`
                  <article class="command-guide-inline">
                    <strong>${P.title}</strong>
                    <div>${P.symptom}</div>
                    <div class="command-card-sub">Fix with ${P.fix_tool}: ${P.fix_summary}</div>
                  </article>
                `)}
              </div>`:null}
        </article>
      </section>

      <section class="card command-section">
        <div class="card-title">How It Works</div>
        ${Rs.value?i`<div class="empty-state">Loading CPv2 runbook…</div>`:ca.value?i`<div class="empty-state error">${ca.value}</div>`:i`
                <div class="command-guide-paths">
                  ${Ft.map(P=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${P.title}</strong>
                        <span class="command-chip">${P.id}</span>
                      </div>
                      <p>${P.summary}</p>
                      <div class="command-card-sub">${P.when_to_use}</div>
                      <div class="command-step-list">
                        ${P.steps.map(Lt=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Lt.tool}</span>
                            <span>${Lt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${bt.length>0?i`<div class="command-doc-links">
                      ${bt.map(P=>i`<span class="command-tag">${P.title}: ${P.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Ko({node:t,depth:e=0}){const n=t.roster_live??0,a=t.roster_total??t.unit.roster.length,s=t.active_operation_count??0,o=t.unit.policy;return i`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${eu(t.unit.kind)}</span>
            <span class="command-chip ${W(t.health)}">${t.health??"ok"}</span>
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
            ${t.children.map(r=>i`<${Ko} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function gu({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,a=`resume:${e.operation_id}`,s=`recall:${e.operation_id}`;return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${W(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Autonomy</span><span>${e.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${e.budget_class??"standard"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Updated</span><span>${ct(e.updated_at)}</span>
      </div>
      ${e.checkpoint_ref?i`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        ${e.source==="managed"&&e.status==="active"?i`
              <button class="control-btn ghost" disabled=${tt(n)} onClick=${()=>Zt(()=>Ud(e.operation_id))}>
                ${tt(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${tt(s)} onClick=${()=>Zt(()=>Wd(e.operation_id))}>
                ${tt(s)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?i`
              <button class="control-btn ghost" disabled=${tt(a)} onClick=${()=>Zt(()=>Bd(e.operation_id))}>
                ${tt(a)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function _u({card:t}){var n;const e=t.detachment;return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${W(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${ct(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${tu(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${ct(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?i`<span class="command-tag ${Zd(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function $u({alert:t}){return i`
    <article class="command-alert ${W(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${W(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${ct(t.timestamp)}</span>
      </div>
      ${t.detail?i`<p>${t.detail}</p>`:null}
    </article>
  `}function Ho({event:t}){return i`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${ct(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${Xd(t.detail)}</pre>
    </article>
  `}function hu({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,a=t.source==="projected_operator";return i`
    <article class="command-card ${W(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${W(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${ct(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!a?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${tt(e)} onClick=${()=>Zt(()=>Jd(t.decision_id))}>
                ${tt(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${tt(n)} onClick=${()=>Zt(()=>Vd(t.decision_id))}>
                ${tt(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${a?i`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function yu({row:t}){var d,p,_;const e=t.unit,n=`freeze:${e.unit_id}`,a=`kill:${e.unit_id}`,s=!!((d=e.policy)!=null&&d.frozen),o=!!((p=e.policy)!=null&&p.kill_switch),r=Math.round((t.utilization??0)*100);return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${W(r>100?"bad":r>70?"warn":"ok")}">${r}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>Headcount Cap</span><span>${t.headcount_cap??0}</span>
        <span>Ops</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${((_=e.policy)==null?void 0:_.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${s?"yes":"no"}</span>
        <span>Kill Switch</span><span>${o?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${tt(n)} onClick=${()=>Zt(()=>Qd(e.unit_id,!s))}>
          ${tt(n)?"Applying…":s?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${tt(a)} onClick=${()=>Zt(()=>Yd(e.unit_id,!o))}>
          ${tt(a)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function bu({item:t}){return i`
    <article class="command-guide-card ${W(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${W(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function ku({blocker:t}){return i`
    <article class="command-alert ${W(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${W(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function xu({worker:t}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${W(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${t.last_message?i`<div class="command-card-foot">${ct(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function Su(){var n,a,s,o,r,d,p,_,v,c,l,g,b,x,C,H;const t=Oo.value,e=au();return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Swarm Live Run</div>
        ${Ls.value?i`<div class="empty-state">Loading swarm live state…</div>`:da.value?i`<div class="empty-state error">${da.value}</div>`:t?i`
                  <div class="command-summary-grid">
                    <div class="monitor-stat-card"><span>Run</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room n/a"}</small></div>
                    <div class="monitor-stat-card"><span>Workers</span><strong>${((n=t.summary)==null?void 0:n.joined_workers)??0}/${((a=t.summary)==null?void 0:a.expected_workers)??0}</strong><small>${((s=t.summary)==null?void 0:s.live_workers)??0} live · ${((o=t.summary)==null?void 0:o.completed_workers)??0} completed</small></div>
                    <div class="monitor-stat-card"><span>Runtime</span><strong>${((r=t.provider)==null?void 0:r.active_slots_now)??0}/${((d=t.provider)==null?void 0:d.total_slots)??0}</strong><small>peak ${((p=t.summary)==null?void 0:p.peak_hot_slots)??0} · ctx ${((_=t.provider)==null?void 0:_.ctx_per_slot)??0}</small></div>
                    <div class="monitor-stat-card"><span>Hot 10+</span><strong>${(v=t.summary)!=null&&v.pass_hot_concurrency?"pass":"check"}</strong><small>${((c=t.provider)==null?void 0:c.slot_url)??"slot n/a"}</small></div>
                    <div class="monitor-stat-card"><span>End to End</span><strong>${(l=t.summary)!=null&&l.pass_end_to_end?"pass":"check"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                  </div>
                  <div class="command-card-grid">
                    <span>Operation</span><span>${((g=t.operation)==null?void 0:g.operation_id)??"none"}</span>
                    <span>Squad</span><span>${((b=t.squad)==null?void 0:b.label)??"none"}</span>
                    <span>Detachment</span><span>${((x=t.detachment)==null?void 0:x.detachment_id)??"none"}</span>
                    <span>Expected</span><span>${((C=t.summary)==null?void 0:C.expected_workers)??0} workers</span>
                    <span>Final Markers</span><span>${((H=t.summary)==null?void 0:H.final_markers_seen)??0}</span>
                    <span>Recommended</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                  </div>
                  ${t.truth_notes.length>0?i`<div class="command-tag-row">
                        ${t.truth_notes.map(D=>i`<span class="command-tag">${D}</span>`)}
                      </div>`:null}
                `:i`<div class="empty-state">No swarm read-model yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Checklist</div>
        ${t&&t.checklist.length>0?i`<div class="command-card-stack">
              ${t.checklist.map(D=>i`<${bu} item=${D} />`)}
            </div>`:i`<div class="empty-state">No checklist yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Workers</div>
        ${t&&t.workers.length>0?i`<div class="command-card-stack">
              ${t.workers.map(D=>i`<${xu} worker=${D} />`)}
            </div>`:i`<div class="empty-state">No worker rows yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Runtime</div>
        ${t!=null&&t.provider?i`
              <div class="command-card-grid">
                <span>Slot URL</span><span>${t.provider.slot_url??"n/a"}</span>
                <span>Total Slots</span><span>${t.provider.total_slots??0}</span>
                <span>Active Now</span><span>${t.provider.active_slots_now??0}</span>
                <span>Peak Active</span><span>${t.provider.peak_active_slots??0}</span>
                <span>Sample Count</span><span>${t.provider.sample_count??0}</span>
                <span>Last Sample</span><span>${t.provider.last_sample_at?ct(t.provider.last_sample_at):"n/a"}</span>
              </div>
              ${t.provider.timeline.length>0?i`<div class="command-trace-stack">
                    ${t.provider.timeline.slice(-12).map(D=>i`
                      <article class="command-trace-row">
                        <div class="command-trace-main">
                          <div class="command-trace-head">
                            <strong>${D.active_slots} active</strong>
                            <span class="command-chip">${ct(D.timestamp)}</span>
                          </div>
                          <div class="command-card-sub">slots ${D.active_slot_ids.join(", ")||"none"}</div>
                        </div>
                      </article>
                    `)}
                  </div>`:i`<div class="empty-state">No slot telemetry captured yet.</div>`}
            `:i`<div class="empty-state">No runtime telemetry yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Blockers</div>
        ${t&&t.blockers.length>0?i`<div class="command-card-stack">
              ${t.blockers.map(D=>i`<${ku} blocker=${D} />`)}
            </div>`:i`<div class="empty-state">No blockers. Use ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} for the next action.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Recent Messages</div>
        ${t&&t.recent_messages.length>0?i`<div class="command-trace-stack">
              ${t.recent_messages.map(D=>i`
                <article class="command-trace-row">
                  <div class="command-trace-main">
                    <div class="command-trace-head">
                      <strong>${D.from}</strong>
                      <span class="command-chip">${ct(D.timestamp)}</span>
                    </div>
                    <div class="command-card-sub">seq ${D.seq}</div>
                  </div>
                  <pre class="command-trace-detail">${D.content}</pre>
                </article>
              `)}
            </div>`:i`<div class="empty-state">No run-scoped broadcasts captured yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Recent Trace Events</div>
        ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
              ${t.recent_trace_events.map(D=>i`<${Ho} event=${D} />`)}
            </div>`:i`<div class="empty-state">No run-scoped trace events captured yet.</div>`}
      </section>
    </div>
  `}function Au(){const t=Gt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Operations</div>
        ${t&&t.operations.operations.length>0?i`<div class="command-card-stack">
              ${t.operations.operations.map(e=>i`<${gu} card=${e} />`)}
            </div>`:i`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title">Detachments</div>
        ${t&&t.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>i`<${_u} card=${e} />`)}
            </div>`:i`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function wu(){const t=Gt.value;return i`
    <section class="card command-section">
      <div class="card-title">Topology</div>
      ${t&&t.topology.units.length>0?i`${t.topology.units.map(e=>i`<${Ko} node=${e} />`)}`:i`<div class="empty-state">No command topology projected yet.</div>`}
    </section>
  `}function Tu(){const t=Gt.value;return i`
    <section class="card command-section">
      <div class="card-title">Alerts</div>
      ${t&&t.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>i`<${$u} alert=${e} />`)}
          </div>`:i`<div class="empty-state">No command-plane alerts right now.</div>`}
    </section>
  `}function Cu(){const t=Gt.value;return i`
    <section class="card command-section">
      <div class="card-title">Trace</div>
      ${t&&t.traces.events.length>0?i`<div class="command-trace-stack">
            ${t.traces.events.map(e=>i`<${Ho} event=${e} />`)}
          </div>`:i`<div class="empty-state">No recent trace events.</div>`}
    </section>
  `}function Nu(){const t=Gt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Approval Queue</div>
        ${t&&t.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>i`<${hu} decision=${e} />`)}
            </div>`:i`<div class="empty-state">No approval queue items.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Unit Controls</div>
        ${t&&t.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>i`<${yu} row=${e} />`)}
            </div>`:i`<div class="empty-state">No capacity rows projected.</div>`}
      </section>
    </div>
  `}function Ru(){switch(si.value){case"swarm":return i`<${Su} />`;case"topology":return i`<${wu} />`;case"alerts":return i`<${Tu} />`;case"trace":return i`<${Cu} />`;case"control":return i`<${Nu} />`;case"operations":default:return i`<${Au} />`}}function Lu(){return Ct(()=>{Hd(),Fo()},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>Command Plane</h2>
          <p>Operations-first command surface for company → platoon → squad → agent orchestration, approvals, alerts, and traceability.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Zt(()=>Gd())}}
            disabled=${tt("dispatch:tick")}
          >
            ${tt("dispatch:tick")?"Reconciling…":"Run Tick"}
          </button>
          <button class="control-btn ghost" onClick=${()=>{kn()}} disabled=${oa.value}>
            ${oa.value?"Refreshing…":"Refresh"}
          </button>
        </div>
      </div>

      ${ra.value?i`<div class="empty-state error">${ra.value}</div>`:null}
      ${la.value?i`<div class="empty-state error">${la.value}</div>`:null}

      <${lu} />
      <${mu} />
      <${fu} />
      <${vu} />
      <${Ru} />
    </section>
  `}const Rn=f(null),ua=f(!1),ee=f(null),K=f(!1),pa=f([]);let Du=1;function U(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function L(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function pt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Uo(t){return typeof t=="boolean"?t:void 0}function Pu(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function xe(t,e=[]){if(Array.isArray(t))return t;if(!U(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function Iu(t){return U(t)?{id:L(t.id),seq:pt(t.seq),from:L(t.from)??L(t.from_agent)??"system",content:L(t.content)??"",timestamp:L(t.timestamp)??new Date().toISOString(),type:L(t.type)}:null}function Eu(t){return U(t)?{room_id:L(t.room_id),current_room:L(t.current_room)??L(t.room),project:L(t.project),cluster:L(t.cluster),paused:Uo(t.paused),pause_reason:L(t.pause_reason)??null,paused_by:L(t.paused_by)??null,paused_at:L(t.paused_at)??null}:{}}function Ii(t){if(!U(t))return;const e=Object.entries(t).map(([n,a])=>{const s=L(a);return s?[n,s]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Mu(t){if(!U(t))return null;const e=U(t.status)?t.status:void 0,n=U(t.summary)?t.summary:U(e==null?void 0:e.summary)?e.summary:void 0,a=U(t.session)?t.session:U(e==null?void 0:e.session)?e.session:void 0,s=L(t.session_id)??L(n==null?void 0:n.session_id)??L(a==null?void 0:a.session_id);if(!s)return null;const o=Ii(t.report_paths)??Ii(e==null?void 0:e.report_paths),r=xe(t.recent_events,["events"]).filter(U);return{session_id:s,status:L(t.status)??L(n==null?void 0:n.status)??L(a==null?void 0:a.status),progress_pct:pt(t.progress_pct)??pt(n==null?void 0:n.progress_pct),elapsed_sec:pt(t.elapsed_sec)??pt(n==null?void 0:n.elapsed_sec),remaining_sec:pt(t.remaining_sec)??pt(n==null?void 0:n.remaining_sec),done_delta_total:pt(t.done_delta_total)??pt(n==null?void 0:n.done_delta_total),summary:n,team_health:U(t.team_health)?t.team_health:U(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:U(t.communication_metrics)?t.communication_metrics:U(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:U(t.orchestration_state)?t.orchestration_state:U(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:U(t.cascade_metrics)?t.cascade_metrics:U(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:a,recent_events:r}}function Ou(t){if(!U(t))return null;const e=L(t.name);if(!e)return null;const n=U(t.context)?t.context:void 0;return{name:e,agent_name:L(t.agent_name),status:L(t.status),autonomy_level:L(t.autonomy_level),context_ratio:pt(t.context_ratio)??pt(n==null?void 0:n.context_ratio),generation:pt(t.generation),active_goal_ids:Pu(t.active_goal_ids),last_autonomous_action_at:L(t.last_autonomous_action_at)??null,last_turn_ago_s:pt(t.last_turn_ago_s),model:L(t.model)??L(t.active_model)??L(t.primary_model)}}function zu(t){if(!U(t))return null;const e=L(t.confirm_token)??L(t.token);return e?{confirm_token:e,actor:L(t.actor),action_type:L(t.action_type),target_type:L(t.target_type),target_id:L(t.target_id)??null,delegated_tool:L(t.delegated_tool),created_at:L(t.created_at),preview:t.preview}:null}function qu(t){const e=U(t)?t:{};return{room:Eu(e.room),sessions:xe(e.sessions,["items","sessions"]).map(Mu).filter(n=>n!==null),keepers:xe(e.keepers,["items","keepers"]).map(Ou).filter(n=>n!==null),recent_messages:xe(e.recent_messages,["messages"]).map(Iu).filter(n=>n!==null),pending_confirms:xe(e.pending_confirms,["items","confirms"]).map(zu).filter(n=>n!==null),available_actions:xe(e.available_actions,["actions"]).filter(U).map(n=>({action_type:L(n.action_type)??"unknown",target_type:L(n.target_type)??"unknown",description:L(n.description),confirm_required:Uo(n.confirm_required)}))}}function In(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Ei(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function ma(t){pa.value=[{...t,id:Du++,at:new Date().toISOString()},...pa.value].slice(0,20)}function Bo(t){return t.confirm_required?In(t.preview)||"Confirmation required":In(t.result)||In(t.executed_action)||In(t.delegated_tool_result)||t.status}async function Oe(){ua.value=!0,ee.value=null;try{const t=await Kr();Rn.value=qu(t)}catch(t){ee.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{ua.value=!1}}async function ju(t){K.value=!0,ee.value=null;try{const e=await Tn(t);return ma({actor:t.actor,action_type:t.action_type,target_label:Ei(t),outcome:e.confirm_required?"preview":"executed",message:Bo(e),delegated_tool:e.delegated_tool}),await Oe(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw ee.value=n,ma({actor:t.actor,action_type:t.action_type,target_label:Ei(t),outcome:"error",message:n}),e}finally{K.value=!1}}async function Fu(t,e){K.value=!0,ee.value=null;try{const n=await Jr(t,e);return ma({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Bo(n),delegated_tool:n.delegated_tool}),await Oe(),n}catch(n){const a=n instanceof Error?n.message:"Operator confirmation failed";throw ee.value=a,ma({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),n}finally{K.value=!1}}const Wo="masc_dashboard_agent_name";function Ku(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(Wo))==null?void 0:a.trim())||"dashboard"}const Da=f(Ku()),tn=f(""),Ds=f("Operator pause"),en=f(""),va=f(""),Ps=f("2"),fa=f(""),Pe=f("note"),ga=f(""),_a=f(""),$a=f(""),Is=f("2"),Es=f("Operator stop request"),Ms=f(""),nn=f("");function Hu(t){const e=t.trim()||"dashboard";Da.value=e,localStorage.setItem(Wo,e)}function Mi(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Uu(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function ha(t){return typeof t=="string"?t.trim().toLowerCase():""}function Bu(t){var a;const e=ha(t.status);if(e==="paused")return"bad";const n=ha((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function Oi(t){const e=ha(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":(t.context_ratio??0)>=.8||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}async function fe(t){const e=Da.value.trim()||"dashboard";try{const n=await ju({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?A("Confirmation queued","warning"):A(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return A(a,"error"),null}}async function zi(){const t=tn.value.trim();if(!t)return;await fe({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(tn.value="")}async function Wu(){await fe({action_type:"room_pause",target_type:"room",payload:{reason:Ds.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function Gu(){await fe({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function Ju(){const t=en.value.trim();if(!t)return;await fe({action_type:"task_inject",target_type:"room",payload:{title:t,description:va.value.trim()||"Injected from Ops tab",priority:Number.parseInt(Ps.value,10)||2},successMessage:"Task injection submitted"})&&(en.value="",va.value="")}async function Vu(){var o;const t=Rn.value,e=fa.value||((o=t==null?void 0:t.sessions[0])==null?void 0:o.session_id)||"";if(!e){A("Select a team session first","warning");return}const n={turn_kind:Pe.value},a=ga.value.trim();a&&(n.message=a),Pe.value==="task"&&(n.task_title=_a.value.trim()||"Operator injected task",n.task_description=$a.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(Is.value,10)||2),await fe({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(ga.value="",Pe.value==="task"&&(_a.value="",$a.value=""))}async function Qu(){var n;const t=Rn.value,e=fa.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){A("Select a team session first","warning");return}await fe({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Es.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function Yu(){var s;const t=Rn.value,e=Ms.value||((s=t==null?void 0:t.keepers[0])==null?void 0:s.name)||"",n=nn.value.trim();if(!e){A("Select a keeper first","warning");return}if(!n)return;await fe({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(nn.value="")}async function Xu(t){const e=Da.value.trim()||"dashboard";try{await Fu(e,t),A("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";A(a,"error")}}function Zu(){var c;const t=Rn.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],a=(t==null?void 0:t.keepers)??[],s=(t==null?void 0:t.pending_confirms)??[],o=(t==null?void 0:t.recent_messages)??[],r=n.find(l=>l.session_id===fa.value)??n[0]??null,d=a.find(l=>l.name===Ms.value)??a[0]??null,p=n.filter(l=>Bu(l)!=="ok"),_=a.filter(l=>Oi(l)!=="ok"),v=[{key:"room",label:"Room Gate",value:e.paused?"Paused":"Open",detail:e.paused?`Resume gate armed${e.pause_reason?` · ${e.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:e.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:s.length,detail:s.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:s.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:p.length,detail:p.length>0?"Team sessions need steering, stop, or checkpoint attention":"Team sessions look healthy from the operator snapshot",tone:p.some(l=>ha(l.status)==="paused")?"bad":p.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:_.length,detail:_.length>0?"At least one keeper is stale, offline, or running hot":"Keepers are available for direct intervention",tone:_.some(l=>Oi(l)==="bad")?"bad":_.length>0?"warn":"ok"}];return i`
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
            value=${Da.value}
            onInput=${l=>Hu(l.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{Oe()}} disabled=${ua.value||K.value}>
            ${ua.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${ee.value?i`
        <section class="ops-banner error">${ee.value}</section>
      `:null}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Action Priority</h2>
          <p class="monitor-subheadline">Ops is the command surface. These four signals explain when to intervene before you drop into a specific control panel.</p>
        </div>
        <div class="ops-priority-grid">
          ${v.map(l=>i`
            <div key=${l.key} class="ops-priority-card ${l.tone}">
              <span class="ops-priority-label">${l.label}</span>
              <strong>${l.value}</strong>
              <div class="ops-priority-detail">${l.detail}</div>
            </div>
          `)}
        </div>
      </section>

      ${s.length>0?i`
        <section class="card ops-confirmations">
          <div class="card-title">Pending Confirmations</div>
          <p class="ops-context-note">Only previewed actions that still need an explicit operator confirmation stay here.</p>
          <div class="ops-confirmation-list">
            ${s.map(l=>i`
              <article key=${l.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${l.action_type??"unknown"}</strong>
                  <span>${l.target_type??"target"}${l.target_id?`:${l.target_id}`:""}</span>
                  <span>${l.delegated_tool??"delegated tool pending"}</span>
                </div>
                ${l.preview?i`<pre class="ops-code-block">${Mi(l.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{Xu(l.confirm_token)}} disabled=${K.value}>
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
              value=${tn.value}
              onInput=${l=>{tn.value=l.target.value}}
              onKeyDown=${l=>{l.key==="Enter"&&zi()}}
              disabled=${K.value}
            />
            <button class="control-btn" onClick=${()=>{zi()}} disabled=${K.value||tn.value.trim()===""}>
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
              disabled=${K.value}
            />
            <button class="control-btn ghost" onClick=${()=>{Wu()}} disabled=${K.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{Gu()}} disabled=${K.value}>
              Resume
            </button>
          </div>

          <div class="ops-section-head">Task Inject</div>
          <input
            class="control-input"
            type="text"
            placeholder="Task title"
            value=${en.value}
            onInput=${l=>{en.value=l.target.value}}
            disabled=${K.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${va.value}
            onInput=${l=>{va.value=l.target.value}}
            disabled=${K.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${Ps.value}
              onChange=${l=>{Ps.value=l.target.value}}
              disabled=${K.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{Ju()}} disabled=${K.value||en.value.trim()===""}>
              Inject
            </button>
          </div>

          ${o.length>0?i`
            <div class="ops-section-head">Context Tail</div>
            <div class="ops-context-note">Recent room chatter stays available for context, but command work remains the primary focus of this tab.</div>
            <div class="ops-feed-list">
              ${o.slice(0,6).map(l=>i`
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
            ${n.length===0?i`<div class="ops-empty">No team sessions available.</div>`:n.map(l=>{var g;return i`
              <button
                key=${l.session_id}
                class="ops-entity-card ${(r==null?void 0:r.session_id)===l.session_id?"active":""}"
                onClick=${()=>{fa.value=l.session_id}}
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

          ${r?i`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${r.session_id}</div>
              <div class="ops-detail-meta">
                <span>Status: ${r.status??"unknown"}</span>
                <span>Elapsed: ${r.elapsed_sec??0}s</span>
                <span>Remaining: ${r.remaining_sec??0}s</span>
              </div>
              ${r.recent_events&&r.recent_events.length>0?i`
                <pre class="ops-code-block compact">${Mi(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${Pe.value}
              onChange=${l=>{Pe.value=l.target.value}}
              disabled=${K.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{Vu()}} disabled=${K.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${ga.value}
            onInput=${l=>{ga.value=l.target.value}}
            disabled=${K.value||!r}
          ></textarea>
          ${Pe.value==="task"?i`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${_a.value}
              onInput=${l=>{_a.value=l.target.value}}
              disabled=${K.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${$a.value}
              onInput=${l=>{$a.value=l.target.value}}
              disabled=${K.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${Is.value}
              onChange=${l=>{Is.value=l.target.value}}
              disabled=${K.value||!r}
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
              value=${Es.value}
              onInput=${l=>{Es.value=l.target.value}}
              disabled=${K.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{Qu()}} disabled=${K.value||!r}>
              Stop
            </button>
          </div>
        </section>

        <section class="card ops-panel">
          <div class="card-title">Keepers</div>
          <div class="ops-entity-list">
            ${a.length===0?i`<div class="ops-empty">No keepers available.</div>`:a.map(l=>i`
              <button
                key=${l.name}
                class="ops-entity-card ${(d==null?void 0:d.name)===l.name?"active":""}"
                onClick=${()=>{Ms.value=l.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${l.name}</strong>
                  <span class="status-badge ${l.status??"idle"}">${l.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${l.model??"model n/a"}</span>
                  <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${Uu(l.last_turn_ago_s)}</span>
                </div>
              </button>
            `)}
          </div>

          ${d?i`
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
            value=${nn.value}
            onInput=${l=>{nn.value=l.target.value}}
            disabled=${K.value||!d}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{Yu()}} disabled=${K.value||!d||nn.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${pa.value.length===0?i`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:pa.value.map(l=>i`
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
  `}function tp({text:t}){if(!t)return null;const e=ep(t);return i`<div class="markdown-content">${e}</div>`}function ep(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],d=s.slice(r.length).trim(),p=[];for(a++;a<e.length&&!e[a].startsWith(r);)p.push(e[a]),a++;a++,n.push(i`<pre><code class=${d?`language-${d}`:""}>${p.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],d=s.trim().replace(/^<think>/,"").trim();for(d&&d!=="</think>"&&r.push(d),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const _=e[a].replace("</think>","").trim();_&&r.push(_),a++}const p=r.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Ba(p)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(i`<blockquote>${Ba(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const o=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;o.push(r),a++}o.length>0&&n.push(i`<p>${Ba(o.join(`
`))}</p>`)}return n}function Ba(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const o=s[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(s[2]){const o=s[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(s[3]){const o=s[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else s[4]&&s[5]&&e.push(i`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const Qe=f("posts"),Os=f([]),zs=f([]),an=f(""),ya=f(!1),sn=f(!1),xn=f(""),ba=f(null),At=f(null),qs=f(!1),Xt=f(null),Gn=f(null);async function Pa(){ya.value=!0,xn.value="";try{const[t,e]=await Promise.all([Ll(),Dl()]);Os.value=t,zs.value=e,Xt.value=!0,Gn.value=Date.now()}catch(t){xn.value=t instanceof Error?t.message:"Failed to load council data",Xt.value=!1}finally{ya.value=!1}}$c(Pa);async function qi(){const t=an.value.trim();if(t){sn.value=!0;try{const e=await Pl(t);an.value="",A(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Pa()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";A(n,"error")}finally{sn.value=!1}}}async function np(t){ba.value=t,qs.value=!0,At.value=null;try{At.value=await Il(t)}catch(e){xn.value=e instanceof Error?e.message:"Failed to load debate status",At.value=null}finally{qs.value=!1}}const Go=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Jn=f(null),on=f([]),me=f(!1),ue=f(null),rn=f("");function ap(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const sp=f(ap()),ln=f(!1);async function ri(t){ue.value=t,Jn.value=null,on.value=[],me.value=!0;try{const e=await el(t);if(ue.value!==t)return;Jn.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},on.value=e.comments??[]}catch{ue.value===t&&(Jn.value=null,on.value=[])}finally{ue.value===t&&(me.value=!1)}}async function ji(t){const e=rn.value.trim();if(e){ln.value=!0;try{await nl(t,sp.value,e),rn.value="",A("Comment posted","success"),await ri(t),Ot()}catch{A("Failed to post comment","error")}finally{ln.value=!1}}}function ip(){const t=gn.value;return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Go.map(e=>i`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{gn.value=e.id,Ot()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${le.value?"is-active":""}"
          onClick=${()=>{le.value=!le.value,Ot()}}
        >
          ${le.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${Ot} disabled=${$n.value}>
          ${$n.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function js(){var e;const t=(e=ne.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:i`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?i`<span class="feed-health-meta">Last sync: <${j} timestamp=${t.last_sync_at} /></span>`:i`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Jo({flair:t}){return t?i`<span class="post-flair ${t}">${t}</span>`:null}function op(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function Fi(t){return t.updated_at!==t.created_at}function Fs(){var n;const t=((n=Go.find(a=>a.id===gn.value))==null?void 0:n.label)??gn.value,e=qe.value.length;return i`
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
        <strong>${le.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Ts.value?i`<${j} timestamp=${Ts.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function rp({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await uo(t.id,n),Ot()}catch{A("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>$r(t.id)}>
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
              <${Jo} flair=${t.flair} />
              ${Fi(t)?i`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${j} timestamp=${t.created_at} /></span>
            ${Fi(t)?i`<span>Updated <${j} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?i`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${op(t.content)}</div>
      </div>
    </div>
  `}function lp({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${j} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function cp({postId:t}){return i`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${rn.value}
        onInput=${e=>{rn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&ji(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${ln.value}
      />
      <button
        onClick=${()=>ji(t)}
        disabled=${ln.value||rn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${ln.value?"...":"Post"}
      </button>
    </div>
  `}function dp({post:t}){ue.value!==t.id&&!me.value&&ri(t.id);const e=async n=>{try{await uo(t.id,n),Ot()}catch{A("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>Et("board")}>← Back to Board</button>
      <${w} title=${i`${t.title} <${Jo} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${tp} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${j} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?i`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${w} title="Comments (${me.value?"...":on.value.length})">
        ${me.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${lp} comments=${on.value} />`}
        <${cp} postId=${t.id} />
      <//>
    </div>
  `}function up({debate:t}){const e=ba.value===t.id;return i`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>np(t.id)}
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
  `}function pp({session:t}){return i`
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
  `}function Vo(){return Xt.value===null||Xt.value&&!Gn.value?null:i`
    <div class="feed-health-banner ${Xt.value===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${Xt.value===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${Gn.value?i`<span class="feed-health-meta">Last sync: <${j} timestamp=${Gn.value} /></span>`:i`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function mp(){const t=Xt.value===!1;return i`
    <div>
      <${Vo} />
      <${w} title="Start Debate" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${an.value}
            onInput=${e=>{an.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&qi()}}
            disabled=${sn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${qi}
            disabled=${sn.value||an.value.trim()===""}
          >
            ${sn.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Pa} disabled=${ya.value}>
            ${ya.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${xn.value?i`<div class="council-error">${xn.value}</div>`:null}
      <//>

      <${w} title="Debates" class="section">
        <div class="council-list">
          ${Os.value.length===0?i`<div class="empty-state">${t?"No debates loaded (council feed degraded).":"No debates yet"}</div>`:Os.value.map(e=>i`<${up} key=${e.id} debate=${e} />`)}
        </div>
      <//>

      <${w} title=${ba.value?`Debate Detail (${ba.value})`:"Debate Detail"} class="section">
        ${qs.value?i`<div class="loading-indicator">Loading debate detail...</div>`:At.value?i`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${At.value.status}</span>
                  <span>Total arguments: ${At.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${At.value.support_count}</span>
                  <span>Oppose: ${At.value.oppose_count}</span>
                  <span>Neutral: ${At.value.neutral_count}</span>
                </div>
                ${At.value.summary_text?i`<pre class="council-detail">${At.value.summary_text}</pre>`:null}
              `:i`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function vp(){const t=Xt.value===!1;return i`
    <div>
      <${Vo} />
      <${w} title="Voting Sessions" class="section">
        <div class="council-list">
          ${zs.value.length===0?i`<div class="empty-state">${t?"No sessions loaded (council feed degraded).":"No active sessions"}</div>`:zs.value.map(e=>i`<${pp} key=${e.id} session=${e} />`)}
        </div>
      <//>
    </div>
  `}function fp(){const t=Qe.value;return i`
    <div class="overview-sub-tabs" style="margin-bottom: 12px;">
      <button class="sub-tab-btn ${t==="posts"?"active":""}" onClick=${()=>{Qe.value="posts"}}>Posts</button>
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{Qe.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{Qe.value="voting"}}>Voting</button>
    </div>
  `}function gp(){var a,s;const t=qe.value,e=$n.value,n=((s=(a=ne.value)==null?void 0:a.data_quality)==null?void 0:s.board_contract_ok)===!1;return i`
    <div>
      <${js} />
      <${Fs} />
      <${ip} />
      ${e?i`<div class="loading-indicator">Loading board...</div>`:t.length===0?i`
              <div class="empty-state">
                ${n?"No posts loaded (board feed degraded). Check board contract sync.":le.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
              </div>
            `:i`<div class="board-post-list">
              ${t.map(o=>i`<${rp} key=${o.id} post=${o} />`)}
            </div>`}
    </div>
  `}function _p(){var s,o;const t=qe.value,e=Tt.value.postId,n=((o=(s=ne.value)==null?void 0:s.data_quality)==null?void 0:o.board_contract_ok)===!1,a=Qe.value;if(Ct(()=>{(a==="debates"||a==="voting")&&Pa()},[a]),e){const r=t.find(d=>d.id===e)??(ue.value===e?Jn.value:null);return!r&&ue.value!==e&&!me.value&&ri(e),r?i`
          <${js} />
          <${Fs} />
          <${dp} post=${r} />
        `:i`
          <div>
            <${js} />
            <${Fs} />
            <button class="back-btn" onClick=${()=>Et("board")}>← Back to Board</button>
            ${me.value?i`<div class="loading-indicator">Loading post...</div>`:i`
                  <div class="empty-state">
                    ${n?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return i`
    <${fp} />
    ${a==="debates"?i`<${mp} />`:a==="voting"?i`<${vp} />`:i`<${gp} />`}
  `}function $p(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function hp(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function yp(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const Qo=120,bp=12,kp=16,xp=12,Ks=f("all"),Sp={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},Ap={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function wp(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Tp(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:$p(t),actor:hp(t),content:yp(t),timestamp:new Date(t.timestamp).toISOString()}}function Cp(t,e){var s;const n=(s=t.assignee)==null?void 0:s.trim(),a=t.updated_at??t.created_at;return!n||!a?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:a}}function Np(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function En(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Hs(t){return t.last_heartbeat??En(t.last_turn_ago_s)??En(t.last_proactive_ago_s)??En(t.last_handoff_ago_s)??En(t.last_compaction_ago_s)}function Rp(t,e){const n=Hs(t);if(!n)return null;const a=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${a}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${a}`,timestamp:n}}function Dt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const Us=yt(()=>{const t=fn.value.map(wp),e=Zn.value.map(Tp),n=[...vt.value].sort((o,r)=>Dt(r.updated_at??r.created_at??0)-Dt(o.updated_at??o.created_at??0)).slice(0,bp).map(Cp).filter(o=>o!==null),a=[...qe.value].sort((o,r)=>Dt(r.updated_at||r.created_at)-Dt(o.updated_at||o.created_at)).slice(0,kp).map(Np),s=[...Wt.value].sort((o,r)=>Dt(Hs(r)??0)-Dt(Hs(o)??0)).slice(0,xp).map(Rp).filter(o=>o!==null);return[...t,...e,...n,...a,...s].sort((o,r)=>Dt(r.timestamp)-Dt(o.timestamp))}),Lp=yt(()=>{const t=Us.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),Dp=yt(()=>{const t=Ks.value;return(t==="all"?Us.value:Us.value.filter(n=>n.kind===t)).slice(0,Qo)}),Pp=yt(()=>{const t=La.value,e={activeAssignedCount:0,lastActivityAt:null,lastActivityText:null};return ht.value.map(n=>({agent:n,motion:t.get(n.name.trim().toLowerCase())??e})).sort((n,a)=>{const s=a.motion.activeAssignedCount-n.motion.activeAssignedCount;return s!==0?s:Dt(a.motion.lastActivityAt??0)-Dt(n.motion.lastActivityAt??0)})});function Ip(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function Ge({label:t,value:e,color:n}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function Ep({row:t}){return i`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${Ip(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${Ap[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function Mp(){const t=Lp.value,e=Dp.value,n=e[0],a=Pp.value;return i`
    <div class="stats-grid">
      <${Ge} label="Visible rows" value=${e.length} />
      <${Ge} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${Ge} label="Keeper signals" value=${t.keepers} color="#4ade80" />
      <${Ge} label="Board signals" value=${t.board} color="#fbbf24" />
      <${Ge} label="SSE events" value=${An.value} color="#c084fc" />
    </div>

    <${w} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(s=>i`
            <button
              class="goal-filter-btn ${Ks.value===s?"active":""}"
              onClick=${()=>{Ks.value=s}}
            >
              ${Sp[s]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${qt.value?"":"pill-stale"}">
            ${qt.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?i`Latest: <${j} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${Qo} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      <div class="terminal-feed">
        ${e.length===0?i`<div class="empty-state">Waiting for live or snapshot signals...</div>`:e.map(s=>i`<${Ep} key=${s.id} row=${s} />`)}
      </div>
    <//>

    <${w} title="Agent Motion" class="section">
      <div class="activity-motion-list">
        ${a.length===0?i`<div class="empty-state">No active agents</div>`:a.map(({agent:s,motion:o})=>i`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${s.name}</div>
                  <div class="activity-motion-meta">
                    ${o.activeAssignedCount>0?`${o.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${o.lastActivityAt?i` · <${j} timestamp=${o.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${o.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function Yo({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,s=e/2,o=2*Math.PI*a,r=o*((100-t*100)/100);let d="mitosis-safe";return t>=.8?d="mitosis-critical":t>=.5&&(d="mitosis-warn"),i`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${s}" cy="${s}" r="${a}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${d}" 
          cx="${s}" cy="${s}" r="${a}" 
          stroke-width="${n}" 
          stroke-dasharray="${o}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${d}">${Math.round(t*100)}%</span>
    </div>
  `}const Wa=600*1e3,Op=1200*1e3,Ki=.8;function Qt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function be(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function zp(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function qp(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function jp(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Fp(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function Kp(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function Hp(t){var p,_;const e=La.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-Qt(n)):Number.POSITIVE_INFINITY,s=!!((p=t.current_task)!=null&&p.trim())||e.activeAssignedCount>0;let o="watching",r="ok",d="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",r="bad",d=n?"Offline or inactive":"No recent presence"):a>Op?(o="quiet",r="bad",d=s?"Working without a fresh signal":"No fresh agent signal"):s?(o="working",r=a>Wa?"warn":"ok",d=a>Wa?"Execution looks quiet for too long":"Task and live signal aligned"):a>Wa?(o="quiet",r="warn",d="Quiet but still reachable"):t.status==="idle"&&(o="watching",r="ok",d="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:r,focus:((_=t.current_task)==null?void 0:_.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:d}}function Up(t){const e=ko.value.get(t.name)??"idle",n=xo.value.has(t.name),a=t.context_ratio??0;let s="healthy",o="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(s="critical",o="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=Ki)&&(s="warning",o="warn",r=a>=Ki?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:s,tone:o,focus:Fp(t),note:r}}function Je({label:t,value:e,color:n,caption:a}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?i`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Bp({item:t}){const e=t.kind==="agent"?()=>De(t.agent.name):()=>ia(t.keeper);return i`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?i`<span><${j} timestamp=${t.timestamp} /></span>`:i`<span>No signal</span>`}
      </div>
    </button>
  `}function Hi({row:t}){const{agent:e,motion:n}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>De(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Yo} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Nt} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${zp(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?i`<span>Signal <${j} timestamp=${t.lastSignalAt} /></span>`:i`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
        ${e.last_seen?i`<span>Seen <${j} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?i`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function Wp({row:t}){const{keeper:e}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>ia(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Yo} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Nt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${qp(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?i`<span>Heartbeat <${j} timestamp=${e.last_heartbeat} /></span>`:i`<span>No heartbeat</span>`}
        <span>${Kp(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${jp(e.context_ratio)}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?i`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function Gp(){const t=[...ht.value].map(Hp).sort((v,c)=>{const l=be(c.tone)-be(v.tone);if(l!==0)return l;const g=c.activeTaskCount-v.activeTaskCount;return g!==0?g:Qt(c.lastSignalAt)-Qt(v.lastSignalAt)}),e=[...Wt.value].map(Up).sort((v,c)=>{const l=be(c.tone)-be(v.tone);if(l!==0)return l;const g=(c.keeper.context_ratio??0)-(v.keeper.context_ratio??0);return g!==0?g:Qt(c.keeper.last_heartbeat)-Qt(v.keeper.last_heartbeat)}),n=t.filter(v=>v.state!=="offline"),a=t.filter(v=>v.state==="offline"),s=n.length,o=t.filter(v=>v.state==="working").length,r=t.filter(v=>v.lastSignalAt&&Date.now()-Qt(v.lastSignalAt)<=12e4).length,d=t.filter(v=>v.tone!=="ok"),p=e.filter(v=>v.tone!=="ok"),_=[...p.map(v=>({kind:"keeper",key:`keeper-${v.keeper.name}`,tone:v.tone,title:v.keeper.name,subtitle:`${v.note} · ${v.focus}`,timestamp:v.keeper.last_heartbeat??null,keeper:v.keeper})),...d.map(v=>({kind:"agent",key:`agent-${v.agent.name}`,tone:v.tone,title:v.agent.name,subtitle:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt,agent:v.agent}))].sort((v,c)=>{const l=be(c.tone)-be(v.tone);return l!==0?l:Qt(c.timestamp)-Qt(v.timestamp)}).slice(0,8);return i`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${Je} label="Agents online" value=${s} color="#4ade80" caption="active + idle" />
        <${Je} label="Working now" value=${o} color="#fbbf24" caption="task or claimed load" />
        <${Je} label="Fresh signals" value=${r} color="#22d3ee" caption="within last 2 minutes" />
        <${Je} label="Agent alerts" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="quiet or offline" />
        <${Je} label="Keeper alerts" value=${p.length} color=${p.length>0?"#fb7185":"#4ade80"} caption="stale or high pressure" />
      </div>

      <${w} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${_.length===0?i`<div class="empty-state">No agent or keeper alerts right now</div>`:_.map(v=>i`<${Bp} key=${v.key} item=${v} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${w} title="Keeper Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?i`<div class="empty-state">No keepers active</div>`:e.map(v=>i`<${Wp} key=${v.keeper.name} row=${v} />`)}
          </div>
        <//>

        <${w} title="Agent Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Current task, recent signal, and quiet drift are surfaced together.</p>
          </div>
          <div class="monitor-list">
            ${t.length===0?i`<div class="empty-state">No agents registered</div>`:i`
                ${n.length>0?i`
                  <div class="agent-group-header">
                    Active <span class="group-count">${n.length}</span>
                  </div>
                  ${n.map(v=>i`<${Hi} key=${v.agent.name} row=${v} />`)}
                `:null}
                ${a.length>0?i`
                  <div class="agent-group-header">
                    Offline <span class="group-count">${a.length}</span>
                  </div>
                  ${a.map(v=>i`<${Hi} key=${v.agent.name} row=${v} />`)}
                `:null}
              `}
          </div>
        <//>
      </div>
    </div>
  `}const ka=f("all"),xa=f("all"),Bs=yt(()=>{let t=_n.value;return ka.value!=="all"&&(t=t.filter(e=>e.horizon===ka.value)),xa.value!=="all"&&(t=t.filter(e=>e.status===xa.value)),t}),Jp=yt(()=>{const t={short:[],mid:[],long:[]};for(const e of Bs.value){const n=t[e.horizon];n&&n.push(e)}return t}),Vp=yt(()=>{const t=Array.from($o.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function Qp(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function li(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function Vn(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Yp(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Ui(t){return t.toFixed(4)}function Bi(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function Xp({goal:t}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${Vn(t.horizon)}">
            ${li(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${Qp(t.priority)}</span>
          ${t.metric?i`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?i`<span class="goal-due">Due: <${j} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?i`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${Nt} status=${t.status} />
        <div class="goal-updated">
          <${j} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Wi({label:t,timestamp:e,source:n,note:a}){return i`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${a?i`<div class="planning-freshness-source">${a}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?i`<${j} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function Ga({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,s)=>s.priority-a.priority);return i`
    <${w} title="${li(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(a=>i`<${Xp} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function Zp(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>i`
          <button
            class="goal-filter-btn ${ka.value===t?"active":""}"
            onClick=${()=>{ka.value=t}}
          >
            ${t==="all"?"All":li(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>i`
          <button
            class="goal-filter-btn ${xa.value===t?"active":""}"
            onClick=${()=>{xa.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function tm(){const t=_n.value,e=t.filter(s=>s.status==="active").length,n=t.filter(s=>s.status==="completed").length,a={short:0,mid:0,long:0};for(const s of t)s.horizon in a&&a[s.horizon]++;return i`
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
        <div class="goal-summary-value" style="color:${Vn("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Vn("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Vn("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function em({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return i`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${Nt} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Ui(t.baseline_metric)}</span>
          <span>Current ${Ui(t.current_metric)}</span>
          <span class=${Bi(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Bi(t)}
          </span>
          <span>Elapsed ${Yp(t.elapsed_seconds)}</span>
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
  `}function Ja({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return i`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?i`<${j} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function nm(){const{todo:t,inProgress:e,done:n}=bo.value;return i`
    <${w} title="Task Backlog" class="section">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?i`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>i`<${Ja} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?i`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>i`<${Ja} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?i`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>i`<${Ja} key=${a.id} task=${a} />`)}
          ${n.length>20?i`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function am(){const t=Jp.value,e=Vp.value,n=e.filter(d=>d.status==="running").length,a=e.filter(d=>d.recoverable).length,s=_n.value.filter(d=>d.status==="active").length,o=xs.value,r=o==="idle"?"No loop running":o==="error"?Ss.value??"MDAL snapshot unavailable":"Current loop snapshot";return i`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${s}</div>
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

      <${w} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>/api/v1/mdal/loops</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${hn} disabled=${we.value}>
              ${we.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${Ee} disabled=${Te.value}>
              ${Te.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{hn(),Ee()}}
              disabled=${we.value||Te.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${Wi} label="Goals" timestamp=${ho.value} source="masc_goal_list" />
          <${Wi}
            label="MDAL loops"
            timestamp=${yo.value}
            source="/api/v1/mdal/loops"
            note=${r}
          />
        </div>
      <//>

      <${w} title="Goal Pipeline" class="section">
        <${tm} />
        <${Zp} />
      <//>

      ${we.value&&_n.value.length===0?i`<div class="loading-indicator">Loading goals...</div>`:Bs.value.length===0?i`<div class="empty-state">No goals match the current filters</div>`:i`
              <${Ga} horizon="short" items=${t.short??[]} />
              <${Ga} horizon="mid" items=${t.mid??[]} />
              <${Ga} horizon="long" items=${t.long??[]} />
            `}

      <${w} title="MDAL Loops" class="section">
        ${Te.value&&e.length===0?i`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&o==="error"?i`
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
                  ${e.map(d=>i`<${em} key=${d.loop_id} loop=${d} />`)}
                </div>
              `}
      <//>

      <${nm} />
    </div>
  `}const Se=f(""),Va=f("ability_check"),Qa=f("10"),Ya=f("12"),Mn=f(""),On=f("idle"),Yt=f(""),zn=f("keeper-late"),Xa=f("player"),Za=f(""),$t=f("idle"),ts=f(null),qn=f(""),es=f(""),ns=f("player"),as=f(""),ss=f(""),is=f(""),cn=f("20"),os=f("20"),rs=f(""),jn=f("idle"),Ws=f(null),Xo=f("overview"),ls=f("all"),cs=f("all"),ds=f("all"),sm=12e4,Ia=f(null),Gi=f(Date.now());function im(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function om(t,e){return e>0?Math.round(t/e*100):0}const rm={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},lm={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Fn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function cm(t){const e=t.trim().toLowerCase();return rm[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function dm(t){const e=t.trim().toLowerCase();return lm[e]??"상황에 따라 선택되는 전술 액션입니다."}function te(t){return typeof t=="object"&&t!==null}function ut(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function Pt(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function Sn(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const um=new Set(["str","dex","con","int","wis","cha"]);function pm(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(s){throw new Error(`능력치 JSON 파싱 실패: ${s instanceof Error?s.message:"invalid json"}`)}if(!te(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([s,o])=>{const r=s.trim();if(r){if(typeof o=="number"&&Number.isFinite(o)){a[r]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const d=Number.parseFloat(o.trim());if(Number.isFinite(d)){a[r]=Math.max(0,Math.trunc(d));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function mm(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt(cn.value.trim(),10);Number.isFinite(a)&&a>n&&(cn.value=String(n))}function Gs(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function vm(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function fm(t){Xo.value=t}function Zo(t){const e=Ia.value;return e==null||e<=t}function gm(t){const e=Ia.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Sa(){Ia.value=null}function tr(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function _m(t,e){tr(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Ia.value=Date.now()+sm,A("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function Qn(t){return Zo(t)?(A("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Js(t,e,n){return tr([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function $m({hp:t,max:e}){const n=om(t,e),a=im(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function hm({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function ym({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function er({actor:t}){var p,_,v,c;const e=(p=t.archetype)==null?void 0:p.trim(),n=(_=t.persona)==null?void 0:_.trim(),a=(v=t.portrait)==null?void 0:v.trim(),s=(c=t.background)==null?void 0:c.trim(),o=t.traits??[],r=t.skills??[],d=Object.entries(t.stats_raw??{}).filter(([l,g])=>Number.isFinite(g)).filter(([l])=>!um.has(l.toLowerCase()));return i`
    <div class="trpg-actor">
      ${a?i`
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
        <${Nt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${ym} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${$m} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${hm} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${Fn(e)}</div>`:null}
      ${s?i`<div class="trpg-actor-meta">Background: ${s}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${d.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${d.map(([l,g])=>i`
                <span class="trpg-custom-stat-chip">${Fn(l)} ${g}</span>
              `)}
            </div>
          </div>
        `:null}
      ${o.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${o.map(l=>i`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Fn(l)}</span>
                  <span class="trpg-annot-desc">${cm(l)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(l=>i`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Fn(l)}</span>
                  <span class="trpg-annot-desc">${dm(l)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function bm({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function nr({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?i`<div class="empty-state" style="font-size:13px">${e}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var s;return i`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${vm(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Gs(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(s=n.dice_roll.rolls)==null?void 0:s.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${j} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function km({events:t}){const e="__none__",n=ls.value,a=cs.value,s=ds.value,o=Array.from(new Set(t.map(Gs).map(c=>c.trim()).filter(c=>c!==""))).sort((c,l)=>c.localeCompare(l)),r=Array.from(new Set(t.map(c=>(c.type??"").trim()).filter(c=>c!==""))).sort((c,l)=>c.localeCompare(l)),d=t.some(c=>(c.type??"").trim()===""),p=Array.from(new Set(t.map(c=>(c.phase??"").trim()).filter(c=>c!==""))).sort((c,l)=>c.localeCompare(l)),_=t.some(c=>(c.phase??"").trim()===""),v=t.filter(c=>{if(n!=="all"&&Gs(c)!==n)return!1;const l=(c.type??"").trim(),g=(c.phase??"").trim();if(a===e){if(l!=="")return!1}else if(a!=="all"&&l!==a)return!1;if(s===e){if(g!=="")return!1}else if(s!=="all"&&g!==s)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${c=>{ls.value=c.target.value}}>
          <option value="all">all</option>
          ${o.map(c=>i`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${c=>{cs.value=c.target.value}}>
          <option value="all">all</option>
          ${d?i`<option value=${e}>(none)</option>`:null}
          ${r.map(c=>i`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${s} onChange=${c=>{ds.value=c.target.value}}>
          <option value="all">all</option>
          ${_?i`<option value=${e}>(none)</option>`:null}
          ${p.map(c=>i`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{ls.value="all",cs.value="all",ds.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${v.length} / 전체 ${t.length}
      </span>
    </div>
    <${nr} events=${v.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function xm({outcome:t}){if(!t)return null;const e=o=>{const r=o.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",s=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${s?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${s}</div>`:null}
    </div>
  `}function ar({state:t}){const e=t.history??[];return e.length===0?null:i`
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
  `}function Sm({state:t,nowMs:e}){var _;const n=Kt.value||((_=t.session)==null?void 0:_.room)||"",a=On.value,s=t.party??[];if(!s.find(v=>v.id===Se.value)&&s.length>0){const v=s[0];v&&(Se.value=v.id)}const r=async()=>{var c,l;if(!n){A("Room ID가 비어 있습니다.","error");return}if(!Qn(e))return;const v=((c=t.current_round)==null?void 0:c.phase)??((l=t.session)==null?void 0:l.status)??"unknown";if(Js("라운드 실행",n,v)){On.value="running";try{const g=await $l(n);Ws.value=g,On.value="ok";const b=te(g.summary)?g.summary:null,x=b?Sn(b,"advanced",!1):!1,C=b?ut(b,"progress_reason",""):"";A(x?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${C?`: ${C}`:""}`,x?"success":"warning"),zt()}catch(g){Ws.value=null,On.value="error";const b=g instanceof Error?g.message:"라운드 실행에 실패했습니다.";A(b,"error")}finally{Sa()}}},d=async()=>{var c,l;if(!n||!Qn(e))return;const v=((c=t.current_round)==null?void 0:c.phase)??((l=t.session)==null?void 0:l.status)??"unknown";if(Js("턴 강제 진행",n,v))try{await bl(n),A("턴을 다음 단계로 이동했습니다.","success"),zt()}catch{A("턴 이동에 실패했습니다.","error")}finally{Sa()}},p=async()=>{if(!n||!Qn(e))return;const v=Se.value.trim();if(!v){A("먼저 Actor를 선택하세요.","warning");return}const c=Number.parseInt(Qa.value,10),l=Number.parseInt(Ya.value,10);if(Number.isNaN(c)||Number.isNaN(l)){A("stat/dc는 숫자여야 합니다.","warning");return}const g=Number.parseInt(Mn.value,10),b=Mn.value.trim()===""||Number.isNaN(g)?void 0:g;try{await yl({roomId:n,actorId:v,action:Va.value.trim()||"ability_check",statValue:c,dc:l,rawD20:b}),A("주사위 판정을 기록했습니다.","success"),zt()}catch{A("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${v=>{Kt.value=v.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Se.value}
            onChange=${v=>{Se.value=v.target.value}}
          >
            <option value="">Actor 선택</option>
            ${s.map(v=>i`<option value=${v.id}>${v.name} (${v.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${Va.value}
              onInput=${v=>{Va.value=v.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Qa.value}
              onInput=${v=>{Qa.value=v.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Ya.value}
              onInput=${v=>{Ya.value=v.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Mn.value}
              onInput=${v=>{Mn.value=v.target.value}}
              onKeyDown=${v=>{v.key==="Enter"&&p()}}
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

      ${a!=="idle"?i`<div class="trpg-run-status ${a}">${a==="running"?"처리 중...":a==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function Am({state:t}){var s;const e=Kt.value||((s=t.session)==null?void 0:s.room)||"",n=jn.value,a=async()=>{if(!e){A("Room ID가 비어 있습니다.","warning");return}const o=qn.value.trim(),r=es.value.trim();if(!r&&!o){A("이름 또는 Actor ID를 입력하세요.","warning");return}const d=Number.parseInt(cn.value.trim(),10),p=Number.parseInt(os.value.trim(),10),_=Number.isFinite(p)?Math.max(1,p):20,v=Number.isFinite(d)?Math.max(0,Math.min(_,d)):_;let c={};try{c=pm(rs.value)}catch(l){A(l instanceof Error?l.message:"능력치 JSON 오류","error");return}jn.value="spawning";try{const l=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,g=await kl(e,{actor_id:o||void 0,name:r||void 0,role:ns.value,idempotencyKey:l,portrait:ss.value.trim()||void 0,background:is.value.trim()||void 0,hp:v,max_hp:_,alive:v>0,stats:Object.keys(c).length>0?c:void 0}),b=typeof g.actor_id=="string"?g.actor_id.trim():"";if(!b)throw new Error("생성 응답에 actor_id가 없습니다.");const x=as.value.trim();x&&await xl(e,b,x),Se.value=b,Yt.value=b,o||(qn.value=""),jn.value="ok",A(`Actor 생성 완료: ${b}`,"success"),await zt()}catch(l){jn.value="error",A(l instanceof Error?l.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${es.value}
            onInput=${o=>{es.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${ns.value}
            onChange=${o=>{ns.value=o.target.value}}
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
            value=${as.value}
            onInput=${o=>{as.value=o.target.value}}
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
              value=${qn.value}
              onInput=${o=>{qn.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${ss.value}
              onInput=${o=>{ss.value=o.target.value}}
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
              value=${cn.value}
              onInput=${o=>{cn.value=o.target.value}}
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
              value=${os.value}
              onInput=${o=>{const r=o.target.value;os.value=r,mm(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${is.value}
              onInput=${o=>{is.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${rs.value}
              onInput=${o=>{rs.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function wm({state:t,nowMs:e}){var l;const n=Kt.value||((l=t.session)==null?void 0:l.room)||"",a=t.join_gate,s=ts.value,o=te(s)?s:null,r=(t.party??[]).filter(g=>g.role!=="dm"),d=Yt.value.trim(),p=r.some(g=>g.id===d),_=p?d:d?"__manual__":"",v=async()=>{const g=Yt.value.trim(),b=zn.value.trim();if(!n||!g){A("Room/Actor가 필요합니다.","warning");return}$t.value="checking";try{const x=await Sl(n,g,b||void 0);ts.value=x,$t.value="ok",A("참가 가능 여부를 갱신했습니다.","success")}catch(x){$t.value="error";const C=x instanceof Error?x.message:"참가 가능 여부 확인에 실패했습니다.";A(C,"error")}},c=async()=>{var H,D;const g=Yt.value.trim(),b=zn.value.trim(),x=Za.value.trim();if(!n||!g||!b){A("Room/Actor/Keeper가 필요합니다.","warning");return}if(!Qn(e))return;const C=((H=t.current_round)==null?void 0:H.phase)??((D=t.session)==null?void 0:D.status)??"unknown";if(Js("Mid-Join 승인 요청",n,C)){$t.value="requesting";try{const q=await Al({room_id:n,actor_id:g,keeper_name:b,role:Xa.value,...x?{name:x}:{}});ts.value=q;const R=te(q)?Sn(q,"granted",!1):!1,I=te(q)?ut(q,"reason_code",""):"";R?A("Mid-Join이 승인되었습니다.","success"):A(`Mid-Join이 거절되었습니다${I?`: ${I}`:""}`,"warning"),$t.value=R?"ok":"error",zt()}catch(q){$t.value="error";const R=q instanceof Error?q.message:"Mid-Join 요청에 실패했습니다.";A(R,"error")}finally{Sa()}}};return i`
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
            value=${_}
            onChange=${g=>{const b=g.target.value;if(b==="__manual__"){(p||!d)&&(Yt.value="");return}Yt.value=b}}
          >
            <option value="">Actor 선택</option>
            ${r.map(g=>i`
              <option value=${g.id}>${g.name} (${g.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${_==="__manual__"?i`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${Yt.value}
                onInput=${g=>{Yt.value=g.target.value}}
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
            value=${zn.value}
            onInput=${g=>{zn.value=g.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Xa.value}
            onChange=${g=>{Xa.value=g.target.value}}
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
            value=${Za.value}
            onInput=${g=>{Za.value=g.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${v} disabled=${$t.value==="checking"||$t.value==="requesting"}>
              ${$t.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${c} disabled=${$t.value==="checking"||$t.value==="requesting"}>
              ${$t.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Sn(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Pt(o,"effective_score",0)}/${Pt(o,"required_points",0)}</span>
            ${ut(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${ut(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function sr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function ir({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function or(){const t=Ws.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=te(e)?e:null,s=(Array.isArray(t.statuses)?t.statuses:[]).filter(te).slice(-8),o=t.canon_check,r=te(o)?o:null,d=r&&Array.isArray(r.warnings)?r.warnings.filter(I=>typeof I=="string").slice(0,3):[],p=r&&Array.isArray(r.violations)?r.violations.filter(I=>typeof I=="string").slice(0,3):[],_=n?Sn(n,"advanced",!1):!1,v=n?ut(n,"progress_reason",""):"",c=n?ut(n,"progress_detail",""):"",l=n?Pt(n,"player_successes",0):0,g=n?Pt(n,"player_required_successes",0):0,b=n?Sn(n,"dm_success",!1):!1,x=n?Pt(n,"timeouts",0):0,C=n?Pt(n,"unavailable",0):0,H=n?Pt(n,"reprompts",0):0,D=n?Pt(n,"npc_attacks",0):0,q=n?Pt(n,"keeper_timeout_sec",0):0,R=n?Pt(n,"roll_audit_count",0):0;return i`
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
        ${v?i`<div style="margin-top:4px; font-size:12px;">${v}</div>`:null}
        ${c?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${c}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${H}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${D}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${q||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${R}</div></div>
      </div>

      ${s.length>0?i`
          <div class="trpg-round-list">
            ${s.map(I=>{const bt=ut(I,"status","unknown"),Ft=ut(I,"actor_id","-"),Jt=ut(I,"role","-"),kt=ut(I,"reason",""),xt=ut(I,"action_type",""),B=ut(I,"reply","");return i`
                <div class="trpg-round-item ${bt.includes("fallback")||bt.includes("timeout")?"failed":"active"}">
                  <span>${Ft} (${Jt})</span>
                  <span style="margin-left:auto; font-size:11px;">${bt}</span>
                  ${xt?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${xt}</div>`:null}
                  ${kt?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${kt}</div>`:null}
                  ${B?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${B.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${ut(r,"status","unknown")}</strong>
            </div>
            ${p.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${p.map(I=>i`<div>violation: ${I}</div>`)}
                </div>`:null}
            ${d.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${d.map(I=>i`<div>warning: ${I}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Tm({state:t,nowMs:e}){var r,d,p;const n=Kt.value||((r=t.session)==null?void 0:r.room)||"",a=((d=t.current_round)==null?void 0:d.phase)??((p=t.session)==null?void 0:p.status)??"unknown",s=Zo(e),o=gm(e);return i`
    <${w} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${s?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${s?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${s?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${o}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${a||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${s?i`<button class="trpg-run-btn recommend" onClick=${()=>_m(n,a)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{Sa(),A("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Cm({active:t}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>fm(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Nm({state:t}){const e=t.party??[],n=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${w} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${w} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${nr} events=${n.slice(-20)} />
        <//>

        ${t.map?i`
            <${w} title="맵" style="margin-top:16px;">
              <${bm} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${w} title="현재 라운드">
          <${ir} state=${t} />
        <//>

        <${w} title="기여도" style="margin-top:16px;">
          <${sr} state=${t} />
        <//>

        <${w} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>i`<${er} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?i`
            <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${ar} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Rm({state:t}){const e=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${w} title=${`이벤트 타임라인 (${e.length})`}>
          <${km} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${w} title="최근 라운드 결과">
          <${or} />
        <//>

        <${w} title="현재 라운드" style="margin-top:16px;">
          <${ir} state=${t} />
        <//>
      </div>
    </div>
  `}function Lm({state:t,nowMs:e}){const n=t.party??[];return i`
    <div>
      <${Tm} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${w} title="조작 패널">
            <${Sm} state=${t} nowMs=${e} />
          <//>

          <${w} title="Actor Spawn" style="margin-top:16px;">
            <${Am} state=${t} />
          <//>

          <${w} title="Mid-Join Gate" style="margin-top:16px;">
            <${wm} state=${t} nowMs=${e} />
          <//>

          <${w} title="최근 라운드 결과" style="margin-top:16px;">
            <${or} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${w} title="기여도" style="margin-top:0;">
            <${sr} state=${t} />
          <//>

          <${w} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>i`<${er} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?i`
              <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${ar} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Dm(){var d,p,_,v,c;const t=_o.value,e=ws.value;if(Ct(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const l=window.setInterval(()=>{Gi.value=Date.now()},1e3);return()=>{window.clearInterval(l)}},[]),e&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>zt()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],s=t.outcome,o=Xo.value,r=Gi.value;return i`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Kt.value||((d=t.session)==null?void 0:d.room)||"-"} · phase: ${((p=t.current_round)==null?void 0:p.phase)??((_=t.session)==null?void 0:_.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>zt()}>새로고침</button>
      </div>

      <${xm} outcome=${s} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((v=t.session)==null?void 0:v.status)??"active"}</div>
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

      <${Cm} active=${o} />

      ${o==="overview"?i`<${Nm} state=${t} />`:o==="timeline"?i`<${Rm} state=${t} />`:i`<${Lm} state=${t} nowMs=${r} />`}
    </div>
  `}const ci="masc_dashboard_agent_name";function Pm(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(ci);return e??n??"dashboard"}const mt=f(Pm()),dn=f(""),un=f(""),Aa=f(""),rr=f(null),wa=f(null),pn=f(!1),Ce=f(!1),mn=f(!1),vn=f(!1),Ta=f(!1),Ca=f(!1),Ea=f(!1);function Na(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function Yn(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function lr(t){return!t||t.length===0?"none":t.join(", ")}function Im(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Na(t.quiet_start)}-${Na(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${Yn(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${Yn(t.interval_s)}.`:`Lodge ticks every ${Yn(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function Fe(){Cn();try{await ve()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function di(t){const e=t.trim();mt.value=e,e&&localStorage.setItem(ci,e)}function Em(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Vs(){const t=mt.value.trim();if(t){mn.value=!0;try{const e=await Tl(t),n=Em(e);n&&di(n),Ea.value=!0,await Fe(),A(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";A(n,"error")}finally{mn.value=!1}}}async function Mm(){const t=mt.value.trim();if(t){vn.value=!0;try{await mo(t),Ea.value=!1,await Fe(),A(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";A(n,"error")}finally{vn.value=!1}}}async function Om(){const t=mt.value.trim();if(t)try{await mo(t)}catch{}localStorage.removeItem(ci),di("dashboard"),Ea.value=!1,await Vs()}async function zm(){const t=mt.value.trim();if(t){Ta.value=!0;try{await Cl(t),await Fe(),A("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";A(n,"error")}finally{Ta.value=!1}}}async function Ji(){const t=mt.value.trim(),e=dn.value.trim();if(!(!t||!e)){pn.value=!0;try{await po(t,e),dn.value="",await Fe(),A("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";A(a,"error")}finally{pn.value=!1}}}async function qm(){const t=un.value.trim(),e=Aa.value.trim()||"Created from dashboard";if(t){Ce.value=!0;try{await wl(t,e,1),un.value="",Aa.value="",await Fe(),A("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";A(a,"error")}finally{Ce.value=!1}}}async function Vi(){const t=mt.value.trim()||"dashboard";Ca.value=!0,wa.value=null;try{const e=await Tn({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=Zs(e.result);rr.value=n,await Fe(),n!=null&&n.skipped_reason?A(n.skipped_reason,"warning"):A(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";wa.value=n,A(n,"error")}finally{Ca.value=!1}}function jm({runtime:t}){var s,o;const e=rr.value??(t==null?void 0:t.last_tick_result)??null;if(wa.value)return i`<div class="control-result-box is-error">${wa.value}</div>`;if(!e)return i`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((s=e.skipped_rows)==null?void 0:s.slice(0,3))??[],a=((o=e.passed_rows)==null?void 0:o.slice(0,3))??[];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?i`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">Last acted: ${lr(e.acted_names)}</div>
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
  `}function Fm(t){return t.find(n=>n.name===Ye.value)??t[0]??null}function Km(){var a,s;const t=Wt.value,e=((a=ne.value)==null?void 0:a.lodge)??null,n=Fm(t);return Ct(()=>{Vs()},[]),Ct(()=>{var r;const o=((r=t[0])==null?void 0:r.name)??"";if(!Ye.value&&o){Kn(o);return}Ye.value&&!t.some(d=>d.name===Ye.value)&&Kn(o)},[t.map(o=>o.name).join("|")]),i`
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
          value=${mt.value}
          onInput=${o=>di(o.target.value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Vs()}}
            disabled=${mn.value||mt.value.trim()===""}
          >
            ${mn.value?"Joining...":Ea.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Mm()}}
            disabled=${vn.value||mt.value.trim()===""}
          >
            ${vn.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Om()}}
            disabled=${mn.value||vn.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{zm()}}
            disabled=${Ta.value||mt.value.trim()===""}
          >
            ${Ta.value?"Pinging...":"Heartbeat"}
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
            value=${dn.value}
            onInput=${o=>{dn.value=o.target.value}}
            onKeyDown=${o=>{o.key==="Enter"&&Ji()}}
            disabled=${pn.value}
          />
          <button
            class="control-btn"
            onClick=${()=>{Ji()}}
            disabled=${pn.value||dn.value.trim()===""||mt.value.trim()===""}
          >
            ${pn.value?"Sending...":"Send"}
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
          onInput=${o=>{Kn(o.target.value)}}
          disabled=${t.length===0}
        >
          ${t.length===0?i`<option value="">No keepers available</option>`:t.map(o=>i`<option value=${o.name}>${o.name}</option>`)}
        </select>

        <${Po} keeper=${n} />
        <${Eo}
          actor=${mt.value.trim()||"dashboard"}
          keeper=${n}
          onPokeLodge=${()=>{Vi()}}
        />
        <${Io}
          keeperName=${(n==null?void 0:n.name)??""}
          placeholder=${t.length===0?"No keeper is active yet":"Direct prompt for the selected keeper"}
        />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${Im(e)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${e!=null&&e.enabled?"enabled":"disabled"}</span>
          <span class="pill">every ${Yn(e==null?void 0:e.interval_s)}</span>
          <span class="pill">quiet ${Na(e==null?void 0:e.quiet_start)}-${Na(e==null?void 0:e.quiet_end)} KST</span>
          <span class="pill">${e!=null&&e.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${e!=null&&e.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${e!=null&&e.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${lr((s=e==null?void 0:e.last_tick_result)==null?void 0:s.acted_names)}
        </div>
        ${e!=null&&e.last_skip_reason?i`<div class="control-status-copy">Last skip reason: ${e.last_skip_reason}</div>`:null}

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{Vi()}}
            disabled=${Ca.value}
          >
            ${Ca.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${jm} runtime=${e} />
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
          value=${un.value}
          onInput=${o=>{un.value=o.target.value}}
          disabled=${Ce.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${Aa.value}
          onInput=${o=>{Aa.value=o.target.value}}
          disabled=${Ce.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${()=>{qm()}}
          disabled=${Ce.value||un.value.trim()===""}
        >
          ${Ce.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
  `}const Qi=[{id:"observe",label:"Observe",description:"Live health, execution state, and room-wide telemetry"},{id:"coordinate",label:"Coordinate",description:"Conversation, decisions, planning, and backlog context"},{id:"command",label:"Command",description:"Direct control surfaces and intervention workflows"}],Qs=[{id:"command",label:"Command",icon:"🧭",group:"command",description:"Company, platoon, squad, and agent command plane with operation and trace visibility"},{id:"overview",label:"Overview",icon:"🏠",group:"observe",description:"Room health, keeper pressure, and top-line execution status"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals, MDAL loops, and task backlog in one planning surface"},{id:"ops",label:"Ops",icon:"🎮",group:"command",description:"Guided operator controls for room, sessions, and keepers"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}],Yi="masc_dashboard_quick_actions_open";function Hm(){const t=qt.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${An.value} events</span>
    </div>
  `}function Um(){const t=Tt.value.tab,e=qt.value,n=Qs.find(r=>r.id===t),a=Qi.find(r=>r.id===(n==null?void 0:n.group)),[s,o]=Zi(()=>{const r=localStorage.getItem(Yi);return r!=="0"});return Ct(()=>{localStorage.setItem(Yi,s?"1":"0")},[s]),i`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${a?i`<span class="rail-section-chip">${a.label}</span>`:null}
        </div>
        ${Qi.map(r=>i`
          <div class="rail-nav-group" key=${r.id}>
            <div class="rail-group-label">${r.label}</div>
            <div class="rail-group-copy">${r.description}</div>
            <div class="rail-tab-list">
              ${Qs.filter(d=>d.group===r.id).map(d=>i`
                  <button
                    class="rail-tab-btn ${t===d.id?"active":""}"
                    onClick=${()=>Et(d.id)}
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
            <strong>${ht.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Keepers</span>
            <strong>${Wt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Tasks</span>
            <strong>${vt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Events</span>
            <strong>${An.value}</strong>
          </div>
        </div>
        <div class="rail-snapshot-copy">
          <span>Connection ${e?"healthy":"recovering"}</span>
          <span>${(a==null?void 0:a.label)??"Observe"} workspace active</span>
        </div>
        <div class="rail-inline-actions">
          <button
            class="rail-refresh-btn"
            onClick=${()=>{ve(),t==="command"&&kn(),t==="ops"&&Oe(),t==="board"&&Ot(),t==="trpg"&&zt(),t==="goals"&&(hn(),Ee())}}
          >
            Refresh Now
          </button>
          <button class="rail-secondary-btn" onClick=${()=>Et("ops")}>
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
        ${s?i`<div class="rail-fold-body"><${Km} /></div>`:i`<div class="rail-fold-hint">Use inline actions for quick room nudges. Open the Ops tab for structured intervention work.</div>`}
      </section>
    </aside>
  `}function Bm(){switch(Tt.value.tab){case"command":return i`<${Lu} />`;case"overview":return i`<${Pi} />`;case"ops":return i`<${Zu} />`;case"board":return i`<${_p} />`;case"agents":return i`<${Gp} />`;case"goals":return i`<${am} />`;case"trpg":return i`<${Dm} />`;default:return i`<${Pi} />`}}function Wm(){Ct(()=>{hr(),io(),ve();const n=hc();return yc(),()=>{Tr(),n(),bc()}},[]),Ct(()=>{const n=setInterval(()=>{const a=Tt.value.tab;a==="command"?kn():a==="ops"?Oe():a==="board"?Ot():a==="trpg"?zt():a==="goals"&&(hn(),Ee())},15e3);return()=>{clearInterval(n)}},[]),Ct(()=>{const n=Tt.value.tab;n==="command"&&kn(),n==="ops"&&Oe(),n==="board"&&Ot(),n==="trpg"&&zt(),n==="goals"&&(hn(),Ee())},[Tt.value.tab]);const t=Tt.value.tab,e=Qs.find(n=>n.id===t);return i`
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
            class="activity-panel-toggle ${Me.value?"active":""}"
            onClick=${Zc}
            title="Toggle Activity Panel"
          >
            Activity
          </button>
          <${Hm} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${Um} />
        <main class="dashboard-main">
          ${As.value&&!qt.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${Bm} />`}
        </main>
      </div>

      ${Me.value?i`
        <div class="activity-panel-backdrop" onClick=${Ci} />
        <aside class="activity-panel">
          <div class="activity-panel-header">
            <h3>Activity Feed</h3>
            <button class="activity-panel-close" onClick=${Ci}>Close</button>
          </div>
          <div class="activity-panel-body">
            <${Mp} />
          </div>
        </aside>
      `:null}

      <${Yc} />
      <${Rc} />
      <${Ac} />
    </div>
  `}const Xi=document.getElementById("app");Xi&&mr(i`<${Wm} />`,Xi);
